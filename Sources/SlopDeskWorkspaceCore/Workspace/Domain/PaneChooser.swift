import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - PaneKind presentation metadata (single source of truth)

/// The presentation metadata for a single ``PaneKind``: everything the UI needs to *name*, *icon*,
/// and *offer* a kind without re-deriving it per call site.
///
/// A pure value type filled from `slopdesk_workspace::pane_chooser` — no SwiftUI/AppKit. The `symbol`
/// is an **SF Symbol name string** (e.g. `"apple.terminal"`) so this file stays import-free; the ClientUI
/// layer wraps it in a type-safe `SFSymbol` at the use site.
///
/// The in-pane kind CHOOSER itself is retired (every new-pane gesture mints a terminal directly;
/// non-terminal kinds have their own explicit shortcuts), but this metadata registry remains the one
/// kind → title/symbol source of truth.
public struct PaneChooserOption: Sendable, Equatable {
    /// The pane kind this option mints.
    public let kind: PaneKind
    /// Default display title for a freshly-created pane of this kind.
    public let title: String
    /// SF Symbol *name* (raw string, e.g. `"display"`). Wrapped in a type-safe symbol by the UI layer.
    public let symbol: String
    /// Single-key mnemonic for the (future) chooser — lower-cased; unique across options.
    public let mnemonic: Character
    /// A video (PATH 2) pane that rides the shared UDP flow and counts against the live-video cap.
    ///
    /// It is no longer a value anyone types: the crate fills it from the kind's own `is_video`, so the
    /// "mirrors ``PaneKind/isVideo``" this field used to carry as a comment is now the implementation.
    public let isVideo: Bool

    public init(
        kind: PaneKind,
        title: String,
        symbol: String,
        mnemonic: Character,
        isVideo: Bool,
    ) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.mnemonic = mnemonic
        self.isVideo = isVideo
    }
}

/// The registry that maps a ``PaneKind`` to its presentation metadata, as a face over
/// `slopdesk_workspace::pane_chooser`.
///
/// The TABLE moved: it was three `switch`es across two targets before it was one, and it is now one on
/// the other side of the boundary, where the exhaustive `match` is what makes a new kind a compile
/// error rather than a blank row. What is left here is the crossing — a kind byte out, four fields
/// back.
public enum PaneChooserRegistry {
    /// The presentation metadata for `kind`. Total over ``PaneKind`` (no optional, no fallback): the
    /// crate's table is exhaustive and folds an unknown byte to the terminal row, so every kind names
    /// something.
    public static func option(for kind: PaneKind) -> PaneChooserOption {
        let blob = wsAnswerBytes { out, cap in
            slopdesk_ws_pane_kind_option(WorkspacePaneKindTag.byte(for: kind), out, cap)
        }
        var cursor = blob.startIndex
        let isVideo = blob.first == 1
        cursor += 1
        let fields = (0 ..< 3).map { _ -> String in
            guard cursor + 4 <= blob.endIndex else { return "" }
            let length = Int(
                UInt32(blob[cursor]) << 24 | UInt32(blob[cursor + 1]) << 16
                    | UInt32(blob[cursor + 2]) << 8 | UInt32(blob[cursor + 3]),
            )
            cursor += 4
            guard cursor + length <= blob.endIndex else { return "" }
            defer { cursor += length }
            return String(decoding: blob[cursor ..< cursor + length], as: UTF8.self)
        }
        return PaneChooserOption(
            kind: kind,
            title: fields[0],
            symbol: fields[1],
            // A mnemonic is one character; an empty run would be a delivery this side could not cut,
            // which the crate's own test says cannot happen.
            mnemonic: fields[2].first ?? " ",
            isVideo: isVideo,
        )
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
