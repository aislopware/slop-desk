import CSlopDeskFFI
import SlopDeskArena

/// The Swift face of `rust/slopdesk-terminal`'s `keybind`, reached through the door of the same name.
///
/// `~/.config/slopdesk/config.toml` lets a user author bindings as `keybind = <chord>:<action>`
/// (see `spec/customization__custom-keybindings.md`). This parses the right-hand side of one such
/// entry — the `<chord>:<action>` text — into a serialisable chord + a typed action. It owns NO state
/// and reaches NO I/O: the dispatcher feeds it the user string, persists the result into
/// ``KeybindingPreferences`` (`textBindings` / `unbinds`), and injects literal-byte actions through the
/// existing `sendBytes` path. There is no new wire message and no golden key (CLAUDE.md §1 N/A here).
///
/// **Validate-then-drop** (CLAUDE.md §3, applied to untrusted *config text* rather than UDP):
/// ``parseLine(_:)`` returns `nil` on a malformed token — an empty key, an unknown modifier, a
/// multi-char key with no named-key spelling, a missing payload, or a non-numeric `goto_tab` arg.
/// The far side never force-unwraps and never traps on hostile input, and it bounds the declared
/// payload (rejecting a `\xNN` escape with too few hex digits) before building any byte buffer.
///
/// The action grammar (`spec/reference__keybindings.md`):
///   - `text:<string>`  → ``ParsedBindingAction/text`` — the literal UTF-8 bytes of `<string>`.
///   - `csi:<payload>`  → ``ParsedBindingAction/csi`` — `ESC [` followed by `<payload>`'s bytes.
///   - `esc:<payload>`  → ``ParsedBindingAction/esc`` — `ESC` followed by `<payload>`'s bytes.
///   - `<named-action>` or `<named-action>:<arg>` (`goto_tab:1`) → ``ParsedBindingAction/named``.
///   - (whole-line) `unbind:<chord>` → ``ParsedBindingAction/unbind`` — suppress a default chord.
///
/// The one thing that stays HERE is ``KeybindingPreferences/KeyChord``'s own canonicalisation: the
/// far side answers the base key as the user lowercased it, and `KeyChord.init` folds the aliases
/// (`leftarrow` → `left`) as it does for every chord, parsed or dispatched.
public enum KeybindGrammar {
    /// The ESCAPE control byte (`0x1B`) — the lead byte of `esc:` and `csi:` (`ESC [`) sequences.
    public static let esc: UInt8 = 0x1B
    /// The CSI introducer that follows `ESC` in a `csi:` sequence: `[` (`0x5B`).
    public static let csiIntroducer: UInt8 = 0x5B

    /// A parsed binding action — the typed right-hand side of one `keybind` entry. Literal-byte variants
    /// (`text`/`csi`/`esc`) carry the resolved bytes ready for `sendBytes`; `named` carries a stable action
    /// id + optional arg for the registry; `unbind` suppresses a default (the chord lives in ``ParsedBinding``).
    public enum ParsedBindingAction: Equatable, Sendable {
        /// `text:<s>` — send `<s>`'s literal UTF-8 bytes.
        case text([UInt8])
        /// `csi:<p>` — send `ESC [` then `<p>`'s bytes (e.g. `csi:17~` → F6).
        case csi([UInt8])
        /// `esc:<p>` — send `ESC` then `<p>`'s bytes (e.g. `esc:O`).
        case esc([UInt8])
        /// A named registry action with an optional colon-separated arg (`goto_tab` / `goto_tab:1`).
        case named(id: String, arg: String?)
        /// `unbind:<chord>` — suppress the default action on the (``ParsedBinding``-carried) chord.
        case unbind
    }

    /// A fully-parsed config-binding line: the chord it triggers on + the action to take. For an
    /// `unbind:<chord>` line, `action == .unbind` and `chord` is the chord being suppressed.
    public struct ParsedBinding: Equatable, Sendable {
        public var chord: KeybindingPreferences.KeyChord
        public var action: ParsedBindingAction

        public init(chord: KeybindingPreferences.KeyChord, action: ParsedBindingAction) {
            self.chord = chord
            self.action = action
        }
    }

    /// Parse one config-binding line (`<chord>:<action>` or `unbind:<chord>`) into a ``ParsedBinding``.
    /// Returns `nil` (validate-then-drop) on any malformed input.
    ///
    /// The record's three runs — base key, payload, arg — ride in one arena lent to the door: the
    /// first call measures, the second fills. A parse whose runs did not fit is not a parse.
    public static func parseLine(_ raw: String) -> ParsedBinding? {
        let bytes = Array(raw.utf8)
        return bytes.withUnsafeBufferPointer { line -> ParsedBinding? in
            let measured = slopdesk_keybind_parse_line(line.baseAddress, line.count, nil, 0)
            guard measured.arena_len > 0 else { return nil }
            var arena = [UInt8](repeating: 0, count: measured.arena_len)
            let record = arena.withUnsafeMutableBufferPointer { pool in
                slopdesk_keybind_parse_line(line.baseAddress, line.count, pool.baseAddress, pool.count)
            }
            guard record.valid else { return nil }
            let chord = KeybindingPreferences.KeyChord(
                key: text(arena, record.key),
                command: record.command, shift: record.shift,
                option: record.option, control: record.control,
            )
            return ParsedBinding(chord: chord, action: action(record, arena))
        }
    }

    /// Whether a config value parses as a binding this grammar honours — the question the CLI's file
    /// validator asks of every line, answered without building the binding.
    public static func isValidLine(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        return bytes.withUnsafeBufferPointer { line in
            slopdesk_keybind_is_valid(line.baseAddress, line.count)
        }
    }

    /// The action a record names, read out of the arena its runs point into.
    private static func action(_ record: SlopDeskKeybind, _ arena: [UInt8]) -> ParsedBindingAction {
        switch record.kind {
        case SLOPDESK_KEYBIND_CSI: .csi(bytes(arena, record.payload))
        case SLOPDESK_KEYBIND_ESC: .esc(bytes(arena, record.payload))
        case SLOPDESK_KEYBIND_NAMED: .named(
                id: text(arena, record.payload),
                arg: record.has_arg ? text(arena, record.arg) : nil,
            )
        case SLOPDESK_KEYBIND_UNBIND: .unbind
        default: .text(bytes(arena, record.payload))
        }
    }

    /// One run's bytes.
    private static func bytes(_ arena: [UInt8], _ run: SlopDeskKeybindRun) -> [UInt8] {
        ArenaText.bytes(arena, offset: Int(run.offset), length: Int(run.length))
    }

    /// One run's bytes as text. The far side interned its own `&str`, so the run is valid UTF-8 by
    /// construction; an empty string on the impossible branch is the same answer a malformed run
    /// would deserve.
    ///
    /// The array is borrowed rather than copied through ``bytes(_:_:)``: this is the read half of the
    /// same arena convention every other face reads, so it goes through the same ``ArenaText``.
    private static func text(_ arena: [UInt8], _ run: SlopDeskKeybindRun) -> String {
        arena.withUnsafeBytes { ArenaText.text($0, run.offset, run.length) }
    }
}
