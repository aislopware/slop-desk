// PalettePresentation — what the command palette IS, for both of the halves that draw it.
//
// The palette is the fourth surface off the shared SwiftUI floor (docs/56 stage D) and the first
// MODAL one: the Mac draws it as an `NSPanel` (``SlopDeskMacUI/MacPaletteView``), the phone as a
// paper card inside ``OverlayHostView``. Neither may re-derive what is written here, because every
// value below is a DECISION rather than a layout — the card's measurements, how the ranked rows pair
// with the keyboard's index, which row a jump scrolls to, and what the WORKING DIRECTORY badge
// reads. What each half keeps for itself is the arrangement: a `LazyVStack` on the phone, an
// `NSStackView` in a scroll view on the Mac.
//
// The ranking, the filtering and the running of a row are NOT here — they are ``OverlayCoordinator``
// and ``SearchMixer``, one floor further down, and the palette has always read them rather than
// owning them.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // PaneSpec.cwdBadgePath — the badge's rule, in Rust

// MARK: - The card's measurements

/// The floating panel's own dimensions, and the one number derived from them.
///
/// Both are from `spec/user-interface__command-palette.md` — a centred panel at ~720pt with a
/// results viewport that stops at ~7 rows so the card never grows to the height of the window.
public enum PaletteMetrics {
    /// The card's fixed width. It does not track the window: a palette that stretched with a
    /// full-screen workspace would put its keycap column a screen away from its titles.
    public static let panelWidth: Double = 720
    /// The tallest the results viewport may be. Past this the list scrolls instead of the card
    /// growing.
    public static let resultsMaxHeight: Double = 336

    /// One ⇞/⇟ stride: the rows one full viewport shows.
    ///
    /// Derived from the SAME two numbers that size the viewport, so re-tuning the card re-tunes the
    /// page rather than leaving a stride that no longer matches what the eye just skipped.
    public static func pageStride(rowHeight: Double) -> Int {
        guard rowHeight > 0 else { return 1 }
        return Swift.max(1, Int(resultsMaxHeight / rowHeight))
    }
}

// MARK: - The rows, paired with the keyboard's index

/// One result row and the index the KEYBOARD knows it by.
///
/// The two indices differ, and that is the whole reason this type exists: the ranked results include
/// section separators, while `paletteSelection` counts only the rows a user can land on. A view that
/// paired them itself would be one off the moment a section header appeared mid-list.
public struct PaletteDisplayRow: Sendable, Identifiable {
    public let ranked: RankedRow
    /// The selectable index, or `nil` for a separator — which is also "this row never highlights".
    public let selectableIndex: Int?
    public var id: String { ranked.id }

    public init(ranked: RankedRow, selectableIndex: Int?) {
        self.ranked = ranked
        self.selectableIndex = selectableIndex
    }
}

public enum PalettePresentation {
    /// The query field's prompt — the card's ONE user-facing string, and it was spelled once per
    /// shell. It names what the card searches, which is the palette's meaning rather than either
    /// half's drawing.
    public static let queryPrompt = "Search for commands…"

    /// Pairs the ranked results with their selectable indices, in draw order.
    public static func displayRows(_ ranked: [RankedRow]) -> [PaletteDisplayRow] {
        var index = 0
        var out: [PaletteDisplayRow] = []
        out.reserveCapacity(ranked.count)
        for row in ranked {
            if row.item.isSeparator {
                out.append(PaletteDisplayRow(ranked: row, selectableIndex: nil))
            } else {
                out.append(PaletteDisplayRow(ranked: row, selectableIndex: index))
                index += 1
            }
        }
        return out
    }

    /// The id of the row the keyboard currently sits on — what an auto-scroll scrolls TO.
    ///
    /// `nil` when nothing is selectable (a zero-state list, or a selection past the end after the
    /// query narrowed the results), which is a caller's cue to scroll nowhere rather than to the top.
    public static func selectedRowID(_ ranked: [RankedRow], selection: Int) -> String? {
        var index = 0
        for row in ranked where !row.item.isSeparator {
            if index == selection { return row.id }
            index += 1
        }
        return nil
    }

    /// The WORKING DIRECTORY badge's text for the focused pane, or `nil` when there is no badge to
    /// draw.
    ///
    /// The badge hangs off ONE header — the category that owns it — and it is contextual: a pane
    /// whose directory the host has not answered for yet simply has no pill, rather than an empty
    /// one. Stale by an RTT is fine here; it is a label, not a target.
    @preconcurrency
    @MainActor
    public static func workingDirectoryBadge(store: WorkspaceStore) -> String? {
        guard let session = store.tree.activeSession,
              let paneID = session.activeTab?.activePane,
              let cwd = store.paneCwd(for: paneID), !cwd.isEmpty
        else { return nil }
        return PaneSpec.cwdBadgePath(cwd)
    }

    /// Which palette rows currently show their ✓ gutter, as a question each row asks once per draw.
    ///
    /// The gutter is a live READ, not a stored flag: a verb run with ⌘↩ leaves the card up, so the row
    /// the user just toggled has to answer differently the moment they let go of the keys.
    ///
    /// It is built here and handed IN to the palette because the coordinator must never learn what a
    /// sidebar is — it ranks and runs rows, and "is the sidebar showing" is the chrome's own state.
    /// Two of the five do not live on the chrome at all: Read Only and Secure Keyboard Entry are the
    /// ACTIVE PANE's, so they read the store instead, and a gutter that asked the chrome for them
    /// would simply never light.
    @MainActor
    package static func toggledState(
        chrome: WorkspaceChromeState, store: WorkspaceStore,
    ) -> @MainActor (PaletteItem) -> Bool {
        { item in
            switch item.id {
            case "action.toggleSidebar": !chrome.sidebarCollapsed
            case "action.toggleCodeSidebar": !chrome.codeSidebarCollapsed
            case "action.pinWindow": chrome.pinned
            case "action.toggleReadOnly": store.isActivePaneReadOnly()
            case "action.secureKeyboardEntry": store.isActivePaneSecureInputActive()
            default: false
            }
        }
    }

    /// Whether `header` is the section header the badge belongs to.
    ///
    /// Matched by the CATEGORY's own label rather than by "whichever separator sorts first" — the
    /// latter mislabelled a Recents/Actions header before the Working Directory section existed.
    public static func headerOwnsWorkingDirectoryBadge(_ header: String) -> Bool {
        header == PaletteCategory.workingDirectory.label
    }
}
