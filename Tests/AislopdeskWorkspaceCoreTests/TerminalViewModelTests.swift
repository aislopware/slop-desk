import AislopdeskClient
import AislopdeskTerminal
import XCTest
@testable import AislopdeskWorkspaceCore

/// State-transition tests for the `@MainActor @Observable` ``TerminalViewModel``: it folds
/// `AislopdeskClient.Event`s + `output` chunks into observable connection / title / byte-count /
/// exit state. Driven synchronously via `handle`/`ingestOutput` (the same path
/// `observe(client:)` uses), so the transitions are deterministic and need no network.
@MainActor
final class TerminalViewModelTests: XCTestCase {
    func testSendInputOffersBytesToBroadcastTapAfterLocalSink() {
        let model = TerminalViewModel()
        var localOrder: [String] = []
        var sunk: [Data] = []
        var tapped: [Data] = []
        model.inputSink = { d in localOrder.append("local")
            sunk.append(d)
        }
        model.broadcastTap = { d in localOrder.append("tap")
            tapped.append(d)
        }
        model.sendInput(Data("x".utf8))
        XCTAssertEqual(sunk, [Data("x".utf8)], "the local pane still receives via inputSink")
        XCTAssertEqual(tapped, [Data("x".utf8)], "the same bytes are offered to the broadcast tap")
        XCTAssertEqual(localOrder, ["local", "tap"], "local delivery happens before the fan-out")
    }

    func testSendInputWithoutTapIsUnchanged() {
        let model = TerminalViewModel()
        var sunk: [Data] = []
        model.inputSink = { sunk.append($0) }
        model.sendInput(Data("y".utf8)) // no broadcastTap wired → no-op, no crash
        XCTAssertEqual(sunk, [Data("y".utf8)])
    }

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

    /// Regression: an empty .title("") used to store "" which PanePresentation.displayTitle
    /// discards — effectively silently clobbering the last real title.  After the fix an empty
    /// title message collapses to nil so the previous non-empty title is preserved.
    func testEmptyTitleDoesNotClobberPriorRealTitle() {
        let model = TerminalViewModel()
        // Establish a real title first.
        model.handle(.title("~/proj — zsh"))
        XCTAssertEqual(model.title, "~/proj — zsh", "precondition: real title stored")
        // A subsequent empty-title message must NOT overwrite it.
        model.handle(.title(""))
        XCTAssertEqual(
            model.title,
            "~/proj — zsh",
            "empty .title(\"\") must not shadow the previous real title",
        )
    }

    /// E14/K11 "Title — Shell Controlled" (default ON): when the toggle is OFF, an OSC 0/2 `.title` event is
    /// DROPPED client-side so a remote program cannot rewrite the tab/window title; when ON (the default), the
    /// title updates as before. Revert-to-confirm-fail: the un-gated `.title` handler updates the title
    /// regardless of the toggle, so the "OFF must not change" assert fails on it.
    func testTitleShellControlledGatesTitleUpdate() {
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.titleShellControlled) }
        let model = TerminalViewModel()
        // Default ON → the title flows through.
        model.handle(.title("first"))
        XCTAssertEqual(model.title, "first", "default ON lets the title through")
        // Gate OFF → a new title event is DROPPED, the prior title preserved.
        UserDefaults.standard.set(false, forKey: SettingsKey.titleShellControlled)
        model.handle(.title("hijacked"))
        XCTAssertEqual(model.title, "first", "Title — Shell Controlled OFF drops the OSC 0/2 title update")
        // Gate ON again → title updates resume.
        UserDefaults.standard.set(true, forKey: SettingsKey.titleShellControlled)
        model.handle(.title("second"))
        XCTAssertEqual(model.title, "second", "Title — Shell Controlled ON resumes title updates")
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
        model.handle(.commandStatus(.idle(exitCode: 0, durationMS: 12000)))
        XCTAssertEqual(model.shellActivity, .idle)
        XCTAssertEqual(model.lastCommand?.exitCode, 0)
        XCTAssertEqual(model.lastCommand?.durationMS, 12000)
    }

    func testCommandStatusIdlePreservesNilExit() {
        let model = TerminalViewModel()
        model.handle(.commandStatus(.running))
        model.handle(.commandStatus(.idle(exitCode: nil, durationMS: 300)))
        XCTAssertEqual(model.shellActivity, .idle)
        // `lastCommand?.exitCode` is `Int??`; the `?? nil` flattens it so `.some(nil)` (command
        // exists, no exit code yet) reads as nil. Removing it would assert on the OUTER optional.
        // swiftlint:disable:next redundant_nil_coalescing
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
        model.handle(.commandStatus(.idle(exitCode: 1, durationMS: 5000)))
        model.reset()
        XCTAssertEqual(model.shellActivity, .idle)
        XCTAssertNil(model.lastCommand)
    }

    func testDeliberateResetWipesStaleFramebufferOnFirstFreshOutput() {
        // REGRESSION: a deliberate reconnect (⇧⌘R / the recovery banner's Retry) of an exited pane left the
        // dead session's framebuffer on the ALWAYS-MOUNTED surface, then grafted the new prompt onto it,
        // because reset() DISARMED the fresh-session wipe. reset() must arm the wipe like markReconnecting().
        let surface = RecordingSurface()
        let model = TerminalViewModel(surface: surface)
        model.ingestOutput(Data("old-dead-session-screen".utf8)) // a prior session painted the surface
        surface.feeds.removeAll() // focus only on what happens post-reset
        model.reset() // deliberate connect/reconnect
        model.ingestOutput(Data("$ ".utf8)) // first output from the FRESH host shell
        XCTAssertEqual(
            surface.feeds.first,
            Self.ris,
            "the first fresh-session output hard-resets the stale surface before painting",
        )
        XCTAssertTrue(surface.feeds.contains(Data("$ ".utf8)), "then the new prompt paints over the clean surface")
    }

    func testOutputFeedsSurface() {
        final class CapturingSurface: TerminalSurface, @unchecked Sendable {
            var fed = Data()
            func feed(_ bytes: Data) { fed.append(bytes) }
            func setSize(cols _: UInt16, rows _: UInt16) {}
            func handleInput(_: Data) {}
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
        model.sendResize(cols: 80, rows: 24) // duplicate (libghostty double-emits) → coalesced
        model.sendResize(cols: 100, rows: 30) // changed → forwarded
        model.sendResize(cols: 100, rows: 30) // duplicate → coalesced
        XCTAssertEqual(calls.count, 2, "consecutive duplicate resizes are coalesced")
        XCTAssertEqual(calls.first?.cols, 80)
        XCTAssertEqual(calls.last?.cols, 100)
    }

    /// While a sidebar/inspector-divider drag is in flight the shell suspends resize forwarding: each
    /// cell-step `sendResize` is RECORDED but not forwarded, and resuming on release flushes the final grid
    /// exactly once. Fails if `setResizeSuspended` doesn't gate `deliverResizeIfNeeded`.
    func testResizeSuspendedHoldsForwardsThenFlushesFinalGridOnResume() {
        let model = TerminalViewModel()
        var calls: [(cols: UInt16, rows: UInt16)] = []
        model.resizeSink = { calls.append((cols: $0, rows: $1)) }

        model.sendResize(cols: 80, rows: 24) // baseline, delivered
        XCTAssertEqual(calls.count, 1)

        model.setResizeSuspended(true) // divider mouse-down
        model.sendResize(cols: 90, rows: 24) // each cell-step during the drag…
        model.sendResize(cols: 100, rows: 24)
        model.sendResize(cols: 110, rows: 24)
        XCTAssertEqual(calls.count, 1, "no grid is forwarded to the host while suspended")

        model.setResizeSuspended(false) // divider mouse-up
        XCTAssertEqual(calls.count, 2, "exactly ONE flush on release")
        XCTAssertEqual(calls.last?.cols, 110, "the flush forwards the grid the drag settled on")
    }

    /// A drag that nets no grid change (dragged out, then back to the start) forwards nothing on release —
    /// the dedup against `lastSentSize` survives the suspend window, so no spurious host reflow fires.
    func testResizeSuspendResumeWithNoNetChangeFlushesNothing() {
        let model = TerminalViewModel()
        var calls = 0
        model.resizeSink = { _, _ in calls += 1 }
        model.sendResize(cols: 80, rows: 24)
        XCTAssertEqual(calls, 1)

        model.setResizeSuspended(true)
        model.sendResize(cols: 95, rows: 24) // dragged out…
        model.sendResize(cols: 80, rows: 24) // …and back to where it started
        model.setResizeSuspended(false)
        XCTAssertEqual(calls, 1, "a drag that nets no grid change forwards nothing on release")
    }

    /// The renderer re-arms its post-resize present burst via `onResizeSettled`, fired exactly once when an
    /// interactive resize ENDS — and AFTER the settled grid has been flushed to the host, so the burst it
    /// arms can cover the host's SIGWINCH-redraw bytes (which that flush triggers, ~1 RTT later). Pins the
    /// "kéo xong không re-render" hardening: without the hook those late bytes can land after the
    /// layout-anchored burst has expired and never get presented (intermittent blank after resize).
    func testResizeSettledFiresOnceOnReleaseAfterFlush() {
        let model = TerminalViewModel()
        var flushedCols: [UInt16] = []
        model.resizeSink = { cols, _ in flushedCols.append(cols) }
        model.sendResize(cols: 80, rows: 24) // baseline, delivered (flushedCols == [80])

        var settledCount = 0
        var sinkCountAtSettle = -1
        model.onResizeSettled = {
            settledCount += 1
            sinkCountAtSettle = flushedCols.count // observe ordering: the flush ran BEFORE this fires
        }

        model.setResizeSuspended(true) // mouse-down — must NOT settle
        XCTAssertEqual(settledCount, 0, "suspending (mouse-down) does not settle")
        model.sendResize(cols: 120, rows: 24) // a cell-step during the drag (held, not forwarded)

        model.setResizeSuspended(false) // mouse-up — settles exactly once, after the flush
        XCTAssertEqual(settledCount, 1, "release fires onResizeSettled exactly once")
        XCTAssertEqual(flushedCols.last, 120, "the settled grid was flushed to the host…")
        XCTAssertEqual(sinkCountAtSettle, 2, "…BEFORE onResizeSettled fired (the flush is ordered first)")
    }

    /// Idempotency: a redundant resume (no suspend→resume transition) must NOT re-fire `onResizeSettled`.
    /// The begin/end bracket is called defensively (e.g. `AislopdeskSplitViewController.viewWillDisappear`),
    /// so a double-settle would arm a wasteful extra present burst on every spurious resume.
    func testResizeSettledDoesNotFireWithoutTransition() {
        let model = TerminalViewModel()
        model.resizeSink = { _, _ in }
        var settledCount = 0
        model.onResizeSettled = { settledCount += 1 }

        model.setResizeSuspended(false) // never suspended → no transition → no settle
        XCTAssertEqual(settledCount, 0)

        model.setResizeSuspended(true)
        model.setResizeSuspended(false) // one real transition → one settle
        XCTAssertEqual(settledCount, 1)
        model.setResizeSuspended(false) // redundant resume → no extra settle
        XCTAssertEqual(settledCount, 1)
    }

    // MARK: awaitingResizeReflow (the resize-scrim "fresh pixels landed" signal)

    /// The scrim-hold signal arms only on a grid CHANGE from a known prior size, and clears on the first
    /// host output after it (the reflow). The FIRST delivery (connect) paints from scratch and must NOT
    /// arm — else the scrim would flash on every connect. Pins the "overlay until re-render, not until
    /// resize-end" fix.
    func testAwaitingReflowArmsOnGridChangeAndClearsOnContent() {
        let model = TerminalViewModel()
        model.resizeSink = { _, _ in }

        model.sendResize(cols: 80, rows: 24) // FIRST delivery (previous == nil) — paints from scratch
        XCTAssertFalse(model.awaitingResizeReflow, "the first grid after connect must not arm the scrim")

        model.sendResize(cols: 120, rows: 24) // a real grid CHANGE from a known prior size → arm
        XCTAssertTrue(model.awaitingResizeReflow, "a committed grid change holds the scrim until the reflow")

        model.ingestOutput(Data("reflowed".utf8)) // host reflow bytes land
        XCTAssertFalse(model.awaitingResizeReflow, "the first content after the change releases the scrim")
    }

    /// The interactive divider commit (suspend → drag → release) arms the hold on the release FLUSH: held
    /// grids during the drag forward nothing, so nothing is awaited until the single release flush sends a
    /// changed grid. This is the path the deferred-host-send race lives on (the scrim must bridge the RTT).
    func testAwaitingReflowArmedByInteractiveDividerCommit() {
        let model = TerminalViewModel()
        model.resizeSink = { _, _ in }
        model.sendResize(cols: 80, rows: 24) // baseline (first delivery — no arm)
        XCTAssertFalse(model.awaitingResizeReflow)

        model.setResizeSuspended(true) // divider mouse-down
        model.sendResize(cols: 120, rows: 24) // a cell-step during the drag (held, not forwarded)
        XCTAssertFalse(model.awaitingResizeReflow, "nothing is sent while suspended → nothing to await")

        model.setResizeSuspended(false) // mouse-up: flush the changed grid → arm
        XCTAssertTrue(model.awaitingResizeReflow, "the release flush is a grid change → await the reflow")

        model.ingestOutput(Data([0x41]))
        XCTAssertFalse(model.awaitingResizeReflow, "the reflow content releases the scrim")
    }

    /// A drag that nets no grid change forwards nothing on release (dedup), so there is no reflow to await
    /// → the hold must NOT arm (else the scrim would stick for the full safety timeout over unchanged
    /// content).
    func testAwaitingReflowNotArmedWhenCommitNetsNoGridChange() {
        let model = TerminalViewModel()
        model.resizeSink = { _, _ in }
        model.sendResize(cols: 80, rows: 24)
        model.setResizeSuspended(true)
        model.sendResize(cols: 95, rows: 24) // dragged out…
        model.sendResize(cols: 80, rows: 24) // …and back to the start
        model.setResizeSuspended(false) // dedup → no sink fired → no arm
        XCTAssertFalse(model.awaitingResizeReflow, "a no-net-change commit reflows nothing → no scrim hold")
    }

    /// A dead link will never reflow — a disconnect / exit must release the hold immediately (not wait out
    /// the safety timeout), so a pane resized right as it drops can't sit under a stuck scrim.
    func testAwaitingReflowClearsOnDisconnectAndExit() {
        for drop in [AislopdeskClient.Event.disconnected(reason: "drop"), .exit(code: 1)] {
            let model = TerminalViewModel()
            model.resizeSink = { _, _ in }
            model.sendResize(cols: 80, rows: 24)
            model.sendResize(cols: 120, rows: 24) // arm
            XCTAssertTrue(model.awaitingResizeReflow)
            model.handle(drop)
            XCTAssertFalse(model.awaitingResizeReflow, "a dead link releases the scrim: \(drop)")
        }
    }

    /// Belt-and-braces: if the host answers a grid change with NO output (a frozen foreground app), the
    /// safety timeout still clears the hold so the scrim can never stick.
    func testAwaitingReflowSafetyTimeoutClearsWithoutContent() async {
        let model = TerminalViewModel()
        model.reflowScrimTimeout = .milliseconds(20)
        model.resizeSink = { _, _ in }
        model.sendResize(cols: 80, rows: 24)
        model.sendResize(cols: 120, rows: 24) // arm — but no content will arrive
        XCTAssertTrue(model.awaitingResizeReflow)
        // Poll up to ~1 s for the 20 ms safety timeout to fire — robust against MainActor contention under
        // the full parallel suite (a fixed sleep could race the timer on a loaded machine).
        for _ in 0..<100 where model.awaitingResizeReflow { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.awaitingResizeReflow, "the scrim never sticks when the host sends no reflow")
    }

    func testResetReArmsResize() {
        let model = TerminalViewModel()
        var calls = 0
        model.resizeSink = { _, _ in calls += 1 }
        model.sendResize(cols: 80, rows: 24)
        model.reset() // a fresh session must re-assert its grid size
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
        model.sendResize(cols: 137, rows: 42) // fires before connect → no sink yet
        XCTAssertTrue(calls.isEmpty, "no sink yet → nothing forwarded")
        model.resizeSink = { calls.append((cols: $0, rows: $1)) } // connect wires the sink
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
        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}
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
        model.ingestOutput(Data("aaaa".utf8)) // 4  → ring=[aaaa] (4)
        model.ingestOutput(Data("bbbb".utf8)) // +4 → ring=[aaaa,bbbb] (8)
        model.ingestOutput(Data("cccc".utf8)) // +4 → 12 > 10 → evict "aaaa" → ring=[bbbb,cccc] (8)
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
            "replay = DECSTR prefix then ring chunks in FIFO order",
        )
    }

    func testReAttachAfterDetachReplaysPriorOutput() {
        let model = TerminalViewModel()
        // First surface receives live output, then the representable is dismantled.
        let first = RecordingSurface()
        model.attachSurface(first) // empty ring → no replay
        XCTAssertTrue(first.feeds.isEmpty)
        model.ingestOutput(Data("live".utf8)) // fed live to `first`
        XCTAssertEqual(first.feeds, [Data("live".utf8)])
        model.detachSurface()

        // Tab re-appears: a BRAND-NEW empty surface must be repainted from the ring.
        let second = RecordingSurface()
        model.attachSurface(second)
        XCTAssertEqual(
            second.feeds,
            [Self.decstr, Data("live".utf8)],
            "a rebuilt surface replays the prior output the host did not re-send",
        )
    }

    func testAttachingSameSurfaceInstanceDoesNotReplay() {
        let model = TerminalViewModel()
        let surface = RecordingSurface()
        model.attachSurface(surface)
        model.ingestOutput(Data("x".utf8)) // fed live
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
        let surface = RecordingSurface() // strong ref keeps the weak `model.surface` alive
        let flag = Flag()
        withObservationTracking {
            _ = model.surface
        } onChange: {
            flag.fired = true
        }
        model.attachSurface(surface) // writes self.surface from "inside an update" (simulated)
        XCTAssertFalse(
            flag.fired,
            "surface must be @ObservationIgnored — mutating it during a SwiftUI update must not "
                + "invalidate the graph (else updateNSView→attach→attachSurface→invalidate→∞ "
                + "hangs the main thread)",
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
        model.attachSurface(surface) // live surface, empty ring
        model.ingestOutput(Data("OLD-SESSION".utf8)) // dead session output (ring + surface)
        XCTAssertEqual(surface.feeds, [Data("OLD-SESSION".utf8)])
        XCTAssertEqual(model.ringByteCount, Data("OLD-SESSION".utf8).count)

        model.markReconnecting() // drop → reconnect campaign begins

        model.ingestOutput(Data("FRESH-PROMPT".utf8)) // first output of the fresh shell
        XCTAssertEqual(
            surface.feeds,
            [Data("OLD-SESSION".utf8), Self.ris, Data("FRESH-PROMPT".utf8)],
            "fresh-session reconnect feeds RIS before the new shell's first output",
        )
        XCTAssertEqual(
            model.ringByteCount, Data("FRESH-PROMPT".utf8).count,
            "the dead session's bytes are dropped from the ring; only the fresh chunk remains",
        )

        // One-shot: a SECOND fresh chunk does NOT re-trigger RIS.
        model.ingestOutput(Data("MORE".utf8))
        XCTAssertEqual(surface.feeds.count(where: { $0 == Self.ris }), 1, "RIS fires exactly once per reconnect")
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
        model.attachSurface(surface) // empty ring → no replay
        model.ingestOutput(Data("a".utf8))
        model.ingestOutput(Data("b".utf8))
        XCTAssertEqual(
            surface.feeds,
            [Data("a".utf8), Data("b".utf8)],
            "after attach, live output still feeds straight through to the surface",
        )
    }

    // MARK: WB2 — copyBlockOutput (request → sanitized clipboard text; unavailable; #5 stale-timer)

    func testCopyBlockOutputRequestsThenSanitizesReply() {
        // With a live sink wired, copyBlockOutput fires a type-15 request for the index, and when the
        // host's type-29 reply lands it is VT-stripped to plain clipboard text via BlockOutputSanitizer.
        let model = TerminalViewModel()
        var requested: [UInt32] = []
        model.requestBlockOutputSink = { requested.append($0) }

        var result: String?
        var resolved = false
        model.copyBlockOutput(index: 4) { text in
            result = text
            resolved = true
        }
        XCTAssertEqual(requested, [4], "the copy fires a type-15 request for the right index")
        XCTAssertFalse(resolved, "stays pending until the host replies")

        // Host replies with colorized output (raw VT) → sanitized to plain text on resolve.
        let colored = Data("\u{1B}[32mok\u{1B}[0m\nline2\n".utf8)
        model.blocks.resolveOutput(index: 4, output: colored)
        XCTAssertTrue(resolved)
        XCTAssertEqual(result, "ok\nline2\n", "the VT colour runs are stripped for the clipboard")
    }

    func testCopyBlockOutputWithoutSinkResolvesUnavailableImmediately() {
        // No live connection (requestBlockOutputSink == nil): the copy resolves as "unavailable" (nil)
        // immediately WITHOUT registering a pending request — it must never hang waiting for a reply
        // that can't come.
        let model = TerminalViewModel()
        model.requestBlockOutputSink = nil

        var result: String? = "sentinel"
        var resolved = false
        model.copyBlockOutput(index: 9) { text in
            result = text
            resolved = true
        }
        XCTAssertTrue(resolved, "disconnected → resolves synchronously (no hang)")
        XCTAssertNil(result, "no sink → 'unavailable' (nil)")
        XCTAssertFalse(model.blocks.isOutputPending(index: 9), "no pending request was left stranded")
    }

    func testCopyBlockOutputStaleTimerDoesNotKillAFreshCopy() {
        // The #5 race at the view-model layer: copy#1 of a block resolves, copy#2 of the SAME block opens
        // a fresh request, and copy#1's (already-armed) 5s timeout must not resolve copy#2 as unavailable.
        // copyBlockOutput now captures the request generation and gates timeoutPending on it; we drive the
        // generation lifecycle directly (the real Task.sleep(5s) is irrelevant — only the gating matters).
        let model = TerminalViewModel()
        model.requestBlockOutputSink = { _ in }

        var firstResult: String?
        model.copyBlockOutput(index: 2) { firstResult = $0 }
        let staleGen = model.blocks.currentRequestGeneration(index: 2)
        XCTAssertNotNil(staleGen, "copy#1 is in flight with a generation token")
        model.blocks.resolveOutput(index: 2, output: Data("first\n".utf8))
        XCTAssertEqual(firstResult, "first\n")

        // copy#2 opens a fresh request for the same index (a newer generation).
        var secondResult: String? = "sentinel"
        var secondResolved = false
        model.copyBlockOutput(index: 2) { text in
            secondResult = text
            secondResolved = true
        }
        XCTAssertTrue(model.blocks.isOutputPending(index: 2))

        // copy#1's stale timer fires with the OLD generation → must be ignored.
        model.blocks.timeoutPending(index: 2, generation: staleGen)
        XCTAssertFalse(secondResolved, "the stale timer must not resolve the fresh copy")
        XCTAssertTrue(model.blocks.isOutputPending(index: 2))

        // The fresh copy still resolves on its real reply.
        model.blocks.resolveOutput(index: 2, output: Data("second\n".utf8))
        XCTAssertEqual(secondResult, "second\n")
    }
}
