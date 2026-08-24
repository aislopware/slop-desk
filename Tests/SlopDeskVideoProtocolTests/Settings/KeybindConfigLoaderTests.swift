import CSlopDeskFFI
import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// Pins for ``KeybindConfigLoader``, the `[keybind]` table → ``KeybindingPreferences`` population path that
/// makes the `text:` / `csi:` / `esc:` / `unbind:` half reachable end-to-end. Without this loader NOTHING
/// writes ``KeybindingPreferences/textBindings`` / ``unbinds`` from a real user-facing source, so the
/// dispatcher's text-binding / unbind branch would be dead code in practice.
final class KeybindConfigLoaderTests: XCTestCase {
    // MARK: text: / csi: / esc: → textBindings (the literal-byte half)

    /// `"cmd+shift+h" = "text:hi"` populates `textBindings` on the ⌘⇧H chord with the literal bytes — so
    /// after publishing into `activeOverrides` a ⌘⇧H keystroke injects `[h, i]`.
    func testTextBindingIsFoldedIntoTextBindings() {
        let prefs = KeybindConfigLoader.apply(table: ["cmd+shift+h": "text:hi"])
        let chord = KeybindingPreferences.KeyChord(key: "h", command: true, shift: true)
        XCTAssertEqual(prefs.textBindings[chord], .init(kind: .text, payload: [0x68, 0x69]))
        XCTAssertTrue(prefs.unbinds.isEmpty)
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    /// `csi:` / `esc:` route into `textBindings` with the ESC / ESC-`[` lead bytes already resolved (the
    /// dispatcher hands `payload` straight to `sendBytes`) and the matching `Kind` recorded for the UI.
    func testCSIAndEscBindingsFoldWithLeadBytes() {
        let prefs = KeybindConfigLoader.apply(table: [
            "cmd+pageup": "csi:5~",
            "opt+o": "esc:O",
        ])
        XCTAssertEqual(
            prefs.textBindings[.init(key: "pageup", command: true)],
            .init(kind: .csi, payload: [0x1B, 0x5B, 0x35, 0x7E]),
        )
        XCTAssertEqual(
            prefs.textBindings[.init(key: "o", option: true)],
            .init(kind: .esc, payload: [0x1B, 0x4F]),
        )
    }

    /// An ALIAS named-key spelling (`pgup`, `pgdn`, `enter`, `leftarrow`, …) is stored under the SAME
    /// canonical token the live dispatcher produces (`pageup`, `pagedown`, `return`, `left`, …) — folded by
    /// `KeybindingPreferences.KeyChord.init`. FAILS before the fix: the chord was stored verbatim under
    /// `"pgup"`/`"enter"`, so a live ⌘PageUp/⌘Return keystroke (which only ever produces the canonical token
    /// via `asPreferencesChord`) could never hit the `textBindings`/`unbinds` entry — the binding parsed yet
    /// was permanently dead.
    func testAliasNamedKeySpellingsAreStoredCanonically() {
        let prefs = KeybindConfigLoader.apply(table: [
            "cmd+pgup": "text:x",
            "ctrl+leftarrow": "csi:1;5D",
            "cmd+enter": "unbind",
        ])
        // Stored under the canonical token (what the dispatcher emits) …
        XCTAssertEqual(
            prefs.textBindings[.init(key: "pageup", command: true)]?.payload, [0x78],
            "cmd+pgup must store under the canonical \"pageup\" token",
        )
        XCTAssertEqual(
            prefs.textBindings[.init(key: "left", control: true)]?.kind, .csi,
            "ctrl+leftarrow must store under the canonical \"left\" token",
        )
        XCTAssertTrue(
            prefs.unbinds.contains(.init(key: "return", command: true)),
            "unbind:cmd+enter must store under the canonical \"return\" token",
        )
    }

    // MARK: unbind: → unbinds (the disable-a-default half)

    /// `"cmd+d" = "unbind"` inserts ⌘D into `unbinds` so the dispatcher passes the chord through instead
    /// of firing the default split-right action (an `unbind` entry disables a default).
    func testUnbindIsFoldedIntoUnbinds() {
        let prefs = KeybindConfigLoader.apply(table: ["cmd+d": "unbind"])
        XCTAssertTrue(prefs.unbinds.contains(.init(key: "d", command: true)))
        XCTAssertTrue(prefs.textBindings.isEmpty)
    }

    /// TWO chords can be unbound in the same file. The grammar reads `unbind` chord-LAST
    /// (`unbind:cmd+d`), so a table keyed the grammar's way could hold exactly one `unbind` key and a
    /// second would be a duplicate-key error from the TOML parser. The loader turns the entry around,
    /// which is what makes this table shape able to say what the line shape said. FAILS on a loader
    /// that joins every entry as `<chord>:<action>`: both would parse as an unknown NAMED action
    /// called `unbind` and be dropped.
    func testSeveralChordsCanBeUnbound() {
        let prefs = KeybindConfigLoader.apply(table: ["cmd+d": "unbind", "cmd+shift+d": "unbind"])
        XCTAssertTrue(prefs.unbinds.contains(.init(key: "d", command: true)))
        XCTAssertTrue(prefs.unbinds.contains(.init(key: "d", command: true, shift: true)))
        XCTAssertEqual(prefs.unbinds.count, 2)
    }

    // MARK: validate-then-drop

    /// A malformed entry is DROPPED and does NOT abort the fold — the well-formed entry beside it still
    /// lands. Revert-to-confirm-fail: deleting the parse guard would make the bad entry poison the whole
    /// table.
    func testMalformedEntryIsDroppedAndRestStillLoads() {
        let prefs = KeybindConfigLoader.apply(table: [
            "badmod+h": "text:nope",
            "cmd+shift+h": "text:hi",
        ])
        XCTAssertEqual(prefs.textBindings.count, 1)
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
    }

    /// An empty chord or an empty action is dropped before the grammar ever sees it — `"" = "text:x"`
    /// would otherwise reach `parseLine` as `":text:x"`, which is not a binding anybody wrote.
    func testEmptyHalvesAreDropped() {
        let prefs = KeybindConfigLoader.apply(table: ["": "text:x", "cmd+j": ""])
        XCTAssertTrue(prefs.textBindings.isEmpty)
        XCTAssertTrue(prefs.unbinds.isEmpty)
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    // MARK: merge into an existing base + named-action hook

    /// Folding preserves the `base` prefs (existing single-chord overrides / sequence overrides survive) and
    /// the table's text bindings are layered on top.
    func testFoldPreservesBaseOverrides() {
        let base = KeybindingPreferences(overrides: ["pane.splitRight": .init(key: "k", command: true)])
        let prefs = KeybindConfigLoader.apply(table: ["cmd+shift+h": "text:hi"], to: base)
        XCTAssertEqual(prefs.overrides["pane.splitRight"], .init(key: "k", command: true))
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
    }

    /// A NAMED action (`goto_tab:1`) is routed through the caller-supplied `resolveNamedBinding` hook into
    /// `overrides` (the registry lives in another module, so the loader cannot resolve the id itself). When
    /// the hook returns `nil` (unknown action), the entry is dropped.
    func testNamedActionRoutesThroughResolverHook() {
        let prefs = KeybindConfigLoader.apply(
            table: ["cmd+1": "goto_tab:1", "cmd+2": "unknown_action"],
            resolveNamedBinding: { named in
                guard named.id == "goto_tab", let arg = named.arg else { return nil }
                return (bindingID: "pane.select.\(arg)", chord: named.chord)
            },
        )
        XCTAssertEqual(prefs.overrides["pane.select.1"], .init(key: "1", command: true))
        // The unknown action resolved to nil ⇒ dropped, no stray override.
        XCTAssertEqual(prefs.overrides.count, 1)
    }

    /// With NO resolver supplied, named-action entries are simply dropped (the text/unbind directives are
    /// still honoured — they need no registry).
    func testNamedActionDroppedWithoutResolver() {
        let prefs = KeybindConfigLoader.apply(table: ["cmd+1": "goto_tab:1", "cmd+q": "unbind"])
        XCTAssertTrue(prefs.overrides.isEmpty)
        XCTAssertTrue(prefs.unbinds.contains(.init(key: "q", command: true)))
    }

    // MARK: the production-shaped resolver folds named/param actions end-to-end

    /// The same resolution the production hook performs, asked of the same door.
    ///
    /// This was a hand-built stand-in — a three-name table plus its own `goto_tab` bound — written
    /// because the VideoProtocol test target cannot import `SlopDeskWorkspaceCore`, where
    /// `WorkspaceBindingRegistry.bindingID(forConfigName:arg:)` lives. It does not need to: the
    /// table moved to `slopdesk-workspace`'s `keybind` and the registry is now marshalling around
    /// `slopdesk_ws_binding_id_for_config_name`, which this target reaches directly. A faithful
    /// fake of a table is still a second copy of it, and the copy had already inherited the bound
    /// the port went on to correct.
    private func handBuiltResolver(
        _ named: KeybindConfigLoader.NamedBinding,
    ) -> (bindingID: String, chord: KeybindingPreferences.KeyChord)? {
        let name = Array(named.id.utf8)
        let argument = Array((named.arg ?? "").utf8)
        let resolved: String? = name.withUnsafeBufferPointer { action in
            argument.withUnsafeBufferPointer { arg in
                var room = [UInt8](repeating: 0, count: 64)
                let needed = room.withUnsafeMutableBufferPointer { out in
                    slopdesk_ws_binding_id_for_config_name(
                        action.baseAddress, action.count, arg.baseAddress, arg.count,
                        out.baseAddress, out.count,
                    )
                }
                guard needed > 0, needed <= room.count else { return nil }
                return String(bytes: room[0..<needed], encoding: .utf8)
            }
        }
        guard let id = resolved else { return nil }
        return (bindingID: id, chord: named.chord)
    }

    /// A bare named action (`"cmd+t" = "new_tab"`) folds into `overrides` under the resolved bindingID with
    /// the trigger chord — the end-to-end fold the launch-time resolver performs (the named-action half).
    /// The `text:`/`unbind:` directives stay empty (this entry is a pure override).
    func testNamedBindingFoldsIntoOverridesViaResolver() {
        let prefs = KeybindConfigLoader.apply(
            table: ["cmd+t": "new_tab"],
            resolveNamedBinding: handBuiltResolver,
        )
        XCTAssertEqual(prefs.overrides["tab.new"], .init(key: "t", command: true))
        XCTAssertEqual(prefs.overrides.count, 1)
        XCTAssertTrue(prefs.textBindings.isEmpty)
        XCTAssertTrue(prefs.unbinds.isEmpty)
    }

    /// The parameterized `goto_tab:N` action folds per-digit: `"cmd+3" = "goto_tab:3"` →
    /// `overrides["pane.select.3"]` on ⌘3 (the resolver expands the arg into the per-digit registry id).
    func testParameterizedGotoTabFoldsPerDigitViaResolver() {
        let prefs = KeybindConfigLoader.apply(
            table: ["cmd+3": "goto_tab:3"],
            resolveNamedBinding: handBuiltResolver,
        )
        XCTAssertEqual(prefs.overrides["pane.select.3"], .init(key: "3", command: true))
        XCTAssertEqual(prefs.overrides.count, 1)
    }

    /// An UNKNOWN named action (`"cmd+t" = "frobnicate"`) the resolver maps to `nil` is dropped — no stray
    /// override, no trap (validate-then-drop). Revert-to-confirm-fail: a resolver that force-unwrapped its
    /// lookup would crash here instead of dropping.
    func testUnknownNamedBindingIsDropped() {
        let prefs = KeybindConfigLoader.apply(
            table: ["cmd+t": "frobnicate"],
            resolveNamedBinding: handBuiltResolver,
        )
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    // MARK: the empty table

    /// An EMPTY `[keybind]` table returns `base` unchanged — a fresh install authored no bindings, so its
    /// behaviour is identical to one that never had a config file.
    func testEmptyTableReturnsBaseUnchanged() {
        let base = KeybindingPreferences(unbinds: [.init(key: "z", command: true)])
        XCTAssertEqual(KeybindConfigLoader.apply(table: [:], to: base), base)
    }
}
