import Foundation

/// User keybinding overrides. `WorkspaceBindingRegistry` is the single
/// source of truth for the available commands (each a stable, string `bindingID` such as
/// `"pane.splitRight"`); `KeybindingPreferences` makes those editable: a sparse map of
/// `bindingID → keyEquivalent` overrides. Absent ⇒ the registry's default shortcut stands.
///
/// This is only the editable MODEL (pure `Codable`, headlessly testable + round-trippable) so the
/// settings system has a place to store overrides; the registry it keys into and the live application
/// of an override live elsewhere. Keyed by `String` (not the registry's own type) so this model builds
/// standalone — the registry supplies the id constants, this only stores them.
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
        /// key `"pageup"` — a permanent miss that silently breaks the literal-byte / `unbind:` matching.
        /// Single printable characters (already lowercased) pass through unchanged; an unmapped
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

    /// A literal-byte override: a chord bound to send raw bytes to the focused terminal instead
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
    /// mis-reading a stale shape. Version 3 covers the ``textBindings`` + ``unbinds`` maps; a blob with no
    /// version field, or version 1 / 2, predates one or both of those fields, so it is intentionally
    /// rejected rather than partially decoded. (Version STAYS 3 after the 2026-07-22 prefix-mode removal:
    /// fields were only REMOVED — a v3 blob still carrying `prefixKey`/`sequenceOverrides` decodes fine,
    /// those keys are simply never read.)
    public static let currentSchemaVersion = 3

    /// Sparse override map: `bindingID → chord`. An id absent here uses the registry default.
    public var overrides: [String: KeyChord]

    /// Literal-byte bindings, keyed by the CHORD (not a registry binding id — a text binding has
    /// no action id). The dispatcher consults this BEFORE the action table: a chord present here sends its
    /// ``TextBinding/payload`` via `sendBytes` and swallows the event. Empty by default ⇒ no behaviour
    /// change. (JSON-encodes as a flat key/value array since the key is not a `String` — round-trips fine.)
    public var textBindings: [KeyChord: TextBinding]

    /// Chords whose DEFAULT action is suppressed (the `unbind:<chord>` config directive). The dispatcher passes
    /// a matching event straight through (the default responder chain handles it) instead of firing the
    /// registry action. Empty by default ⇒ no behaviour change.
    public var unbinds: Set<KeyChord>

    public init(
        overrides: [String: KeyChord] = [:],
        textBindings: [KeyChord: TextBinding] = [:],
        unbinds: Set<KeyChord> = [],
    ) {
        self.overrides = overrides
        self.textBindings = textBindings
        self.unbinds = unbinds
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case overrides
        case textBindings
        case unbinds
    }

    /// Decode with a STRICT schema-version gate (no-backcompat): a blob missing the version field (the
    /// pre-W-B shape) or carrying a version ≠ ``currentSchemaVersion`` THROWS, so the store's
    /// `try? decode ?? .init()` lands on the empty default rather than silently importing a stale shape.
    /// `textBindings` / `unbinds` are optional-in-decode (forward-only additive fields within v3 are
    /// fine), defaulting to empty when absent. Unknown keys in the blob (e.g. the retired
    /// `prefixKey`/`sequenceOverrides`) are simply not read.
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
        textBindings = try c.decodeIfPresent([KeyChord: TextBinding].self, forKey: .textBindings) ?? [:]
        unbinds = try c.decodeIfPresent(Set<KeyChord>.self, forKey: .unbinds) ?? []
    }

    /// Encode WITH the current schema version stamped (so a round-trip / future read passes the gate).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(overrides, forKey: .overrides)
        try c.encode(textBindings, forKey: .textBindings)
        try c.encode(unbinds, forKey: .unbinds)
    }

    /// The single-chord override for a binding id, or `nil` (⇒ use the registry default).
    public func chord(for bindingID: String) -> KeyChord? {
        overrides[bindingID]
    }

    /// Whether two DISTINCT binding ids resolve to the same chord (a conflict the UI highlights).
    /// Only considers explicit overrides — reconciling against registry defaults is the registry's own
    /// concern.
    ///
    /// ``textBindings`` and ``unbinds`` participate too — they own the SAME chord namespace as a
    /// single-chord action override, so a text binding (or an unbind) on a chord that an action override
    /// also resolves to is a real clash the UI must surface. They fold in under synthetic ids
    /// (`"text:<canonical>"` / `"unbind:<canonical>"`) so a collision lists every contender on that chord.
    public func conflicts() -> [String: [String]] {
        var byCanonical: [String: [String]] = [:]
        for (id, chord) in overrides {
            byCanonical[chord.canonical, default: []].append(id)
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
