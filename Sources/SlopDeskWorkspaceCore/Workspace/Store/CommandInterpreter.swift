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

// MARK: - Key sequences (multi-key / prefix bindings)

/// An ordered, non-empty list of ``KeyChord``s — the tmux/zellij prefix idiom (e.g. `⌃B` then `D`).
/// A single-chord binding is the degenerate length-1 sequence; the prefix machine walks a sequence
/// chord-by-chord. Pure / `Hashable` / value-typed so the chord → action mapping is unit-testable
/// with no view.
///
/// Invariant: ``chords`` is never empty — the initialiser returns `nil` for an empty list
/// (validate-then-default), so a sequence value always has a first key.
public struct KeySequence: Hashable, Sendable {
    /// The chords in press order. Guaranteed non-empty.
    public let chords: [KeyChord]

    /// Build a sequence from `chords`; returns `nil` for an EMPTY list (a sequence must have ≥1 chord).
    public init?(_ chords: [KeyChord]) {
        guard !chords.isEmpty else { return nil }
        self.chords = chords
    }

    /// A single-chord (length-1) sequence — bridges an ordinary chord into the sequence world (so a
    /// single chord and a 1-element sequence compare equal where it matters).
    public init(single chord: KeyChord) {
        chords = [chord]
    }

    /// The first chord — the PREFIX a multi-key sequence arms on (and the only chord of a single binding).
    public var head: KeyChord { chords[0] }

    /// Whether this is a multi-key sequence (≥2 chords) rather than a plain single chord.
    public var isMultiKey: Bool { chords.count > 1 }
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

// MARK: - Prefix state machine (tmux/zellij-style multi-key prefix)

/// What the prefix state machine decides a keystroke MEANS — the view layer (B3 / GhosttyTerminalView /
/// the iOS substrate) maps this to swallow-or-forward, keeping ALL transition logic in the machine. A pure
/// value type so the whole machine is unit-testable with no AppKit.
public enum PrefixIntent: Equatable, Sendable {
    /// Let the keystroke through UNCHANGED — normal typing / a chord the workspace does not own. The view
    /// forwards `chord` to the focused PTY / video pane. The machine is (or stays) idle.
    case passthrough(KeyChord)
    /// The prefix key was pressed from idle: ARM the machine and SWALLOW the key (do not leak the prefix to
    /// the terminal). The view forwards nothing.
    case consumedArm
    /// A bound key/sequence resolved while armed: run `action` and SWALLOW the key. The view dispatches the
    /// action (e.g. via `WorkspaceBindingRegistry.route`) and forwards nothing.
    case resolved(WorkspaceAction)
    /// The prefix was pressed AGAIN while armed (double-tap): emit the LITERAL prefix byte to the focused
    /// pane/PTY (tmux `send-prefix`) and DISARM. The view forwards the prefix chord's bytes once.
    case sendPrefixLiteral
    /// An UNBOUND key was pressed while armed (or the arm timed out and a key arrived): DISARM and SWALLOW
    /// the key (tmux-faithful — the prefix is NOT replayed, and the follow-up key is eaten). The view
    /// forwards nothing.
    case disarmSwallow
}

/// A PURE, clock-injected tmux/zellij-style prefix state machine (mirrors ``ClaudeStatusMachine``'s
/// clock-injection precedent — every `feed` takes an absolute `now`, the machine NEVER calls `Date()`).
///
/// PREFIX POLICY (decided):
///   1. idle + the prefix       → ARM (swallow, never leak the prefix). → `.consumedArm`
///   2. armed + a bound key/seq → resolve the action (swallow); a BARE key also resolves via its
///      implied-⌘ chord (`prefix, d` → the ⌘D binding — tmux's prefix-converts-the-next-key idiom).
///                                                                       → `.resolved(action)`
///   3. armed + the prefix AGAIN → emit the literal prefix byte (send-prefix passthrough), disarm.
///                                                                       → `.sendPrefixLiteral`
///   4. armed + escape-timeout  → the arm has expired; an arriving key is treated as idle (passthrough /
///      arm), i.e. the timeout makes the machine fall back to idle BEFORE classifying the key.
///   5. armed + an UNBOUND key  → disarm and SWALLOW that key (tmux-faithful; the prefix is NOT replayed).
///                                                                       → `.disarmSwallow`
///   6. idle + a bare key       → ALWAYS passthrough (never swallow normal typing).   → `.passthrough`
///
/// The prefix is CONFIGURABLE (default `⌃B` — ``WorkspaceBindingRegistry/defaultPrefixChord``) so the user
/// can move it off a Ctrl-letter; resolve the configured chord from config / `PreferencesStore` and inject
/// it here. The machine NEVER leaks the prefix to the terminal while armed.
@preconcurrency
@MainActor
public final class PrefixStateMachine {
    /// The configured prefix chord (default `⌃B`). From idle it arms the machine; again while armed it sends
    /// the literal prefix byte (double-tap passthrough). CONFIGURABLE so the user can move it off a Ctrl-letter.
    public var prefix: KeyChord

    /// The escape timeout (seconds). An armed machine that has not seen a follow-up key within this window
    /// silently falls back to idle, so a stale arm never eats a later normal keystroke.
    public var timeout: TimeInterval

    /// Resolve a post-prefix key to its action, or `nil` if UNBOUND while armed. Injected (the live
    /// dispatcher passes a lookup over ``WorkspaceBindingRegistry/resolvedChordTable``); pure so the machine
    /// stays headless-testable. The SINGLE-chord fallback — consulted only after the multi-key
    /// ``resolveSequenceAfterPrefix`` (when injected) misses, so a prefix sequence whose tail key is ALSO a
    /// standalone binding keeps resolving as before.
    public var resolveAfterPrefix: (KeyChord) -> WorkspaceAction?

    /// Resolve a COMPLETED multi-key prefix sequence (the full `[prefix, follow-up]` ``KeySequence``) to its
    /// action, or `nil` if no sequence binding matches. Injected (a lookup over
    /// ``WorkspaceBindingRegistry/resolvedSequenceTable``); `nil` when unset, in which case the machine
    /// falls back to resolving the follow-up via ``resolveAfterPrefix`` alone (plain single-chord
    /// resolution). Consulted FIRST while armed so a user-defined sequence whose tail key is NOT a
    /// standalone binding still fires. Keeping it here keeps ALL prefix transition logic in this machine.
    public var resolveSequenceAfterPrefix: ((KeySequence) -> WorkspaceAction?)?

    /// Internal state: idle, or armed at an absolute time (the escape-timeout anchor).
    private enum State: Equatable {
        case idle
        case armed(since: TimeInterval)
    }

    private var state: State = .idle

    /// Whether the machine is currently armed (the prefix has been pressed and the follow-up key awaited).
    /// Exposed so a view can show a "prefix armed" affordance. NOT time-aware on its own — a read does not
    /// expire a stale arm (only `feed`/`expireIfStale` do).
    public var isArmed: Bool {
        if case .armed = state { return true }
        return false
    }

    public init(
        prefix: KeyChord = WorkspaceBindingRegistry.defaultPrefixChord,
        timeout: TimeInterval = 1,
        resolveAfterPrefix: @escaping (KeyChord) -> WorkspaceAction? = { _ in nil },
        resolveSequenceAfterPrefix: ((KeySequence) -> WorkspaceAction?)? = nil,
    ) {
        self.prefix = prefix
        // Ordered max guards a negative / NaN injected timeout (validate-then-clamp; NaN-faithful ordered
        // max per the repo convention, never a bare `<` ternary).
        self.timeout = Double.maximum(0, timeout)
        self.resolveAfterPrefix = resolveAfterPrefix
        self.resolveSequenceAfterPrefix = resolveSequenceAfterPrefix
    }

    /// Fold one keystroke at absolute time `now`, returning the ``PrefixIntent`` the view maps to
    /// swallow-or-forward. Idempotent on the state it leaves behind; never traps on any chord.
    public func feed(_ chord: KeyChord, at now: TimeInterval) -> PrefixIntent {
        // Step 4: a stale arm expires to idle BEFORE the key is classified, so a late key is normal typing.
        expireIfStale(at: now)

        switch state {
        case .idle:
            if chord == prefix {
                // Step 1: arm + swallow the prefix (never leak it).
                state = .armed(since: now)
                return .consumedArm
            }
            // Step 6: a bare key in idle ALWAYS passes through (never swallow normal typing).
            return .passthrough(chord)

        case .armed:
            if chord == prefix {
                // Step 3: double-tap the prefix → send the literal prefix byte, disarm.
                state = .idle
                return .sendPrefixLiteral
            }
            // Disarm on any follow-up key (resolved or not — the arm is single-shot for one key/sequence).
            state = .idle
            // Step 2a: the COMPLETED multi-key sequence `[prefix, chord]` resolves FIRST (when a sequence
            // resolver is injected), so a user-defined prefix sequence whose tail key is NOT a standalone
            // binding still fires. The single-chord `resolveAfterPrefix` is the fallback below.
            if let resolveSequence = resolveSequenceAfterPrefix,
               let sequence = KeySequence([prefix, chord]),
               let action = resolveSequence(sequence)
            {
                return .resolved(action)
            }
            if let action = resolveAfterPrefix(chord) {
                // Step 2: a bound single chord resolves its action (swallowed).
                return .resolved(action)
            }
            // Step 2b: the tmux-faithful BARE follow-up — `prefix, d` fires the ⌘D binding. Every workspace
            // chord is ⌘/⌥-prefixed (the §5 conflict rule), so a bare armed key can never hit the table
            // directly; folding ⌘ in resolves it as its command chord (⇧/⌥ carry through: `prefix, ⇧d` →
            // ⌘⇧D). ONLY while armed — an idle bare key is normal typing and never reaches this branch.
            if !chord.modifiers.contains(.command) {
                let folded = KeyChord(chord.key, chord.modifiers.union(.command))
                if let action = resolveAfterPrefix(folded) {
                    return .resolved(action)
                }
            }
            // Step 5: an unbound key disarms + is SWALLOWED (tmux-faithful; the prefix is NOT replayed).
            return .disarmSwallow
        }
    }

    /// Expire a stale arm to idle if `now` has passed the escape-timeout deadline. Public so a view's idle
    /// timer (or a `tick`) can disarm the affordance without a keystroke; called internally by `feed` so a
    /// late key is classified as idle. No-op when not armed or still within the window.
    public func expireIfStale(at now: TimeInterval) {
        guard case let .armed(since) = state else { return }
        // Ordered comparison (the arm expires once `now` reaches `since + timeout`). Using `>=` on plain
        // Doubles is fine here (no NaN: `now`/`since` are caller-supplied monotonic timestamps).
        if now - since >= timeout { state = .idle }
    }

    /// Force the machine back to idle (e.g. focus loss / explicit Escape from the view). Swallows nothing on
    /// its own — the view decides; this only clears the armed state.
    public func disarm() {
        state = .idle
    }
}
