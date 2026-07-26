import CoreGraphics
import Foundation

/// A named snapshot of a canvas LAYOUT — the panes (with their video bindings by app+title), groups,
/// and which pane was focused. Deliberately NOT the app connection (a layout is host-agnostic; the one
/// connection persists separately) and never recursive (no nested presets). Restoring it rebuilds every
/// session through the store's reconcile diff; a remote-window binding whose host window is gone
/// degrades to the picker, exactly like a normal restore.
public struct LayoutPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var canvas: Canvas
    public var groups: [PaneGroup]
    public var focusedPane: PaneID?
    /// When set, this layout AUTO-SWITCHES the moment a host window owned by this app first appears
    /// (case-insensitive match on the app name) — e.g. "monitoring" snaps in when you launch Grafana
    /// on the host. `nil` = no trigger (manual switch only).
    public var triggerAppName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        canvas: Canvas,
        groups: [PaneGroup],
        focusedPane: PaneID?,
        triggerAppName: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.groups = groups
        self.focusedPane = focusedPane
        self.triggerAppName = triggerAppName
    }
}
