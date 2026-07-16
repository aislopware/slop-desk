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
}
