import XCTest
@testable import SlopDeskWorkspaceCore

/// Pure-logic tests for the PATH 2 ``RemoteWindowModel``: field parsing, the `canOpen` gate,
/// and that `open()` builds a complete-endpoint ``RemoteWindowDescriptor`` (so the app factory
/// takes the LIVE `VideoWindowView(title:connection:)` path). No video frameworks involved.
@MainActor
final class RemoteWindowModelTests: XCTestCase {
    /// The host + UDP ports now come from the app-global ``ConnectionTarget``; only the windowID is
    /// per-pane, so `canOpen` is purely "is the window id parseable".
    private let target = ConnectionTarget(host: "h.local", port: 7420, mediaPort: 9000, cursorPort: 9001)

    func testCanOpenRequiresWindowID() {
        let m = RemoteWindowModel(target: { self.target }) // empty windowID
        XCTAssertFalse(m.canOpen)
        m.windowID = "12345"
        XCTAssertTrue(m.canOpen, "a valid window id ⇒ can open (host/ports come from the app target)")
    }

    func testCanOpenRejectsUnparseableWindowID() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "notanumber")
        XCTAssertFalse(m.canOpen)
        m.windowID = "1"
        XCTAssertTrue(m.canOpen)
    }

    /// C5 — the "Release Stuck Input" escape hatch: `releaseStuckInput()` drives the LIVE published
    /// sink exactly once per invocation, is a safe no-op with no sink (not streaming / read-only —
    /// the seam withholds it), and `canReleaseStuckInput` requires BOTH a streaming pane and a sink.
    func testReleaseStuckInputDrivesThePublishedSink() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.releaseStuckInput() // no sink yet — must not crash, nothing to fire
        XCTAssertFalse(m.canReleaseStuckInput, "no sink + not streaming ⇒ the palette row is inert")

        var fired = 0
        m.inputReleaseInjector = { fired += 1 }
        XCTAssertFalse(m.canReleaseStuckInput, "a sink alone is not enough — the pane must be streaming")
        m.open()
        XCTAssertTrue(m.canReleaseStuckInput, "streaming + live sink ⇒ the escape hatch is armed")

        m.releaseStuckInput()
        XCTAssertEqual(fired, 1, "one invocation fires the release exactly once")

        m.inputReleaseInjector = nil // teardown / read-only: the view (or seam) clears the sink
        m.releaseStuckInput()
        XCTAssertEqual(fired, 1, "a cleared sink makes the escape hatch inert again")
        XCTAssertFalse(m.canReleaseStuckInput)
    }

    func testOpenBuildsDescriptorFromAppTarget() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        guard let d = m.active else { XCTFail("open() should set active")
            return
        }
        XCTAssertEqual(d.windowID, 42)
        XCTAssertEqual(d.host, "h.local", "host comes from the app target")
        XCTAssertEqual(d.mediaPort, 9000)
        XCTAssertEqual(d.cursorPort, 9001)
        XCTAssertEqual(d.title, "Safari")
        XCTAssertTrue(d.hasEndpoint, "descriptor carries a live endpoint ⇒ factory takes live path")
    }

    func testOpenWithInvalidWindowIDIsNoOp() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "x")
        m.open()
        XCTAssertNil(m.active)
    }

    func testEmptyTitleFallsBackToWindowID() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "7", title: "")
        m.open()
        XCTAssertEqual(m.active?.title, "window 7")
    }

    func testCloseClearsActive() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        m.open()
        XCTAssertNotNil(m.active)
        m.close()
        XCTAssertNil(m.active)
    }

    // MARK: Host-window resize (numeric popover) — absolute resize sink + geometry mirror

    /// `resizeWindow(toWidth:height:)` drives the published resize sink with the ABSOLUTE point size (the
    /// popover's Apply path) — replacing the old `(phase,tx,ty)` drag. No sink wired ⇒ a silent no-op.
    func testResizeWindowDrivesInjectorWithAbsoluteSize() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        var requested: CGSize?
        m.resizeInjector = { w, h in requested = CGSize(width: w, height: h) }
        m.resizeWindow(toWidth: 1440, height: 900)
        XCTAssertEqual(requested, CGSize(width: 1440, height: 900))
        m.resizeInjector = nil
        m.resizeWindow(toWidth: 800, height: 600) // no sink ⇒ no-op, must not crash
    }

    /// `canResizeWindow` (the "Resize…" button gate) requires BOTH a live stream and a wired sink — so a
    /// read-only pane (sink withheld) or a not-yet-streaming pane hides the button.
    func testCanResizeWindowRequiresActiveAndSink() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        XCTAssertFalse(m.canResizeWindow, "no active stream, no sink")
        m.resizeInjector = { _, _ in }
        XCTAssertFalse(m.canResizeWindow, "sink but no active stream")
        m.open()
        XCTAssertTrue(m.canResizeWindow, "active stream + sink ⇒ resizable")
    }

    /// `noteWindowGeometry` mirrors the live window size (popover pre-fill) and the host display max
    /// (popover cap). A zero/unknown max leaves the cap unset; once a real max lands it PERSISTS — a later
    /// zero-max push (a fresh decoded-points before the next report) must not clear it.
    func testNoteWindowGeometryMirrorsCurrentAndPersistsMax() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        XCTAssertNil(m.windowPointSize)
        XCTAssertNil(m.windowMaxPointSize)
        m.noteWindowGeometry(currentW: 1280, currentH: 800, maxW: 0, maxH: 0)
        XCTAssertEqual(m.windowPointSize, CGSize(width: 1280, height: 800))
        XCTAssertNil(m.windowMaxPointSize, "a zero max leaves the popover uncapped")
        m.noteWindowGeometry(currentW: 1280, currentH: 800, maxW: 1920, maxH: 1080)
        XCTAssertEqual(m.windowMaxPointSize, CGSize(width: 1920, height: 1080))
        m.noteWindowGeometry(currentW: 1600, currentH: 1000, maxW: 0, maxH: 0)
        XCTAssertEqual(m.windowPointSize, CGSize(width: 1600, height: 1000), "current tracks the live size")
        XCTAssertEqual(m.windowMaxPointSize, CGSize(width: 1920, height: 1080), "max persists once known")
    }

    // MARK: Connection-section stats — host stream cadence (FPS)

    /// `noteStreamFps` mirrors the host-announced stream cadence for the sidebar Connection section's FPS row:
    /// `nil` until the first cadence lands, then tracks each announced value — but a non-positive value is
    /// IGNORED (a spurious zero must not blank the row; the last good reading stands).
    func testNoteStreamFpsTracksHostCadenceAndIgnoresNonPositive() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        XCTAssertNil(m.streamFps, "no cadence announced yet ⇒ no FPS row")
        m.noteStreamFps(30)
        XCTAssertEqual(m.streamFps, 30)
        m.noteStreamFps(60)
        XCTAssertEqual(m.streamFps, 60, "tracks the latest host-announced cadence")
        m.noteStreamFps(0)
        XCTAssertEqual(m.streamFps, 60, "a spurious zero is ignored — the last good reading stands")
        m.noteStreamFps(-5)
        XCTAssertEqual(m.streamFps, 60, "a negative cadence is ignored")
    }

    // MARK: Paste-as-keystrokes read-only / teardown gate (E21 WI-3 · F5-paste-leak)

    /// **F5 — a read-only lock landing MID-PASTE must withhold the remaining keystrokes.** The read-only
    /// seam enforces WI-3 by clearing ``RemoteWindowModel/keyInjector`` (the sink). Before the fix the
    /// paste loop captured the sink into a local at spawn and never re-read it, so toggling Read Only
    /// mid-paste kept injecting keystrokes (incl. into a SECURE field) for the rest of the paste. The
    /// fixed loop re-reads the LIVE sink each iteration and stops the instant it goes `nil`.
    ///
    /// Deterministic (no timing reliance): the injector clears the live sink on its FIRST call, so a
    /// faithful loop delivers only the first character's down+up (2 edges) and withholds the rest. On the
    /// un-fixed code the captured local kept firing → all 6 edges of "abc" landed (revert-to-confirm-fail).
    func testReadOnlyLockMidPasteWithholdsRemainingKeystrokes() async {
        let m = RemoteWindowModel(target: { self.target }, windowID: "9", pasteInterval: .zero)
        m.open()
        let recorder = StrokeRecorder()
        m.keyInjector = { [weak m] keyCode, down, _ in
            recorder.events.append(StrokeRecorder.Edge(keyCode: keyCode, down: down))
            m?.keyInjector = nil // the read-only seam nils the sink mid-paste
        }
        m.pasteAsKeystrokes("abc") // 3 mappable chars → 6 edges if uninterrupted
        for _ in 0..<200 where recorder.events.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(20)) // let any leaked extra edges land before asserting
        XCTAssertEqual(
            recorder.events.count, 2,
            "after the sink is cleared mid-paste only the first character's down+up reached the host",
        )
    }

    /// **F5 — tearing the pane down (`close()`) MID-PASTE must cancel the in-flight paste.** Before the fix
    /// `close()` left ``RemoteWindowModel/pasteTask`` running, so a closed pane kept injecting. Here the
    /// injector calls `close()` on its first stroke; the cancelled task must stop at the next iteration, so
    /// only the first character's 2 edges land. The un-fixed code (no cancel in `close()`, captured local
    /// sink) delivered all 6 edges of "abc".
    func testCloseMidPasteCancelsInFlightKeystrokes() async {
        let m = RemoteWindowModel(target: { self.target }, windowID: "9", pasteInterval: .zero)
        m.open()
        let recorder = StrokeRecorder()
        m.keyInjector = { [weak m] keyCode, down, _ in
            recorder.events.append(StrokeRecorder.Edge(keyCode: keyCode, down: down))
            m?.close() // pane torn down mid-paste must cancel the in-flight paste
        }
        m.pasteAsKeystrokes("abc")
        for _ in 0..<200 where recorder.events.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            recorder.events.count, 2,
            "close() cancels the in-flight paste — the remaining keystrokes are not injected",
        )
    }

    // MARK: awaitingResizeReflow (the resize-scrim "fresh pixels landed" signal — generic with terminal)

    /// The video analogue of the terminal scrim-hold: a resize arms the hold (the Metal view shows the
    /// last frame upscaled/blurry until the host re-captures), and the first frame at the new native size
    /// clears it. Drives the SAME `PaneContainer` scrim via `LivePaneSession.awaitingResizeReflow`.
    func testAwaitingReflowArmsOnResizeClearsOnRender() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        XCTAssertFalse(m.awaitingResizeReflow)
        m.noteResized() // the pane was resized → hold the scrim until the re-captured frame lands
        XCTAssertTrue(m.awaitingResizeReflow)
        m.noteRendered() // first frame at the new native size rendered
        XCTAssertFalse(m.awaitingResizeReflow, "the re-captured frame releases the scrim")
    }

    /// A closed window will never re-capture — `close()` must release the hold (not wait the safety timeout).
    func testAwaitingReflowClearsOnClose() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        m.noteResized()
        XCTAssertTrue(m.awaitingResizeReflow)
        m.close()
        XCTAssertFalse(m.awaitingResizeReflow)
    }

    /// Belt-and-braces: if the host never re-captures (frozen window / dropped UDP), the safety timeout
    /// still clears the hold so the scrim can never stick.
    func testAwaitingReflowSafetyTimeoutClears() async {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        m.reflowScrimTimeout = .milliseconds(20)
        m.noteResized()
        XCTAssertTrue(m.awaitingResizeReflow)
        // Poll up to ~1 s for the 20 ms safety timeout (robust under the full parallel suite — see the
        // terminal sibling test).
        for _ in 0..<100 where m.awaitingResizeReflow { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(m.awaitingResizeReflow, "the scrim never sticks if the host never re-captures")
    }

    func testTitleOnlyDescriptorHasNoEndpoint() {
        // The placeholder/preview path: a descriptor with no host is NOT live.
        let d = RemoteWindowDescriptor(title: "x", windowID: 3)
        XCTAssertFalse(d.hasEndpoint)
    }

    // MARK: - Picker discovery (docs/31) — the refresh()/pick() state machine via the injected seam

    /// `RemoteWindowDiscovery.shared` is a process-global static — reset it after every test so a stub
    /// set here never bleeds into another test (or the app's AppMain wiring).
    override func tearDown() {
        RemoteWindowDiscovery.shared = nil
        super.tearDown()
    }

    func testRefreshWithNoSeamSurfacesUnavailable() async {
        RemoteWindowDiscovery.shared = nil
        let m = RemoteWindowModel(target: { self.target })
        await m.refresh()
        XCTAssertTrue(m.availableWindows.isEmpty)
        XCTAssertFalse(m.isLoading)
        XCTAssertEqual(m.loadError, "Window discovery is unavailable — enter a window id manually.")
    }

    func testRefreshEmptyResultSurfacesNoWindows() async {
        RemoteWindowDiscovery.shared = { _, _, _ in [] }
        let m = RemoteWindowModel(target: { self.target })
        await m.refresh()
        XCTAssertTrue(m.availableWindows.isEmpty)
        XCTAssertFalse(m.isLoading)
        XCTAssertNotNil(m.loadError, "an empty list surfaces the 'no windows' hint (+ manual fallback)")
    }

    func testRefreshPopulatesAvailableWindows() async {
        let rows = [
            RemoteWindowSummary(windowID: 604, appName: "Google Chrome", title: "Claude", width: 1800, height: 943),
            RemoteWindowSummary(windowID: 464, appName: "Ghostty", title: "", width: 1408, height: 889),
        ]
        RemoteWindowDiscovery.shared = { host, media, cursor in
            XCTAssertEqual(host, "h.local")
            XCTAssertEqual(media, 9000)
            XCTAssertEqual(cursor, 9001)
            return rows
        }
        let m = RemoteWindowModel(target: { self.target })
        await m.refresh()
        XCTAssertEqual(m.availableWindows, rows, "the seam result populates the picker, queried with the app target")
        XCTAssertNil(m.loadError)
        XCTAssertFalse(m.isLoading)
    }

    func testPickFillsWindowIDAndTitleWithAppNameFallback() {
        let m = RemoteWindowModel(target: { self.target })
        m.pick(RemoteWindowSummary(windowID: 42, appName: "Safari", title: "Apple", width: 100, height: 50))
        XCTAssertEqual(m.windowID, "42")
        XCTAssertEqual(m.title, "Apple")
        XCTAssertTrue(m.canOpen, "a picked row makes the pane openable")

        m.pick(RemoteWindowSummary(windowID: 7, appName: "Finder", title: "", width: 100, height: 50))
        XCTAssertEqual(m.windowID, "7")
        XCTAssertEqual(m.title, "Finder", "an empty window title falls back to the app name")
        XCTAssertEqual(m.appName, "Finder", "pick records the owning app (PANE REBIND)")
    }

    // MARK: - PANE REBIND (2026-06-12): endpoint commit + stale-binding revalidation

    func testOpenCommitsEndpointWithAppName() {
        let m = RemoteWindowModel(target: { self.target })
        var committed: VideoEndpoint?
        m.onEndpointCommitted = { committed = $0 }
        m.pick(RemoteWindowSummary(windowID: 42, appName: "Safari", title: "Apple", width: 100, height: 50))
        m.open()
        XCTAssertEqual(
            committed,
            VideoEndpoint(windowID: 42, title: "Apple", appName: "Safari"),
            "open() persists the binding (app+title travel with the id)",
        )
    }

    func testRevalidateKeepsLiveBinding() async {
        RemoteWindowDiscovery.shared = { _, _, _ in
            [RemoteWindowSummary(windowID: 58, appName: "Code", title: "main.swift", width: 100, height: 50)]
        }
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "main.swift", appName: "Code")
        m.open()
        let outcome = await m.revalidateBinding()
        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(m.active?.windowID, 58, "a valid binding streams untouched")
    }

    func testRevalidateRebindsStaleIDAndRecommits() async {
        RemoteWindowDiscovery.shared = { _, _, _ in
            [RemoteWindowSummary(windowID: 77, appName: "Code", title: "new.swift — proj", width: 100, height: 50)]
        }
        // Restored binding: id 58 died with the host restart; 77 is the same app's window now.
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "old.swift — proj", appName: "Code")
        var committed: VideoEndpoint?
        m.onEndpointCommitted = { committed = $0 }
        m.open()
        let outcome = await m.revalidateBinding()
        XCTAssertEqual(outcome, .rebound)
        XCTAssertEqual(m.active?.windowID, 77, "the pane re-opened on the rebound window")
        XCTAssertEqual(committed?.windowID, 77, "the healed binding is persisted (stale id overwritten)")
        XCTAssertEqual(committed?.appName, "Code")
    }

    func testRevalidateUnbindsWhenAppGone() async {
        let rows = [RemoteWindowSummary(windowID: 9, appName: "Safari", title: "Apple", width: 100, height: 50)]
        RemoteWindowDiscovery.shared = { _, _, _ in rows }
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "main.swift", appName: "Code")
        m.open()
        let outcome = await m.revalidateBinding()
        XCTAssertEqual(outcome, .unbound)
        XCTAssertNil(m.active, "no window of that app remains — back to the picker form")
        XCTAssertEqual(m.availableWindows, rows, "the picker is pre-warmed with the fetched list")
        XCTAssertNotNil(m.loadError, "the form explains why the pane fell back")
    }

    // MARK: pickAndOpen — a fresh user pick revalidates against a stale list (2026-07-02 fix)

    // A live window the user picks stays live (the common case: the picked id is still open).
    func testPickAndOpenKeepsLiveWindow() async {
        let rows = [RemoteWindowSummary(windowID: 58, appName: "Code", title: "main.swift", width: 100, height: 50)]
        RemoteWindowDiscovery.shared = { _, _, _ in rows }
        let m = RemoteWindowModel(target: { self.target })
        m.pickAndOpen(rows[0])
        XCTAssertEqual(m.active?.windowID, 58, "opens optimistically")
        await m.revalidationTask?.value
        XCTAssertEqual(m.active?.windowID, 58, "a still-open window stays live after revalidation")
        XCTAssertNil(m.loadError)
    }

    // THE BUG: the picker list went stale — the window the user taps closed on the host after the fetch. A
    // bare pick+open would stream a permanent black pane; pickAndOpen revalidates and falls back to the picker
    // with an error (the re-pick affordance). Here the tapped id (58) is absent from the FRESH query.
    func testPickAndOpenUnbindsAndSurfacesErrorForStalePick() async {
        // The user's list still shows id 58, but by tap time the host only has a different app's window.
        let stale = RemoteWindowSummary(windowID: 58, appName: "Preview", title: "Doc.pdf", width: 100, height: 50)
        RemoteWindowDiscovery.shared = { _, _, _ in
            [RemoteWindowSummary(windowID: 9, appName: "Safari", title: "Apple", width: 100, height: 50)]
        }
        let m = RemoteWindowModel(target: { self.target })
        m.pickAndOpen(stale)
        XCTAssertEqual(m.active?.windowID, 58, "opens optimistically before the query lands")
        await m.revalidationTask?.value
        XCTAssertNil(m.active, "the picked window is gone on the host — fall back to the picker, no black pane")
        XCTAssertNotNil(m.loadError, "the picker explains why the pick fell back (re-pick affordance)")
    }

    // A recycled id (same app, new CGWindowID) re-binds instead of unbinding — the pick still lands live.
    func testPickAndOpenRebindsRecycledID() async {
        let stale = RemoteWindowSummary(
            windowID: 58, appName: "Code", title: "main.swift — proj", width: 100, height: 50,
        )
        RemoteWindowDiscovery.shared = { _, _, _ in
            [RemoteWindowSummary(windowID: 77, appName: "Code", title: "main.swift — proj", width: 100, height: 50)]
        }
        let m = RemoteWindowModel(target: { self.target })
        m.pickAndOpen(stale)
        await m.revalidationTask?.value
        XCTAssertEqual(m.active?.windowID, 77, "re-bound to the same app's live window")
        XCTAssertNil(m.loadError)
    }

    // MARK: Stale-verdict guard (2026-07-10): a close() racing the discovery await must stay closed

    /// **THE BUG:** `revalidateBinding()` suspended on the discovery query and then acted on the verdict
    /// UNCONDITIONALLY — closing the pane while the query was in flight let a `.rebind` verdict silently
    /// re-open the video stream on a torn-down pane. The outer task is NOT cancelled here (the model's own
    /// `revalidationTask` is unrelated to this direct call), isolating the IN-BODY liveness guard: the
    /// generation snapshot taken before the await must invalidate the verdict landing after `close()`.
    func testCloseDuringRevalidationLeavesModelClosed() async {
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        let entered = expectation(description: "discovery query suspended in flight")
        RemoteWindowDiscovery.shared = { _, _, _ in
            entered.fulfill()
            var it = gateStream.makeAsyncIterator()
            _ = await it.next() // held open until the test releases the gate
            // A `.rebind`-shaped verdict: same app, recycled id — the poisonous case (it re-open()s).
            return [RemoteWindowSummary(windowID: 77, appName: "Code", title: "main.swift", width: 100, height: 50)]
        }
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "main.swift", appName: "Code")
        var commits = 0
        m.onEndpointCommitted = { _ in commits += 1 }
        m.open()
        XCTAssertEqual(commits, 1)
        let validation = Task { @MainActor in await m.revalidateBinding() }
        await fulfillment(of: [entered], timeout: 5)
        m.close() // the user tears the pane down while the query is suspended
        gate.yield() // …then the stale verdict lands
        let outcome = await validation.value
        XCTAssertEqual(outcome, .skipped, "a verdict landing after close() is stale — dropped, not acted on")
        XCTAssertNil(m.active, "the closed pane must NOT silently reactivate its video stream")
        XCTAssertEqual(commits, 1, "no new endpoint is committed after teardown")
    }

    /// The same race through the REAL spawn site: `pickAndOpen` starts `revalidationTask`, `close()`
    /// cancels it — but cancellation is cooperative and the discovery await isn't a reliable checkpoint
    /// (a plain closure can complete normally under cancellation), so the body must ALSO check
    /// `Task.isCancelled` / liveness after resuming instead of rebinding a torn-down pane.
    func testCloseDuringPickAndOpenRevalidationStaysClosed() async {
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        RemoteWindowDiscovery.shared = { _, _, _ in
            var it = gateStream.makeAsyncIterator()
            _ = await it.next() // under cancellation next() returns nil immediately — the query still "lands"
            return [RemoteWindowSummary(windowID: 77, appName: "Code", title: "main.swift", width: 100, height: 50)]
        }
        let m = RemoteWindowModel(target: { self.target })
        m.pickAndOpen(RemoteWindowSummary(windowID: 58, appName: "Code", title: "main.swift", width: 100, height: 50))
        XCTAssertEqual(m.active?.windowID, 58, "opens optimistically")
        m.close() // cancels revalidationTask — but the query result still lands afterwards
        gate.yield()
        await m.revalidationTask?.value
        XCTAssertNil(m.active, "close() during the post-pick revalidation must stay closed — no rebind revival")
    }

    func testRevalidateSkipsOnUnreachableHostOrNoSeam() async {
        // Empty list (host unreachable / discovery timeout): NOT evidence of staleness.
        RemoteWindowDiscovery.shared = { _, _, _ in [] }
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "t", appName: "Code")
        m.open()
        let unreachable = await m.revalidateBinding()
        XCTAssertEqual(unreachable, .skipped)
        XCTAssertEqual(m.active?.windowID, 58, "an unreachable host changes nothing")

        RemoteWindowDiscovery.shared = nil
        let noSeam = await m.revalidateBinding()
        XCTAssertEqual(noSeam, .skipped, "no seam ⇒ no-op")
    }
}

// MARK: - Picker filter (RemoteWindowModel.filtered — pure)

/// Pins the picker's filter-field policy: token-AND, case-insensitive, over title + app name.
@MainActor
final class RemoteWindowFilterTests: XCTestCase {
    private let windows = [
        RemoteWindowSummary(
            windowID: 1,
            appName: "Google Chrome",
            title: "Claude — research",
            width: 1800,
            height: 943,
        ),
        RemoteWindowSummary(windowID: 2, appName: "Ghostty", title: "", width: 1408, height: 889),
        RemoteWindowSummary(
            windowID: 3,
            appName: "Xcode",
            title: "SlopDesk — WorkspaceStore.swift",
            width: 1600,
            height: 1000,
        ),
        RemoteWindowSummary(
            windowID: 4,
            appName: "Google Chrome",
            title: "GitHub — slopdesk",
            width: 1280,
            height: 800,
        ),
    ]

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "").map(\.windowID), [1, 2, 3, 4])
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "   ").map(\.windowID), [1, 2, 3, 4])
    }

    func testMatchesTitleAndAppNameCaseInsensitively() {
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "claude").map(\.windowID), [1])
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "CHROME").map(\.windowID), [1, 4])
        XCTAssertEqual(
            RemoteWindowModel.filtered(windows, query: "ghostty").map(\.windowID),
            [2],
            "an empty title still matches via the app name",
        )
    }

    func testMultiTokenIsANDAcrossTitleAndApp() {
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "chrome github").map(\.windowID), [4])
        XCTAssertTrue(RemoteWindowModel.filtered(windows, query: "chrome xcode").isEmpty)
    }

    func testFilterEmptyMessageIsActionable() {
        // The empty-list message names the filter AND tells the user there ARE windows behind it (the list
        // only renders when discovery found ≥1), with the fix (clear the filter) and correct pluralization.
        let many = RemoteWindowModel.windowFilterEmptyMessage(filter: "xcode", totalCount: 4)
        XCTAssertTrue(many.contains("“xcode”"), "names the filter token")
        XCTAssertTrue(many.contains("clear the filter"), "points at the fix")
        XCTAssertTrue(many.contains("4 windows"), "tells the user how many windows the filter hid")

        let one = RemoteWindowModel.windowFilterEmptyMessage(filter: "  xcode  ", totalCount: 1)
        XCTAssertTrue(one.contains("“xcode”"), "the filter is trimmed before display")
        XCTAssertTrue(one.contains("1 window."), "singular when exactly one window is hidden")
    }
}

// MARK: - Test support

/// Records the per-key edges the model injects through ``RemoteWindowModel/keyInjector`` (no real
/// CGEvent / secure field — pure value capture for the F5 paste-leak regression tests).
@MainActor
private final class StrokeRecorder {
    struct Edge: Equatable {
        var keyCode: UInt16
        var down: Bool
    }

    var events: [Edge] = []
}
