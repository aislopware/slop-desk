import Foundation

/// E1/WI-6 (production wiring) — the loader that turns a `~/.config/slopdesk/config.toml`
/// into live ``KeybindingPreferences``. It is the MISSING population path: ``KeybindGrammar`` parses one
/// `keybind` line and the dispatcher (WI-7) already consults ``KeybindingPreferences/textBindings`` /
/// ``KeybindingPreferences/unbinds``, but until now NOTHING wrote those maps — so the `text:` / `csi:` /
/// `esc:` / `unbind:` half of ES-E1-6 was unreachable end-to-end. This loader closes that gap: it reads the
/// flat `key = value` config (`spec/reference__config-file-format.md`), parses
/// every `keybind = <chord>:<action>` line via ``KeybindGrammar/parseLine``, and FOLDS the result into a
/// ``KeybindingPreferences`` the app publishes into ``WorkspaceBindingRegistry/activeOverrides``.
///
/// **Validate-then-drop, file edition (CLAUDE.md §3, applied to untrusted *config text*):** the file is a
/// user document, not a hostile UDP datagram, but the same discipline holds — a malformed `keybind` line is
/// DROPPED (the line is skipped, the rest of the file still loads) rather than failing the whole load or
/// trapping. Unknown keys are silently ignored (a lenient reader), blank lines and `#` comments are
/// skipped, and whitespace around `=` is optional.
///
/// **Pure + headless.** This owns no state and reaches I/O only through the explicit ``loadFile(at:into:)``
/// entry; the byte-fold core (``apply(configText:to:resolveNamedBinding:)``) is a pure String → struct
/// transform unit-tested without touching disk. Literal-byte actions resolve their bytes at parse time (in
/// ``KeybindGrammar``), so this only routes the already-resolved payload into the right map.
///
/// **Named actions** (`cmd+1:goto_tab:1`, `cmd+t:new_tab`) need the W6 registry's action-id → `bindingID`
/// mapping, which lives in `SlopDeskWorkspaceCore` (this module cannot import it). The fold therefore takes
/// an optional `resolveNamedBinding` hook: when supplied, a `named` action whose `(id, arg)` the caller maps
/// to a `(bindingID, chord)` is written into ``KeybindingPreferences/overrides``; when `nil` (or when the
/// caller returns `nil` for an unknown action id), the named line is dropped. The `text:` / `csi:` / `esc:` /
/// `unbind:` directives need NO registry and are handled here unconditionally — that is the ES-E1-6 core.
public enum KeybindConfigLoader {
    /// The default config path: `~/.config/slopdesk/config.toml`. Honours `XDG_CONFIG_HOME` when set (the
    /// freedesktop convention the `~/.config` base follows); falls back to `$HOME/.config`. Returns `nil` when
    /// no home can be resolved.
    public static func defaultConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL?
    {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else if let home = environment["HOME"], !home.isEmpty {
            base = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        } else {
            return nil
        }
        return base.appendingPathComponent("slopdesk", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// One `keybind = <chord>:<action>` directive whose action is a NAMED registry action (`new_tab`,
    /// `goto_tab:1`) rather than a literal-byte / unbind directive — surfaced so the WorkspaceCore wiring can
    /// resolve `(id, arg)` to a `bindingID` against the registry. The `chord` is the (already-validated)
    /// trigger; the literal-byte and unbind directives never produce one (they fold here directly).
    public struct NamedBinding: Equatable, Sendable {
        public var chord: KeybindingPreferences.KeyChord
        public var id: String
        public var arg: String?

        public init(chord: KeybindingPreferences.KeyChord, id: String, arg: String?) {
            self.chord = chord
            self.id = id
            self.arg = arg
        }
    }

    /// Read the config file at `url` and fold its `keybind` lines into `base`, returning the merged prefs.
    /// A MISSING file (the common case — no config authored) is NOT an error: it returns `base` unchanged so a
    /// fresh install is behaviour-identical. An unreadable file is likewise treated as empty (validate-then-
    /// drop: a broken config must never crash the client). `resolveNamedBinding` is forwarded to the fold for
    /// named-action lines (see ``apply(configText:to:resolveNamedBinding:)``).
    public static func loadFile(
        at url: URL,
        into base: KeybindingPreferences = KeybindingPreferences(),
        resolveNamedBinding: ((NamedBinding) -> (bindingID: String, chord: KeybindingPreferences.KeyChord)?)? = nil,
    ) -> KeybindingPreferences {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return base }
        return apply(configText: text, to: base, resolveNamedBinding: resolveNamedBinding)
    }

    /// The PURE fold (no I/O): parse `configText` and merge its `keybind` directives into `base`.
    ///
    /// Each line is read in a flat-config dialect: leading/trailing whitespace trimmed, blank lines and
    /// `#` comments skipped, and exactly one `key = value` per line (lenient whitespace around `=`). Only the
    /// `keybind` key is consulted here — every OTHER key is silently ignored (unknown keys are silently
    /// ignored, so this loader can share the file with the rest of the config). A `keybind` value is
    /// handed to ``KeybindGrammar/parseLine``; a line that fails to parse is DROPPED (the rest still load).
    ///
    /// The parsed action routes by kind:
    ///   - `text:` / `csi:` / `esc:` → a ``KeybindingPreferences/TextBinding`` keyed by the trigger chord in
    ///     ``KeybindingPreferences/textBindings`` (the literal-byte half of ES-E1-6).
    ///   - `unbind:<chord>` → the chord is inserted into ``KeybindingPreferences/unbinds``.
    ///   - a named action → routed through `resolveNamedBinding` (caller-supplied) into
    ///     ``KeybindingPreferences/overrides`` when it resolves to a `bindingID`, else dropped.
    ///
    /// LAST-WRITER-WINS within the file (a later `keybind` on the same chord replaces an earlier one); the
    /// file's bindings take precedence over `base` (the file is the explicit user authoring). This never
    /// traps and never partially-applies a malformed line.
    public static func apply(
        configText: String,
        to base: KeybindingPreferences = KeybindingPreferences(),
        resolveNamedBinding: ((NamedBinding) -> (bindingID: String, chord: KeybindingPreferences.KeyChord)?)? = nil,
    ) -> KeybindingPreferences {
        var overrides = base.overrides
        var textBindings = base.textBindings
        var unbinds = base.unbinds

        for rawLine in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let value = keybindValue(in: String(rawLine)) else { continue }
            guard let parsed = KeybindGrammar.parseLine(value) else { continue } // malformed line → drop
            switch parsed.action {
            case let .text(bytes):
                textBindings[parsed.chord] = .init(kind: .text, payload: bytes)
            case let .csi(bytes):
                textBindings[parsed.chord] = .init(kind: .csi, payload: bytes)
            case let .esc(bytes):
                textBindings[parsed.chord] = .init(kind: .esc, payload: bytes)
            case .unbind:
                unbinds.insert(parsed.chord)
            case let .named(id, arg):
                guard let resolve = resolveNamedBinding,
                      let mapped = resolve(NamedBinding(chord: parsed.chord, id: id, arg: arg))
                else { continue } // no resolver / unknown action → drop (registry lives elsewhere)
                overrides[mapped.bindingID] = mapped.chord
            }
        }

        return KeybindingPreferences(
            overrides: overrides,
            sequenceOverrides: base.sequenceOverrides,
            textBindings: textBindings,
            unbinds: unbinds,
        )
    }

    /// The `keybind` value on one config line, or `nil` when the line is blank, a comment, or assigns a
    /// DIFFERENT key. Splits on the FIRST `=` (lenient whitespace), trims, and matches the bare key `keybind`.
    /// An optional surrounding pair of double quotes on the value is stripped (lenient quoting).
    private static func keybindValue(in rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard key == "keybind" else { return nil } // every other config key is silently ignored
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
