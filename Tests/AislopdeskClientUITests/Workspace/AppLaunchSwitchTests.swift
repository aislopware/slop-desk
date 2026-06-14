import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins layout auto-switch on host app launch: the trigger save, the pure matcher, and the
/// switch-once-per-launch latch (with re-arm when the app leaves) the AppLaunchMonitor drives.
@MainActor
final class AppLaunchSwitchTests: XCTestCase {
    private func twoPaneStore() -> WorkspaceStore {
        let a = PaneID(), b = PaneID()
        let items = [
            CanvasItem(
                id: a,
                spec: PaneSpec(kind: .terminal, title: "A"),
                frame: CGRect(x: 0, y: 0, width: 480, height: 320),
                z: 0,
            ),
            CanvasItem(
                id: b,
                spec: PaneSpec(kind: .terminal, title: "B"),
                frame: CGRect(x: 600, y: 0, width: 480, height: 320),
                z: 1,
            ),
        ]
        return WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: items), focusedPane: a),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    func testSaveWithTriggerStoresIt() {
        let store = twoPaneStore()
        store.saveLayoutPreset(name: "monitoring", triggerAppName: "Grafana")
        XCTAssertEqual(store.workspace.layoutPresets.first?.triggerAppName, "Grafana")
        // Empty/whitespace trigger normalises to nil.
        store.saveLayoutPreset(name: "plain", triggerAppName: "   ")
        XCTAssertNil(store.workspace.layoutPresets.first(where: { $0.name == "plain" })?.triggerAppName)
    }

    func testMatcherIsCaseInsensitive() {
        let store = twoPaneStore()
        store.saveLayoutPreset(name: "m", triggerAppName: "Grafana")
        XCTAssertEqual(store.presetForLaunchedApp("grafana")?.name, "m")
        XCTAssertNil(store.presetForLaunchedApp("Safari"))
    }

    func testAutoSwitchFiresOncePerLaunchThenReArmsWhenAppLeaves() throws {
        let store = twoPaneStore()
        // Save "single" = a one-pane layout triggered by Grafana.
        try store.closePane(XCTUnwrap(store.workspace.canvas.allIDs().last)) // one pane now
        store.saveLayoutPreset(name: "single", triggerAppName: "Grafana")
        // Restore a two-pane live canvas so a switch is observable.
        store.addPane(kind: .terminal)
        XCTAssertEqual(store.workspace.canvas.items.count, 2)

        XCTAssertTrue(store.autoSwitchForLaunchedApp("Grafana"), "first launch switches")
        XCTAssertEqual(store.workspace.canvas.items.count, 1, "switched to the 1-pane layout")
        XCTAssertFalse(store.autoSwitchForLaunchedApp("Grafana"), "same launch (still present) doesn't re-switch")

        // Grafana's windows all close → latch re-arms; a relaunch switches again.
        store.clearAutoSwitchLatch(forAbsentApps: ["Grafana"])
        store.addPane(kind: .terminal) // mutate so a re-switch is observable
        XCTAssertTrue(store.autoSwitchForLaunchedApp("Grafana"), "relaunch after the app left switches again")
    }

    func testNoSwitchWithoutAMatchingTrigger() {
        let store = twoPaneStore()
        store.saveLayoutPreset(name: "m", triggerAppName: "Grafana")
        XCTAssertFalse(store.autoSwitchForLaunchedApp("Safari"))
    }

    func testTriggerSurvivesCodableRoundTrip() throws {
        let store = twoPaneStore()
        store.saveLayoutPreset(name: "m", triggerAppName: "Grafana")
        let data = try JSONEncoder().encode(store.workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.layoutPresets.first?.triggerAppName, "Grafana")
    }

    /// Hunt 2026-06-13, finding #3: across a disconnect the monitor's `lastApps` (and the store's auto-switch
    /// latch) must be FORGOTTEN, so a reconnect re-evaluates from scratch. Without the fix, a trigger app
    /// that was already in `lastApps` before the drop is diffed away as "already seen" on reconnect and its
    /// layout switch is silently missed. Drives `AppLaunchMonitor.pollOnce()` directly across a connected →
    /// disconnected → connected sequence via a stubbed discovery seam.
    func testReconnectAfterDisconnectReFiresAutoSwitch() async throws {
        // Force the feature on hermetically (default is ON, but don't depend on prior tests / user defaults).
        UserDefaults.standard.set(true, forKey: SettingsKey.autoSwitchLayouts)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.autoSwitchLayouts) }

        let store = twoPaneStore()
        // A 1-pane layout triggered by Grafana (a switch is observable as the pane count dropping to 1).
        try store.closePane(XCTUnwrap(store.workspace.canvas.allIDs().last))
        store.saveLayoutPreset(name: "single", triggerAppName: "Grafana")
        store.addPane(kind: .terminal) // back to 2 live panes
        XCTAssertEqual(store.workspace.canvas.items.count, 2)

        // A @MainActor reference holder for the connected flag so the `isConnected` closure captures by
        // reference (no "var mutated after capture by sendable closure" warning).
        let link = ConnectionFlag()
        let target = ConnectionTarget(host: "h", port: 7420, mediaPort: 9000, cursorPort: 9001)
        RemoteWindowDiscovery.shared = { _, _, _ in
            [RemoteWindowSummary(windowID: 1, appName: "Grafana", title: "", width: 100, height: 100)]
        }
        defer { RemoteWindowDiscovery.shared = nil }
        let monitor = AppLaunchMonitor(
            store: store,
            isConnected: { link.connected },
            target: { target },
            pollGap: .milliseconds(1),
        )

        // Connected, Grafana present → first poll auto-switches to the 1-pane layout (latches Grafana).
        await monitor.pollOnce()
        XCTAssertEqual(store.workspace.canvas.items.count, 1, "connected poll auto-switched on Grafana")

        // User moves on (a 2-pane layout again), Grafana still running, then the connection drops.
        store.addPane(kind: .terminal)
        XCTAssertEqual(store.workspace.canvas.items.count, 2)
        link.connected = false
        await monitor.pollOnce() // disconnected: clears latch + lastApps

        // Reconnect with Grafana still present (a quit+relaunch during the gap is indistinguishable): the
        // monitoring layout must snap back in rather than be diffed away as already-seen.
        link.connected = true
        await monitor.pollOnce()
        XCTAssertEqual(
            store.workspace.canvas.items.count,
            1,
            "reconnect re-evaluates and re-fires the auto-switch (no stale-lastApps miss)",
        )
    }
}

/// A tiny @MainActor reference holder for a mutable connected flag the monitor's `isConnected` closure
/// reads — captured by reference so flipping it does not warn about mutating a captured `var`.
@MainActor
private final class ConnectionFlag {
    var connected = true
}
