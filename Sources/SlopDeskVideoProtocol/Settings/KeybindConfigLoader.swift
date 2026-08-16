import CSlopDeskFFI
import Foundation

/// The loader that turns a `~/.config/slopdesk/config.toml`
/// into live ``KeybindingPreferences``. It is the population path: ``KeybindGrammar`` parses one
/// `keybind` line and the dispatcher already consults ``KeybindingPreferences/textBindings`` /
/// ``KeybindingPreferences/unbinds``, but nothing else writes those maps — so the `text:` / `csi:` /
/// `esc:` / `unbind:` config directives would otherwise be unreachable end-to-end. This loader closes that gap: it reads the
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
/// **Named actions** (`cmd+1:goto_tab:1`, `cmd+t:new_tab`) need the registry's action-id → `bindingID`
/// mapping, which lives in `SlopDeskWorkspaceCore` (this module cannot import it). The fold therefore takes
/// an optional `resolveNamedBinding` hook: when supplied, a `named` action whose `(id, arg)` the caller maps
/// to a `(bindingID, chord)` is written into ``KeybindingPreferences/overrides``; when `nil` (or when the
/// caller returns `nil` for an unknown action id), the named line is dropped. The `text:` / `csi:` / `esc:` /
/// `unbind:` directives need NO registry and are handled here unconditionally — that is the core of this loader.
public enum KeybindConfigLoader {
    /// The default config path: `~/.config/slopdesk/config.toml`, honouring `XDG_CONFIG_HOME` — the same
    /// path `slopdesk config path` prints, because it is spelled by the same door.
    ///
    /// The one decision that stays here is `nil`: with neither variable set there is no home to build a
    /// path under, and this loader declines to GUESS one rather than reading a file at an invented
    /// location. The CLI, which must always print something, supplies a fallback instead.
    public static func defaultConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL?
    {
        let xdg = Array((environment["XDG_CONFIG_HOME"] ?? "").utf8)
        let home = Array((environment["HOME"] ?? "").utf8)
        guard !xdg.isEmpty || !home.isEmpty else { return nil }
        let path = xdg.withUnsafeBufferPointer { config in
            home.withUnsafeBufferPointer { base in
                lentText { out, cap in
                    slopdesk_cli_config_default_path(
                        config.baseAddress, config.count, base.baseAddress, base.count, nil, 0, out, cap,
                    )
                }
            }
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
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
    ///     ``KeybindingPreferences/textBindings`` (the literal-byte directives).
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

        // A CRLF pair is ONE Swift `Character`, so splitting on the `"\n"` Character would not find it
        // and a whole CRLF file would arrive as a single line. Both separators are named, which is
        // exactly the far side's `split('\n')` over bytes: there, the `\r` stays on the line and the
        // line reader trims it.
        for rawLine in configText.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r\n" },
        ) {
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
            textBindings: textBindings,
            unbinds: unbinds,
        )
    }

    /// The `keybind` value on one config line, or `nil` when the line declares none — blank, a comment, a
    /// `[section]` header, another key, or a `keybind` with nothing after the `=`.
    ///
    /// The reading is the far side's, and it is the SAME reading `slopdesk config validate` reports on: a
    /// second one here could call a line good that this loader then drops, which is the one thing a
    /// validator must not do. It is also why a CRLF file works — the trim includes the carriage return,
    /// which the keybind grammar would otherwise refuse as part of the base key.
    private static func keybindValue(in rawLine: String) -> String? {
        let bytes = Array(rawLine.utf8)
        let value = bytes.withUnsafeBufferPointer { line in
            lentText { out, cap in
                slopdesk_cli_config_keybind_value(line.baseAddress, line.count, out, cap)
            }
        }
        return value.isEmpty ? nil : value
    }
}
