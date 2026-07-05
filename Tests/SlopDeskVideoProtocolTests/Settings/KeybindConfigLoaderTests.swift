import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// E1/WI-6 (production wiring) — pins for ``KeybindConfigLoader``, the config-file → ``KeybindingPreferences``
/// population path that makes the `text:` / `csi:` / `esc:` / `unbind:` half of ES-E1-6 reachable end-to-end.
/// Before this loader existed NOTHING wrote ``KeybindingPreferences/textBindings`` / ``unbinds`` from a real
/// user-facing source, so the dispatcher's text-binding / unbind branch was dead code in practice; these
/// tests FAIL to compile/run against that earlier tree (the type did not exist) and prove the fold here.
final class KeybindConfigLoaderTests: XCTestCase {
    // MARK: text: / csi: / esc: → textBindings (the literal-byte half)

    /// `keybind = cmd+shift+h:text:hi` populates `textBindings` on the ⌘⇧H chord with the literal bytes — so
    /// after publishing into `activeOverrides` a ⌘⇧H keystroke injects `[h, i]` (the ES-E1-6 acceptance).
    func testTextBindingIsFoldedIntoTextBindings() {
        let prefs = KeybindConfigLoader.apply(configText: "keybind = cmd+shift+h:text:hi")
        let chord = KeybindingPreferences.KeyChord(key: "h", command: true, shift: true)
        XCTAssertEqual(prefs.textBindings[chord], .init(kind: .text, payload: [0x68, 0x69]))
        XCTAssertTrue(prefs.unbinds.isEmpty)
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    /// `csi:` / `esc:` route into `textBindings` with the ESC / ESC-`[` lead bytes already resolved (the
    /// dispatcher hands `payload` straight to `sendBytes`) and the matching `Kind` recorded for the UI.
    func testCSIAndEscBindingsFoldWithLeadBytes() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+pageup:csi:5~
            keybind = opt+o:esc:O
            """,
        )
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
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+pgup:text:x
            keybind = ctrl+leftarrow:csi:1;5D
            keybind = unbind:cmd+enter
            """,
        )
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

    /// `keybind = unbind:cmd+d` inserts ⌘D into `unbinds` so the dispatcher passes the chord through instead
    /// of firing the default split-right action (the ES-E1-6 "an unbind: directive disables a default").
    func testUnbindIsFoldedIntoUnbinds() {
        let prefs = KeybindConfigLoader.apply(configText: "keybind = unbind:cmd+d")
        XCTAssertTrue(prefs.unbinds.contains(.init(key: "d", command: true)))
        XCTAssertTrue(prefs.textBindings.isEmpty)
    }

    // MARK: lenient flat-config dialect

    /// Blank lines, `#` comments, OTHER config keys (silently ignored), lenient `=` whitespace, and an
    /// optional quoted value all parse — only `keybind` lines contribute, every other key is dropped.
    func testLenientDialectIgnoresCommentsBlanksAndOtherKeys() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            # a comment line

            font-size = 14
            theme = Nord
            keybind=cmd+shift+h:text:hi
            keybind = "ctrl+a:text:x"
            """,
        )
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
        XCTAssertEqual(prefs.textBindings[.init(key: "a", control: true)]?.payload, [0x78])
        // No `font-size` / `theme` key leaked into any override map.
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    /// A malformed `keybind` line is DROPPED (validate-then-drop) and does NOT abort the load — the
    /// well-formed line on the next row still folds. Revert-to-confirm-fail: deleting the parse guard would
    /// make the bad line crash / poison the whole load.
    func testMalformedLineIsDroppedAndRestStillLoads() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = badmod+h:text:nope
            keybind = cmd+shift+h:text:hi
            """,
        )
        XCTAssertEqual(prefs.textBindings.count, 1)
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
    }

    /// Later `keybind` on the same chord wins (last-writer-wins within the file).
    func testLastWriterWinsOnTheSameChord() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+shift+h:text:aa
            keybind = cmd+shift+h:text:bb
            """,
        )
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x62, 0x62],
        )
    }

    // MARK: merge into an existing base + named-action hook

    /// Folding preserves the `base` prefs (existing single-chord overrides / sequence overrides survive) and
    /// the file's text bindings are layered on top.
    func testFoldPreservesBaseOverrides() {
        let base = KeybindingPreferences(overrides: ["pane.splitRight": .init(key: "k", command: true)])
        let prefs = KeybindConfigLoader.apply(configText: "keybind = cmd+shift+h:text:hi", to: base)
        XCTAssertEqual(prefs.overrides["pane.splitRight"], .init(key: "k", command: true))
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
    }

    /// A NAMED action (`goto_tab:1`) is routed through the caller-supplied `resolveNamedBinding` hook into
    /// `overrides` (the registry lives in another module, so the loader cannot resolve the id itself). When
    /// the hook returns `nil` (unknown action), the named line is dropped.
    func testNamedActionRoutesThroughResolverHook() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+1:goto_tab:1
            keybind = cmd+2:unknown_action
            """,
            resolveNamedBinding: { named in
                guard named.id == "goto_tab", let arg = named.arg else { return nil }
                return (bindingID: "tab.select.\(arg)", chord: named.chord)
            },
        )
        XCTAssertEqual(prefs.overrides["tab.select.1"], .init(key: "1", command: true))
        // The unknown action resolved to nil ⇒ dropped, no stray override.
        XCTAssertEqual(prefs.overrides.count, 1)
    }

    /// With NO resolver supplied, named-action lines are simply dropped (the text/unbind directives are still
    /// honoured — they need no registry). This is the launch-time default for the ES-E1-6 wiring.
    func testNamedActionDroppedWithoutResolver() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+1:goto_tab:1
            keybind = unbind:cmd+q
            """,
        )
        XCTAssertTrue(prefs.overrides.isEmpty)
        XCTAssertTrue(prefs.unbinds.contains(.init(key: "q", command: true)))
    }

    // MARK: WI-2 — the production-shaped resolver folds named/param actions end-to-end

    /// A hand-built stand-in for the production `WorkspaceBindingRegistry.bindingID(forConfigName:arg:)`
    /// resolver installed at launch (`SlopDeskClientApp.swift`). The VideoProtocol test target cannot import
    /// `SlopDeskWorkspaceCore` (the registry lives there — the very reason the loader takes a closure hook),
    /// so this mirrors the table's CONTRACT: bare names map to ids, `goto_tab:N` (N ∈ 1…9) expands per-digit,
    /// and an unknown name / out-of-range arg resolves to `nil` (drop, no trap). It is deliberately NOT the
    /// registry — it is a faithful fake of the shape WI-2 wires, so these loader-level cases stay in-module.
    private func handBuiltResolver(
        _ named: KeybindConfigLoader.NamedBinding,
    ) -> (bindingID: String, chord: KeybindingPreferences.KeyChord)? {
        let bareTable: [String: String] = [
            "new_tab": "tab.new",
            "close_pane": "pane.close",
            "split_right": "pane.splitRight",
        ]
        let bindingID: String? =
            if named.id == "goto_tab" {
                if let arg = named.arg, let n = Int(arg), (1...9).contains(n) {
                    "tab.select.\(n)"
                } else {
                    nil
                }
            } else {
                bareTable[named.id]
            }
        guard let id = bindingID else { return nil }
        return (bindingID: id, chord: named.chord)
    }

    /// A bare named action (`cmd+t:new_tab`) folds into `overrides` under the resolved bindingID with the
    /// trigger chord — the end-to-end fold the launch-time resolver performs (ES-E1-6's named half). The
    /// `text:`/`unbind:` directives stay empty (this line is a pure override).
    func testNamedBindingFoldsIntoOverridesViaResolver() {
        let prefs = KeybindConfigLoader.apply(
            configText: "keybind = cmd+t:new_tab",
            resolveNamedBinding: handBuiltResolver,
        )
        XCTAssertEqual(prefs.overrides["tab.new"], .init(key: "t", command: true))
        XCTAssertEqual(prefs.overrides.count, 1)
        XCTAssertTrue(prefs.textBindings.isEmpty)
        XCTAssertTrue(prefs.unbinds.isEmpty)
    }

    /// The parameterized `goto_tab:N` action folds per-digit: `cmd+3:goto_tab:3` → `overrides["tab.select.3"]`
    /// on ⌘3 (the resolver expands the arg into the per-digit registry id).
    func testParameterizedGotoTabFoldsPerDigitViaResolver() {
        let prefs = KeybindConfigLoader.apply(
            configText: "keybind = cmd+3:goto_tab:3",
            resolveNamedBinding: handBuiltResolver,
        )
        XCTAssertEqual(prefs.overrides["tab.select.3"], .init(key: "3", command: true))
        XCTAssertEqual(prefs.overrides.count, 1)
    }

    /// An UNKNOWN named action (`cmd+t:frobnicate`) the resolver maps to `nil` is dropped — no stray override,
    /// no trap (validate-then-drop). Revert-to-confirm-fail: a resolver that force-unwrapped its lookup would
    /// crash here instead of dropping.
    func testUnknownNamedBindingIsDropped() {
        let prefs = KeybindConfigLoader.apply(
            configText: "keybind = cmd+t:frobnicate",
            resolveNamedBinding: handBuiltResolver,
        )
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    // MARK: file I/O entry (missing / present)

    /// A MISSING file returns `base` unchanged (a fresh install authored no config ⇒ behaviour-identical).
    func testMissingFileReturnsBaseUnchanged() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-no-such-\(UUID().uuidString).toml")
        let base = KeybindingPreferences(unbinds: [.init(key: "z", command: true)])
        XCTAssertEqual(KeybindConfigLoader.loadFile(at: url, into: base), base)
    }

    /// A real on-disk file is read and folded — the full path the app launch uses (sans the default URL).
    func testFileOnDiskIsLoadedAndFolded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-config-\(UUID().uuidString).toml")
        try "keybind = cmd+shift+h:text:hi\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let prefs = KeybindConfigLoader.loadFile(at: url)
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
    }

    // MARK: default config URL resolution

    /// `XDG_CONFIG_HOME` wins; else `$HOME/.config`; the file is `slopdesk/config.toml`.
    func testDefaultConfigURLHonoursXDGThenHome() {
        let xdg = KeybindConfigLoader.defaultConfigURL(environment: ["XDG_CONFIG_HOME": "/tmp/cfg"])
        XCTAssertEqual(xdg?.path, "/tmp/cfg/slopdesk/config.toml")
        let home = KeybindConfigLoader.defaultConfigURL(environment: ["HOME": "/Users/me"])
        XCTAssertEqual(home?.path, "/Users/me/.config/slopdesk/config.toml")
        XCTAssertNil(KeybindConfigLoader.defaultConfigURL(environment: [:]))
    }
}
