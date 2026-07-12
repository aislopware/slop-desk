import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the config action-name → registry-bindingID resolver — ``WorkspaceBindingRegistry/bindingID(forConfigName:arg:)``
/// — that closes the gap where named / parameterized config bindings are PARSED by ``KeybindGrammar`` but
/// were dropped end-to-end for want of a name table.
///
/// The names come from the config grammar (`docs/ui-shell/spec/reference__keybindings.md` "Config keys" +
/// `docs/ui-shell/spec/customization__custom-keybindings.md`): `cmd+t:new_tab`, `cmd+w:close_pane`,
/// `cmd+shift+t:reopen_closed`, `cmd+1:goto_tab:1`, … . The resolver must:
///   - map every supported bare name to a REAL `binding.id` (no orphan);
///   - resolve `goto_tab:N` for N ∈ 1…9 to `tab.select.<n>`, and reject 0 / 10 / non-numeric / no-arg;
///   - return `nil` (validate-then-drop, CLAUDE.md §3) for an unknown name and for the libghostty-only
///     responder actions (`copy_to_clipboard` / `paste_from_clipboard` / `select_all`) that have NO
///     `WorkspaceAction` — never an invented id, never a trap.
final class WorkspaceActionConfigNamesTests: XCTestCase {
    /// The id-set the registry actually knows (the dedup key the resolver must never produce an orphan of).
    private var registeredIDs: Set<String> {
        Set(WorkspaceBindingRegistry.allBindings.map(\.id))
    }

    // MARK: - Bare-name coverage: every supported config name resolves to a REAL binding id

    func testEverySlateConfigNameResolvesToARealBindingID() {
        // (configName, arg) → expected bindingID. The bare-name surface of the config grammar.
        let expected: [String: String] = [
            "new_tab": "tab.new",
            "split_right": "pane.splitRight",
            "split_left": "pane.splitLeft",
            "split_down": "pane.splitDown",
            "split_up": "pane.splitUp",
            "close_pane": "pane.close",
            "reopen_closed": "tab.reopenClosed",
            "next_tab": "tab.next",
            "prev_tab": "tab.prev",
            "focus_left": "focus.left",
            "focus_right": "focus.right",
            "focus_up": "focus.up",
            "focus_down": "focus.down",
            "command_palette": "view.palette",
            "cheat_sheet": "view.cheatSheet",
            "find": "view.find",
        ]

        let ids = registeredIDs
        for (name, wantID) in expected {
            let resolved = WorkspaceBindingRegistry.bindingID(forConfigName: name, arg: nil)
            XCTAssertEqual(resolved, wantID, "config name \(name) should resolve to \(wantID)")
            // And the resolved id must be a real registry binding — no orphan.
            XCTAssertTrue(
                ids.contains(wantID),
                "resolved id \(wantID) for \(name) must exist in allBindings (no orphan)",
            )
        }
    }

    // MARK: - goto_tab:N — bounded 1…9, drop everything else

    func testGotoTabResolvesPerDigitAndRejectsOutOfRange() {
        let ids = registeredIDs
        // In-range: each digit maps to its own select-tab id, all of which are real bindings.
        for n in 1...9 {
            let resolved = WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: String(n))
            XCTAssertEqual(resolved, "tab.select.\(n)", "goto_tab:\(n) should resolve to tab.select.\(n)")
            XCTAssertTrue(ids.contains("tab.select.\(n)"), "tab.select.\(n) must be a registered binding")
        }
        // Out-of-range / malformed / missing arg → nil (validate-then-drop, never a trap).
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: "0"))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: "10"))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: "-1"))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: "x"))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: ""))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: " 3 "))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: nil))
    }

    // MARK: - A bare name MUST NOT swallow a stray arg meant for a parameterized action

    func testBareNamesIgnoreOrRejectIrrelevantArgs() {
        // A bare action carries no arg; passing one for a name that doesn't take one must not invent a
        // different id. `new_tab` with an arg still means new tab (the arg is irrelevant), and a name that
        // ONLY exists as a parameterized action (`goto_tab`) with NO arg is nil (covered above).
        XCTAssertEqual(WorkspaceBindingRegistry.bindingID(forConfigName: "new_tab", arg: "7"), "tab.new")
    }

    // MARK: - Unknown + libghostty-only responder names → nil (drop, no invented id)

    func testUnknownAndLibghosttyOnlyNamesReturnNil() {
        // Wholly unknown name.
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "frobnicate", arg: nil))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "", arg: nil))
        // libghostty's own responder actions — they have NO WorkspaceAction (TerminalContextMenu handles
        // them), so the registry must DROP them, not invent an id.
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "copy_to_clipboard", arg: nil))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "paste_from_clipboard", arg: nil))
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "select_all", arg: nil))
        // `goto_tab` is NOT a valid BARE name (it requires an arg) — see the goto_tab test for the param form.
        XCTAssertNil(WorkspaceBindingRegistry.bindingID(forConfigName: "goto_tab", arg: nil))
    }
}
