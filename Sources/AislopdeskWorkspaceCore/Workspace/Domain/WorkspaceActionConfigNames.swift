import Foundation

// MARK: - otty config action-name → registry bindingID resolver (E1 / WI-1, the N5 resolver core)

/// Maps otty config action NAMES (`new_tab`, `split_right`, `goto_tab:N`, …) to this registry's stable
/// binding ids (`tab.new`, `pane.splitRight`, `tab.select.<n>`, …).
///
/// **Why this exists (the N5 gap).** ``KeybindGrammar/parseAction`` already turns a config line's
/// right-hand side into `.named(id:arg:)` for a name like `new_tab` or `goto_tab:1`, and
/// `KeybindConfigLoader.apply` folds a resolved override into ``KeybindingPreferences`` through an
/// OPTIONAL `resolveNamedBinding` hook — but the loader CANNOT call this registry directly
/// (`KeybindConfigLoader` lives in `AislopdeskVideoProtocol`, which must not import
/// `AislopdeskWorkspaceCore`; that layering is exactly why the hook is a closure). This table is the
/// production resolver the app layer (`AislopdeskClientUI`, which imports both) installs into that hook so
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
/// of `AislopdeskWorkspaceCore` (macOS `swift build` won't type-check that slice — run
/// `scripts/check-ios.sh`). Names taken from `spec/reference__keybindings.md` "Config keys" +
/// `spec/customization__custom-keybindings.md`.
public extension WorkspaceBindingRegistry {
    /// The bare otty config name → registry bindingID table (the non-parameterized actions). The values
    /// are exactly the `WorkspaceBinding.id`s in ``bindings`` / ``selectTabBindings`` — pinned to have no
    /// orphan by `WorkspaceActionConfigNamesTests`. The parameterized `goto_tab:N` family is resolved
    /// separately (it expands to nine per-digit ids in ``selectTabBindings``).
    private static let configNameToBindingID: [String: String] = [
        // Panes
        "new_tab": "tab.new",
        "split_right": "pane.splitRight",
        "split_left": "pane.splitLeft",
        "split_down": "pane.splitDown",
        "split_up": "pane.splitUp",
        "close_pane": "pane.close",
        // Tabs
        "reopen_closed": "tab.reopenClosed",
        "next_tab": "tab.next",
        "prev_tab": "tab.prev",
        // Focus
        "focus_left": "focus.left",
        "focus_right": "focus.right",
        "focus_up": "focus.up",
        "focus_down": "focus.down",
        // View
        "command_palette": "view.palette",
        "cheat_sheet": "view.cheatSheet",
        "find": "view.find",
        // Sessions
        "new_session": "session.new",
    ]

    /// Resolve an otty config action `name` (with an optional `arg`) to this registry's binding id, or
    /// `nil` if the name is unknown, the arg is out of range, or the action is a libghostty-only responder
    /// action with no ``WorkspaceAction`` (validate-then-drop — never a trap, never an invented id).
    ///
    /// - `goto_tab` requires a base-10 `arg` in `1...9` → `tab.select.<n>`; any other arg (`0`, `10`,
    ///   non-numeric, surrounding whitespace, or a missing arg) is dropped.
    /// - Every other supported name is a bare action looked up in ``configNameToBindingID``; a stray `arg`
    ///   on a bare action is ignored (the action takes none).
    /// - `copy_to_clipboard` / `paste_from_clipboard` / `select_all` and any unrecognised name → `nil`.
    static func bindingID(forConfigName name: String, arg: String?) -> String? {
        // The ONE parameterized action: `goto_tab:N`, N ∈ 1…9 → tab.select.<n>. Validate the arg as a
        // base-10 integer in range BEFORE building the id (no `!`, no out-of-range id).
        if name == "goto_tab" {
            guard let arg, let n = Int(arg), (1...9).contains(n) else { return nil }
            return "tab.select.\(n)"
        }
        // A bare action — the arg (if any) is irrelevant. Unknown name → nil (drop).
        return configNameToBindingID[name]
    }
}
