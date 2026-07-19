import XCTest
@testable import SlopDeskWorkspaceCore

/// Pure-logic tests for the live per-session stream controls + the client-local stats mirror on
/// ``RemoteWindowModel``: the `noteNetworkStats` observables, the `streamSettingsInjector` /
/// `systemKeyInjector` sinks and their `can…` gates, and the seam's read-only withholding of the
/// two HOST-AFFECTING sinks (mirrors `ReadOnlyStoreTests`' videoLeaf discipline). No video
/// frameworks involved.
@MainActor
final class RemoteWindowStreamControlsTests: XCTestCase {
    private let target = ConnectionTarget(host: "h.local", port: 7420, mediaPort: 9000, cursorPort: 9001)

    // MARK: Stats mirror observables

    func testNoteNetworkStatsPopulatesTheObservables() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42")
        XCTAssertNil(m.statsFps, "no reading before the first push")
        m.noteNetworkStats(fps: 29.5, fecPerSec: 0.5, unrecoveredPerSec: 0.0, holdMs: 12, pacerDepth: 1)
        XCTAssertEqual(m.statsFps, 29.5)
        XCTAssertEqual(m.statsFecPerSec, 0.5)
        XCTAssertEqual(m.statsUnrecoveredPerSec, 0.0)
        XCTAssertEqual(m.statsHoldMs, 12)
        XCTAssertEqual(m.statsPacerDepth, 1)
    }

    func testNoteNetworkStatsKeepsZerosButDropsNegatives() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42")
        m.noteNetworkStats(fps: 30, fecPerSec: 1, unrecoveredPerSec: 1, holdMs: 8, pacerDepth: 1)
        // Zeros are REAL readings (an idle stream receives nothing) — they overwrite.
        m.noteNetworkStats(fps: 0, fecPerSec: 0, unrecoveredPerSec: 0, holdMs: 0, pacerDepth: 0)
        XCTAssertEqual(m.statsFps, 0)
        XCTAssertEqual(m.statsHoldMs, 0)
        // A negative axis is nonsense — the WHOLE reading is dropped (no half-applied mix).
        m.noteNetworkStats(fps: -1, fecPerSec: 2, unrecoveredPerSec: 2, holdMs: 2, pacerDepth: 2)
        XCTAssertEqual(m.statsFps, 0, "negative reading dropped wholesale")
        XCTAssertEqual(m.statsFecPerSec, 0)
    }

    // MARK: Stream-settings sink

    func testApplyStreamSettingsDrivesThePublishedSink() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.applyStreamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000) // no sink — must not crash
        XCTAssertFalse(m.canAdjustStreamSettings, "no sink + not streaming ⇒ the controls are inert")

        var received: [(Int, Int)] = []
        m.streamSettingsInjector = { received.append(($0, $1)) }
        XCTAssertFalse(m.canAdjustStreamSettings, "a sink alone is not enough — the pane must be streaming")
        m.open()
        XCTAssertTrue(m.canAdjustStreamSettings, "streaming + live sink ⇒ the controls are armed")
        m.applyStreamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000)
        m.applyStreamSettings(fpsCap: 0, bitrateCeilingBps: 0) // 0s = restore auto
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].0, 24)
        XCTAssertEqual(received[0].1, 8_000_000)
        XCTAssertEqual(received[1].0, 0)
        XCTAssertEqual(received[1].1, 0)
    }

    // MARK: Viewport lock (the model-owned "lock position" state)

    /// `toggleViewportLock()` flips the model's ``RemoteWindowModel/viewportLocked`` and drives the
    /// ABSOLUTE `lockOn`/`lockOff` bytes down the published viewport sink — one source of truth for the
    /// footer icon, the ⌥⌘L chord, and the menu row. Gated on `canControlViewport`: off-stream / sink-less
    /// flips are graceful no-ops (a lock the view never saw must not strand the mirror).
    func testToggleViewportLockFlipsStateAndSendsAbsoluteLockBytes() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.toggleViewportLock() // no sink + not streaming — must not crash, must not flip
        XCTAssertFalse(m.viewportLocked, "off-stream toggle is a graceful no-op")

        var received: [UInt8] = []
        m.viewportInjector = { received.append($0) }
        m.toggleViewportLock()
        XCTAssertFalse(m.viewportLocked, "a sink alone is not enough — the pane must be streaming")
        XCTAssertEqual(received, [], "nothing sent while the gate is closed")

        m.open()
        XCTAssertTrue(m.canControlViewport)
        m.toggleViewportLock()
        XCTAssertTrue(m.viewportLocked)
        m.toggleViewportLock()
        XCTAssertFalse(m.viewportLocked)
        XCTAssertEqual(
            received,
            [RemoteWindowModel.ViewportCommand.lockOn.rawValue, RemoteWindowModel.ViewportCommand.lockOff.rawValue],
            "absolute lock bytes, in flip order",
        )
    }

    /// Publishing a viewport sink RE-ASSERTS a held lock (`lockOn` fired into the fresh sink): a
    /// detach/reattach re-binds the SAME model to a fresh view that always starts unlocked, so without
    /// this the icon would say locked while the new view happily edge-pans. An unlocked model publishes
    /// nothing (the fresh view's default is already correct), and clearing the sink fires nothing.
    func testViewportSinkPublishReassertsAHeldLock() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        m.viewportInjector = { _ in }
        m.toggleViewportLock()
        XCTAssertTrue(m.viewportLocked)

        // The detach/reattach remount: a FRESH view publishes a replacement sink.
        var freshSink: [UInt8] = []
        m.viewportInjector = { freshSink.append($0) }
        XCTAssertEqual(
            freshSink, [RemoteWindowModel.ViewportCommand.lockOn.rawValue],
            "the held lock is re-asserted into the fresh sink",
        )

        m.close() // clears the sink (nil publish) — must not fire anything / crash
        XCTAssertNil(m.viewportInjector)

        // Unlocked model: a new publish stays silent (the fresh view's unlocked default is correct).
        let m2 = RemoteWindowModel(target: { self.target }, windowID: "7", title: "Safari")
        m2.open()
        var silent: [UInt8] = []
        m2.viewportInjector = { silent.append($0) }
        XCTAssertEqual(silent, [], "no lock held ⇒ nothing re-asserted")
    }

    // MARK: System-key sink

    func testCanInjectSystemKeysRequiresStreamingAndASink() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42")
        XCTAssertFalse(m.canInjectSystemKeys)
        var keys: [(UInt16, UInt64, Bool)] = []
        m.systemKeyInjector = { keys.append(($0, $1, $2)) }
        XCTAssertFalse(m.canInjectSystemKeys, "a sink alone is not enough — the pane must be streaming")
        m.open()
        XCTAssertTrue(m.canInjectSystemKeys)
        m.systemKeyInjector?(53, 0, true) // Escape down through the published sink
        m.systemKeyInjector?(53, 0, false)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].0, 53)
        XCTAssertTrue(keys[0].2)
        XCTAssertFalse(keys[1].2)
    }

    #if canImport(SwiftUI)

    // MARK: Read-only withholding at the seam (videoLeaf)

    /// **Read-only WITHHOLDS the stream-settings sink at the seam.** The settings drive changes
    /// HOST encode behaviour (fps cap / bitrate ceiling), so — exactly like the resize sink — the
    /// `.videoLeaf` derivation binds `nil` while read-only: the controls are inert on a locked pane
    /// (`canAdjustStreamSettings == false`) without the model ever learning the read-only state.
    func testReadOnlyWithholdsTheStreamSettingsSinkAtTheSeam() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "7", title: "Safari")
        m.open()
        let liveSink: (Int, Int) -> Void = { _, _ in }

        // WRITABLE: the seam binds the published sink → the controls are armed.
        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: false, bindKeyInjector: { _ in },
            bindStreamSettingsInjector: { m.streamSettingsInjector = $0 },
        ).onStreamSettingsInjectorReady?(liveSink)
        XCTAssertNotNil(m.streamSettingsInjector, "writable: the published sink reaches the model")
        XCTAssertTrue(m.canAdjustStreamSettings)

        // READ-ONLY: the seam withholds the sink (binds nil) EVEN THOUGH the view publishes a real one.
        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: true, bindKeyInjector: { _ in },
            bindStreamSettingsInjector: { m.streamSettingsInjector = $0 },
        ).onStreamSettingsInjectorReady?(liveSink)
        XCTAssertNil(m.streamSettingsInjector, "read-only: the seam clears the settings sink")
        XCTAssertFalse(m.canAdjustStreamSettings, "read-only: a locked pane cannot retune the host encode")
    }

    /// **Read-only WITHHOLDS the system-key sink at the seam.** The injector sends host KEY input,
    /// so — exactly like the paste-keystrokes sink — the `.videoLeaf` derivation binds `nil` while
    /// read-only (`canInjectSystemKeys == false`).
    func testReadOnlyWithholdsTheSystemKeySinkAtTheSeam() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "7", title: "Safari")
        m.open()
        let liveSink: (UInt16, UInt64, Bool) -> Void = { _, _, _ in }

        // WRITABLE: the seam binds the published sink → programmatic keys are armed.
        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: false, bindKeyInjector: { _ in },
            bindSystemKeyInjector: { m.systemKeyInjector = $0 },
        ).onSystemKeyInjectorReady?(liveSink)
        XCTAssertNotNil(m.systemKeyInjector, "writable: the published sink reaches the model")
        XCTAssertTrue(m.canInjectSystemKeys)

        // READ-ONLY: the seam withholds the sink (binds nil) EVEN THOUGH the view publishes a real one.
        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: true, bindKeyInjector: { _ in },
            bindSystemKeyInjector: { m.systemKeyInjector = $0 },
        ).onSystemKeyInjectorReady?(liveSink)
        XCTAssertNil(m.systemKeyInjector, "read-only: the seam clears the system-key sink")
        XCTAssertFalse(m.canInjectSystemKeys, "read-only: a locked pane cannot inject keys")
    }

    /// **Read-only KEEPS the stats push live.** The network-stats mirror is informational (never
    /// reaches the host), so — like the cadence/bitrate pushes — the seam binds it unconditionally:
    /// a locked pane's stats surface still tracks the stream.
    func testReadOnlyKeepsTheNetworkStatsPushLive() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "7", title: "Safari")
        m.open()
        let locked = RemotePaneContext.videoLeaf(
            isActive: true, readOnly: true, bindKeyInjector: { _ in },
            onNetworkStats: { fps, fec, unrec, holdMs, depth in
                m.noteNetworkStats(
                    fps: fps, fecPerSec: fec, unrecoveredPerSec: unrec, holdMs: holdMs, pacerDepth: depth,
                )
            },
        )
        locked.onNetworkStats?(30, 0, 0, 9, 1)
        XCTAssertEqual(m.statsFps, 30, "informational push flows on a read-only pane")
        XCTAssertEqual(m.statsHoldMs, 9)
    }
    #endif

    // MARK: close() owns sink teardown (the detach remount race)

    /// **`close()` clears every published sink — the MODEL owns teardown, not the view's dismantle.**
    /// During a pane detach/reattach the same model is re-bound by a view in another hosting root, and
    /// SwiftUI can dismantle the OLD view after the NEW one published fresh sinks — so
    /// `VideoWindowView.deactivate()` deliberately publishes nothing, and this clear is the single
    /// teardown path. A stale sink surviving close() would leak the dead pipeline it captures.
    func testCloseClearsEveryPublishedSink() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        m.keyInjector = { _, _, _ in }
        m.resizeInjector = { _, _ in }
        m.viewportInjector = { _ in }
        m.inputReleaseInjector = {}
        m.streamSettingsInjector = { _, _ in }
        m.systemKeyInjector = { _, _, _ in }

        m.close()

        XCTAssertNil(m.keyInjector)
        XCTAssertNil(m.resizeInjector)
        XCTAssertNil(m.viewportInjector)
        XCTAssertNil(m.inputReleaseInjector)
        XCTAssertNil(m.streamSettingsInjector)
        XCTAssertNil(m.systemKeyInjector)
        XCTAssertFalse(m.canPasteKeystrokes)
        XCTAssertFalse(m.canAdjustStreamSettings)
        XCTAssertFalse(m.canInjectSystemKeys)
    }

    /// **`close()` resets `viewportLocked`, mirroring the `audioStreamEnabled` reset.** Without it a lock
    /// set on window A silently re-applies itself (via ``RemoteWindowModel/viewportInjector``'s re-assert
    /// `didSet`) the instant a totally unrelated window B's view publishes its sink on the SAME reused
    /// model — freezing B's edge-hover auto-pan with no action from the user for B.
    func testCloseResetsViewportLocked() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        m.viewportInjector = { _ in }
        m.toggleViewportLock()
        XCTAssertTrue(m.viewportLocked, "precondition: locked")

        m.close()

        XCTAssertFalse(m.viewportLocked, "close() clears the lock — the next (re)bound window starts unlocked")

        // Proves the re-assert hazard is actually defused: publishing a fresh sink after close+reopen must
        // stay silent (an unlocked model asserts nothing), unlike ``testViewportSinkPublishReassertsAHeldLock``.
        m.open()
        var freshSink: [UInt8] = []
        m.viewportInjector = { freshSink.append($0) }
        XCTAssertEqual(freshSink, [], "no stale lock carries into the re-bound window")
    }

    /// **`close()` clears the cadence/bitrate/network-stats/geometry telemetry.** `ConnectionTelemetry`
    /// reads `streamFps`/`streamKbps` unconditionally (no gate on `active != nil`), so a closed/re-bound
    /// pane must not keep the titlebar/sidebar connection cluster showing the LAST session's numbers as if
    /// it were still streaming.
    func testCloseClearsStreamTelemetryAndGeometry() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        m.noteStreamFps(30)
        m.noteStreamKbps(4000)
        m.noteNetworkStats(fps: 29.5, fecPerSec: 0.5, unrecoveredPerSec: 0.0, holdMs: 12, pacerDepth: 1)
        m.noteWindowGeometry(currentW: 1280, currentH: 800, maxW: 1920, maxH: 1080)
        XCTAssertNotNil(m.streamFps)
        XCTAssertNotNil(m.windowPointSize)
        XCTAssertNotNil(m.windowMaxPointSize)

        m.close()

        XCTAssertNil(m.streamFps, "a closed pane must not keep showing the last session's cadence")
        XCTAssertNil(m.streamKbps)
        XCTAssertNil(m.statsFps)
        XCTAssertNil(m.statsFecPerSec)
        XCTAssertNil(m.statsUnrecoveredPerSec)
        XCTAssertNil(m.statsHoldMs)
        XCTAssertNil(m.statsPacerDepth)
        XCTAssertNil(m.windowPointSize)
        XCTAssertNil(m.windowMaxPointSize)
    }

    // MARK: Display switcher (desktop pane)

    /// **`switchDisplay(to:)` re-targets a desktop pane and re-commits its endpoint** (the persisted
    /// spec follows the new display); a window-target pane and a same-display switch are no-ops.
    func testSwitchDisplayRetargetsDesktopPaneAndRecommitsEndpoint() {
        let m = RemoteWindowModel(target: { self.target }, title: "Desktop", desktopDisplayID: 0)
        var committed: [VideoEndpoint] = []
        m.onEndpointCommitted = { committed.append($0) }
        m.open()
        XCTAssertEqual(m.active?.displayID, 0)
        XCTAssertEqual(committed.last?.displayID, 0)

        m.switchDisplay(to: 42)

        XCTAssertEqual(m.desktopDisplayID, 42)
        XCTAssertEqual(m.active?.displayID, 42, "re-opened at the new display")
        XCTAssertEqual(committed.last?.displayID, 42, "the new target persists to the pane spec")

        let before = committed.count
        m.switchDisplay(to: 42)
        XCTAssertEqual(committed.count, before, "same-display switch is a no-op (no re-hello churn)")
    }

    func testSwitchDisplayIsANoOpForWindowTargets() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        m.switchDisplay(to: 7)
        XCTAssertNil(m.desktopDisplayID)
        XCTAssertEqual(m.active?.windowID, 42, "window target untouched")
    }

    // MARK: Audio toggle (host app-audio opt-in)

    /// `applyAudioEnabled` is gated exactly like the other host-affecting sinks: no sink or no
    /// stream ⇒ inert no-op (state never flips, nothing fires); a same-value apply is dropped so
    /// the sink only ever sees transitions.
    func testApplyAudioEnabledRequiresStreamingAndASinkAndDropsSameValue() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.applyAudioEnabled(true) // no sink + not streaming — must not crash, must not flip
        XCTAssertFalse(m.audioStreamEnabled)
        XCTAssertFalse(m.canToggleAudio)

        var received: [Bool] = []
        m.audioInjector = { received.append($0) }
        m.applyAudioEnabled(true)
        XCTAssertFalse(m.audioStreamEnabled, "a sink alone is not enough — the pane must be streaming")
        XCTAssertEqual(received, [], "nothing sent while the gate is closed")

        m.open()
        XCTAssertTrue(m.canToggleAudio)
        m.applyAudioEnabled(true)
        m.applyAudioEnabled(true) // same-value — dropped, the sink sees transitions only
        m.applyAudioEnabled(false)
        XCTAssertEqual(received, [true, false])
        XCTAssertFalse(m.audioStreamEnabled)
    }

    /// Publishing an audio sink RE-ASSERTS a held ON state (the viewportLocked precedent): a
    /// detach/reattach re-binds the SAME model to a fresh view whose new session — and so the host
    /// — starts with audio OFF, so the model's wish must re-push. OFF publishes nothing (the fresh
    /// session's default is already correct).
    func testAudioSinkPublishReassertsAHeldOnState() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        m.audioInjector = { _ in }
        m.applyAudioEnabled(true)
        XCTAssertTrue(m.audioStreamEnabled)

        var freshSink: [Bool] = []
        m.audioInjector = { freshSink.append($0) }
        XCTAssertEqual(freshSink, [true], "the held ON is re-asserted into the fresh sink")

        m.close()
        XCTAssertNil(m.audioInjector)
        XCTAssertFalse(m.audioStreamEnabled, "the next session mints with audio OFF — the light resets")

        let m2 = RemoteWindowModel(target: { self.target }, windowID: "7", title: "Safari")
        m2.open()
        var silent: [Bool] = []
        m2.audioInjector = { silent.append($0) }
        XCTAssertEqual(silent, [], "audio OFF ⇒ nothing re-asserted")
    }

    #if canImport(SwiftUI)
    /// **Read-only WITHHOLDS the audio sink at the seam.** Enabling audio changes HOST capture
    /// behaviour, so — exactly like the stream-settings sink — the `.videoLeaf` derivation binds
    /// `nil` while read-only: the speaker is inert on a locked pane.
    func testReadOnlyWithholdsTheAudioSinkAtTheSeam() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "7", title: "Safari")
        m.open()
        let liveSink: (Bool) -> Void = { _ in }

        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: false, bindKeyInjector: { _ in },
            bindAudioInjector: { m.audioInjector = $0 },
        ).onAudioInjectorReady?(liveSink)
        XCTAssertNotNil(m.audioInjector, "writable: the published sink reaches the model")
        XCTAssertTrue(m.canToggleAudio)

        RemotePaneContext.videoLeaf(
            isActive: true, readOnly: true, bindKeyInjector: { _ in },
            bindAudioInjector: { m.audioInjector = $0 },
        ).onAudioInjectorReady?(liveSink)
        XCTAssertNil(m.audioInjector, "read-only: the seam clears the audio sink")
        XCTAssertFalse(m.canToggleAudio, "read-only: a locked pane cannot start host audio")
    }
    #endif
}
