import Foundation

/// User keybinding overrides (decision #4 / W6). The W6 `WorkspaceBindingRegistry` is the single
/// source of truth for the available commands (each a stable, string `bindingID` such as
/// `"pane.splitRight"`); `KeybindingPreferences` makes those editable: a sparse map of
/// `bindingID → keyEquivalent` overrides. Absent ⇒ the registry's default shortcut stands.
///
/// W12 ships only the editable MODEL (pure `Codable`, headlessly testable + round-trippable) so the
/// settings system has a place to store overrides; the registry it keys into and the live application
/// of an override land with W6. Keyed by `String` (not the W6 registry type) so this model builds
/// standalone — W6 supplies the id constants, this only stores them.
///
/// A `KeyChord` is a normalised, serialisable shortcut: a base key plus modifier flags. Equality /
/// `Codable` are derived; the chord's CANONICAL string form (`"cmd+shift+d"`) is what the UI shows and
/// what conflict-detection compares.
public struct KeybindingPreferences: Codable, Sendable, Equatable {
    /// A serialisable keyboard shortcut: a base key + modifier set. Pure data — no AppKit
    /// `NSEvent.ModifierFlags` (which is not `Codable` and pulls in AppKit). The UI maps to/from it.
    public struct KeyChord: Codable, Sendable, Equatable, Hashable {
        /// The base key as a lowercased single character or named key (e.g. `"d"`, `"return"`, `"left"`).
        public var key: String
        public var command: Bool
        public var shift: Bool
        public var option: Bool
        public var control: Bool

        public init(
            key: String,
            command: Bool = false,
            shift: Bool = false,
            option: Bool = false,
            control: Bool = false,
        ) {
            self.key = Self.canonicalKey(key)
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }

        /// Normalise a base-key spelling to the ONE canonical token: lowercased, with the named-key ALIAS
        /// spellings this format also accepts (`pgup`/`pageup`, `pgdn`/`pagedown`, `enter`/`return`,
        /// `leftarrow`/`left`, `rightarrow`/`right`, `uparrow`/`up`, `downarrow`/`down`) folded to the single
        /// token the dispatcher's reverse bridge emits (`KeyChord.asPreferencesChord` →
        /// `preferencesKeyToken`: `"pageup"`, `"return"`, `"left"`, …). WITHOUT this fold a config line like
        /// `keybind = cmd+pgup:text:x` would store under key `"pgup"` while a live ⌘PageUp keystroke produces
        /// key `"pageup"` — a permanent miss that silently kills the literal-byte / `unbind:` half of
        /// ES-E1-6. Single printable characters (already lowercased) pass through unchanged; an unmapped
        /// multi-char token (e.g. `space`) is left as-is (it has no registry `Key`, so it can't match anyway).
        private static func canonicalKey(_ key: String) -> String {
            switch key.lowercased() {
            case "enter": "return"
            case "leftarrow": "left"
            case "rightarrow": "right"
            case "uparrow": "up"
            case "downarrow": "down"
            case "pgup": "pageup"
            case "pgdn": "pagedown"
            case let other: other
            }
        }

        private enum CodingKeys: String, CodingKey {
            case key
            case command
            case shift
            case option
            case control
        }

        /// Custom decode so a PERSISTED / hand-edited file with an uppercase `key` ("D") or an alias named-key
        /// spelling ("PGUP") is normalised to the same canonical form the memberwise
        /// ``init(key:command:shift:option:control:)`` enforces (via ``canonicalKey(_:)``) — otherwise the
        /// synthesised decoder would store the verbatim spelling and ``canonical`` would never match the
        /// canonical chord the lookup compares against (a silently-dead override). The other fields decode
        /// normally. (Encoding stays synthesised — `key` is already canonical.)
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try Self.canonicalKey(c.decode(String.self, forKey: .key))
            command = try c.decodeIfPresent(Bool.self, forKey: .command) ?? false
            shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
            option = try c.decodeIfPresent(Bool.self, forKey: .option) ?? false
            control = try c.decodeIfPresent(Bool.self, forKey: .control) ?? false
        }

        /// Canonical, order-stable display/identity string (`"cmd+shift+d"`). Two chords with the same
        /// keys + modifiers produce the same string ⇒ usable as a conflict-detection key.
        public var canonical: String {
            var parts: [String] = []
            if control { parts.append("ctrl") }
            if option { parts.append("opt") }
            if shift { parts.append("shift") }
            if command { parts.append("cmd") }
            parts.append(key)
            return parts.joined(separator: "+")
        }
    }

    /// A serialisable multi-key SEQUENCE (tmux/zellij prefix idiom — e.g. `⌃A` then `D`): an ordered,
    /// non-empty list of ``KeyChord``s. A single-chord override is the degenerate length-1 sequence; the
    /// registry bridge (`asRegistrySequence`) lifts BOTH into the dispatcher's `KeySequence`. Pure data —
    /// no AppKit. Its CANONICAL form (`"ctrl+a ; d"`) is the conflict-detection key, so a sequence and a
    /// single chord that begin the same way are distinguishable yet a prefix-clash is detectable.
    public struct KeySequence: Codable, Sendable, Equatable, Hashable {
        /// The chords in press order. The custom decoder REJECTS an empty list (a sequence needs ≥1 chord);
        /// the memberwise init asserts the same in debug and falls back to a single empty-key chord in
        /// release (validate-then-default — the registry bridge then drops the unmappable chord).
        public var chords: [KeyChord]

        public init(chords: [KeyChord]) {
            self.chords = chords.isEmpty ? [KeyChord(key: "")] : chords
        }

        /// A single-chord (length-1) sequence — the bridge from an ordinary chord override into the
        /// sequence world (so the editor can keep writing single chords and they round-trip as sequences).
        public init(single chord: KeyChord) {
            chords = [chord]
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            let decoded = try c.decode([KeyChord].self)
            guard !decoded.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "a key sequence must contain at least one chord",
                )
            }
            chords = decoded
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(chords)
        }

        /// Whether this is a multi-key sequence (≥2 chords) rather than a plain single chord.
        public var isMultiKey: Bool { chords.count > 1 }

        /// Canonical, order-stable identity string for conflict detection — the per-chord ``KeyChord``
        /// canonical forms joined by `" ; "` (e.g. `"ctrl+a ; d"`). A length-1 sequence's canonical is its
        /// single chord's canonical (no separator), so a single-chord override and a 1-element sequence
        /// override of the same chord COLLIDE in ``conflicts()`` as they must.
        public var canonical: String {
            chords.map(\.canonical).joined(separator: " ; ")
        }
    }

    /// A literal-byte override (E1/WI-6): a chord bound to send raw bytes to the focused terminal instead
    /// of firing a named action — the `text:` / `csi:` / `esc:` config bindings (see
    /// `spec/customization__custom-keybindings.md`). The bytes are RESOLVED at parse time (by
    /// ``KeybindGrammar``, which prepends `ESC` / `ESC [` for the `esc:` / `csi:` kinds), so the dispatcher
    /// just hands ``payload`` to `sendBytes` — no escape re-interpretation at dispatch. ``kind`` is kept for
    /// the Settings UI to round-trip the prefix the user typed; the dispatcher only reads ``payload``.
    public struct TextBinding: Codable, Sendable, Equatable, Hashable {
        /// Which config prefix produced this binding — for UI display only (``payload`` already carries the
        /// fully-resolved bytes, ESC/CSI lead bytes included).
        public enum Kind: String, Codable, Sendable {
            case text
            case csi
            case esc
        }

        public var kind: Kind
        /// The fully-resolved bytes to send (UTF-8 of a `text:`, or ESC/ESC-`[` prefixed for `esc:`/`csi:`).
        public var payload: [UInt8]

        public init(kind: Kind, payload: [UInt8]) {
            self.kind = kind
            self.payload = payload
        }
    }

    /// The persisted schema version. No-backcompat (single-user): a stored blob whose version is not the
    /// CURRENT one decode-FAILS so the store falls back to a default (empty) override set rather than
    /// mis-reading a stale shape. Bumped to 2 for the W-B sequence model, then to 3 for E1/WI-6's
    /// ``textBindings`` + ``unbinds`` maps (the old shape had no version field, no sequence overrides, and no
    /// text/unbind maps, so any old blob — version absent / 1 / 2 — is intentionally rejected).
    public static let currentSchemaVersion = 3

    /// Sparse override map: `bindingID → chord`. An id absent here uses the W6 registry default. A
    /// single-chord override (the editor's common case). For a MULTI-KEY override see ``sequenceOverrides``.
    public var overrides: [String: KeyChord]

    /// Sparse multi-key SEQUENCE override map: `bindingID → sequence`. Separate from ``overrides`` so the
    /// single-chord editor path is unchanged; an id present here takes precedence over a single-chord
    /// override for the same id (a sequence is the richer rebind). Empty by default ⇒ no behaviour change.
    public var sequenceOverrides: [String: KeySequence]

    /// E1/WI-6: literal-byte bindings, keyed by the CHORD (not a registry binding id — a text binding has
    /// no action id). The dispatcher consults this BEFORE the action table: a chord present here sends its
    /// ``TextBinding/payload`` via `sendBytes` and swallows the event. Empty by default ⇒ no behaviour
    /// change. (JSON-encodes as a flat key/value array since the key is not a `String` — round-trips fine.)
    public var textBindings: [KeyChord: TextBinding]

    /// E1/WI-6: chords whose DEFAULT action is suppressed (the `unbind:<chord>` config directive). The dispatcher passes
    /// a matching event straight through (the default responder chain handles it) instead of firing the
    /// registry action. Empty by default ⇒ no behaviour change.
    public var unbinds: Set<KeyChord>

    public init(
        overrides: [String: KeyChord] = [:],
        sequenceOverrides: [String: KeySequence] = [:],
        textBindings: [KeyChord: TextBinding] = [:],
        unbinds: Set<KeyChord> = [],
    ) {
        self.overrides = overrides
        self.sequenceOverrides = sequenceOverrides
        self.textBindings = textBindings
        self.unbinds = unbinds
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case overrides
        case sequenceOverrides
        case textBindings
        case unbinds
    }

    /// Decode with a STRICT schema-version gate (no-backcompat): a blob missing the version field (the
    /// pre-W-B shape) or carrying a version ≠ ``currentSchemaVersion`` THROWS, so the store's
    /// `try? decode ?? .init()` lands on the empty default rather than silently importing a stale shape.
    /// `sequenceOverrides` / `textBindings` / `unbinds` are optional-in-decode (forward-only additive fields
    /// within v3 are fine), defaulting to empty when absent.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "keybinding schema version \(version.map(String.init) ?? "absent") "
                    + "!= current \(Self.currentSchemaVersion); decode-fail to default (no-backcompat)",
            )
        }
        overrides = try c.decodeIfPresent([String: KeyChord].self, forKey: .overrides) ?? [:]
        sequenceOverrides = try c.decodeIfPresent([String: KeySequence].self, forKey: .sequenceOverrides) ?? [:]
        textBindings = try c.decodeIfPresent([KeyChord: TextBinding].self, forKey: .textBindings) ?? [:]
        unbinds = try c.decodeIfPresent(Set<KeyChord>.self, forKey: .unbinds) ?? []
    }

    /// Encode WITH the current schema version stamped (so a round-trip / future read passes the gate).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(overrides, forKey: .overrides)
        try c.encode(sequenceOverrides, forKey: .sequenceOverrides)
        try c.encode(textBindings, forKey: .textBindings)
        try c.encode(unbinds, forKey: .unbinds)
    }

    /// The single-chord override for a binding id, or `nil` (⇒ use the registry default). A MULTI-KEY
    /// override for the same id is NOT returned here (it would not fit the single-chord shape) — use
    /// ``sequence(for:)`` for the full rebind.
    public func chord(for bindingID: String) -> KeyChord? {
        overrides[bindingID]
    }

    /// The override SEQUENCE for a binding id: the explicit multi-key sequence if one is set, else a
    /// length-1 sequence wrapping a single-chord override, else `nil` (⇒ use the registry default). The ONE
    /// accessor the dispatcher reads so single and multi-key overrides are honoured uniformly.
    public func sequence(for bindingID: String) -> KeySequence? {
        if let seq = sequenceOverrides[bindingID] { return seq }
        if let chord = overrides[bindingID] { return KeySequence(single: chord) }
        return nil
    }

    /// Whether two DISTINCT binding ids resolve to the same chord/sequence (a conflict the UI highlights).
    /// Only considers explicit overrides — registry defaults are W6's to reconcile. A single-chord override
    /// and a 1-element SEQUENCE override of the same chord collide (their canonicals match); a multi-key
    /// sequence collides only with another binding bound to the IDENTICAL full sequence.
    ///
    /// E1/WI-6: ``textBindings`` and ``unbinds`` participate too — they own the SAME chord namespace as a
    /// single-chord action override, so a text binding (or an unbind) on a chord that an action override
    /// also resolves to is a real clash the UI must surface. They fold in under synthetic ids
    /// (`"text:<canonical>"` / `"unbind:<canonical>"`) so a collision lists every contender on that chord.
    public func conflicts() -> [String: [String]] {
        var byCanonical: [String: [String]] = [:]
        // Iterate the unified accessor so a single-chord and a sequence override compare on one canonical
        // axis; an id present in both maps is counted ONCE (sequence wins, per `sequence(for:)`).
        let ids = Set(overrides.keys).union(sequenceOverrides.keys)
        for id in ids {
            guard let seq = sequence(for: id) else { continue }
            byCanonical[seq.canonical, default: []].append(id)
        }
        // Text bindings and unbinds key by chord directly — fold each under a synthetic id so a clash with
        // an action override (or with each other) shows up on the same canonical bucket.
        for chord in textBindings.keys {
            byCanonical[chord.canonical, default: []].append("text:\(chord.canonical)")
        }
        for chord in unbinds {
            byCanonical[chord.canonical, default: []].append("unbind:\(chord.canonical)")
        }
        return byCanonical.filter { $0.value.count > 1 }
    }
}
