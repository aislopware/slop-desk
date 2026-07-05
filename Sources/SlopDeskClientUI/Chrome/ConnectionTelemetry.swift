// ConnectionTelemetry — resolves the ACTIVE pane's live numbers for the connection cluster. Shared by
// the cluster's two mounts (the sidebar top when expanded; the titlebar fallback while the sidebar is
// collapsed) so the readings can never drift between them.

#if canImport(SwiftUI)
import Foundation
import SlopDeskWorkspaceCore

@MainActor
enum ConnectionTelemetry {
    /// The active pane's live session — resolves the per-pane connection telemetry the cluster shows.
    private static func activeLive(_ store: WorkspaceStore) -> LivePaneSession? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The RTT (ms) for the cluster. Prefers the ACTIVE pane's per-channel `latencyMS`, falling back to
    /// ANY live pane's when the active pane has none — a `.remoteGUI` window pane has no terminal-channel
    /// ping (`connection == nil`), so without this the ping would VANISH the moment you focus a window.
    /// Every pane pings the SAME host, so a sibling terminal's RTT is representative; `.min()` keeps it
    /// deterministic across the unordered registry.
    static func pingMS(_ store: WorkspaceStore) -> Double? {
        if let active = activeLive(store)?.connection?.latencyMS { return active }
        return store.allSessions
            .compactMap { ($0 as? LivePaneSession)?.connection?.latencyMS }
            .min()
    }

    /// The active VIDEO pane's host-announced stream cadence (fps); `nil` for a terminal pane / until the
    /// host's FPS governor announces a value.
    static func fps(_ store: WorkspaceStore) -> Int? {
        activeLive(store)?.remoteWindow?.streamFps
    }

    /// The active VIDEO pane's client-measured stream bitrate (kbps, ~1 Hz); `nil` for a terminal pane /
    /// until the first reading.
    static func kbps(_ store: WorkspaceStore) -> Int? {
        activeLive(store)?.remoteWindow?.streamKbps
    }
}
#endif
