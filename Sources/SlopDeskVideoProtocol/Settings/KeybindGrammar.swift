import Foundation

/// E1/WI-6 — the PURE, platform-neutral parser for ONE config keybinding line.
///
/// `~/.config/slopdesk/config.toml` lets a user author bindings as `keybind = <chord>:<action>`
/// (see `spec/customization__custom-keybindings.md`). This grammar parses the right-hand side of one
/// such entry — the `<chord>:<action>` text — into a serialisable chord + a typed action. It owns NO
/// state and reaches NO I/O: the dispatcher (WI-7) feeds it the user string, persists the result into
/// ``KeybindingPreferences`` (`textBindings` / `unbinds`), and injects literal-byte actions through the
/// existing `sendBytes` path. There is no new wire message and no golden key (CLAUDE.md §1 N/A here).
///
/// **Validate-then-drop** (CLAUDE.md §3, applied to untrusted *config text* rather than UDP): every
/// `parse*` returns `nil` on a malformed token — an empty key, an unknown modifier, a multi-char key
/// with no named-key spelling, a missing payload, or a non-numeric `goto_tab` arg. The parser NEVER
/// force-unwraps and NEVER traps on hostile input, and it bounds the declared payload (rejecting a
/// `\xNN` escape with too few hex digits) before building any byte buffer.
///
/// The action grammar (`spec/reference__keybindings.md`):
///   - `text:<string>`  → ``ParsedBindingAction/text`` — the literal UTF-8 bytes of `<string>`.
///   - `csi:<payload>`  → ``ParsedBindingAction/csi`` — `ESC [` followed by `<payload>`'s bytes.
///   - `esc:<payload>`  → ``ParsedBindingAction/esc`` — `ESC` followed by `<payload>`'s bytes.
///   - `<named-action>` or `<named-action>:<arg>` (`goto_tab:1`) → ``ParsedBindingAction/named``.
///   - (whole-line) `unbind:<chord>` → ``ParsedBindingAction/unbind`` — suppress a default chord.
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

    // MARK: - Whole-line parse

    /// Parse one config-binding line (`<chord>:<action>` or `unbind:<chord>`) into a ``ParsedBinding``.
    /// Returns `nil` (validate-then-drop) on any malformed input. Surrounding whitespace is trimmed first.
    ///
    /// The leading token decides the split: a line that STARTS with `unbind:` is the `unbind:<chord>`
    /// special form (the chord is the remainder); otherwise the FIRST `:` separates the chord from the
    /// action (so `cmd+1:goto_tab:1` splits as chord=`cmd+1`, action=`goto_tab:1`, and the action parser
    /// then splits its own first `:`).
    public static func parseLine(_ raw: String) -> ParsedBinding? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        // `unbind:<chord>` — the directive is the WHOLE left side; the chord is everything after the colon.
        if let chordText = stripPrefix("unbind:", from: line) {
            guard let chord = parseChord(chordText) else { return nil }
            return ParsedBinding(chord: chord, action: .unbind)
        }

        // `<chord>:<action>` — split on the FIRST colon only (the action keeps any further colons).
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let chordText = String(line[line.startIndex..<colon])
        let actionText = String(line[line.index(after: colon)...])
        guard let chord = parseChord(chordText), let action = parseAction(actionText) else { return nil }
        return ParsedBinding(chord: chord, action: action)
    }

    // MARK: - Chord parse

    /// Parse a chord string (`cmd+shift+h`, `ctrl+a`, `cmd+1`, `cmd+pageup`) into a serialisable
    /// ``KeybindingPreferences/KeyChord``. Modifier names: `cmd`, `ctrl`, `alt`/`opt`,
    /// `shift`, joined by `+`; the LAST `+`-segment is the base key. Returns `nil` on an empty string,
    /// an unknown modifier, a duplicate/empty segment, a missing base key, or a multi-char base key that
    /// is not a recognised named key (so the chord can later map via `KeyChord.asRegistryChord`).
    ///
    /// This does NOT support multi-key `>` sequences (`cmd+b>cmd+v`) — those are a sequence, not a
    /// single chord; a `>` in the string is rejected here so a sequence isn't silently truncated.
    public static func parseChord(_ raw: String) -> KeybindingPreferences.KeyChord? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, !text.contains(">") else { return nil }

        // Split on `+` keeping empty segments so a stray `cmd+`, `+h`, or `cmd++h` surfaces an empty
        // modifier (→ drop) rather than silently collapsing. The FINAL segment is the base key; all
        // preceding segments are modifiers. (A literal `+` base key is not expressible via this split —
        // an acceptable gap, since the config grammar never binds a bare `+`.)
        let segments = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty else { return nil }

        var command = false, shift = false, option = false, control = false
        // All but the last segment are modifiers; the last is the base key.
        for mod in segments.dropLast() {
            switch mod {
            case "cmd",
                 "command": command = true
            case "ctrl",
                 "control": control = true
            case "alt",
                 "opt",
                 "option": option = true
            case "shift": shift = true
            case "":
                // An empty modifier segment (`cmd++h`, `+h`, `cmd+`) is malformed — drop.
                return nil
            default:
                return nil // unknown modifier token
            }
        }

        let key = segments[segments.count - 1]
        guard isValidBaseKey(key) else { return nil }
        return KeybindingPreferences.KeyChord(
            key: key, command: command, shift: shift, option: option, control: control,
        )
    }

    // MARK: - Action parse

    /// Parse an action string into a ``ParsedBindingAction``. Recognises the three literal-byte prefixes
    /// (`text:` / `csi:` / `esc:`), and otherwise treats the string as a named action with an optional
    /// `:arg` (e.g. `goto_tab:1`). Returns `nil` for an empty string, an empty literal payload, an empty
    /// named-action id, a `goto_tab` arg that is not a base-10 integer, or a malformed `\xNN` escape.
    public static func parseAction(_ raw: String) -> ParsedBindingAction? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if let payload = stripPrefix("text:", from: text) {
            guard let bytes = literalBytes(payload), !bytes.isEmpty else { return nil }
            return .text(bytes)
        }
        if let payload = stripPrefix("csi:", from: text) {
            guard let bytes = literalBytes(payload), !bytes.isEmpty else { return nil }
            return .csi([esc, csiIntroducer] + bytes)
        }
        if let payload = stripPrefix("esc:", from: text) {
            guard let bytes = literalBytes(payload), !bytes.isEmpty else { return nil }
            return .esc([esc] + bytes)
        }

        // A named action, optionally `id:arg` (`goto_tab:1`). Split on the FIRST colon only.
        if let colon = text.firstIndex(of: ":") {
            let id = String(text[text.startIndex..<colon])
            let arg = String(text[text.index(after: colon)...])
            guard !id.isEmpty, !arg.isEmpty else { return nil }
            // Bound the one parameterised action we know of (`goto_tab:N`): the arg must be a base-10 int.
            if id == "goto_tab", Int(arg) == nil { return nil }
            return .named(id: id, arg: arg)
        }
        // A bare named action (`new_tab`, `copy_to_clipboard`).
        return .named(id: text, arg: nil)
    }

    // MARK: - Literal-byte payload

    /// The raw bytes for a `text:` / `csi:` / `esc:` payload. UTF-8 of the string, with a small escape
    /// vocabulary so a user can author control bytes a config file cannot hold literally:
    ///   - `\n` → 0x0A, `\r` → 0x0D, `\t` → 0x09, `\e` → 0x1B (ESC), `\0` → 0x00, `\\` → 0x5C, `\:` → 0x3A.
    ///   - `\xNN` → the byte `0xNN` (exactly two hex digits; fewer/non-hex → drop the whole payload).
    /// Returns `nil` (validate-then-drop) on a dangling backslash or a malformed `\x` escape — the length
    /// of a `\x` escape is bounded BEFORE any byte is appended, never reading past the payload end.
    static func literalBytes(_ payload: String) -> [UInt8]? {
        var out: [UInt8] = []
        let chars = Array(payload.unicodeScalars)
        var i = 0
        while i < chars.count {
            let scalar = chars[i]
            if scalar != "\\" {
                out.append(contentsOf: Array(String(scalar).utf8))
                i += 1
                continue
            }
            // An escape: there must be at least one more char after the backslash.
            guard i + 1 < chars.count else { return nil }
            let next = chars[i + 1]
            switch next {
            case "n": out.append(0x0A)
            case "r": out.append(0x0D)
            case "t": out.append(0x09)
            case "e": out.append(0x1B)
            case "0": out.append(0x00)
            case "\\": out.append(0x5C)
            case ":": out.append(0x3A)
            case "x",
                 "X":
                // `\xNN` — bound the two hex digits BEFORE indexing (CLAUDE.md §3 validate-then-drop):
                // chars[i+2] and chars[i+3] must both be in range, i.e. i+3 must be a valid index.
                guard i + 3 < chars.count else { return nil }
                let hi = chars[i + 2], lo = chars[i + 3]
                guard let byte = hexByte(hi, lo) else { return nil }
                out.append(byte)
                i += 4
                continue
            default:
                return nil // an unknown escape is malformed — drop the whole payload
            }
            i += 2
        }
        return out
    }

    // MARK: - Helpers

    /// Whether `key` is an acceptable base key for a chord: a single printable character OR a recognised
    /// named key (the EXACT vocabulary `KeybindingPreferences.KeyChord.asRegistryChord` / `mapKey` accepts,
    /// so a parsed chord can later resolve to a registry `Key`). A multi-char token that is NOT a named key
    /// is rejected (validate-then-drop) rather than stored as an unmappable chord.
    ///
    /// **E7/WI-6 (carry-over #3):** `space`, `escape`/`esc`, `delete`, `backspace`, and `forwarddelete` are
    /// DELIBERATELY excluded — neither `mapKey` nor the registry's `KeyChord.Key` enum has a case for them, so
    /// a config line binding one of these parsed but could NEVER resolve (a silent no-op). Validate-then-drop
    /// (CLAUDE.md §3) means rejecting them HERE rather than storing an unresolvable chord; this keeps
    /// `isValidBaseKey` and `mapKey` in lock-step. (Adding the five `KeyChord.Key` cases end-to-end — glyph,
    /// dispatcher, `mapKey` — is the alternative, deferred out of E7 to avoid touching the live keyboard path.)
    static func isValidBaseKey(_ key: String) -> Bool {
        if key.count == 1 { return true }
        switch key {
        case "return",
             "enter",
             "tab",
             "left",
             "leftarrow",
             "right",
             "rightarrow",
             "up",
             "uparrow",
             "down",
             "downarrow",
             "pageup",
             "pgup",
             "pagedown",
             "pgdn",
             "home",
             "end":
            return true
        default:
            return false
        }
    }

    /// Two hex scalars → the byte they spell, or `nil` if either is not a hex digit.
    private static func hexByte(_ hi: Unicode.Scalar, _ lo: Unicode.Scalar) -> UInt8? {
        guard let h = hexNibble(hi), let l = hexNibble(lo) else { return nil }
        return (h << 4) | l
    }

    /// A single hex scalar → its 0…15 value, or `nil` if it is not `[0-9a-fA-F]`.
    private static func hexNibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": UInt8(scalar.value - Unicode.Scalar("0").value)
        case "a"..."f": UInt8(scalar.value - Unicode.Scalar("a").value + 10)
        case "A"..."F": UInt8(scalar.value - Unicode.Scalar("A").value + 10)
        default: nil
        }
    }

    /// Return the substring AFTER `prefix` if `text` starts with it, else `nil`. (Case-sensitive; the
    /// action prefixes are lowercase by this grammar.)
    private static func stripPrefix(_ prefix: String, from text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count))
    }
}
