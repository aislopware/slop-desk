#if canImport(SwiftUI)
import Foundation

/// Client-side driver of the "show system popups in their own pane" feature: while the app is connected
/// it POLLS the host for its open SYSTEM dialogs (a SecurityAgent login/password prompt etc.) via the
/// ``SystemDialogDiscovery`` seam, and diffs the answer to AUTO-SPAWN an ephemeral ``PaneKind/systemDialog``
/// pane per dialog — closing it again the moment the dialog leaves the list.
///
/// **Why poll (not host-push):** a dialog is a discrete event; polling reuses the proven session-LESS
/// request/answer plumbing (the picker's `listWindows` lane) with zero new host-push infrastructure, and a
/// ~2 s detection latency for a prompt is imperceptible. The host answers `listSystemDialogs` session-less.
///
/// **Lifecycle:** the app scene owns a `.task { await monitor.run() }`; `run()` loops until that task is
/// cancelled (scene teardown), then closes every pane it spawned. Inert when no discovery seam is
/// registered (headless / no video module) or while disconnected.
@preconcurrency
@MainActor
public final class SystemDialogMonitor {
    private weak var store: WorkspaceStore?
    private let isConnected: @MainActor () -> Bool
    private let target: @MainActor () -> ConnectionTarget
    private let pollGap: Duration
    /// host windowID → the ephemeral pane currently streaming it.
    private var spawned: [UInt32: PaneID] = [:]
    /// host windowID → when the user MANUALLY closed our pane while the dialog was still up. A
    /// still-present prompt re-spawns after ``respawnSuppression`` so an important password dialog can
    /// never be dismissed into invisibility forever — but a deliberate close gets a grace window first.
    private var manuallyClosedAt: [UInt32: Date] = [:]
    /// Wall clock (injectable for deterministic tests). Main-actor-isolated storage; called only from
    /// the main-actor reconcile, so a plain (non-Sendable) closure is correct.
    private let clock: () -> Date
    /// How long a manually-closed dialog pane stays closed before a still-present dialog re-spawns it.
    private let respawnSuppression: TimeInterval

    @preconcurrency
    public init(
        store: WorkspaceStore,
        isConnected: @escaping @MainActor () -> Bool,
        target: @escaping @MainActor () -> ConnectionTarget,
        pollGap: Duration = .seconds(2),
        respawnSuppression: TimeInterval = 10,
        clock: @escaping () -> Date = { Date() },
    ) {
        self.store = store
        self.isConnected = isConnected
        self.target = target
        self.pollGap = pollGap
        self.respawnSuppression = respawnSuppression
        self.clock = clock
    }

    /// Polls + reconciles until the owning Task is cancelled, then closes any spawned panes. While
    /// DISCONNECTED it simply idles (the spawned panes show the "paused" placeholder; the next connected
    /// poll reconciles them) rather than tearing them down on every transient blip.
    public func run() async {
        defer { closeAllSpawned() }
        while !Task.isCancelled {
            if isConnected(), let query = SystemDialogDiscovery.shared {
                let t = target()
                let dialogs = await query(t.host, t.mediaPort, t.cursorPort)
                if Task.isCancelled { break }
                reconcile(dialogs)
            }
            try? await Task.sleep(for: pollGap)
        }
    }

    /// Spawn a pane for each newly-seen dialog; close the pane for each dialog that is gone; re-spawn a
    /// dialog the user manually closed once its grace window elapses (a still-present prompt must not be
    /// dismissed into invisibility forever — the "frozen host" trap). Pure diff over `spawned`.
    private func reconcile(_ dialogs: [SystemDialogInfo]) {
        guard let store else { return }
        let present = Set(dialogs.map(\.windowID))
        // 1. Dialogs gone host-side → close our pane + forget ALL state (a future reappearance is fresh).
        //    Close FIRST so a freed video-cap slot is available before a new one is admitted.
        for (wid, id) in spawned where !present.contains(wid) {
            store.closePane(id)
            spawned.removeValue(forKey: wid)
        }
        // Clear the manual-close grace for any dialog no longer present — even one already removed from
        // `spawned` (a user-closed pane whose dialog then left host-side), so its next reappearance is
        // NOT spuriously suppressed by a stale timestamp.
        for wid in manuallyClosedAt.keys where !present.contains(wid) {
            manuallyClosedAt.removeValue(forKey: wid)
        }
        // 2. Detect a MANUAL close: a still-present dialog whose pane is no longer on the canvas (the
        //    user closed it). Drop it from `spawned` and start its grace timer — so it is eligible to
        //    re-spawn after the suppression window rather than lingering as a dead id (the old bug:
        //    spawned[wid] kept a closed pane's id, so the dialog was unrecoverable).
        for (wid, id) in spawned where !store.isPaneOnCanvas(id) {
            spawned.removeValue(forKey: wid)
            if manuallyClosedAt[wid] == nil { manuallyClosedAt[wid] = clock() }
        }
        // 3. Spawn any present dialog with no live pane — respecting a recent manual close's grace window.
        let now = clock()
        for d in dialogs where spawned[d.windowID] == nil {
            if let closedAt = manuallyClosedAt[d.windowID], now.timeIntervalSince(closedAt) < respawnSuppression {
                continue // still inside the grace window — leave it closed
            }
            manuallyClosedAt.removeValue(forKey: d.windowID)
            spawned[d.windowID] = store.addSystemDialogPane(
                windowID: d.windowID, owner: d.owner, title: d.title, isSecure: d.isSecure,
            )
        }
    }

    /// Test seam: drive one reconcile pass directly (the production caller is the polling `run()` loop).
    func reconcileForTesting(_ dialogs: [SystemDialogInfo]) { reconcile(dialogs) }

    private func closeAllSpawned() {
        if let store { for (_, id) in spawned { store.closePane(id) } }
        spawned.removeAll()
    }
}
#endif
