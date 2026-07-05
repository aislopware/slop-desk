#if canImport(SwiftUI)
import Foundation

/// Polls the host's shareable-window list while connected and AUTO-SWITCHES to a layout preset when a
/// host app it is bound to (``LayoutPreset/triggerAppName``) first appears — e.g. launching Grafana on
/// the host snaps in your "monitoring" canvas. Reuses the ``RemoteWindowDiscovery`` seam (the same
/// host-window query the picker uses), diffs the app-name set across polls, and fires
/// ``WorkspaceStore/autoSwitchForLaunchedApp(_:)`` for each NEWLY-appeared app. Inert unless the
/// feature toggle is on AND at least one preset has a trigger (so a user with no triggers pays nothing).
@preconcurrency
@MainActor
public final class AppLaunchMonitor {
    private weak var store: WorkspaceStore?
    private let isConnected: @MainActor () -> Bool
    private let target: @MainActor () -> ConnectionTarget
    private let pollGap: Duration
    /// The host app names present on the last poll (to diff for newly-appeared apps).
    private var lastApps: Set<String> = []

    @preconcurrency
    public init(
        store: WorkspaceStore,
        isConnected: @escaping @MainActor () -> Bool,
        target: @escaping @MainActor () -> ConnectionTarget,
        pollGap: Duration = .seconds(3),
    ) {
        self.store = store
        self.isConnected = isConnected
        self.target = target
        self.pollGap = pollGap
    }

    public func run() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(for: pollGap)
        }
    }

    /// One poll: when enabled and any preset has a trigger, query host apps, switch for the new ones,
    /// and clear the latch for apps that have left (so a relaunch can re-fire). Exposed for tests.
    func pollOnce() async {
        guard let store else { return }
        // Cheap early-out: nothing to do unless the feature is on and some preset carries a trigger.
        guard SettingsKey.autoSwitchLayoutsEnabled,
              store.liveLayoutPresets.contains(where: { $0.triggerAppName != nil }),
              isConnected(), let query = RemoteWindowDiscovery.shared
        else {
            // Not ready (feature off / no trigger / DISCONNECTED): treat it like the host's whole app set
            // went absent — clear the auto-switch latch for every previously-seen app AND forget the
            // last-seen set. So a later reconnect re-evaluates from scratch: present host apps are
            // newly-appeared (lastApps reset) AND no longer latched, mirroring the connected
            // app-gone→relaunch path. Without this, `lastApps` (and the latch) stay frozen at the
            // pre-disconnect snapshot, so an app that quit+relaunched during the gap is diffed away as
            // "already seen" and its layout switch is silently missed on reconnect. Idempotent once
            // `lastApps` is empty (the latch clear then passes an empty set → no-op).
            store.clearAutoSwitchLatch(forAbsentApps: lastApps)
            lastApps = []
            return
        }
        let t = target()
        let windows = await query(t.host, t.mediaPort, t.cursorPort)
        if Task.isCancelled { return }
        let apps = Set(windows.map(\.appName).filter { !$0.isEmpty })
        let newApps = apps.subtracting(lastApps)
        let goneApps = lastApps.subtracting(apps)
        lastApps = apps
        store.clearAutoSwitchLatch(forAbsentApps: goneApps)
        // One switch per poll, with a DETERMINISTIC winner when several trigger apps appear at once
        // (e.g. a multi-poll reconnect batch): iterate the presets in saved order, not the unordered
        // newApps Set, so the same launch always picks the same layout.
        for preset in store.liveLayoutPresets {
            guard let trigger = preset.triggerAppName,
                  newApps.contains(where: { $0.lowercased() == trigger.lowercased() }) else { continue }
            if store.autoSwitchForLaunchedApp(trigger) { break }
        }
    }
}
#endif
