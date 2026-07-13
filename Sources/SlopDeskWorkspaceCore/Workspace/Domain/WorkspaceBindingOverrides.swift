import Foundation
import SlopDeskVideoProtocol

// MARK: - WorkspaceBindingRegistry × KeybindingPreferences (user overrides)

/// The wiring that makes ``WorkspaceBindingRegistry`` resolve a chord using the
/// ``KeybindingPreferences`` OVERRIDE when one is present — WITHOUT duplicating the binding table. The
/// registry stays the single source of truth for the available commands + their DEFAULT chords; this
/// extension layers a sparse `bindingID → chord` override map on top.
///
/// Two `KeyChord` shapes meet here:
///   • the registry's framework-neutral ``KeyChord`` (enum `Key` + `Modifiers` OptionSet), the keyboard
///     dispatcher's join key;
///   • the serialisable ``KeybindingPreferences/KeyChord`` (a `key: String` + four `Bool` modifier
///     flags), what the Settings UI stores + round-trips.
/// ``KeybindingPreferences/KeyChord/asRegistryChord`` maps the persisted shape into the dispatcher
/// shape so `resolvedChord(for:)` and `resolvedChordTable` honour an override transparently.
public extension WorkspaceBindingRegistry {
    /// The process-wide live keybinding overrides, published by the ``PreferencesStore`` on a settings
    /// change. EMPTY by default ⇒ every binding resolves to its registry default ⇒ behaviour-identical
    /// to the no-override registry. `nonisolated(unsafe)` for the same write-once-then-read-many contract
    /// as ``EnvConfig/overlay``: the store sets it on the main actor; the dispatcher reads it.
    nonisolated(unsafe) static var activeOverrides = KeybindingPreferences()

    /// The chord that should fire `action` RIGHT NOW: the user override (if one is set for the action's
    /// binding id) else the registry default. The keyboard dispatcher + the menu-shortcut derivation use
    /// this so a rebind takes effect everywhere from one place.
    static func resolvedChord(for action: WorkspaceAction) -> KeyChord? {
        resolvedChord(for: action, overrides: activeOverrides)
    }

    /// Override-aware resolution against an EXPLICIT override set (the pure, testable form). An override
    /// for the action's binding id (`KeybindingPreferences.chord(for:)`) wins; otherwise the registry
    /// default stands. An override whose persisted chord can't map to a registry chord (a malformed
    /// stored value) is IGNORED → falls back to the default (validate-then-default, never traps).
    static func resolvedChord(for action: WorkspaceAction, overrides: KeybindingPreferences) -> KeyChord? {
        guard let binding = binding(for: action) else { return nil }
        if let override = overrides.chord(for: binding.id), let mapped = override.asRegistryChord {
            return mapped
        }
        return binding.chord
    }

    /// The chord → action lookup table WITH the active overrides applied — the override-aware sibling of
    /// ``chordTable``. The keyboard dispatcher reads THIS so a rebind routes the new chord. A binding whose
    /// override collides with another binding's chord is last-writer-wins in the map (the UI surfaces the
    /// collision via ``KeybindingPreferences/conflicts()`` so the user resolves it).
    static var resolvedChordTable: [KeyChord: WorkspaceAction] {
        resolvedChordTable(overrides: activeOverrides)
    }

    /// The override-aware chord table against an explicit override set (pure, testable). Folds in
    /// ``aliasChords`` (the ⌘+ font-increase alias, etc.) AFTER the resolved bindings — but only onto a chord
    /// the user has not rebound onto, so an override always wins (the alias is a free second chord, never a
    /// squatter). This is the table the live dispatcher reads, so the aliases fire at runtime too.
    static func resolvedChordTable(overrides: KeybindingPreferences) -> [KeyChord: WorkspaceAction] {
        var map: [KeyChord: WorkspaceAction] = [:]
        for binding in allBindings {
            if let chord = resolvedChord(for: binding.action, overrides: overrides) {
                map[chord] = binding.action
            }
        }
        for (chord, action) in aliasChords where map[chord] == nil { map[chord] = action }
        return map
    }

    // MARK: - Prefix-key resolution (the tmux-style workspace prefix chord)

    /// The DEFAULT workspace prefix chord — ⌃B. The single source every prefix consumer defaults to
    /// (`WorkspaceStore.workspaceKeyPrefix`, `TerminalKeyInterceptor`, `PrefixStateMachine`), so the app
    /// monitor and the per-surface interceptors can never disagree on the out-of-the-box prefix. ⌃B (not
    /// tmux's ⌃A / screen's ⌃A): ⌃A is readline beginning-of-line — heavily typed at a shell prompt — while
    /// ⌃B (backward-char) has the arrow keys as its idiomatic spelling, so claiming it costs the PTY least.
    /// The double-tap send-prefix still delivers the literal 0x02 when it's genuinely wanted.
    nonisolated static let defaultPrefixChord = KeyChord(character: "b", [.control])

    /// The workspace prefix chord that should arm RIGHT NOW: the user override (Settings ▸ Key Bindings ▸
    /// Prefix Key) if one is set AND usable, else ``defaultPrefixChord``.
    static var resolvedPrefixChord: KeyChord {
        resolvedPrefixChord(overrides: activeOverrides)
    }

    /// Prefix resolution against an EXPLICIT override set (pure, testable). Validate-then-default: a stored
    /// chord that can't map to a registry chord, or that carries NO ⌃/⌥/⌘ modifier (a bare or shift-only key
    /// as prefix would swallow normal typing), is IGNORED → the default stands. Never traps.
    static func resolvedPrefixChord(overrides: KeybindingPreferences) -> KeyChord {
        guard let stored = overrides.prefixKey, let mapped = stored.asRegistryChord,
              !mapped.modifiers.isDisjoint(with: [.control, .option, .command])
        else { return defaultPrefixChord }
        return mapped
    }

    // MARK: - Sequence-aware resolution (prefix sequences)

    /// The full SEQUENCE that should fire `action` RIGHT NOW: the user override sequence (single-chord OR
    /// multi-key) if one is set for the action's binding id, else the registry default sequence. The prefix
    /// dispatcher reads this so a rebind to a multi-key prefix takes effect everywhere from one place.
    static func resolvedSequence(for action: WorkspaceAction) -> KeySequence? {
        resolvedSequence(for: action, overrides: activeOverrides)
    }

    /// Sequence resolution against an EXPLICIT override set (pure, testable). An override sequence whose
    /// chords can't all map to registry chords (a malformed stored value) is IGNORED → falls back to the
    /// registry default (validate-then-default, never traps).
    static func resolvedSequence(for action: WorkspaceAction, overrides: KeybindingPreferences) -> KeySequence? {
        guard let binding = binding(for: action) else { return nil }
        if let override = overrides.sequence(for: binding.id), let mapped = override.asRegistrySequence {
            return mapped
        }
        return binding.effectiveSequence
    }

    /// The sequence → action lookup table WITH the active overrides applied — the override-aware sibling of
    /// ``sequenceTable``. The prefix state machine reads THIS so a rebind (single OR multi-key) routes.
    static var resolvedSequenceTable: [KeySequence: WorkspaceAction] {
        resolvedSequenceTable(overrides: activeOverrides)
    }

    /// The override-aware sequence table against an explicit override set (pure, testable).
    static func resolvedSequenceTable(overrides: KeybindingPreferences) -> [KeySequence: WorkspaceAction] {
        var map: [KeySequence: WorkspaceAction] = [:]
        for binding in allBindings {
            if let seq = resolvedSequence(for: binding.action, overrides: overrides) {
                map[seq] = binding.action
            }
        }
        return map
    }
}

// MARK: - Text-binding / unbind resolution

/// The dispatcher consults these BEFORE the action table. A `text:`/`csi:`/`esc:` config binding
/// sends raw bytes to the focused terminal (a literal-byte binding); an `unbind:` suppresses the
/// default action so the chord passes through to the responder chain. Both maps are keyed by the persisted
/// ``KeybindingPreferences/KeyChord`` shape, so a registry ``KeyChord`` (what the live dispatcher's
/// `KeyChordNormalizer` produces) is bridged via ``KeyChord/asPreferencesChord`` before the lookup. Pure +
/// headless: the byte payload is RESOLVED at parse time (by ``KeybindGrammar``), so this only forwards it.
public extension WorkspaceBindingRegistry {
    /// The literal-byte ``KeybindingPreferences/TextBinding`` bound to `chord` in the active overrides, or
    /// `nil` when no text binding owns it. The dispatcher sends ``KeybindingPreferences/TextBinding/payload``
    /// via `sendBytes` and swallows the event. The empty-`textBindings` fast path avoids bridging the chord
    /// at all (the no-override default is a clean miss).
    static func textBinding(for chord: KeyChord) -> KeybindingPreferences.TextBinding? {
        textBinding(for: chord, overrides: activeOverrides)
    }

    /// Text-binding resolution against an EXPLICIT override set (the pure, testable form).
    static func textBinding(
        for chord: KeyChord, overrides: KeybindingPreferences,
    ) -> KeybindingPreferences.TextBinding? {
        guard !overrides.textBindings.isEmpty else { return nil }
        return overrides.textBindings[chord.asPreferencesChord]
    }

    /// Whether `chord` is an `unbind:` target in the active overrides — its DEFAULT action is suppressed, so
    /// the dispatcher passes the event straight through to the focused responder. The empty-`unbinds` fast
    /// path short-circuits the no-override default.
    static func isUnbound(_ chord: KeyChord) -> Bool {
        isUnbound(chord, overrides: activeOverrides)
    }

    /// Unbind resolution against an EXPLICIT override set (pure, testable).
    static func isUnbound(_ chord: KeyChord, overrides: KeybindingPreferences) -> Bool {
        guard !overrides.unbinds.isEmpty else { return false }
        return overrides.unbinds.contains(chord.asPreferencesChord)
    }
}

// MARK: - registry KeyChord → KeybindingPreferences.KeyChord (the reverse bridge)

public extension KeyChord {
    /// Map the registry's framework-neutral ``KeyChord`` into the persisted shape
    /// (``KeybindingPreferences/KeyChord``) so a live keystroke can be looked up in the chord-keyed
    /// `textBindings` / `unbinds` maps. The INVERSE of ``KeybindingPreferences/KeyChord/asRegistryChord``:
    /// it emits the canonical named-key token `mapKey` round-trips (`"return"`, `"left"`, `"pageup"`, …) so
    /// a chord parsed by ``KeybindGrammar`` and a chord produced by the dispatcher key the SAME map entry.
    /// Total (every registry chord has a persisted spelling) — no `nil` path.
    var asPreferencesChord: KeybindingPreferences.KeyChord {
        KeybindingPreferences.KeyChord(
            key: Self.preferencesKeyToken(key),
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
        )
    }

    /// The canonical persisted-key token for a registry `Key` — the spelling `KeybindingPreferences.KeyChord
    /// .mapKey` accepts, so the round-trip registry → prefs → registry is identity.
    private static func preferencesKeyToken(_ key: Key) -> String {
        switch key {
        case let .character(c): String(c) // already lowercased by KeyChord.init
        case .tab: "tab"
        case .return: "return"
        case .space: "space"
        case .leftArrow: "left"
        case .rightArrow: "right"
        case .upArrow: "up"
        case .downArrow: "down"
        case .pageUp: "pageup"
        case .pageDown: "pagedown"
        case .home: "home"
        case .end: "end"
        }
    }
}

// MARK: - KeybindingPreferences.KeyChord → registry KeyChord

public extension KeybindingPreferences.KeyChord {
    /// Map the persisted chord (`key: String` + modifier flags) into the registry's framework-neutral
    /// ``KeyChord``. Named keys (`"return"`, `"left"`, `"tab"`, …) map to the registry's `Key` cases; a
    /// single printable character maps to `.character`. An empty / multi-char / unknown-named key yields
    /// `nil` (validate-then-default: the resolver then keeps the registry default).
    var asRegistryChord: KeyChord? {
        guard let mappedKey = Self.mapKey(key) else { return nil }
        var mods: KeyChord.Modifiers = []
        if shift { mods.insert(.shift) }
        if control { mods.insert(.control) }
        if option { mods.insert(.option) }
        if command { mods.insert(.command) }
        return KeyChord(mappedKey, mods)
    }

    /// Map a normalised key token (lowercased single char or a named key) to the registry `Key`. Returns
    /// `nil` for an empty / multi-char / unrecognised-named key.
    private static func mapKey(_ key: String) -> KeyChord.Key? {
        switch key {
        case "return",
             "enter": return .return
        case "tab": return .tab
        case "space": return .space
        case "left",
             "leftarrow": return .leftArrow
        case "right",
             "rightarrow": return .rightArrow
        case "up",
             "uparrow": return .upArrow
        case "down",
             "downarrow": return .downArrow
        case "pageup",
             "pgup": return .pageUp
        case "pagedown",
             "pgdn": return .pageDown
        case "home": return .home
        case "end": return .end
        default:
            // A single printable character (already lowercased by KeyChord.init). Reject empty / multi.
            guard key.count == 1, let c = key.first else { return nil }
            return .character(c)
        }
    }
}

// MARK: - KeybindingPreferences.KeySequence → registry KeySequence

public extension KeybindingPreferences.KeySequence {
    /// Map the persisted sequence (a list of serialisable chords) into the dispatcher's framework-neutral
    /// ``KeySequence``. EVERY chord must map (via ``KeybindingPreferences/KeyChord/asRegistryChord``); if ANY
    /// chord is unmappable (a malformed stored value) the whole sequence yields `nil` (validate-then-default:
    /// the resolver then keeps the registry default rather than firing a partial / wrong sequence).
    var asRegistrySequence: KeySequence? {
        var mapped: [KeyChord] = []
        for chord in chords {
            guard let registryChord = chord.asRegistryChord else { return nil }
            mapped.append(registryChord)
        }
        return KeySequence(mapped) // nil only if `chords` was empty (rejected at decode/init)
    }
}
