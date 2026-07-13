import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// The CONFIGURABLE workspace prefix key (Settings ▸ Key Bindings ▸ Prefix Key): the ⌃B default, the
/// override-aware `resolvedPrefixChord` (validate-then-default), the `WorkspaceStore` seeding + LIVE
/// re-key sweep (`applyWorkspaceKeyPrefix`), the `PreferencesStore.onPrefixKeyApply` hook the app wires
/// both cached consumers through, and the editor-model capture gate (`isUsablePrefixKey`).
@MainActor
final class PrefixKeyResolutionTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "PrefixKeyResolutionTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    override func tearDown() {
        // Restore the process-wide statics these paths mutate so a later test isn't polluted.
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        PreferencesStore.onPrefixKeyApply = nil
        EnvConfig.overlay = [:]
        super.tearDown()
    }

    // MARK: - Resolution (registry)

    /// The out-of-the-box prefix is ⌃B — the ONE default every consumer (store seed, interceptor init,
    /// machine init) reads, so the app monitor and the per-surface interceptors can never disagree.
    func testDefaultPrefixIsCtrlB() {
        XCTAssertEqual(WorkspaceBindingRegistry.defaultPrefixChord, KeyChord(character: "b", [.control]))
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedPrefixChord(overrides: KeybindingPreferences()),
            KeyChord(character: "b", [.control]),
            "no override ⇒ the ⌃B default stands",
        )
    }

    /// A stored `prefixKey` override that maps and carries a real modifier moves the resolved prefix.
    func testUsableOverrideMovesThePrefix() {
        let prefs = KeybindingPreferences(prefixKey: .init(key: "g", control: true))
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedPrefixChord(overrides: prefs),
            KeyChord(character: "g", [.control]),
        )
        // A non-Ctrl modifier is accepted too (the double-tap send-prefix then gracefully no-ops).
        let optPrefs = KeybindingPreferences(prefixKey: .init(key: "p", option: true))
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedPrefixChord(overrides: optPrefs),
            KeyChord(character: "p", [.option]),
        )
    }

    /// Validate-then-default: a bare or shift-only stored chord would make NORMAL TYPING arm the prefix
    /// (every "g" swallowed) — the resolver must discard it and keep the default.
    func testModifierlessOrShiftOnlyOverrideFallsBackToDefault() {
        let bare = KeybindingPreferences(prefixKey: .init(key: "g"))
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedPrefixChord(overrides: bare),
            WorkspaceBindingRegistry.defaultPrefixChord,
            "a modifier-less prefix must be discarded",
        )
        let shiftOnly = KeybindingPreferences(prefixKey: .init(key: "g", shift: true))
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedPrefixChord(overrides: shiftOnly),
            WorkspaceBindingRegistry.defaultPrefixChord,
            "shift alone is still typing — discarded",
        )
    }

    /// A malformed stored chord (a key token the registry bridge can't map) falls back to the default —
    /// never traps, never yields a dead un-armable prefix.
    func testUnmappableOverrideFallsBackToDefault() {
        let junk = KeybindingPreferences(prefixKey: .init(key: "notakey", control: true))
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedPrefixChord(overrides: junk),
            WorkspaceBindingRegistry.defaultPrefixChord,
        )
    }

    // MARK: - WorkspaceStore seeding + the live re-key sweep

    /// A store built AFTER the overrides are published (the app builds `PreferencesStore` first) seeds
    /// `workspaceKeyPrefix` from the RESOLVED prefix — the persisted override is live from the first pane.
    func testStoreSeedsTheResolvedPrefixAtBuild() {
        WorkspaceBindingRegistry.activeOverrides =
            KeybindingPreferences(prefixKey: .init(key: "g", control: true))
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { FakePaneSession($0) }, liveVideoCap: 2,
        )
        XCTAssertEqual(store.workspaceKeyPrefix, KeyChord(character: "g", [.control]))
    }

    /// `applyWorkspaceKeyPrefix` re-points the shared prefix AND re-keys the ALREADY-materialized pane's
    /// interceptor — without the sweep the surface would keep arming on the OLD prefix while the app
    /// monitor armed on the new one (split-brain).
    func testApplyWorkspaceKeyPrefixRekeysLivePaneInterceptors() throws {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) }, liveVideoCap: 2,
        )
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let model = try XCTUnwrap(
            (store.handle(for: active) as? RecordingTerminalPaneSession)?.terminalModel,
        )
        // The production wiring hands the surface its interceptor keyed on the store's live prefix.
        store.wireKeyInterceptor(terminal: model)
        XCTAssertEqual(model.keyInterceptor?.prefix, WorkspaceBindingRegistry.defaultPrefixChord)

        let moved = KeyChord(character: "g", [.control])
        store.applyWorkspaceKeyPrefix(moved)
        XCTAssertEqual(store.workspaceKeyPrefix, moved, "new panes wire with the moved prefix")
        XCTAssertEqual(model.keyInterceptor?.prefix, moved, "the LIVE pane's interceptor is re-keyed")
    }

    // MARK: - PreferencesStore hook (the app's live re-key channel)

    /// Every keybindings (re)apply fires `onPrefixKeyApply` with the RESOLVED chord — setting a prefix
    /// override delivers the new chord; clearing it delivers the ⌃B default back.
    func testKeybindingsApplyFiresThePrefixHookWithTheResolvedChord() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        var received: [KeyChord] = []
        PreferencesStore.onPrefixKeyApply = { received.append($0) }

        store.keybindings = KeybindingPreferences(prefixKey: .init(key: "g", control: true))
        XCTAssertEqual(received.last, KeyChord(character: "g", [.control]))

        store.keybindings = KeybindingPreferences()
        XCTAssertEqual(
            received.last, WorkspaceBindingRegistry.defaultPrefixChord,
            "clearing the override delivers the default back so consumers re-key to ⌃B",
        )
    }

    // MARK: - Editor model (the capture gate + reset affordance)

    /// The editor's capture gate mirrors the resolver's acceptance: ⌃/⌥/⌘ required (shift alone / bare is
    /// typing), and an unmappable token is unusable — so a recorded prefix is never silently discarded.
    func testIsUsablePrefixKeyRequiresARealModifier() {
        XCTAssertTrue(KeybindingsEditorModel.isUsablePrefixKey(.init(key: "b", control: true)))
        XCTAssertTrue(KeybindingsEditorModel.isUsablePrefixKey(.init(key: "p", command: true)))
        XCTAssertFalse(KeybindingsEditorModel.isUsablePrefixKey(.init(key: "g")))
        XCTAssertFalse(KeybindingsEditorModel.isUsablePrefixKey(.init(key: "g", shift: true)))
        XCTAssertFalse(KeybindingsEditorModel.isUsablePrefixKey(.init(key: "notakey", control: true)))
    }

    /// The prefix write/clear helpers preserve every OTHER customization (the mutate-a-copy contract that
    /// keeps config.toml text/unbind/sequence bindings intact), and a set prefix flips `hasCustomizations`
    /// so the editor surfaces "Reset to Default".
    func testPrefixHelpersPreserveOtherCollectionsAndGateReset() {
        var prefs = KeybindingPreferences(
            overrides: ["pane.splitRight": .init(key: "e", command: true)],
            unbinds: [.init(key: "t", command: true)],
        )
        XCTAssertNil(prefs.prefixKey)

        prefs = KeybindingsEditorModel.settingPrefixKey(.init(key: "g", control: true), in: prefs)
        XCTAssertEqual(prefs.prefixKey, .init(key: "g", control: true))
        XCTAssertEqual(prefs.overrides.count, 1, "setting the prefix preserves action overrides")
        XCTAssertEqual(prefs.unbinds.count, 1, "setting the prefix preserves unbinds")
        XCTAssertTrue(KeybindingsEditorModel.hasCustomizations(prefs))

        prefs = KeybindingsEditorModel.clearingPrefixKey(in: prefs)
        XCTAssertNil(prefs.prefixKey)
        XCTAssertEqual(prefs.overrides.count, 1, "clearing the prefix preserves action overrides")

        // The prefix ALONE gates the reset affordance (no other customization present).
        let onlyPrefix = KeybindingPreferences(prefixKey: .init(key: "g", control: true))
        XCTAssertTrue(KeybindingsEditorModel.hasCustomizations(onlyPrefix))
        XCTAssertFalse(KeybindingsEditorModel.hasCustomizations(KeybindingPreferences()))
    }
}
