import CSlopDeskFFI
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
    nonisolated(unsafe) static var activeOverrides = KeybindingPreferences() {
        didSet { liveChordTable = nil }
    }

    /// ``resolvedChordTable``'s answer, held until ``activeOverrides`` is written again.
    ///
    /// The table is a pure function of the registry (a `let`) and the overrides (write-once-then-read-
    /// many), so rebuilding it per key event was recomputing a constant: 85 rows resolved, 85 chords
    /// hashed and a dictionary allocated, on every keystroke the app sees, plus one crossing per
    /// override to re-map a chord that had not changed. The invalidation is the SETTER's rather than a
    /// revision compare, because the setter is the only thing that can make the answer stale.
    private nonisolated(unsafe) static var liveChordTable: [KeyChord: WorkspaceAction]?

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
    /// override collides with another binding's chord is last-writer-wins in the map — arbitrary, so the
    /// collision is REPORTED rather than resolved here: `slopdesk config validate` prints one line per
    /// pair, out of `config::render::keybind_conflicts`.
    static var resolvedChordTable: [KeyChord: WorkspaceAction] {
        if let liveChordTable { return liveChordTable }
        let built = resolvedChordTable(overrides: activeOverrides)
        liveChordTable = built
        return built
    }

    /// The override-aware chord table against an explicit override set (pure, testable). Folds in
    /// ``aliasChords`` (the ⌘+ font-increase alias, etc.) AFTER the resolved bindings — but only onto a chord
    /// the user has not rebound onto, so an override always wins (the alias is a free second chord, never a
    /// squatter). This is the table the live dispatcher reads, so the aliases fire at runtime too.
    ///
    /// Resolves each row against the row it is ALREADY holding rather than through
    /// ``resolvedChord(for:overrides:)``, which would look the same binding up again by action — the
    /// same fold, one line shorter, and 85 lookups per build cheaper. The override arm is
    /// ``resolvedChord(for:overrides:)``'s, spelled once: an override that maps wins, one that does not
    /// falls back to the row's own chord (validate-then-default).
    static func resolvedChordTable(overrides: KeybindingPreferences) -> [KeyChord: WorkspaceAction] {
        var map: [KeyChord: WorkspaceAction] = [:]
        map.reserveCapacity(allBindings.count + aliasChords.count)
        for binding in allBindings {
            if let chord = overrides.chord(for: binding.id)?.asRegistryChord ?? binding.chord {
                map[chord] = binding.action
            }
        }
        for (chord, action) in aliasChords where map[chord] == nil { map[chord] = action }
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
            key: key.canonicalToken,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
        )
    }
}

public extension KeyChord.Key {
    /// The ONE spelling this key is persisted and looked up under, asked of
    /// `slopdesk_video::key_naming` — the same table the config grammar folds its aliases into, so
    /// the round-trip registry → prefs → registry is identity. A printable character is its own
    /// token (already lower-cased by ``KeyChord/init(character:_:)``).
    var canonicalToken: String {
        if case let .character(c) = self { return String(c) }
        guard let index = namedIndex else { return "" }
        var token = [UInt8](repeating: 0, count: Self.tokenCapacity)
        let written = token.withUnsafeMutableBufferPointer { out in
            slopdesk_key_named_canonical(index, out.baseAddress, out.count)
        }
        return String(bytes: token.prefix(max(0, written)), encoding: .utf8) ?? ""
    }

    /// The key a canonical token names, or `nil` for an empty / multi-character / unrecognised one.
    /// The inverse of ``canonicalToken`` — the door answers the case INDEX, so the eleven cases are
    /// named in one place (``init(namedIndex:)``) rather than in a second string table here.
    static func named(token: String) -> Self? {
        var token = token
        let index = token.withUTF8 { slopdesk_key_named_index($0.baseAddress, $0.count) }
        if index >= 0, let named = Self(namedIndex: UInt8(truncatingIfNeeded: index)) { return named }
        guard token.count == 1, let character = token.first else { return nil }
        return .character(character)
    }

    /// `pagedown` is the longest token there is, so nothing here ever forces the door's retry.
    private static var tokenCapacity: Int { 16 }
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

    /// Map a CANONICAL key token (lowercased single char or a named key) to the registry `Key`. Returns
    /// `nil` for an empty / multi-char / unrecognised-named key.
    ///
    /// One spelling per key, because a `KeybindingPreferences.KeyChord` has already folded its alias
    /// spellings (`pgup`, `enter`, `leftarrow`, …) through the grammar's table — both its memberwise
    /// init and its decoder do. An alias branch here would be a second table that could only ever
    /// drift from that one, and unreachable while it agreed.
    private static func mapKey(_ key: String) -> KeyChord.Key? {
        KeyChord.Key.named(token: key)
    }
}
