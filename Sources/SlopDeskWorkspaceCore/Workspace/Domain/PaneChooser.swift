import Foundation

// MARK: - PaneKind presentation metadata (single source of truth)

/// The presentation metadata for a single ``PaneKind``: everything the UI needs to *name*, *icon*,
/// and *offer* a kind without re-deriving it per call site.
///
/// This is the single source of truth that ends the duplicated kind→title / kind→SF-symbol switches:
/// `WorkspaceStore.defaultTitle(for:)` and `NavigatorColumn` (title + symbol) both read these values,
/// so adding a ``PaneKind`` case or changing a title touches ONE place.
///
/// Pure value type — no SwiftUI/AppKit. The `symbol` is an **SF Symbol name string** (e.g.
/// `"apple.terminal"`) so this file stays import-free; the ClientUI layer wraps it in a type-safe
/// `SFSymbol` at the use site.
///
/// The in-pane kind CHOOSER itself is retired (every new-pane gesture mints a terminal directly;
/// non-terminal kinds have their own explicit shortcuts), but this metadata registry remains the one
/// kind → title/symbol source of truth.
public struct PaneChooserOption: Sendable, Equatable {
    /// The pane kind this option mints.
    public let kind: PaneKind
    /// Default display title for a freshly-created pane of this kind (the EXACT historical string).
    public let title: String
    /// SF Symbol *name* (raw string, e.g. `"display"`). Wrapped in a type-safe symbol by the UI layer.
    public let symbol: String
    /// Single-key mnemonic for the (future) chooser — lower-cased; unique across options.
    public let mnemonic: Character
    /// A video (PATH 2) pane that rides the shared UDP flow and counts against the live-video cap.
    /// Mirrors ``PaneKind/isVideo`` (kept here so the option is self-describing for chooser rows).
    public let isVideo: Bool
    /// Whether resolving this option must first run the remote-window picker (it cannot mint a bare
    /// pane — it needs a host-side window id). True for ``PaneKind/remoteGUI``.
    public let requiresWindowPick: Bool

    public init(
        kind: PaneKind,
        title: String,
        symbol: String,
        mnemonic: Character,
        isVideo: Bool,
        requiresWindowPick: Bool,
    ) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.mnemonic = mnemonic
        self.isVideo = isVideo
        self.requiresWindowPick = requiresWindowPick
    }
}

/// The registry that maps a ``PaneKind`` to its presentation metadata. Exhaustive over every
/// ``PaneKind`` case — the `switch` is the compile-time guarantee that a new kind cannot be added
/// without giving it a title/symbol/mnemonic here.
public enum PaneChooserRegistry {
    /// The presentation metadata for `kind`. Total over ``PaneKind`` (no optional, no fallback): a
    /// new case forces a compile error here, which is the whole point of centralizing.
    public static func option(for kind: PaneKind) -> PaneChooserOption {
        switch kind {
        case .terminal:
            PaneChooserOption(
                kind: .terminal,
                title: "Terminal",
                symbol: "apple.terminal",
                mnemonic: "t",
                isVideo: false,
                requiresWindowPick: false,
            )
        case .remoteGUI:
            PaneChooserOption(
                kind: .remoteGUI,
                title: "Remote window",
                symbol: "macwindow",
                mnemonic: "r",
                isVideo: true,
                requiresWindowPick: true,
            )
        case .desktop:
            PaneChooserOption(
                kind: .desktop,
                title: "Desktop",
                symbol: "display",
                mnemonic: "d",
                isVideo: true,
                requiresWindowPick: false, // the display target is fixed at mint (0 = main display)
            )
        case .systemDialog:
            PaneChooserOption(
                kind: .systemDialog,
                title: "System dialog",
                symbol: "lock.shield",
                mnemonic: "s",
                isVideo: true,
                requiresWindowPick: false,
            )
        }
    }
}

// MARK: - New-pane placement (the placement intent of a new-pane gesture)

/// WHERE a new-pane gesture was triggered from — carried to ``WorkspaceStore/newTerminalPane(_:)`` so it
/// places the new `.terminal` pane (`.newTab → newTab`, `.split → split the active pane`). Pure value.
/// (Formerly `PaneChooserContext`; the in-pane kind chooser is retired — the gesture mints a terminal
/// directly — but the placement intent it carried is unchanged.)
public enum NewPanePlacement: Sendable, Equatable {
    /// New tab in the active session (the `+` button / ⌘T-equivalent generic action).
    case newTab
    /// Split the active pane along `axis`. `leading == true` inserts the new leaf on the
    /// LEADING side of the active pane (left of a `.horizontal` split / above a `.vertical` split) rather
    /// than the natural trailing side — the split-left (⌘⌥D) / split-up (⌘⌥⇧D) chords feed `leading:
    /// true`, every other split (the ⌘D right / ⌘⇧D down) keeps the default trailing insert. Defaulted so
    /// every existing `.split(axis:)` call site is byte-identical.
    case split(axis: SplitAxis, leading: Bool = false)
}
