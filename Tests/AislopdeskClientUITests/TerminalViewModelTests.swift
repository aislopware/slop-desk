import XCTest
import AislopdeskClient
import AislopdeskTerminal
@testable import AislopdeskClientUI

/// State-transition tests for the `@MainActor @Observable` ``TerminalViewModel``: it folds
/// `AislopdeskClient.Event`s + `output` chunks into observable connection / title / byte-count /
/// exit state. Driven synchronously via `handle`/`ingestOutput` (the same path
/// `observe(client:)` uses), so the transitions are deterministic and need no network.
@MainActor
final class TerminalViewModelTests: XCTestCase {

    func testFirstOutputFlipsConnectingToConnected() {
        let model = TerminalViewModel()
        XCTAssertEqual(model.connectionStatus, .idle)

        // observe() sets .connecting; simulate that precondition.
        model.markReconnecting()
        XCTAssertEqual(model.connectionStatus, .reconnecting)

        model.ingestOutput(Data("hello".utf8))
        XCTAssertEqual(model.connectionStatus, .connected, "first byte after reconnecting → connected")
        XCTAssertEqual(model.bytesReceived, 5)
    }

    func testTitleEvent() {
        let model = TerminalViewModel()
        model.handle(.title("~/proj — zsh"))
        XCTAssertEqual(model.title, "~/proj — zsh")
    }

    func testBellEventSetsAndClears() {
        let model = TerminalViewModel()
        XCTAssertFalse(model.bellPending)
        model.handle(.bell)
        XCTAssertTrue(model.bellPending)
        model.clearBell()
        XCTAssertFalse(model.bellPending)
    }

    func testExitEvent() {
        let model = TerminalViewModel()
        model.handle(.exit(code: 130))
        XCTAssertEqual(model.connectionStatus, .exited(code: 130))
    }

    func testDisconnectedEvent() {
        let model = TerminalViewModel()
        model.handle(.disconnected(reason: "stream ended (FIN)"))
        XCTAssertEqual(model.connectionStatus, .disconnected(reason: "stream ended (FIN)"))
    }

    func testReconnectedEventRestoresConnectedAndResumeSeq() {
        let model = TerminalViewModel()
        let sid = UUID()
        model.handle(.disconnected(reason: "drop"))
        model.markReconnecting()
        model.handle(.reconnected(sessionID: sid, resumeFromSeq: 42))
        XCTAssertEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.sessionID, sid)
        XCTAssertEqual(model.lastResumeSeq, 42)
    }

    // MARK: OSC 133 shell activity (WF11)

    func testCommandStatusRunningSetsRunningActivity() {
        let model = TerminalViewModel()
        XCTAssertEqual(model.shellActivity, .idle, "a fresh model is idle")
        model.handle(.commandStatus(.running))
        XCTAssertEqual(model.shellActivity, .running)
        XCTAssertNil(model.lastCommand, "lastCommand is only set when a command FINISHES")
    }

    func testCommandStatusIdleClearsRunningAndRecordsLastCommand() {
        let model = TerminalViewModel()
        model.handle(.commandStatus(.running))
        model.handle(.commandStatus(.idle(exitCode: 0, durationMS: 12_000)))
        XCTAssertEqual(model.shellActivity, .idle)
        XCTAssertEqual(model.lastCommand?.exitCode, 0)
        XCTAssertEqual(model.lastCommand?.durationMS, 12_000)
    }

    func testCommandStatusIdlePreservesNilExit() {
        let model = TerminalViewModel()
        model.handle(.commandStatus(.running))
        model.handle(.commandStatus(.idle(exitCode: nil, durationMS: 300)))
        XCTAssertEqual(model.shellActivity, .idle)
        XCTAssertNil(model.lastCommand?.exitCode ?? nil)
        XCTAssertEqual(model.lastCommand?.durationMS, 300)
    }

    func testMarkReconnectingClearsStaleRunningActivity() {
        let model = TerminalViewModel()
        model.handle(.commandStatus(.running))
        XCTAssertEqual(model.shellActivity, .running)
        // A drop mid-command must not leave the indicator stuck running across the reconnect.
        model.markReconnecting()
        XCTAssertEqual(model.shellActivity, .idle)
    }

    func testExitClearsStaleRunningActivity() {
        let model = TerminalViewModel()
        model.handle(.commandStatus(.running))
        XCTAssertEqual(model.shellActivity, .running)
        // `exit` itself emits OSC 133;C with no matching ;D (the shell dies first); the pane must
        // not be left showing "running…" on a dead shell (HW-confirmed on Mac Studio).
        model.handle(.exit(code: 0))
        XCTAssertEqual(model.shellActivity, .idle, "an exited shell runs nothing")
        XCTAssertEqual(model.connectionStatus, .exited(code: 0))
    }

    func testDisconnectClearsStaleRunningActivity() {
        let model = TerminalViewModel()
        model.handle(.commandStatus(.running))
        model.handle(.disconnected(reason: "FIN"))
        XCTAssertEqual(model.shellActivity, .idle, "a drop mid-command must not pin the indicator on running")
    }

    func testResetClearsShellActivityAndLastCommand() {
        let model = TerminalViewModel()
        model.handle(.commandStatus(.running))
        model.handle(.commandStatus(.idle(exitCode: 1, durationMS: 5_000)))
        model.reset()
        XCTAssertEqual(model.shellActivity, .idle)
        XCTAssertNil(model.lastCommand)
    }

    func testOutputFeedsSurface() {
        final class CapturingSurface: TerminalSurface, @unchecked Sendable {
            var fed = Data()
            func feed(_ bytes: Data) { fed.append(bytes) }
            func setSize(cols: UInt16, rows: UInt16) {}
            func handleInput(_ bytes: Data) {}
            var onWrite: ((Data) -> Void)?
        }
        let surface = CapturingSurface()
        let model = TerminalViewModel(surface: surface)
        model.ingestOutput(Data([0x41, 0x42]))
        model.ingestOutput(Data([0x43]))
        XCTAssertEqual(surface.fed, Data([0x41, 0x42, 0x43]), "model mirrors output into the renderer seam")
        XCTAssertEqual(model.bytesReceived, 3)
    }

    func testSendInputRoutesThroughInputSinkInOrder() {
        let model = TerminalViewModel()
        var captured = Data()
        model.inputSink = { captured.append($0) }
        model.sendInput(Data([0x61, 0x62]))
        model.sendInput(Data([0x63]))
        XCTAssertEqual(captured, Data([0x61, 0x62, 0x63]), "sendInput funnels through inputSink, in order")
    }

    func testSendInputWithoutSinkIsNoOp() {
        let model = TerminalViewModel()
        // Disconnected (no inputSink): keystrokes are dropped, never crash.
        model.sendInput(Data([0x61]))
        XCTAssertNil(model.inputSink)
    }

    func testSendResizeRoutesThroughResizeSink() {
        let model = TerminalViewModel()
        var captured: [(cols: UInt16, rows: UInt16)] = []
        model.resizeSink = { captured.append((cols: $0, rows: $1)) }
        model.sendResize(cols: 120, rows: 40)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.cols, 120)
        XCTAssertEqual(captured.first?.rows, 40)
    }

    func testSendResizeWithoutSinkIsNoOp() {
        let model = TerminalViewModel()
        model.sendResize(cols: 80, rows: 24)
        XCTAssertNil(model.resizeSink)
    }

    func testSendResizeCoalescesConsecutiveDuplicates() {
        let model = TerminalViewModel()
        var calls: [(cols: UInt16, rows: UInt16)] = []
        model.resizeSink = { calls.append((cols: $0, rows: $1)) }
        model.sendResize(cols: 80, rows: 24)
        model.sendResize(cols: 80, rows: 24)   // duplicate (libghostty double-emits) → coalesced
        model.sendResize(cols: 100, rows: 30)  // changed → forwarded
        model.sendResize(cols: 100, rows: 30)  // duplicate → coalesced
        XCTAssertEqual(calls.count, 2, "consecutive duplicate resizes are coalesced")
        XCTAssertEqual(calls.first?.cols, 80)
        XCTAssertEqual(calls.last?.cols, 100)
    }

    func testResetReArmsResize() {
        let model = TerminalViewModel()
        var calls = 0
        model.resizeSink = { _, _ in calls += 1 }
        model.sendResize(cols: 80, rows: 24)
        model.reset()                          // a fresh session must re-assert its grid size
        model.sendResize(cols: 80, rows: 24)
        XCTAssertEqual(calls, 2, "reset re-arms coalescing so the same size re-sends on reconnect")
    }

    /// REGRESSION (render lộn xộn, 2026-06-07): libghostty's `resize_callback` fires during surface
    /// creation / initial layout — BEFORE `ConnectionViewModel.connect()` wires `resizeSink`. The old
    /// `sendResize` recorded `lastSentSize` even with a nil sink, so the grid was dropped AND the dedup
    /// then suppressed the real send once the sink appeared → the host PTY stayed at its 80×24 init
    /// size while libghostty rendered the true grid (overlapping glyphs, fzf drawn at the wrong row).
    /// Wiring the sink must FLUSH the latest pre-connect grid.
    func testPreConnectResizeIsFlushedWhenSinkWired() {
        let model = TerminalViewModel()
        var calls: [(cols: UInt16, rows: UInt16)] = []
        model.sendResize(cols: 137, rows: 42)            // fires before connect → no sink yet
        XCTAssertTrue(calls.isEmpty, "no sink yet → nothing forwarded")
        model.resizeSink = { calls.append((cols: $0, rows: $1)) }   // connect wires the sink
        XCTAssertEqual(calls.count, 1, "wiring the sink flushes the pre-connect grid to the host")
        XCTAssertEqual(calls.first?.cols, 137)
        XCTAssertEqual(calls.first?.rows, 42)
    }

    func testResetClearsState() {
        let model = TerminalViewModel()
        model.handle(.title("x"))
        model.ingestOutput(Data("abc".utf8))
        model.handle(.bell)
        model.reset()
        XCTAssertNil(model.title)
        XCTAssertEqual(model.bytesReceived, 0)
        XCTAssertFalse(model.bellPending)
        XCTAssertEqual(model.connectionStatus, .idle)
    }

    // MARK: Replay byte-ring (surface-rebuild survival)

    /// A surface seam that records EACH `feed(_:)` as a separate element, so a replay's chunk
    /// boundaries + ordering (and the DECSTR prefix) are observable — `CapturingSurface` in
    /// `testOutputFeedsSurface` concatenates, which would hide them.
    private final class RecordingSurface: TerminalSurface, @unchecked Sendable {
        var feeds: [Data] = []
        func feed(_ bytes: Data) { feeds.append(bytes) }
        func setSize(cols: UInt16, rows: UInt16) {}
        func handleInput(_ bytes: Data) {}
        var onWrite: ((Data) -> Void)?
    }

    /// DECSTR — Soft Terminal Reset (`ESC [ ! p`), the replay prefix.
    private static let decstr = Data([0x1B, 0x5B, 0x21, 0x70])

    func testRingRetainsFedChunksUpToBound() {
        let model = TerminalViewModel()
        model.maxRingBytes = 1024
        model.ingestOutput(Data("aaa".utf8))
        model.ingestOutput(Data("bbbb".utf8))
        // Nothing evicted: under the bound. ringByteCount tracks the exact sum.
        XCTAssertEqual(model.ringByteCount, 7)
    }

    func testRingEvictsOldestWholeChunksOverBound() {
        let model = TerminalViewModel()
        model.maxRingBytes = 10
        model.ingestOutput(Data("aaaa".utf8))  // 4  → ring=[aaaa] (4)
        model.ingestOutput(Data("bbbb".utf8))  // +4 → ring=[aaaa,bbbb] (8)
        model.ingestOutput(Data("cccc".utf8))  // +4 → 12 > 10 → evict "aaaa" → ring=[bbbb,cccc] (8)
        XCTAssertEqual(model.ringByteCount, 8, "evicted exactly the oldest WHOLE chunk to get back under bound")

        // Attach a fresh surface and confirm the evicted chunk is gone, the surviving two replay
        // (in FIFO order) after the DECSTR prefix.
        let surface = RecordingSurface()
        model.attachSurface(surface)
        XCTAssertEqual(surface.feeds, [Self.decstr, Data("bbbb".utf8), Data("cccc".utf8)])
    }

    func testAttachSurfaceReplaysRingInFIFOOrderWithDecstrPrefix() {
        let model = TerminalViewModel()
        model.ingestOutput(Data("one".utf8))
        model.ingestOutput(Data("two".utf8))
        model.ingestOutput(Data("three".utf8))

        let surface = RecordingSurface()
        model.attachSurface(surface)
        // First a DECSTR soft reset, then every retained chunk in the order it arrived.
        XCTAssertEqual(
            surface.feeds,
            [Self.decstr, Data("one".utf8), Data("two".utf8), Data("three".utf8)],
            "replay = DECSTR prefix then ring chunks in FIFO order"
        )
    }

    func testReAttachAfterDetachReplaysPriorOutput() {
        let model = TerminalViewModel()
        // First surface receives live output, then the representable is dismantled.
        let first = RecordingSurface()
        model.attachSurface(first)              // empty ring → no replay
        XCTAssertTrue(first.feeds.isEmpty)
        model.ingestOutput(Data("live".utf8))   // fed live to `first`
        XCTAssertEqual(first.feeds, [Data("live".utf8)])
        model.detachSurface()

        // Tab re-appears: a BRAND-NEW empty surface must be repainted from the ring.
        let second = RecordingSurface()
        model.attachSurface(second)
        XCTAssertEqual(
            second.feeds,
            [Self.decstr, Data("live".utf8)],
            "a rebuilt surface replays the prior output the host did not re-send"
        )
    }

    func testAttachingSameSurfaceInstanceDoesNotReplay() {
        let model = TerminalViewModel()
        let surface = RecordingSurface()
        model.attachSurface(surface)
        model.ingestOutput(Data("x".utf8))     // fed live
        XCTAssertEqual(surface.feeds, [Data("x".utf8)])

        // Idempotent re-attach (SwiftUI updateNSView/updateUIView) of the SAME instance: the
        // bytes are already on screen — replaying would double them.
        model.attachSurface(surface)
        XCTAssertEqual(surface.feeds, [Data("x".utf8)], "same instance re-attach does not replay")
    }

    func testEmptyRingAttachFeedsNothing() {
        let model = TerminalViewModel()
        let surface = RecordingSurface()
        model.attachSurface(surface)
        XCTAssertTrue(surface.feeds.isEmpty, "no retained output → attach feeds nothing (not even DECSTR)")
    }

    /// REGRESSION (the multi-second-beachball "crash"): `surface` MUST be `@ObservationIgnored`.
    /// `attachSurface(_:)` both reads (`self.surface !== surface`) and writes (`self.surface = surface`)
    /// this property, and the renderer calls it from `GhosttyMetalLayerView.updateNSView` — i.e. from
    /// inside a SwiftUI AttributeGraph update. If `surface` were observation-tracked, that read would
    /// register the updating attribute as a dependency and the write would invalidate it, so SwiftUI
    /// would re-run the update → `updateNSView` → `attach` → `attachSurface` → invalidate → ∞ (an
    /// infinite re-render loop pinning the main thread — observed as a hang when a focus change / new
    /// pane / reconnect triggers `updateNSView`). Here: read `model.surface` INSIDE
    /// `withObservationTracking`; with `@ObservationIgnored` that read registers no dependency, so the
    /// `attachSurface` write must NOT fire `onChange`. Drop `@ObservationIgnored` and this fails.
    func testSurfaceMutationDoesNotTriggerObservation() {
        final class Flag: @unchecked Sendable { var fired = false }
        let model = TerminalViewModel()
        let surface = RecordingSurface()   // strong ref keeps the weak `model.surface` alive
        let flag = Flag()
        withObservationTracking {
            _ = model.surface
        } onChange: {
            flag.fired = true
        }
        model.attachSurface(surface)   // writes self.surface from "inside an update" (simulated)
        XCTAssertFalse(
            flag.fired,
            "surface must be @ObservationIgnored — mutating it during a SwiftUI update must not invalidate the graph (else updateNSView→attach→attachSurface→invalidate→∞ hangs the main thread)"
        )
    }

    /// RIS — Reset to Initial State (`ESC c`), fed on a fresh-session reconnect.
    private static let ris = Data([0x1B, 0x63])

    /// A real transport drop kills the host shell; the reconnect spawns a BRAND-NEW one whose
    /// output restarts at seq 1 (the mux path never resumes). The first fresh chunk must be
    /// preceded by a RIS hard reset and the dead session's replay ring must be dropped, so the user
    /// sees a clean shell — not the old framebuffer with a new prompt grafted on (audit finding #9).
    func testReconnectWipesDeadSessionScreenAndRingBeforeFreshOutput() {
        let model = TerminalViewModel()
        let surface = RecordingSurface()
        model.attachSurface(surface)                       // live surface, empty ring
        model.ingestOutput(Data("OLD-SESSION".utf8))       // dead session output (ring + surface)
        XCTAssertEqual(surface.feeds, [Data("OLD-SESSION".utf8)])
        XCTAssertEqual(model.ringByteCount, Data("OLD-SESSION".utf8).count)

        model.markReconnecting()                           // drop → reconnect campaign begins

        model.ingestOutput(Data("FRESH-PROMPT".utf8))      // first output of the fresh shell
        XCTAssertEqual(
            surface.feeds,
            [Data("OLD-SESSION".utf8), Self.ris, Data("FRESH-PROMPT".utf8)],
            "fresh-session reconnect feeds RIS before the new shell's first output"
        )
        XCTAssertEqual(
            model.ringByteCount, Data("FRESH-PROMPT".utf8).count,
            "the dead session's bytes are dropped from the ring; only the fresh chunk remains"
        )

        // One-shot: a SECOND fresh chunk does NOT re-trigger RIS.
        model.ingestOutput(Data("MORE".utf8))
        XCTAssertEqual(surface.feeds.filter { $0 == Self.ris }.count, 1, "RIS fires exactly once per reconnect")
    }

    /// A normal FIRST connect (no reconnect campaign) must NOT inject a RIS — only a reconnect does.
    func testFirstConnectDoesNotInjectHardReset() {
        let model = TerminalViewModel()
        let surface = RecordingSurface()
        model.attachSurface(surface)
        model.ingestOutput(Data("hello".utf8))
        XCTAssertEqual(surface.feeds, [Data("hello".utf8)], "no RIS on a fresh first connect")
    }

    func testResetClearsRing() {
        let model = TerminalViewModel()
        model.ingestOutput(Data("abc".utf8))
        XCTAssertEqual(model.ringByteCount, 3)
        model.reset()
        XCTAssertEqual(model.ringByteCount, 0, "reset clears the byte count")

        // And a post-reset attach replays nothing (the ring is empty).
        let surface = RecordingSurface()
        model.attachSurface(surface)
        XCTAssertTrue(surface.feeds.isEmpty, "reset cleared the ring → no replay")
    }

    func testLiveAttachStillFeedsNewChunks() {
        let model = TerminalViewModel()
        let surface = RecordingSurface()
        model.attachSurface(surface)            // empty ring → no replay
        model.ingestOutput(Data("a".utf8))
        model.ingestOutput(Data("b".utf8))
        XCTAssertEqual(
            surface.feeds,
            [Data("a".utf8), Data("b".utf8)],
            "after attach, live output still feeds straight through to the surface"
        )
    }
}
