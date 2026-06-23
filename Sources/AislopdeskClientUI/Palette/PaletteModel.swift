// PaletteModel — the pure, view-independent data model for the command palette (warp-overlays-actions.md
// §1). A `PaletteItem` is one heterogeneous result row (icon + title + subtitle + optional shortcut hint),
// carrying the typed `PaletteAction` it runs on accept. `QueryFilter` mirrors Warp's per-domain filter
// chips; a `PaletteSection` groups rows under a separator header.
//
// Everything here is value types so the SearchMixer + ranking + filtering are unit-testable with no view
// and no live store (the ACTIONS catalog builds a fixed list; the TABS/NAV sources take a snapshot the
// store hands them). The store mutation runs in `PaletteAction.run` which the palette view dispatches.

import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import Foundation

// MARK: - Query filter (the chip categories)

/// A per-domain palette filter — the zero-state filter chips + the registration key for each data source
/// (warp-overlays-actions.md §1.5 / §2.2). A query carries at most one active filter; a source runs when
/// the query has no filter OR its filter matches one the source is registered against.
public enum QueryFilter: String, CaseIterable, Sendable, Hashable {
    case actions = "Actions"
    case tabs = "Tabs"
    case sessions = "Sessions"
    case files = "Files"
    case conversations = "Conversations"
    case repos = "Repos"

    /// The chip display label.
    public var label: String { rawValue }

    /// A representative SF Symbol for the chip / source rows.
    public var icon: String {
        switch self {
        case .actions: "command"
        case .tabs: "rectangle.split.3x1"
        case .sessions: "square.stack.3d.up"
        case .files: "doc"
        case .conversations: "bubble.left.and.bubble.right"
        case .repos: "shippingbox"
        }
    }
}

// MARK: - Palette action (the typed intent a row runs)

/// The typed action a palette row carries — the SwiftUI analogue of `CommandPaletteItemAction`
/// (warp-overlays-actions.md §4.3). `run` performs the side effect on the store (a tree mutation, a focus
/// jump, opening settings, etc.); the palette view calls it then closes. `NoOp` backs the section
/// separators (non-interactable).
public enum PaletteAction: Sendable {
    /// Run a closure against the store (the common case — a tree mutation / navigation).
    case store(@MainActor @Sendable (WorkspaceStore) -> Void)
    /// Run a workspace command through the central `apply(_:to:)` dispatch (records recents at the chokepoint).
    case command(WorkspaceCommand)
    /// Open the command palette in a fresh filter (a filter chip → re-query) — handled by the palette view.
    case selectFilter(QueryFilter)
    /// Open the Settings overlay (handled by the overlay coordinator).
    case openSettings
    /// Open the Connect-to-Host overlay (the host/port editor — handled by the overlay coordinator).
    case openConnect
    /// Open the keyboard cheat sheet overlay (handled by the overlay coordinator).
    case openCheatSheet
    /// Open the Remote-Window picker (L6 / W1 — handled by the overlay coordinator; a pick opens a
    /// `.remoteGUI` pane streaming the chosen host window).
    case openRemotePicker
    /// A non-interactable separator/zero row.
    case noOp
}

// MARK: - Palette item (one result row)

/// One heterogeneous result row in the palette (warp-overlays-actions.md §1.3). Identifiable + Equatable
/// (by `id`) so the SwiftUI list diffs cleanly and tests can assert ordering by id.
public struct PaletteItem: Identifiable, Sendable {
    public let id: String
    /// SF Symbol name for the leading icon.
    public let icon: String
    public let title: String
    public let subtitle: String?
    /// Right-aligned shortcut hint chip text (e.g. "⌘T"), or `nil`.
    public let shortcut: String?
    /// Which source/domain produced this row (for the section grouping + filter match).
    public let filter: QueryFilter
    /// The typed action this row runs on accept.
    public let action: PaletteAction
    /// A separator row hugs the next row and never highlights/runs (warp-overlays-actions.md §1.4).
    public let isSeparator: Bool

    public init(
        id: String,
        icon: String,
        title: String,
        subtitle: String? = nil,
        shortcut: String? = nil,
        filter: QueryFilter,
        action: PaletteAction,
        isSeparator: Bool = false,
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.filter = filter
        self.action = action
        self.isSeparator = isSeparator
    }

    /// A section separator row (header label, no action).
    public static func separator(_ label: String, filter: QueryFilter) -> Self {
        Self(
            id: "separator.\(filter.rawValue).\(label)",
            icon: "",
            title: label,
            filter: filter,
            action: .noOp,
            isSeparator: true,
        )
    }

    /// Whether `query` matches this row's title or subtitle (case-insensitive substring). Empty query ⇒
    /// matches (the zero-state path filters elsewhere).
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) { return true }
        if let subtitle, subtitle.lowercased().contains(q) { return true }
        return false
    }

    /// A simple relevance score for `query` (higher = better). 0 ⇒ no match. Prefix matches outrank
    /// mid-word substring matches; a title hit outranks a subtitle hit (warp's mixer ranks per-source then
    /// by match quality — this is the SwiftUI analogue, deterministic + testable).
    func score(for query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return 1 }
        let t = title.lowercased()
        if t == q { return 100 }
        if t.hasPrefix(q) { return 80 }
        if t.contains(q) { return 50 }
        if let subtitle, subtitle.lowercased().contains(q) { return 20 }
        return 0
    }
}
