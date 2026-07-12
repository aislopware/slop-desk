import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// PURE host-window feed logic (docs/45): inclusion/flags/caps in ``WindowFeedSnapshotBuilder``,
/// byte-budgeted packing in ``WindowFeedChunkPacker``, and the TTL/generation rules in
/// ``WindowFeedCache``. Headless — no CGWindowList, no AppKit (hang-safety rule 6).
final class WindowFeedLogicTests: XCTestCase {
    private func source(
        id: UInt32 = 1,
        owner: String = "Ghostty",
        bundleID: String = "com.mitchellh.ghostty",
        layer: Int = 0,
        onScreen: Bool = true,
        title: String = "zsh",
        w: Int = 800,
        h: Int = 600,
        display: UInt8 = 0,
        hidden: Bool = false,
        frontmost: Bool = false,
        minimized: Bool = false,
        axListed: Bool = false,
    ) -> WindowFeedSourceWindow {
        WindowFeedSourceWindow(
            windowID: id, ownerName: owner, bundleID: bundleID, layer: layer, isOnScreen: onScreen,
            title: title, widthPt: w, heightPt: h, displayIndex: display, isAppHidden: hidden,
            isFrontmostApp: frontmost, isMinimized: minimized, isAXListed: axListed,
        )
    }

    // MARK: Builder — inclusion

    func testExcludesNonZeroLayersSystemAppsAndTinyWindows() {
        let records = WindowFeedSnapshotBuilder.records(from: [
            source(id: 1, layer: 25), // status item layer
            source(id: 2, owner: "Dock"),
            source(id: 3, owner: ""),
            source(id: 4, w: 79), // under the 80 pt floor
            source(id: 5, h: 20),
            source(id: 6), // the one real window
        ])
        XCTAssertEqual(records.map(\.windowID), [6])
    }

    func testInclusionPolicyMatchesThePickerPolicy() {
        // The feed and the picker share ONE policy — pin the exact picker semantics (docs/31 set +
        // the 80 pt floor) so a drift in either surface fails here.
        XCTAssertFalse(WindowFeedInclusionPolicy.includes(ownerName: "Window Server", widthPt: 500, heightPt: 500))
        XCTAssertFalse(WindowFeedInclusionPolicy.includes(ownerName: "Ghostty", widthPt: 79, heightPt: 500))
        XCTAssertTrue(WindowFeedInclusionPolicy.includes(ownerName: "Ghostty", widthPt: 80, heightPt: 80))
    }

    func testOffScreenWindowsNeedAXEvidence() {
        // The phantom-window junk filter (user report 2026-07-11: 16 of 27 records were Chrome tab
        // caches / panel services / `loginwindow`): an OFF-SCREEN window is listed only with AX
        // evidence — its app's `kAXWindows` sweep returned it (axListed) or called it minimized.
        // On-screen windows never need evidence.
        let records = WindowFeedSnapshotBuilder.records(from: [
            source(id: 1, onScreen: true), // on screen — always in
            source(id: 2, onScreen: false), // phantom: no evidence — OUT
            source(id: 3, onScreen: false, minimized: true), // real minimized window — in
            source(id: 4, onScreen: false, axListed: true), // real other-Space window — in
            source(id: 5, onScreen: false, hidden: true), // hidden app's PHANTOM: still no AX — OUT
            source(id: 6, onScreen: false, hidden: true, axListed: true), // hidden app's real window — in
        ])
        XCTAssertEqual(records.map(\.windowID), [1, 3, 4, 6])
    }

    func testOverlayAppsAndAsverifyPhantomsAreExcluded() {
        // User report 2026-07-12: two survivors of the AX-evidence gate were still junk — the
        // "Cua Driver" automation overlay (a REAL on-screen window, but a transparent full-display
        // cursor overlay — nothing to stream) and Finder's App Store `asverify` receipt-verification
        // window (AX-listed, never rendered).
        let records = WindowFeedSnapshotBuilder.records(from: [
            source(id: 1, owner: "Cua Driver", bundleID: "com.trycua.driver", title: "", w: 1920, h: 1080),
            source(
                id: 2,
                owner: "Finder",
                bundleID: "com.apple.finder",
                onScreen: false,
                title: "asverify",
                axListed: true,
            ),
            source(
                id: 3,
                owner: "Finder",
                bundleID: "com.apple.finder",
                title: "Downloads",
            ), // real Finder window stays
        ])
        XCTAssertEqual(records.map(\.windowID), [3])
    }

    // MARK: Builder — flags

    func testFlagsMapStateBits() {
        let records = WindowFeedSnapshotBuilder.records(from: [
            source(id: 1, onScreen: false, hidden: true, minimized: true),
        ])
        XCTAssertEqual(records[0].flags, [.minimized, .appHidden])
    }

    func testFocusedWindowIsTheFrontmostAppsFirstOnScreenWindowOnly() {
        let records = WindowFeedSnapshotBuilder.records(from: [
            source(id: 1, onScreen: true, frontmost: false),
            // frontmost app's MINIMIZED window: never focused (minimized also keeps it past the
            // off-screen AX-evidence gate, so this pin still exercises the focused-bit rule).
            source(id: 2, onScreen: false, frontmost: true, minimized: true),
            source(id: 3, onScreen: true, frontmost: true), // ← the focused one (first on-screen in z-order)
            source(id: 4, onScreen: true, frontmost: true), // same app, behind: frontmostApp but NOT focused
        ])
        XCTAssertEqual(records.map { $0.flags.contains(.focusedWindow) }, [false, false, true, false])
        XCTAssertEqual(records.map { $0.flags.contains(.frontmostApp) }, [false, true, true, true])
    }

    // MARK: Builder — caps + order

    func testStringCapsTruncateOnGraphemeBoundaries() {
        // 130 × "é" (2 UTF-8 bytes each) = 260 bytes — must cap to ≤ 120 with no split scalar.
        let long = String(repeating: "é", count: 130)
        let records = WindowFeedSnapshotBuilder.records(from: [
            source(owner: long, bundleID: long, title: long),
        ])
        let r = records[0]
        XCTAssertLessThanOrEqual(r.title.utf8.count, VideoControlMessage.feedTitleMaxBytes)
        XCTAssertLessThanOrEqual(r.bundleID.utf8.count, WindowFeedSnapshotBuilder.bundleIDMaxBytes)
        XCTAssertLessThanOrEqual(r.appName.utf8.count, WindowFeedSnapshotBuilder.appNameMaxBytes)
        XCTAssertTrue(r.title.allSatisfy { $0 == "é" }, "no replacement chars — truncation kept graphemes whole")
        // The capped record must round-trip the codec bit-exactly.
        let msg = VideoControlMessage.windowFeedSnapshot(
            generation: 1, chunkIndex: 0, chunkCount: 1, records: records,
        )
        XCTAssertEqual(try? VideoControlMessage.decode(msg.encode()), msg)
    }

    func testZOrderPreservedAndCappedAt64() {
        let many = (0..<200).map { source(id: UInt32($0)) }
        let records = WindowFeedSnapshotBuilder.records(from: many)
        XCTAssertEqual(records.count, WindowFeedSnapshotBuilder.maxRecords)
        XCTAssertEqual(records.map(\.windowID), (0..<64).map(UInt32.init), "input z-order preserved")
    }

    // MARK: Packer

    private func record(id: UInt32, title: String) -> HostWindowRecord {
        HostWindowRecord(
            windowID: id, widthPt: 100, heightPt: 100, flags: [.onScreen], displayIndex: 0,
            bundleID: "com.example.app", appName: "Example", title: title,
        )
    }

    func testEveryChunkFitsOneMuxDatagram() throws {
        // Worst realistic load: 64 records at the full wire caps.
        let records = (0..<64).map { i in
            HostWindowRecord(
                windowID: UInt32(i), widthPt: 3840, heightPt: 2160, flags: [.onScreen], displayIndex: 1,
                bundleID: String(repeating: "b", count: WindowFeedSnapshotBuilder.bundleIDMaxBytes),
                appName: String(repeating: "a", count: WindowFeedSnapshotBuilder.appNameMaxBytes),
                title: String(repeating: "t", count: VideoControlMessage.feedTitleMaxBytes),
            )
        }
        let chunks = WindowFeedChunkPacker.encodedChunks(generation: 5, records: records)
        XCTAssertGreaterThan(chunks.count, 1, "worst-case 64 records cannot fit one datagram")
        for chunk in chunks {
            // 5 = mux framing (u32 channelID + u8 tag) the transport adds around the payload.
            XCTAssertLessThanOrEqual(chunk.count + 5, VideoPacketizer.maxDatagramSize)
        }
        // Reassembling every chunk in order yields exactly the input records, all agreeing on count.
        var reassembled: [HostWindowRecord] = []
        for (i, chunk) in chunks.enumerated() {
            guard case let .windowFeedSnapshot(gen, index, count, recs) =
                try VideoControlMessage.decode(chunk)
            else {
                XCTFail("chunk \(i) decoded to a different case")
                return
            }
            XCTAssertEqual(gen, 5)
            XCTAssertEqual(Int(index), i)
            XCTAssertEqual(Int(count), chunks.count)
            reassembled += recs
        }
        XCTAssertEqual(reassembled, records)
    }

    func testEmptySnapshotIsOneEmptyChunk() throws {
        let chunks = WindowFeedChunkPacker.encodedChunks(generation: 1, records: [])
        XCTAssertEqual(chunks.count, 1)
        guard case let .windowFeedSnapshot(_, index, count, recs) = try VideoControlMessage.decode(chunks[0])
        else {
            XCTFail("decoded to a different case")
            return
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(recs.isEmpty)
    }

    // MARK: Cache — generation + TTL

    func testGenerationBumpsOnlyWhenRecordsChange() {
        var cache = WindowFeedCache(ttl: 1.0)
        XCTAssertTrue(cache.needsRebuild(now: 100))
        cache.fold([record(id: 1, title: "a")], now: 100)
        XCTAssertEqual(cache.generation, 1)
        // Identical fold refreshes the TTL but never bumps (an unchanged desktop stays "current").
        cache.fold([record(id: 1, title: "a")], now: 101.5)
        XCTAssertEqual(cache.generation, 1)
        XCTAssertFalse(cache.needsRebuild(now: 102.4))
        // A changed set bumps.
        cache.fold([record(id: 1, title: "b")], now: 103)
        XCTAssertEqual(cache.generation, 2)
    }

    func testTTLGatesRebuilds() {
        var cache = WindowFeedCache(ttl: 1.0)
        cache.fold([], now: 100)
        XCTAssertFalse(cache.needsRebuild(now: 100.9), "fresh within the TTL")
        XCTAssertTrue(cache.needsRebuild(now: 101.0), "stale at the TTL boundary")
    }

    func testReplyIsCurrentAckWhenGenerationsMatchElseChunks() {
        var cache = WindowFeedCache(ttl: 1.0)
        cache.fold([record(id: 1, title: "a")], now: 100)
        let current = cache.replyDatagrams(forKnownGeneration: 1)
        XCTAssertFalse(current.isSnapshot)
        XCTAssertEqual(current.payloads, [VideoControlMessage.windowFeedCurrent(generation: 1).encode()])
        let stale = cache.replyDatagrams(forKnownGeneration: 0)
        XCTAssertTrue(stale.isSnapshot)
        XCTAssertEqual(stale.payloads, cache.encodedChunks)
    }

    func testGenerationSkipsTheZeroSentinelOnWrap() {
        // Force the wrap path via fold-by-fold? 2^32 folds is absurd — pin the invariant on the
        // published API instead: a freshly built cache is never generation 0, and the reply for
        // knownGeneration 0 is ALWAYS a snapshot (0 must always mean "send me everything").
        var cache = WindowFeedCache(ttl: 1.0)
        cache.fold([], now: 100)
        XCTAssertNotEqual(cache.generation, 0)
        XCTAssertTrue(cache.replyDatagrams(forKnownGeneration: 0).isSnapshot)
    }
}
