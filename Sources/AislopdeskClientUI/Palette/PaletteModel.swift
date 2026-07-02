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

/// A per-domain palette filter — the registration key for each data source (warp-overlays-actions.md §1.5 /
/// §2.2). A query carries at most one active filter; a source runs when the query has no filter OR its
/// filter matches one the source is registered against.
///
/// This is the verbs-only ⌘⇧P taxonomy — DISTINCT from the ⌘⇧O ``OpenQuicklyFilter`` pills (Open-Quickly is
/// its own E11 surface). Only ``actions`` is wired by a live source today (``ActionsPaletteSource`` /
/// ``CategoryActionsSource``); ``tabs`` is wired by ``TabsPaletteSource`` for ad-hoc mounts. The remaining
/// domains (``sessions`` / ``files`` / ``conversations`` / ``repos``) are RETAINED as the documented Warp
/// taxonomy but are no longer surfaced by any source — their empty-stub sources were removed in E11 / WI-5
/// once the multi-source jump-to moved to ``OpenQuicklyFilter`` (they were never reachable under ⌘⇧P).
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

// MARK: - Palette category (the verb grouping under section headers)

/// The action categories the verbs-only ⌘⇧P command palette groups its catalog under (spec §Behaviors:
/// "Actions are grouped under capitalized section headers e.g. WORKING DIRECTORY, VIEW"). This is DISTINCT
/// from ``QueryFilter`` (the Open-Quickly jump-to domains): a `PaletteCategory` only SUB-groups the single
/// ACTIONS source so the command palette reads as a sectioned verb list, whereas a `QueryFilter` picks
/// which multi-source provider runs. Every catalog row carries one; the mixer / zero-state emit a section
/// header per non-empty category in ``commandOrder``.
public enum PaletteCategory: String, CaseIterable, Sendable, Hashable {
    case workingDirectory = "Working Directory"
    case window = "Window"
    case pane = "Pane"
    case tab = "Tab"
    case view = "View"
    case shell = "Shell"
    case settings = "Settings"

    /// The section-header label (title case; the palette view uppercases it for display).
    public var label: String { rawValue }

    /// The fixed display order: Working Directory leads (it OWNS the cwd badge in the view, per the
    /// screenshot), then the remaining verb groups. An empty category is skipped by the mixer / zero-state, so it
    /// never renders an empty header. (Shell carries the E17 "Read Only" verb.)
    public static let commandOrder: [Self] = [
        .workingDirectory, .window, .pane, .tab, .view, .shell, .settings,
    ]
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
    /// Toggle the left navigator / Tabs panel — routed by the overlay coordinator to the LIVE
    /// ``WorkspaceChromeState`` (the macOS split + the palette's ✓ both read `chrome.sidebarCollapsed`), NOT
    /// the legacy `store.sidebarCollapsed` the native shell never reads. Same live flag the ⌘⇧L chord + the
    /// titlebar button drive, so the run path, the chord, the button, and the ✓ stay in lockstep.
    case toggleSidebar
    /// E19 WI-4: toggle "Pin Window" (keep the window floating above all other apps).
    /// Routed by the overlay coordinator to the injected ``OverlayCoordinator/togglePinWindow`` closure (bound
    /// to the SAME live ``WorkspaceChromeState`` `pinned` flag the menu Button + the `NSWindow.level` glue
    /// read), so the palette row's ✓ gutter (resolved in ``OverlayHostView/toggledState(for:)``) tracks the
    /// real pinned state. A checkable toggle (ES-E2-3); a documented no-op on iOS (no window level).
    case togglePinWindow
    /// Close the active window. Routed by the overlay coordinator to the injected
    /// ``OverlayCoordinator/closeWindow`` closure (bound on macOS to `NSWindow.performClose(nil)` → the native
    /// `windowShouldClose` close-confirmation gate, preserving the configured ``CloseConfirmationPolicy``).
    /// `nil` (iOS / tests / a pre-`onAppear` scene) falls back to ``WorkspaceStore/requestCloseWindow()`` so
    /// the row PARKS the confirmation rather than trapping — the SAME fallback the ⌘⇧W route arm uses, never a
    /// dead control.
    case closeWindow
    /// Theme catalog verb (Batch 4 catalog-completeness): the palette "Switch Theme" row — switch the active local
    /// theme. Routed by the overlay coordinator to the injected ``OverlayCoordinator/switchTheme`` closure
    /// (bound app-side to ``PreferencesStore`` — it advances the primary slot through the built-in themes, the
    /// SAME live `appearance.theme` Settings → Appearance edits, so the chrome retints + the terminal cells
    /// repaint immediately). `nil`-closure default (tests / previews) is a graceful no-op.
    case switchTheme
    /// Theme catalog verb (Batch 4): the palette "Reload Config" / "Reload Theme" row — re-apply the live client
    /// settings (theme retint + keybinding republish). Routed by the coordinator to the injected
    /// ``OverlayCoordinator/reloadConfig`` closure (bound app-side to ``PreferencesStore/reapplyLiveSettings()``
    /// plus the config-reload broadcast the CLI `config reload` posts). A graceful no-op by default.
    case reloadConfig
    /// Theme catalog verb (Batch 4): the palette "Open Theme File" row — reveal the custom-themes folder
    /// (`~/.config/aislopdesk/themes/`) in Finder so a hand-authored `.aislopdesktheme` can be edited. Routed by the
    /// coordinator to the injected ``OverlayCoordinator/openThemeFile`` closure (macOS `NSWorkspace`; iOS has no
    /// `~/.config` so it is a documented no-op). A graceful no-op by default.
    case openThemeFile
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
    /// HIDDEN fuzzy-match synonyms — extra terms the user might type that should surface this row but are
    /// NEVER rendered (e.g. "Read Only" also accepts `lock` / `freeze` / `view only`). The ``SearchMixer``
    /// folds them into the haystack at a LOWER tier than the title / subtitle (a keyword hit never out-ranks
    /// a title hit and adds no title highlight), so the row stays visually clean. `nil` for rows with no
    /// synonyms. Mirrors ``WorkspaceBinding/keywords`` (the same idea on the registry side).
    public let keywords: String?
    /// Right-aligned shortcut hint chip text (e.g. "⌘T"), or `nil`.
    public let shortcut: String?
    /// Which source/domain produced this row (for the section grouping + filter match).
    public let filter: QueryFilter
    /// The verb category this row groups under in the verbs-only ⌘⇧P palette (Working Directory /
    /// Window / Pane / …). `nil` for non-action rows (jump-to Tabs/Files results, separators) — only the
    /// ACTIONS catalog tags its rows.
    public let category: PaletteCategory?
    /// The typed action this row runs on accept.
    public let action: PaletteAction
    /// A separator row hugs the next row and never highlights/runs (warp-overlays-actions.md §1.4).
    public let isSeparator: Bool

    public init(
        id: String,
        icon: String,
        title: String,
        subtitle: String? = nil,
        keywords: String? = nil,
        shortcut: String? = nil,
        filter: QueryFilter,
        category: PaletteCategory? = nil,
        action: PaletteAction,
        isSeparator: Bool = false,
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.shortcut = shortcut
        self.filter = filter
        self.category = category
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

    /// A copy of this row carrying a recents-namespaced id (`"recent.<id>"`) — used ONLY by the zero-state
    /// Recents section. The same catalog row can appear under BOTH "Recents" and "Actions"; without distinct
    /// ids the two collide in the palette's `ForEach`/`.id(_:)` (SwiftUI's documented "the ID occurs multiple
    /// times … undefined results" — rows dropped/mis-diffed and an ambiguous `scrollTo` target). Everything
    /// else (icon/title/shortcut/`action`) is preserved verbatim so accept still runs the catalog verb.
    public func namespacedForRecents() -> Self {
        Self(
            id: "recent.\(id)",
            icon: icon,
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            shortcut: shortcut,
            filter: filter,
            category: category,
            action: action,
            isSeparator: isSeparator,
        )
    }
}

// MARK: - Ranked row (item + fzf match ranges)

/// A result row paired with the title code-point ranges fzf matched (``FuzzyMatcher``) — carried WITHOUT
/// mutating ``PaletteItem`` so the palette view can highlight the matched characters. `titleRanges` is
/// empty for a separator, an empty-query row, or a row matched only on its subtitle.
public struct RankedRow: Sendable, Identifiable {
    public let item: PaletteItem
    public let titleRanges: [Range<String.Index>]
    public var id: String { item.id }

    public init(item: PaletteItem, titleRanges: [Range<String.Index>] = []) {
        self.item = item
        self.titleRanges = titleRanges
    }
}
