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
            self.key = key.lowercased()
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }

        private enum CodingKeys: String, CodingKey {
            case key
            case command
            case shift
            case option
            case control
        }

        /// Custom decode so a PERSISTED / hand-edited file with an uppercase `key` ("D") is normalised to
        /// the same lowercase form the memberwise ``init(key:command:shift:option:control:)`` enforces —
        /// otherwise the synthesised decoder would store "D" verbatim and ``canonical`` ("cmd+D") would
        /// never match the lowercase chord the lookup compares against (a silently-dead override). The
        /// other fields decode normally. (Encoding stays synthesised — `key` is already lowercased.)
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key).lowercased()
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

    /// Sparse override map: `bindingID → chord`. An id absent here uses the W6 registry default.
    public var overrides: [String: KeyChord]

    public init(overrides: [String: KeyChord] = [:]) {
        self.overrides = overrides
    }

    /// The override for a binding id, or `nil` (⇒ use the registry default).
    public func chord(for bindingID: String) -> KeyChord? {
        overrides[bindingID]
    }

    /// Whether two DISTINCT binding ids resolve to the same chord (a conflict the UI highlights).
    /// Only considers explicit overrides — registry defaults are W6's to reconcile.
    public func conflicts() -> [String: [String]] {
        var byCanonical: [String: [String]] = [:]
        for (id, chord) in overrides {
            byCanonical[chord.canonical, default: []].append(id)
        }
        return byCanonical.filter { $0.value.count > 1 }
    }
}
