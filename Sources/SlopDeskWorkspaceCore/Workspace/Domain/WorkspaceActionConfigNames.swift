import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - Config action-name → registry bindingID resolver (the N5 resolver core)

/// Maps config action NAMES (`new_tab`, `split_right`, `goto_tab:N`, …) to this registry's stable
/// binding ids (`tab.new`, `pane.splitRight`, `pane.select.<n>`, …).
///
/// **Why this exists (the N5 gap).** ``KeybindGrammar/parseLine(_:)`` already turns a config line's
/// right-hand side into `.named(id:arg:)` for a name like `new_tab` or `goto_tab:1`, and
/// `KeybindConfigLoader.apply` folds a resolved override into ``KeybindingPreferences`` through an
/// OPTIONAL `resolveNamedBinding` hook — but the loader CANNOT call this registry directly
/// (`KeybindConfigLoader` lives in `SlopDeskVideoProtocol`, which must not import
/// `SlopDeskWorkspaceCore`; that layering is exactly why the hook is a closure). This is the
/// production resolver the app layer (`SlopDeskClientUI`, which imports both) installs into that hook so
/// a user's `keybind = cmd+t:new_tab` actually rebinds the registry action instead of silently doing
/// nothing.
///
/// **Validate-then-drop (CLAUDE.md §3, applied to untrusted config text).** An unknown name, an
/// out-of-range / non-numeric `goto_tab` arg, and the libghostty-only responder actions
/// (`copy_to_clipboard` / `paste_from_clipboard` / `select_all`, which have NO ``WorkspaceAction`` — the
/// terminal's own responder owns them) all return `nil`. The resolver NEVER force-unwraps, NEVER invents
/// an id, and NEVER traps on hostile input — a malformed binding is simply dropped.
///
/// **iOS.** Pure `String → String?`, no SwiftUI / view / platform API; it compiles into the iOS slice
/// of `SlopDeskWorkspaceCore` (macOS `swift build` won't type-check that slice — run
/// `slopdesk-gate ios`). Names taken from `spec/reference__keybindings.md` "Config keys" +
/// `spec/customization__custom-keybindings.md`.
public extension WorkspaceBindingRegistry {
    /// Resolve a config action `name` (with an optional `arg`) to this registry's binding id, or
    /// `nil` if the name is unknown, the arg is out of range, or the action is a libghostty-only responder
    /// action with no ``WorkspaceAction`` (validate-then-drop — never a trap, never an invented id).
    ///
    /// The table and the `goto_tab` bound are `slopdesk-workspace`'s `keybind`, reached through
    /// `slopdesk_ws_binding_id_for_config_name`. Both used to be written here as well, and the
    /// difference between the two spellings was the `goto_tab` argument: the Swift bounded it to
    /// `1...9`, the crate's grammar accepted any integer, and only the Swift bound is real — there
    /// are nine per-digit bindings, so `goto_tab:99` names nothing. That bound now lives on the
    /// Rust side, in both halves of the line: the grammar refuses the argument outright (so a
    /// keybinding editor stops calling such a line valid), and the resolver here answers nothing
    /// for it (so nothing reaches this registry that it cannot bind).
    ///
    /// - `goto_tab` requires a base-10 `arg` in `1...9` → `pane.select.<n>`; any other arg (`0`, `10`,
    ///   non-numeric, surrounding whitespace, or a missing arg) is dropped. The NAME stays `goto_tab`
    ///   because it is Ghostty's, not ours — what a ⌘-digit lands on in this app is a pane, and a config
    ///   that asks for "the Nth thing" gets the Nth thing this workspace counts.
    /// - Every other supported name is a bare action; a stray `arg` on a bare action is ignored (the
    ///   action takes none).
    /// - `copy_to_clipboard` / `paste_from_clipboard` / `select_all` and any unrecognised name → `nil`.
    static func bindingID(forConfigName name: String, arg: String?) -> String? {
        withOptionalText(name) { action, actionLength, _ in
            withOptionalText(arg) { argument, argumentLength, _ in
                wsAnswer { out, cap in
                    slopdesk_ws_binding_id_for_config_name(
                        action, actionLength, argument, argumentLength, out, cap,
                    )
                }
            }
        }
    }
}
