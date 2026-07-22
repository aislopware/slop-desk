import Foundation

// MARK: - Workspace commands (the intent layer)

/// A resolved workspace command — the pure intent the keyboard layer produces and the store
/// later applies (docs/22 §5). SwiftUI `Commands`, `.keyboardShortcut`, and the compact
/// affordances (`.contextMenu`, swipe) are thin adapters emitting the same cases. A value type
/// so the chord → command mapping is fully unit-testable with no view.
public enum WorkspaceCommand: Sendable, Equatable {
    case newPaneDefault // ⌘N   — a pane of the user's default kind (Settings ▸ Canvas)
    case newPane(PaneKind) // ⌘T terminal, ⌥⌘N remoteGUI
    case duplicatePane // ⌘D   — copy the focused pane's spec (incl. endpoint) beside it
    case tidy // ⇧⌘D  — pack panes into a grid
    case centerFocusedPane // ⌥⌘C  — centre the camera on the focused pane (the pan-only "recenter")
    case centerAll // ⌥⇧⌘C — centre the camera on the bounding box of ALL panes
    case closePane // ⌘W
    case reopenClosedPane // ⇧⌘T  — restore the last closed pane (browser "reopen tab" idiom)
    case newGroup // ⌃⌘G  — group the selection (≥1 selected), else a new empty group
    case groupSelection // ⌥⌘G  — group the current multi-selection into a new group
    case focus(FocusDirection) // ⌥⌘←/→/↑/↓
    case cycleFocus(forward: Bool) // ⌘] (forward) / ⌘[ (back)
    case switchRecentPane(forward: Bool) // ⌥⌘; (to the previously-focused pane) / ⌥⇧⌘; (back toward newer)
    case cycleFocusInGroup(forward: Bool) // ⌃⌘] / ⌃⌘[ — cycle focus WITHIN the focused pane's group only
    case toggleZoom // ⇧⌘↩  — maximize the focused pane to the viewport
    case toggleOverview // ⌘\   — fit-all overview (Mission Control for the canvas)
    case toggleBroadcast // ⇧⌘B — arm/disarm synchronized input to the pane group (tmux synchronize-panes)
    case renamePane // ⌘R   — rename the focused pane
    case reconnectPane // ⇧⌘R — re-dial the focused pane (primary failure recovery)
    case saveBookmark(Int) // ⇧⌘1–9 — save the viewport as bookmark n
    case recallBookmark(Int) // ⌘1–9  — jump back to bookmark n
    case align(AlignEdge) // align the Arrange targets (selection ≥2, else all) to an edge/centre
    case distribute(horizontal: Bool) // even-space the Arrange targets horizontally / vertically
    case saveLayout // open the "Save Current Layout…" prompt
    case selectAllPanes // ⌥⌘A — multi-select every pane on the canvas
}

public extension WorkspaceCommand {
    /// Whether this command is worth surfacing in the ⌘K palette's "recents" — action VERBS only, not
    /// navigation/transient moves (focus, cycle, bookmarks) that would churn the small recents ring.
    /// Recorded at the ``apply(_:to:)`` chokepoint so a verb run by keyboard or menu (not just the
    /// palette) populates recents.
    var isRecentsWorthy: Bool {
        switch self {
        case .focus,
             .cycleFocus,
             .switchRecentPane,
             .cycleFocusInGroup,
             .saveBookmark,
             .recallBookmark,
             .centerFocusedPane,
             .centerAll,
             .selectAllPanes:
            false
        default:
            true
        }
    }

    /// Whether this command acts on "the focused pane" (a no-op without one) so the ⌘K palette can OMIT
    /// it on an empty canvas ("Close Pane" with nothing to close reads as broken). Creation / camera /
    /// global verbs don't require a focused pane and always show.
    var requiresFocusedPane: Bool {
        switch self {
        case .duplicatePane,
             .closePane,
             .renamePane,
             .reconnectPane,
             .toggleZoom,
             .centerFocusedPane:
            true
        default:
            false
        }
    }
}

// MARK: - Key chords

/// A keyboard chord: a normalized key token plus its modifier set. The join key of the bindings
/// table (``CommandInterpreter/bindings``). Framework-neutral (no SwiftUI `KeyEquivalent` /
/// `EventModifiers`) so it stays pure and `Hashable`-keyable in tests; platform adapters translate
/// native events into this shape.
public struct KeyChord: Hashable, Sendable {
    /// The modifier flags carried by a chord. An `OptionSet` so combinations (⇧⌘, ⌥⌘) compose.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Self(rawValue: 1 << 0)
        public static let control = Self(rawValue: 1 << 1)
        public static let option = Self(rawValue: 1 << 2)
        public static let command = Self(rawValue: 1 << 3)
    }

    /// A normalized key token. Printable keys are lower-cased single characters (the chord is
    /// modifier-explicit, so case is carried by `.shift`, not by the character); named keys cover
    /// the non-printable keys the workspace binds.
    public enum Key: Hashable, Sendable {
        /// A single printable character, normalized to lower case (e.g. `"d"`, `"]"`, `"1"`).
        case character(Character)
        case tab
        case `return`
        /// The Space bar as a NAMED key (keyCode 49), NOT `.character(" ")` — the macOS normalizer rejects a
        /// whitespace character, so a Space chord must be named (like Tab/Return). Only ever bound with a
        /// non-shift modifier (Vi Mode entry is ⌃⇧Space); a bare/⇧-only Space stays normal typing.
        case space
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
        /// Non-printable named navigation keys (terminal-native shift-scroll / page-jump chords). The one
        /// exemption to the "every workspace chord is ⌘/⌥-prefixed" §5 rule — a ⇧-prefixed named key cannot
        /// steal a printable terminal letter (E1 scroll bindings).
        case pageUp
        case pageDown
        case home
        case end
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Convenience for a printable-character chord, lower-casing the character so binding lookups
    /// are case-insensitive on the base key (⇧ is expressed in `modifiers`, not in the char).
    public init(character: Character, _ modifiers: Modifiers = []) {
        key = .character(Character(character.lowercased()))
        self.modifiers = modifiers
    }
}

// MARK: - The interpreter

/// Maps key chords to ``WorkspaceCommand``s against a rebindable table (docs/22 §5). `@MainActor`
/// because it is owned by the UI.
///
/// Per WF2 scope this owns ONLY the pure chord → command mapping — it does **not** apply a command
/// to a store; `apply(_:to:)` lives with the store in a later workstream.
@preconcurrency
@MainActor
public final class CommandInterpreter {
    /// The active bindings. Public + mutable so the UI (or a settings screen) can rebind; defaults
    /// to ``defaultBindings``.
    public var bindings: [KeyChord: WorkspaceCommand]

    /// - Parameters:
    ///   - bindings: the initial chord table (defaults to ``defaultBindings``).
    public init(
        bindings: [KeyChord: WorkspaceCommand] = CommandInterpreter.defaultBindings,
    ) {
        self.bindings = bindings
    }

    /// Resolves `chord` to a command, or `nil` if unbound (the caller then lets the chord fall through
    /// — e.g. to the focused terminal, per the §5 conflict rule: every workspace chord is ⌘/⌥-prefixed
    /// so plain keys and Ctrl-letters reach the terminal untouched).
    public func feed(_ chord: KeyChord) -> WorkspaceCommand? {
        bindings[chord]
    }

    /// Every default chord bound to `command`, in a DETERMINISTIC display order (fewest modifiers first,
    /// ties broken lexicographically). A command may carry more than one chord (⌘N and the ⌘T alias both
    /// make a terminal pane), so a naive `first { $0.value == command }` reverse lookup would be
    /// dictionary-order nondeterministic — every shortcut-display site (menu items, palette hints) goes
    /// through this instead. `[0]` is the canonical chord.
    public static func defaultChords(for command: WorkspaceCommand) -> [KeyChord] {
        defaultBindings
            .filter { $0.value == command }
            .map(\.key)
            .sorted { a, b in
                let (ma, mb) = (a.modifiers.rawValue.nonzeroBitCount, b.modifiers.rawValue.nonzeroBitCount)
                if ma != mb { return ma < mb }
                return describe(a) < describe(b)
            }
    }

    /// A pure, stable textual form for the deterministic sort above (NOT a display string — the
    /// palette owns glyph rendering).
    private static func describe(_ chord: KeyChord) -> String {
        let key =
            switch chord.key {
            case let .character(c): String(c)
            case .tab: "\u{F700}tab"
            case .return: "\u{F700}return"
            case .space: "\u{F700}space"
            case .leftArrow: "\u{F700}left"
            case .rightArrow: "\u{F700}right"
            case .upArrow: "\u{F700}up"
            case .downArrow: "\u{F700}down"
            case .pageUp: "\u{F700}pageup"
            case .pageDown: "\u{F700}pagedown"
            case .home: "\u{F700}home"
            case .end: "\u{F700}end"
            }
        return "\(chord.modifiers.rawValue)-\(key)"
    }
}

// MARK: - Default bindings

public extension CommandInterpreter {
    /// The shipped default chord table (docs/22 §5). Every binding is ⌘- or ⌥-prefixed so it never
    /// shadows a key the terminal needs (the load-bearing conflict rule): focus-move is ⌥⌘+arrows
    /// specifically because plain arrows belong to the shell, and there is no bare-key binding.
    static var defaultBindings: [KeyChord: WorkspaceCommand] {
        var map: [KeyChord: WorkspaceCommand] = [:]

        // New pane. ⌘N = macOS-native "new" (the File menu replaces New-Window, so ⌘N makes a pane not
        // an unwanted second window) creating the user's DEFAULT kind (Settings ▸ Canvas, default
        // Terminal). ⌘T is the muscle-memory alias that always makes a Terminal (the freed "new tab"
        // chord). ⌥⌘N makes a Remote Window. There is no dedicated Claude Code pane kind — a `claude`
        // process is auto-detected in any terminal — so ⇧⌘N stays unbound.
        map[KeyChord(character: "n", [.command])] = .newPaneDefault
        map[KeyChord(character: "t", [.command])] = .newPane(.terminal)
        map[KeyChord(character: "n", [.command, .option])] = .newPane(.remoteGUI)

        // Duplicate the focused pane (spec + endpoint + group, cascaded beside it): ⌘D — the Finder
        // duplicate idiom. (⇧⌘D = tidy, unchanged.)
        map[KeyChord(character: "d", [.command])] = .duplicatePane

        // ⇧⌘D = tidy into a grid.
        map[KeyChord(character: "d", [.command, .shift])] = .tidy

        // Close the focused pane: ⌘W. Reopen the last closed pane: ⇧⌘T (browser idiom, beside ⌘T = new
        // pane). NOT ⌘Z — that belongs to text-field undo (the inline rename fields), which a menu-level
        // binding would shadow.
        map[KeyChord(character: "w", [.command])] = .closePane
        map[KeyChord(character: "t", [.command, .shift])] = .reopenClosedPane

        // New group: ⌃⌘G (groups organize panes in the sidebar + draw a labeled box). Context-sensitive in
        // `apply`: with a multi-selection it groups the selection, else makes an empty group. ⌥⌘G is the
        // explicit "Group Selected Panes" (no-op without a selection).
        map[KeyChord(character: "g", [.control, .command])] = .newGroup
        map[KeyChord(character: "g", [.option, .command])] = .groupSelection

        // Geometric focus move: ⌃⌘ + arrows (the documented default — spec/reference__keybindings.md:82-85).
        map[KeyChord(.leftArrow, [.control, .command])] = .focus(.left)
        map[KeyChord(.rightArrow, [.control, .command])] = .focus(.right)
        map[KeyChord(.upArrow, [.control, .command])] = .focus(.up)
        map[KeyChord(.downArrow, [.control, .command])] = .focus(.down)

        // Centre the camera: ⌥⌘C on the focused pane, ⌥⇧⌘C on all panes (⌥⌘ avoids the ⌘C copy chord).
        map[KeyChord(character: "c", [.option, .command])] = .centerFocusedPane
        map[KeyChord(character: "c", [.option, .command, .shift])] = .centerAll

        // Select all panes (multi-select): ⌥⌘A. NOT ⌘A — that bare chord is the focused terminal's
        // select-all-text (libghostty performKeyEquivalent); the workspace table never binds ⌘C/V/A.
        map[KeyChord(character: "a", [.option, .command])] = .selectAllPanes

        // Cycle focus: ⌘] forward / ⌘[ back.
        map[KeyChord(character: "]", [.command])] = .cycleFocus(forward: true)
        map[KeyChord(character: "[", [.command])] = .cycleFocus(forward: false)

        // Recent-pane quick-switch ("go to last pane"): ⌥⌘; jumps to the previously-focused pane (toward
        // OLDER in the focus-history MRU), ⌥⇧⌘; walks back toward newer. ⌥⌘-prefixed (";" is free for the
        // terminal). `forward:false` = toward the previous pane (the primary action).
        map[KeyChord(character: ";", [.option, .command])] = .switchRecentPane(forward: false)
        map[KeyChord(character: ";", [.option, .command, .shift])] = .switchRecentPane(forward: true)

        // Cycle focus WITHIN the focused pane's group only: ⌃⌘] forward / ⌃⌘[ back — companion to the
        // whole-canvas ⌘]/⌘[, so a cluster is navigable in isolation. ⌃⌘ (the newGroup prefix) is a safe
        // ⌘-carrying chord; "]"/"[" are not Ctrl-letters the terminal needs.
        map[KeyChord(character: "]", [.control, .command])] = .cycleFocusInGroup(forward: true)
        map[KeyChord(character: "[", [.control, .command])] = .cycleFocusInGroup(forward: false)

        // Zoom toggle: ⇧⌘↩.
        map[KeyChord(.return, [.command, .shift])] = .toggleZoom

        // Overview (fit-all "Mission Control"): ⌘\ — a free chord the terminal never needs.
        map[KeyChord(character: "\\", [.command])] = .toggleOverview

        // Broadcast / synchronized input: ⇧⌘B arms fan-out of input to the pane group (tmux
        // synchronize-panes). ⇧⌘ so it never shadows a terminal key (plain b / Ctrl-B reach the shell).
        map[KeyChord(character: "b", [.command, .shift])] = .toggleBroadcast

        // Rename the focused pane: ⌘R.
        map[KeyChord(character: "r", [.command])] = .renamePane

        // Reconnect the focused pane: ⇧⌘R — the primary failure-recovery command, bound so it's learnable
        // as a chord and surfaces its glyph in the menu + palette (not palette-only).
        map[KeyChord(character: "r", [.command, .shift])] = .reconnectPane

        // Viewport bookmarks: ⇧⌘n saves the current viewport into slot n, ⌘n jumps back — the
        // single-key spatial loop a pan-only canvas needs (no tabs ever claimed ⌘1–9 here).
        for n in 1...9 {
            let digit = Character("\(n)")
            map[KeyChord(character: digit, [.command, .shift])] = .saveBookmark(n)
            map[KeyChord(character: digit, [.command])] = .recallBookmark(n)
        }

        return map
    }
}
