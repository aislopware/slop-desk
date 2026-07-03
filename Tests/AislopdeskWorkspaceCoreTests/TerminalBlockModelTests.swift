import AislopdeskClient
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// WB2 — the PURE per-pane block model: upsert (running → complete transition), index ordering, the
/// bounded ring (mirrors the host's 64-block cap), `latest`/`navigatorBlocks`, the status → icon/label
/// mapping, and the copy-output request → resolve flow incl. empty-eviction (never hangs).
@MainActor
final class TerminalBlockModelTests: XCTestCase {
    // MARK: Upsert + running → complete

    func testUpsertAppendsNewBlocksInIndexOrder() {
        let model = TerminalBlockModel()
        model.upsert(index: 0, commandText: "a", exitCode: nil, durationMS: nil, complete: false, outputLen: 0)
        model.upsert(index: 1, commandText: "b", exitCode: nil, durationMS: nil, complete: false, outputLen: 0)
        model.upsert(index: 2, commandText: "c", exitCode: nil, durationMS: nil, complete: false, outputLen: 0)
        XCTAssertEqual(model.blocks.map(\.index), [0, 1, 2])
        XCTAssertEqual(model.blocks.map(\.commandText), ["a", "b", "c"])
        XCTAssertEqual(model.latest?.index, 2, "latest is the newest (highest) index")
    }

    func testUpsertUpdatesExistingBlockInPlace() {
        let model = TerminalBlockModel()
        // A running block then its completion update — same index updates in place (one block, not two).
        model.upsert(index: 5, commandText: "make", exitCode: nil, durationMS: nil, complete: false, outputLen: 8)
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.block(at: 5)?.status, .running)
        model.upsert(index: 5, commandText: "make", exitCode: 0, durationMS: 4200, complete: true, outputLen: 4096)
        XCTAssertEqual(model.blocks.count, 1, "the completion update mutates the existing block, not a new one")
        let block = model.block(at: 5)
        XCTAssertEqual(block?.status, .succeeded)
        XCTAssertEqual(block?.exitCode, 0)
        XCTAssertEqual(block?.durationMS, 4200)
        XCTAssertEqual(block?.outputLen, 4096)
    }

    func testInterruptedBlockWithDurationIsNotRunning() {
        // Bug 3: the host closes an interrupted (nested-shell / ssh) block as `complete == false`
        // but stamps a durationMS so the close is a distinct update. The client must treat a block
        // that has a duration as FINISHED (spinner off) — not perpetually "running…". Before the fix
        // `status` gated purely on `complete`, so a duration-stamped incomplete block spun forever
        // (and snapshotForResync re-armed the same stuck spinner on every reattach).
        let model = TerminalBlockModel()
        model.upsert(index: 0, commandText: "ssh host", exitCode: nil, durationMS: 2000, complete: false, outputLen: 12)
        XCTAssertNotEqual(
            model.block(at: 0)?.status,
            .running,
            "a duration-stamped incomplete block must not spin forever",
        )
        // A genuinely-running block (no duration yet) is still running.
        model.upsert(index: 1, commandText: "tail -f", exitCode: nil, durationMS: nil, complete: false, outputLen: 4)
        XCTAssertEqual(model.block(at: 1)?.status, .running, "a block with no duration is still running")
    }

    func testNavigatorBlocksAreNewestFirst() {
        let model = TerminalBlockModel()
        for i in 0..<4 {
            model.upsert(
                index: UInt32(i),
                commandText: "c\(i)",
                exitCode: 0,
                durationMS: 1,
                complete: true,
                outputLen: 0,
            )
        }
        XCTAssertEqual(model.navigatorBlocks.map(\.index), [3, 2, 1, 0], "navigator lists newest first")
    }

    // MARK: Bounded ring (evicts the oldest)

    func testRingIsBoundedAndEvictsOldest() {
        let model = TerminalBlockModel()
        let n = TerminalBlockModel.maxBlocks + 10
        for i in 0..<n {
            model.upsert(
                index: UInt32(i),
                commandText: "c\(i)",
                exitCode: 0,
                durationMS: 1,
                complete: true,
                outputLen: 0,
            )
        }
        XCTAssertEqual(model.blocks.count, TerminalBlockModel.maxBlocks, "the ring is capped at maxBlocks")
        // The oldest 10 were evicted; the newest is still index n-1.
        XCTAssertEqual(model.latest?.index, UInt32(n - 1))
        XCTAssertNil(model.block(at: 0), "the oldest block was evicted")
        XCTAssertNotNil(model.block(at: UInt32(n - 1)))
    }

    // MARK: handle(_:) folds only the two block events

    func testHandleFoldsCommandBlockEvent() {
        let model = TerminalBlockModel()
        model.handle(.commandBlock(
            index: 2, exitCode: 1, durationMS: 100, complete: true, outputLen: 3, commandText: "false",
            promptOrdinal: 5,
        ))
        XCTAssertEqual(model.block(at: 2)?.status, .failed(code: 1))
        XCTAssertEqual(model.block(at: 2)?.promptOrdinal, 5, "the prompt ordinal folds into the stored block")
        // A non-block event is ignored.
        model.handle(.title("ignored"))
        XCTAssertEqual(model.blocks.count, 1)
    }

    // MARK: Copy-output request → resolve flow

    func testRequestOutputResolvesWithRawBytes() {
        let model = TerminalBlockModel()
        var sent: [UInt32] = []
        var resolved: Data?
        var didResolve = false
        model.requestOutput(index: 4, send: { sent.append($0) }, completion: { result in
            resolved = result
            didResolve = true
        })
        XCTAssertEqual(sent, [4], "the request fires the wire send for this index")
        XCTAssertTrue(model.isOutputPending(index: 4))
        XCTAssertFalse(didResolve, "the request stays pending until the reply lands")

        model.resolveOutput(index: 4, output: Data("hello\n".utf8))
        XCTAssertTrue(didResolve)
        XCTAssertEqual(resolved, Data("hello\n".utf8))
        XCTAssertFalse(model.isOutputPending(index: 4), "resolving clears the pending slot")
    }

    func testEmptyReplyResolvesAsUnavailableNeverHangs() {
        // The empty-eviction path: an evicted/unknown block replies with empty output → resolve as nil
        // (unavailable), NOT a hang and NOT a spurious empty-Data result.
        let model = TerminalBlockModel()
        var didResolve = false
        var result: Data?
        model.requestOutput(index: 9, send: { _ in }, completion: { r in
            didResolve = true
            result = r
        })
        model.resolveOutput(index: 9, output: Data()) // empty == evicted/unknown
        XCTAssertTrue(didResolve, "an empty reply still invokes the completion (no hang)")
        XCTAssertNil(result, "empty output resolves as 'unavailable' (nil), not empty Data")
        XCTAssertFalse(model.isOutputPending(index: 9))
    }

    func testConcurrentRequestsForSameIndexCoalesceOntoOneSend() {
        let model = TerminalBlockModel()
        var sends = 0
        var resolves = 0
        model.requestOutput(index: 1, send: { _ in sends += 1 }, completion: { _ in resolves += 1 })
        model.requestOutput(index: 1, send: { _ in sends += 1 }, completion: { _ in resolves += 1 })
        XCTAssertEqual(sends, 1, "a second request for the same index does NOT re-send (coalesced)")
        model.resolveOutput(index: 1, output: Data("x".utf8))
        XCTAssertEqual(resolves, 2, "the single reply fans out to BOTH coalesced callbacks")
    }

    func testResolveForUnknownIndexIsDroppedNotCrash() {
        let model = TerminalBlockModel()
        // A stray / late type-29 for an index with no pending request must be a no-op (not a trap).
        model.resolveOutput(index: 123, output: Data("stray".utf8))
        XCTAssertFalse(model.isOutputPending(index: 123))
    }

    func testTimeoutResolvesPendingAsUnavailable() {
        let model = TerminalBlockModel()
        var didResolve = false
        var result: Data?
        model.requestOutput(index: 2, send: { _ in }, completion: { r in
            didResolve = true
            result = r
        })
        XCTAssertTrue(model.isOutputPending(index: 2))
        model.timeoutPending(index: 2)
        XCTAssertTrue(didResolve)
        XCTAssertNil(result, "a timeout resolves the pending request as unavailable")
        XCTAssertFalse(model.isOutputPending(index: 2))
        // A timeout AFTER a real resolve is a harmless no-op.
        model.timeoutPending(index: 2)
    }

    func testStaleTimeoutDoesNotKillAFreshRequestForSameIndex() {
        // The #5 race: copy#1 of block 3 schedules a 5s timeout; copy#1 then RESOLVES; copy#2 of the
        // SAME block 3 opens a fresh request; copy#1's stale timer must NOT resolve copy#2 as
        // "unavailable". The fix gates the timeout on the per-index request GENERATION captured at send.
        let model = TerminalBlockModel()
        var firstResult: Data?
        var firstResolved = false
        let gen1 = model.requestOutput(index: 3, send: { _ in }, completion: { r in
            firstResolved = true
            firstResult = r
        })
        // copy#1 resolves normally with real bytes.
        model.resolveOutput(index: 3, output: Data("first\n".utf8))
        XCTAssertTrue(firstResolved)
        XCTAssertEqual(firstResult, Data("first\n".utf8))

        // copy#2 opens a fresh pending request for the same index — a NEWER generation.
        var secondResult: Data?
        var secondResolved = false
        let gen2 = model.requestOutput(index: 3, send: { _ in }, completion: { r in
            secondResolved = true
            secondResult = r
        })
        XCTAssertNotEqual(gen1, gen2, "a fresh request for the same index gets a newer generation token")
        XCTAssertTrue(model.isOutputPending(index: 3))

        // copy#1's STALE timeout fires (its captured gen1). It must be a no-op — NOT resolve copy#2.
        model.timeoutPending(index: 3, generation: gen1)
        XCTAssertFalse(secondResolved, "the stale timer (gen1) must NOT resolve the fresh request (gen2)")
        XCTAssertTrue(model.isOutputPending(index: 3), "the fresh request is still in flight")

        // The fresh request still resolves on its own real reply.
        model.resolveOutput(index: 3, output: Data("second\n".utf8))
        XCTAssertTrue(secondResolved)
        XCTAssertEqual(secondResult, Data("second\n".utf8))

        // And copy#2's OWN timeout (gen2) WOULD have fired had the reply been lost — prove it is the
        // live token (a no-op now only because the request already resolved).
        XCTAssertNil(model.currentRequestGeneration(index: 3), "no request pending after resolve")
    }

    func testResetClearsBlocksAndStrandsNoPendingRequest() {
        let model = TerminalBlockModel()
        model.upsert(index: 0, commandText: "a", exitCode: 0, durationMS: 1, complete: true, outputLen: 0)
        var didResolve = false
        var result: Data?
        model.requestOutput(index: 7, send: { _ in }, completion: { r in
            didResolve = true
            result = r
        })
        model.reset()
        XCTAssertTrue(model.blocks.isEmpty, "reset drops the dead session's blocks")
        XCTAssertTrue(didResolve, "reset resolves every in-flight request (no strand)")
        XCTAssertNil(result, "the stranded request resolves as unavailable")
        XCTAssertFalse(model.isOutputPending(index: 7))
    }

    // MARK: First-seen timestamps (E9 Outline — client-receive time side-map)

    func testFirstSeenIsSetOnFirstUpsertAndStableAcrossUpdate() {
        let model = TerminalBlockModel()
        let t0 = Date(timeIntervalSince1970: 1000)
        model.now = { t0 }
        model.upsert(index: 0, commandText: "make", exitCode: nil, durationMS: nil, complete: false, outputLen: 0)
        XCTAssertEqual(model.firstSeen(index: 0), t0, "firstSeen is the client-receive time of the NEW index")

        // A later in-place update (running → complete) at a DIFFERENT clock must NOT move firstSeen.
        let t1 = Date(timeIntervalSince1970: 1050)
        model.now = { t1 }
        model.upsert(index: 0, commandText: "make", exitCode: 0, durationMS: 50000, complete: true, outputLen: 9)
        XCTAssertEqual(model.firstSeen(index: 0), t0, "an in-place update keeps the ORIGINAL first-seen time")
        XCTAssertNil(model.firstSeen(index: 99), "an unknown index has no first-seen time")
    }

    func testFirstSeenIsDroppedOnEviction() {
        let model = TerminalBlockModel()
        var clock = Date(timeIntervalSince1970: 0)
        model.now = { clock }
        let n = TerminalBlockModel.maxBlocks + 5
        for i in 0..<n {
            clock = Date(timeIntervalSince1970: TimeInterval(i))
            model.upsert(
                index: UInt32(i),
                commandText: "c\(i)",
                exitCode: 0,
                durationMS: 1,
                complete: true,
                outputLen: 0,
            )
        }
        // The oldest 5 indices were evicted from the ring — and their first-seen entries cleaned up with them.
        XCTAssertNil(model.block(at: 0), "the oldest block was evicted from the ring")
        XCTAssertNil(model.firstSeen(index: 0), "an evicted block's first-seen entry is cleaned up (no leak)")
        XCTAssertNil(model.firstSeen(index: 4), "all evicted indices' first-seen entries are cleaned up")
        XCTAssertNotNil(model.firstSeen(index: UInt32(n - 1)), "a live block keeps its first-seen entry")
    }

    func testFirstSeenIsClearedOnReset() {
        let model = TerminalBlockModel()
        let t0 = Date(timeIntervalSince1970: 500)
        model.now = { t0 }
        model.upsert(index: 0, commandText: "a", exitCode: 0, durationMS: 1, complete: true, outputLen: 0)
        XCTAssertEqual(model.firstSeen(index: 0), t0)
        model.reset()
        XCTAssertNil(model.firstSeen(index: 0), "reset clears the first-seen side-map along with the blocks")
    }

    // MARK: Status → icon / label mapping

    func testStatusDerivation() {
        XCTAssertEqual(
            CommandBlock(index: 0, commandText: "x", complete: false).status, .running,
        )
        XCTAssertEqual(
            CommandBlock(index: 0, commandText: "x", exitCode: 0, complete: true).status, .succeeded,
        )
        XCTAssertEqual(
            CommandBlock(index: 0, commandText: "x", exitCode: nil, complete: true).status, .succeeded,
            "a completed block with no reported exit code is treated as success",
        )
        XCTAssertEqual(
            CommandBlock(index: 0, commandText: "x", exitCode: 137, complete: true).status, .failed(code: 137),
        )
    }

    func testStatusSymbolAndLabel() {
        let running = CommandBlock(index: 0, commandText: "x", complete: false)
        XCTAssertEqual(running.statusLabel, "running…")
        XCTAssertFalse(running.statusSymbol.isEmpty)

        let ok = CommandBlock(index: 0, commandText: "x", exitCode: 0, durationMS: 250, complete: true)
        XCTAssertEqual(ok.statusSymbol, "checkmark.circle.fill")
        XCTAssertEqual(ok.statusLabel, "exit 0")

        let fail = CommandBlock(index: 0, commandText: "x", exitCode: 2, complete: true)
        XCTAssertEqual(fail.statusSymbol, "xmark.octagon.fill")
        XCTAssertEqual(fail.statusLabel, "exit 2")
    }

    func testDurationLabelFormatting() {
        XCTAssertNil(CommandBlock(index: 0, commandText: "x").durationLabel, "no duration while running/unknown")
        XCTAssertEqual(
            CommandBlock(index: 0, commandText: "x", durationMS: 340, complete: true).durationLabel, "340ms",
        )
        // `%.1f` of 1.250 rounds half-to-even → "1.2s"; 1300ms → "1.3s" (an unambiguous round).
        XCTAssertEqual(
            CommandBlock(index: 0, commandText: "x", durationMS: 1250, complete: true).durationLabel, "1.2s",
        )
        XCTAssertEqual(
            CommandBlock(index: 0, commandText: "x", durationMS: 1300, complete: true).durationLabel, "1.3s",
        )
    }
}
