import Foundation

// MARK: - Workspace commands (the intent layer)

/// A resolved workspace command — the pure intent the keyboard layer produces and the store
/// later applies (docs/22 §5). SwiftUI `Commands` (macOS menu bar, iPad `UIKeyCommand`) and
/// `.keyboardShortcut` are thin adapters over this tested core; the on-screen compact affordances
/// (`.contextMenu`, swipe) emit the same cases. Keeping it a value type makes the chord → command
/// mapping fully unit-testable with no view.
public enum WorkspaceCommand: Sendable, Equatable {
    case newPane                   // ⌘T   — add a pane to the single canvas
    case tidy                      // ⇧⌘D  — pack panes into a grid
    case centerFocusedPane         // ⌥⌘C  — centre the camera on the focused pane (the pan-only "recenter")
    case centerAll                 // ⌥⇧⌘C — centre the camera on the bounding box of ALL panes
    case closePane                 // ⌘W
    case newGroup                  // ⌃⌘G  — create a new (empty) pane group
    case focus(FocusDirection)     // ⌥⌘←/→/↑/↓
    case cycleFocus(forward: Bool) // ⌘] (forward) / ⌘[ (back)
    case toggleZoom                // ⇧⌘↩  — maximize the focused pane to the viewport
    case renamePane                // ⌘R   — rename the focused pane
    case reconnectPane             // ⇧⌘R — re-dial the focused pane (primary failure recovery)
}

// MARK: - Key chords

/// A keyboard chord: a normalized key token plus its modifier set. The join key of the bindings
/// table (``CommandInterpreter/bindings``). Framework-neutral (no SwiftUI `KeyEquivalent` /
/// `EventModifiers`) so it is pure and `Hashable`-keyable in tests; the platform key adapters
/// translate their native events into this shape.
public struct KeyChord: Hashable, Sendable {
    /// The modifier flags carried by a chord. An `OptionSet` so combinations (⇧⌘, ⌥⌘) compose.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift   = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// A normalized key token. Printable keys are lower-cased single characters (the chord is
    /// modifier-explicit, so case is carried by `.shift`, not by the character); named keys cover
    /// the non-printable keys the workspace binds.
    public enum Key: Hashable, Sendable {
        /// A single printable character, normalized to lower case (e.g. `"d"`, `"]"`, `"1"`).
        case character(Character)
        case tab
        case `return`
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
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
        self.key = .character(Character(character.lowercased()))
        self.modifiers = modifiers
    }
}

// MARK: - The interpreter

/// Maps key chords to ``WorkspaceCommand``s against a rebindable table (docs/22 §5). `@MainActor`
/// because it is owned by the UI.
///
/// Per the WF2 scope this owns ONLY the pure chord → command mapping. It does **not** apply a
/// command to a store (the store does not exist yet); `apply(_:to:)` lives with the store in a
/// later workstream.
@MainActor
public final class CommandInterpreter {
    /// The active bindings. Public + mutable so the UI (or a settings screen) can rebind; defaults
    /// to ``defaultBindings``.
    public var bindings: [KeyChord: WorkspaceCommand]

    /// - Parameters:
    ///   - bindings: the initial chord table (defaults to ``defaultBindings``).
    public init(
        bindings: [KeyChord: WorkspaceCommand] = CommandInterpreter.defaultBindings
    ) {
        self.bindings = bindings
    }

    /// Resolves `chord` to a command, or `nil` if it is not bound (the caller then lets the chord
    /// fall through — e.g. to the focused terminal, per the §5 conflict rule: every workspace
    /// chord is ⌘/⌥-prefixed so plain keys and Ctrl-letters reach the terminal untouched).
    public func feed(_ chord: KeyChord) -> WorkspaceCommand? {
        bindings[chord]
    }
}

// MARK: - Default bindings

public extension CommandInterpreter {
    /// The shipped default chord table (docs/22 §5). Every binding is ⌘- or ⌥-prefixed so it never
    /// shadows a key the terminal needs (the load-bearing conflict rule): focus-move is ⌥⌘+arrows
    /// specifically because plain arrows belong to the shell, and there is no bare-key binding.
    static var defaultBindings: [KeyChord: WorkspaceCommand] {
        var map: [KeyChord: WorkspaceCommand] = [:]

        // Canvas: ⌘T = new pane (the freed "new tab" chord, intuitive for "new"), ⇧⌘D = tidy into a grid.
        map[KeyChord(character: "t", [.command])] = .newPane
        map[KeyChord(character: "d", [.command, .shift])] = .tidy

        // Close the focused pane: ⌘W.
        map[KeyChord(character: "w", [.command])] = .closePane

        // New group: ⌃⌘G (groups organize panes in the sidebar + draw a labeled box on the canvas).
        map[KeyChord(character: "g", [.control, .command])] = .newGroup

        // Geometric focus move: ⌥⌘ + arrows.
        map[KeyChord(.leftArrow, [.option, .command])] = .focus(.left)
        map[KeyChord(.rightArrow, [.option, .command])] = .focus(.right)
        map[KeyChord(.upArrow, [.option, .command])] = .focus(.up)
        map[KeyChord(.downArrow, [.option, .command])] = .focus(.down)

        // Centre the camera: ⌥⌘C on the focused pane, ⌥⇧⌘C on all panes (⌥⌘ avoids the ⌘C copy chord).
        map[KeyChord(character: "c", [.option, .command])] = .centerFocusedPane
        map[KeyChord(character: "c", [.option, .command, .shift])] = .centerAll

        // Cycle focus: ⌘] forward / ⌘[ back.
        map[KeyChord(character: "]", [.command])] = .cycleFocus(forward: true)
        map[KeyChord(character: "[", [.command])] = .cycleFocus(forward: false)

        // Zoom toggle: ⇧⌘↩.
        map[KeyChord(.return, [.command, .shift])] = .toggleZoom

        // Rename the focused pane: ⌘R.
        map[KeyChord(character: "r", [.command])] = .renamePane

        // Reconnect the focused pane: ⇧⌘R. The primary failure-recovery command was palette-only;
        // a chord makes it learnable and surfaces its glyph in the menu + palette automatically.
        map[KeyChord(character: "r", [.command, .shift])] = .reconnectPane

        return map
    }
}
