import SlopDeskWorkspaceModel
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

    /// The "Release Stuck Input" escape hatch: `releaseStuckInput()` drives the LIVE published
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

    // The host REFUSED the session (helloAck accepted:false — window gone /
    // mux mint-failure refusal). The pane must LEAVE `.active` (the black dead surface) and fall
    // back to the placeholder with an error explaining why.
    func testNoteSessionRejectedLeavesActiveAndFallsBackToPickerWithError() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        XCTAssertNotNil(m.active)
        m.noteSessionRejected()
        XCTAssertNil(m.active, "a host refusal must leave .active — the pane falls back to the placeholder")
        XCTAssertNotNil(m.loadError, "loadError explains WHY (the target is gone on the host)")
    }

    func testNoteSessionRejectedIsInertWhenNothingIsActive() {
        // A late/duplicate refusal after the user already closed the pane must not stamp a stale
        // error onto a fresh picker (or crash).
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.noteSessionRejected()
        XCTAssertNil(m.active)
        XCTAssertNil(m.loadError, "no refusal error without a live session to refuse")

        m.open()
        m.close()
        m.noteSessionRejected()
        XCTAssertNil(m.active)
        XCTAssertNil(m.loadError, "a refusal landing after close() is a no-op")
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

    // MARK: Paste-as-keystrokes read-only / teardown gate

    /// **A read-only lock landing MID-PASTE must withhold the remaining keystrokes.** The read-only
    /// seam enforces this by clearing ``RemoteWindowModel/keyInjector`` (the sink). Before the fix the
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

    /// **Tearing the pane down (`close()`) MID-PASTE must cancel the in-flight paste.** Before the fix
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

    // MARK: - Fullscreen auto-arm (docs/DECISIONS.md 2026-07-22)

    /// Entering native fullscreen arms the EFFECTIVE immersive wish without touching the latched
    /// toggle or the persistence sink; exiting returns to the latched value.
    func testFullscreenArmsEffectiveImmersiveWithoutPersisting() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        var persisted: [VideoPaneModes] = []
        m.onModesChanged = { persisted.append($0) }

        m.noteFullscreenPresentation(true)
        XCTAssertTrue(m.immersiveEffective, "fullscreen arms capture")
        XCTAssertFalse(m.immersiveDesired, "…without flipping the latched toggle")
        XCTAssertEqual(persisted, [], "…and without a persistence write (never latched)")

        m.noteFullscreenPresentation(false)
        XCTAssertFalse(m.immersiveEffective, "exit returns to the latched value")
    }

    /// The in-session escape hatch WINS: an explicit immersive-off while fullscreen drops the
    /// auto-arm too (the Moonlight lesson — capture with no in-stream off switch traps the user).
    func testExplicitImmersiveOffClearsTheFullscreenArm() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        m.noteFullscreenPresentation(true)
        XCTAssertTrue(m.immersiveEffective)

        m.setImmersiveDesired(false)
        XCTAssertFalse(m.immersiveEffective, "the user's OFF beats the fullscreen arm")

        m.noteFullscreenPresentation(true)
        XCTAssertTrue(m.immersiveEffective, "re-entering fullscreen re-arms")
    }

    /// A latched immersive toggle survives the fullscreen round-trip untouched.
    func testLatchedImmersiveSurvivesFullscreenRoundTrip() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        m.setImmersiveDesired(true)
        m.noteFullscreenPresentation(true)
        m.noteFullscreenPresentation(false)
        XCTAssertTrue(m.immersiveDesired, "the latch is the user's, fullscreen never rewrites it")
        XCTAssertTrue(m.immersiveEffective)
    }

    /// The kbps dirty-guard behind the connection surface's bitrate reading.
    ///
    /// This lived in `Apps/ClientApp-iOS/Tests/ConnectionPillTests.swift` because the SwiftUI
    /// `ConnectionPill` was iOS-only. The pill is gone and the assertion never touched it — it is
    /// plain `SlopDeskWorkspaceCore` logic — so keeping it in the iOS bundle only meant it ran under
    /// `slopdesk-gate ios-tests` and nowhere else. Here it runs on every `swift test`.
    func testNoteStreamKbpsKeepsZeroAndDropsNegative() {
        let m = RemoteWindowModel(target: { self.target })
        XCTAssertNil(m.streamKbps)
        m.noteStreamKbps(2400)
        XCTAssertEqual(m.streamKbps, 2400)
        // Idle-skip: a real 0 reading REPLACES the last value (the instrument shows the stream breathing).
        m.noteStreamKbps(0)
        XCTAssertEqual(m.streamKbps, 0)
        // Nonsense negative is dropped — the last reading stands.
        m.noteStreamKbps(-5)
        XCTAssertEqual(m.streamKbps, 0)
    }
}

// MARK: - Test support

/// Records the per-key edges the model injects through ``RemoteWindowModel/keyInjector`` (no real
/// CGEvent / secure field — pure value capture for the paste-leak regression tests).
@MainActor
private final class StrokeRecorder {
    struct Edge: Equatable {
        var keyCode: UInt16
        var down: Bool
    }

    var events: [Edge] = []
}
