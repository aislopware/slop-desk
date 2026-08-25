import Foundation

/// Turns the config file's `[keybind]` table into live ``KeybindingPreferences``.
///
/// It is the population path: ``KeybindGrammar`` parses one binding and the dispatcher already
/// consults ``KeybindingPreferences/textBindings`` / ``KeybindingPreferences/unbinds``, but nothing
/// else writes those maps — so the `text:` / `csi:` / `esc:` / `unbind:` directives would otherwise
/// be unreachable end-to-end. This closes that gap and FOLDS the result into a
/// ``KeybindingPreferences`` the app publishes into ``WorkspaceBindingRegistry/activeOverrides``.
///
/// ## The table, not the lines
///
/// The input used to be the raw file text, scanned for `keybind = <chord>:<action>` lines by a
/// hand-written reader that had to agree, byte for byte, with a validator on the other side of an
/// FFI door. It is a TOML table now:
///
///     [keybind]
///     "cmd+t" = "new_tab"
///     "cmd+shift+k" = "text:\\u001b[3~"
///
/// so the parse is the TOML parser's, the duplicate-key check is the TOML parser's, and what is left
/// here is the part that was always this file's own: routing an action to the map it belongs in.
/// The grammar still sees `<chord>:<action>` — the two halves are joined back together — because
/// that grammar is shared with the terminal's own keybind syntax and is not this side's to redefine.
///
/// The ONE spelling the join cannot reproduce is `unbind`, which the grammar reads as a whole-line
/// form with the chord on the RIGHT (`unbind:cmd+d`). Keyed by chord, that would be `unbind` naming
/// one chord for the whole file — a table can only hold the key once. So `"cmd+d" = "unbind"` is
/// turned back around before the grammar sees it, and a file may disable as many defaults as it
/// likes.
///
/// **Validate-then-drop, file edition (CLAUDE.md §3, applied to untrusted *config text*):** a
/// malformed entry is DROPPED and the rest of the table still loads, rather than failing the whole
/// read or trapping.
///
/// **Pure + headless.** No state, no I/O — a `[String: String]` → struct transform, unit-tested
/// without touching disk.
///
/// **Named actions** (`cmd+1` → `goto_tab:1`, `cmd+t` → `new_tab`) need the registry's action-id →
/// `bindingID` mapping, which lives in `SlopDeskWorkspaceCore` (this module cannot import it). The
/// fold therefore takes an optional `resolveNamedBinding` hook: when supplied, a `named` action
/// whose `(id, arg)` the caller maps to a `(bindingID, chord)` is written into
/// ``KeybindingPreferences/overrides``; when `nil` (or when the caller returns `nil` for an unknown
/// action id), the entry is dropped. The `text:` / `csi:` / `esc:` / `unbind:` directives need NO
/// registry and are handled here unconditionally — that is the core of this loader.
///
/// ## The conflict diagnostic is NOT here
///
/// Two rows spelling one chord differently (`"cmd+leftarrow"` and `"cmd+left"`) is the one
/// `[keybind]` problem TOML cannot see, and it is reported by `slopdesk config validate` — which is
/// Rust, and reads `config::render::keybind_conflicts`. This loader stays a plain fold: the app runs
/// it on every activation and has nowhere to put a complaint.
public enum KeybindConfigLoader {
    /// The action word the grammar reads chord-last, and this loader therefore has to turn around.
    private static let unbindAction = "unbind"

    /// One entry whose action is a NAMED registry action (`new_tab`, `goto_tab:1`) rather than a
    /// literal-byte or unbind directive — surfaced so the WorkspaceCore wiring can resolve
    /// `(id, arg)` to a `bindingID` against the registry. The `chord` is the (already-validated)
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

    /// Fold a `[keybind]` table — chord → action — into `base`, returning the merged preferences.
    ///
    /// Each entry is handed to ``KeybindGrammar/parseLine`` as `<chord>:<action>`; one that fails to
    /// parse is dropped. The parsed action routes by kind:
    ///   - `text:` / `csi:` / `esc:` → a ``KeybindingPreferences/TextBinding`` keyed by the trigger
    ///     chord in ``KeybindingPreferences/textBindings`` (the literal-byte directives).
    ///   - `unbind` → the chord is inserted into ``KeybindingPreferences/unbinds``.
    ///   - a named action → routed through `resolveNamedBinding` into
    ///     ``KeybindingPreferences/overrides`` when it resolves to a `bindingID`, else dropped.
    ///
    /// The table's entries take precedence over `base` — the file is the explicit user authoring.
    /// Two entries cannot contend for one chord: a TOML table cannot declare the same key twice, so
    /// the last-writer-wins rule the line reader needed has no case left to decide.
    public static func apply(
        table: [String: String],
        to base: KeybindingPreferences = KeybindingPreferences(),
        resolveNamedBinding: ((NamedBinding) -> (bindingID: String, chord: KeybindingPreferences.KeyChord)?)? = nil,
    ) -> KeybindingPreferences {
        var overrides = base.overrides
        var textBindings = base.textBindings
        var unbinds = base.unbinds

        for (chord, action) in table {
            guard !chord.isEmpty, !action.isEmpty else { continue }
            let line = action == Self.unbindAction ? "\(action):\(chord)" : "\(chord):\(action)"
            guard let parsed = KeybindGrammar.parseLine(line) else { continue }
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
}
