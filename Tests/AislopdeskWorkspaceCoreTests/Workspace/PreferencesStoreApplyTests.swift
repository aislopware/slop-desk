import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskWorkspaceCore

/// W13 — the ``PreferencesStore`` APPLY paths (live env overlay, sidecar, terminal broadcast, keybinding
/// overrides) + the W6 ``WorkspaceBindingRegistry`` consulting ``KeybindingPreferences``. These prove the
/// wiring, not just the round-trip (which `SettingsKeyTests` covers).
@MainActor
final class PreferencesStoreApplyTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "PreferencesStoreApplyTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    override func tearDown() {
        // Restore the process-wide overlays the apply paths mutate so a later test isn't polluted.
        EnvConfig.overlay = [:]
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        AppearanceApplier.apply = nil
        AppearanceApplier.resolveTerminalColors = nil
        AppearanceApplier.resolveActiveThemeSlug = nil
        super.tearDown()
    }

    // MARK: Live env overlay

    func testVideoAndRawOverridesFoldIntoEnvConfigOverlay() {
        EnvConfig.overlay = [:]
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        // Empty prefs ⇒ empty overlay (behaviour-preserving — the golden corpus is unaffected).
        XCTAssertTrue(EnvConfig.overlay.isEmpty, "default prefs produce an empty overlay")

        store.video = VideoPreferences(qpSharp: 22, fecM: 2)
        XCTAssertEqual(EnvConfig.overlay["AISLOPDESK_QP_SHARP"], "22")
        XCTAssertEqual(EnvConfig.overlay["AISLOPDESK_FEC_M"], "2")

        // A raw override is folded LAST so it wins over a matching typed setting.
        store.rawOverrides = ["AISLOPDESK_QP_SHARP": "18", "AISLOPDESK_CUSTOM": "x"]
        XCTAssertEqual(EnvConfig.overlay["AISLOPDESK_QP_SHARP"], "18", "raw override wins over the typed pref")
        XCTAssertEqual(EnvConfig.overlay["AISLOPDESK_CUSTOM"], "x")
    }

    func testEnvConfigResolvesTheOverlayValueAfterApply() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.agent = AgentPreferences(agentDetect: true)
        // The agent gate is default-OFF (== "1"); an explicit ON writes "1" into the overlay, which
        // `EnvConfig` then resolves.
        XCTAssertEqual(EnvConfig.string("AISLOPDESK_AGENT_DETECT"), "1")
        XCTAssertTrue(EnvConfig.boolDefaultOff("AISLOPDESK_AGENT_DETECT"))
    }

    // MARK: Sidecar (video-prefs.json)

    func testVideoChangeWritesTheSidecar() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-prefs-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: tmp)
        store.video = VideoPreferences(fecM: 3, fecK: 6)

        let sidecar = EnvBridge.readSidecar(at: tmp)
        XCTAssertEqual(sidecar?.video.fecM, 3)
        XCTAssertEqual(sidecar?.video.fecK, 6)
        // Its env contribution matches the typed prefs.
        XCTAssertEqual(sidecar?.toEnv()["AISLOPDESK_FEC_M"], "3")
    }

    // MARK: Terminal broadcast

    func testTerminalChangeBumpsTheBroadcaster() {
        let before = TerminalConfigBroadcaster.shared.generation
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        // init published once (applyOnInit default ON).
        XCTAssertGreaterThan(TerminalConfigBroadcaster.shared.generation, before)
        let afterInit = TerminalConfigBroadcaster.shared.generation
        store.terminal = TerminalPreferences(fontFamily: "Menlo", fontSize: 16)
        XCTAssertGreaterThan(TerminalConfigBroadcaster.shared.generation, afterInit, "a change re-publishes")
        XCTAssertTrue(TerminalConfigBroadcaster.shared.configString.contains("font-family = Menlo"))
        XCTAssertTrue(TerminalConfigBroadcaster.shared.configString.contains("font-size = 16"))
    }

    /// E8 WI-2: `applyTerminal()` now resolves the fire-time Controls bundle and passes it to the builder,
    /// so the published config carries the control passthrough block — and `refreshTerminalControls()`
    /// re-publishes it live. Asserts the KEY's PRESENCE (value depends on `Defaults.standard`, the global
    /// toggle store), which is absent on the pre-WI-2 `controls: nil` build — revert-to-confirm-fail.
    func testTerminalBroadcastCarriesTheControlPassthrough() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        let afterInit = TerminalConfigBroadcaster.shared.generation
        store.refreshTerminalControls()
        XCTAssertGreaterThan(TerminalConfigBroadcaster.shared.generation, afterInit, "refresh re-publishes")
        let config = TerminalConfigBroadcaster.shared.configString
        XCTAssertTrue(config.contains("copy-on-select = "), "the Copy-on-Select control line is emitted via the store")
        XCTAssertTrue(config.contains("mouse-reporting = "), "the Allow-Mouse-Capture control line is emitted")
        XCTAssertTrue(config.contains("keybind = shift+left="), "the ⇧+arrow select keybind is emitted")
    }

    /// E15 item 8: the per-SCOPE (Light/Dark-theme) font override REACHES the live terminal. With Global
    /// (`terminal.fontFamily`) unset, the active slot's `appearance.themeFonts[slug]` resolves into the
    /// builder's primary `font-family` line. Pre-fix the override was persisted but the builder read the raw
    /// `terminal.fontFamily`, so the per-scope font never applied (revert-to-confirm-fail).
    func testPerScopeThemeFontReachesTheBuilderOutput() {
        // The GUI hook reports the active slot's resolved theme slug.
        AppearanceApplier.resolveActiveThemeSlug = { "dracula" }
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        // Global unset (so the per-theme override wins — otty "Global overrides theme" precedence) + a
        // per-theme font for the active slug.
        store.terminal.fontFamily = ""
        store.appearance.themeFonts = ["dracula": "Fira Code"]

        let config = TerminalConfigBroadcaster.shared.configString
        XCTAssertTrue(
            config.contains("font-family = Fira Code"),
            "the active scope's per-theme font reaches the live terminal config",
        )
    }

    /// With a non-empty Global `terminal.fontFamily`, the Global font WINS over the per-theme override
    /// (otty's "Global overrides theme; takes priority everywhere") — the resolved override equals the Global
    /// family, so the builder emits it.
    func testGlobalFontWinsOverPerScopeFont() {
        AppearanceApplier.resolveActiveThemeSlug = { "dracula" }
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.terminal.fontFamily = "JetBrains Mono"
        store.appearance.themeFonts = ["dracula": "Fira Code"]

        let config = TerminalConfigBroadcaster.shared.configString
        XCTAssertTrue(config.contains("font-family = JetBrains Mono"), "a set Global font overrides the per-theme one")
        XCTAssertFalse(config.contains("font-family = Fira Code"), "the per-theme font is suppressed by Global")
    }

    // MARK: Appearance (D2 — client chrome; NEVER touches the overlay/sidecar)

    /// A default ``AppearancePreferences`` + a default ``PreferencesStore`` leaves ``EnvConfig/overlay``
    /// empty — the GOLDEN CANARY. Appearance is pure client chrome; if it ever leaked into the overlay the
    /// 43-key corpus would shift on a fresh install.
    func testDefaultAppearanceLeavesOverlayEmpty() {
        EnvConfig.overlay = [:]
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        XCTAssertEqual(store.appearance, AppearancePreferences(), "default appearance is all-nil")
        XCTAssertTrue(EnvConfig.overlay.isEmpty, "default appearance must not write the env overlay")
    }

    func testAppearanceApplyRepointsThemeAndWritesDensityWithoutOverlayOrSidecar() {
        EnvConfig.overlay = [:]
        // Capture the WHOLE model the GUI-layer ThemeStore hook receives (E15 WI-3 widened the seam from a
        // bare `ThemeChoice?` to the full `AppearancePreferences`; the store can't import ClientUI).
        var appliedAppearance: AppearancePreferences?
        AppearanceApplier.apply = { appliedAppearance = $0 }

        let defaults = makeIsolatedDefaults()
        // A temp sidecar URL that must NOT be written by an appearance change.
        let sidecar = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-appearance-sidecar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let store = PreferencesStore(defaults: defaults, sidecarURL: sidecar)
        // init applies the default (all-nil) appearance once → hook fired with the default model.
        XCTAssertEqual(appliedAppearance, AppearancePreferences(), "init applies the default appearance")
        appliedAppearance = nil
        // init's applyVideoAndAgent already wrote the (default) sidecar; capture its bytes to prove an
        // appearance change does NOT re-touch it.
        let sidecarBefore = try? Data(contentsOf: sidecar)

        store.appearance = AppearancePreferences(theme: .dark, density: "compact")

        // 1) Repoints the theme (via the AppearanceApplier hook → ThemeStore.shared in the GUI layer) — the
        //    WHOLE model is handed over so the GUI resolves the dual-slot / custom-slug / follow-OS selection.
        XCTAssertEqual(
            appliedAppearance, AppearancePreferences(theme: .dark, density: "compact"),
            "appearance apply hands the GUI layer the whole model",
        )
        // 2) Persists under settings.appearance.v1.
        let blob = defaults.data(forKey: "settings.appearance.v1")
        XCTAssertNotNil(blob)
        let decoded = try? JSONDecoder().decode(AppearancePreferences.self, from: blob ?? Data())
        XCTAssertEqual(decoded, AppearancePreferences(theme: .dark, density: "compact"))
        // 3) Writes SettingsKey.density.
        XCTAssertEqual(defaults.string(forKey: SettingsKey.density), "compact")
        // 4) Does NOT mutate the env overlay …
        XCTAssertTrue(EnvConfig.overlay.isEmpty, "appearance must not touch EnvConfig.overlay")
        // 5) … and does NOT re-touch the sidecar (the only writer is the video/agent apply path; an
        //    appearance change leaves the sidecar bytes exactly as init left them).
        let sidecarAfter = try? Data(contentsOf: sidecar)
        XCTAssertEqual(sidecarAfter, sidecarBefore, "an appearance change must not rewrite the sidecar")
    }

    /// E15 WI-3 golden-safety: the NEW dual-slot / custom-slug / follow-OS / per-theme-font appearance fields
    /// are PURE client chrome — setting them must NOT mutate ``EnvConfig/overlay`` nor rewrite the sidecar (the
    /// frozen golden corpus would shift otherwise). The whole model still reaches the GUI hook for resolution.
    func testDualSlotAppearanceFieldsStayOutOfOverlayAndSidecar() {
        EnvConfig.overlay = [:]
        var appliedAppearance: AppearancePreferences?
        AppearanceApplier.apply = { appliedAppearance = $0 }

        let defaults = makeIsolatedDefaults()
        let sidecar = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-dualslot-sidecar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let store = PreferencesStore(defaults: defaults, sidecarURL: sidecar)
        let sidecarBefore = try? Data(contentsOf: sidecar)
        appliedAppearance = nil

        let dualSlot = AppearancePreferences(
            theme: .paper,
            themeDark: .dark,
            useSeparateDarkTheme: true,
            customLightSlug: "solarized-light",
            customDarkSlug: "dracula",
            themeFonts: ["dracula": "Fira Code"],
        )
        store.appearance = dualSlot

        // The whole dual-slot model reaches the GUI hook …
        XCTAssertEqual(appliedAppearance, dualSlot, "the whole dual-slot model reaches the GUI hook")
        // … it round-trips through UserDefaults …
        let blob = defaults.data(forKey: "settings.appearance.v1")
        XCTAssertEqual(try? JSONDecoder().decode(AppearancePreferences.self, from: blob ?? Data()), dualSlot)
        // … and NOTHING leaked into the overlay or the sidecar (the golden canary).
        XCTAssertTrue(EnvConfig.overlay.isEmpty, "dual-slot appearance must not touch EnvConfig.overlay")
        XCTAssertEqual(
            try? Data(contentsOf: sidecar), sidecarBefore,
            "dual-slot appearance must not rewrite the sidecar",
        )
    }

    func testResetAllResetsAppearance() {
        let defaults = makeIsolatedDefaults()
        let store = PreferencesStore(defaults: defaults, sidecarURL: nil)
        store.appearance = AppearancePreferences(theme: .dark, density: "compact")
        XCTAssertNotEqual(store.appearance, AppearancePreferences())
        store.resetAll()
        XCTAssertEqual(store.appearance, AppearancePreferences(), "resetAll restores the default appearance")
    }

    func testMalformedPersistedAppearanceDecodesToDefault() {
        let defaults = makeIsolatedDefaults()
        // Seed a malformed blob under the appearance key (unknown theme raw → whole-struct decode fails).
        defaults.set(Data(#"{"theme":"midnight"}"#.utf8), forKey: "settings.appearance.v1")
        let store = PreferencesStore(defaults: defaults, sidecarURL: nil)
        XCTAssertEqual(store.appearance, AppearancePreferences(), "a malformed blob decode-fails to default")
    }

    // MARK: Keybinding overrides → the W6 registry

    func testStorePublishesKeybindingOverridesToTheRegistry() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.keybindings = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true, shift: true),
        ])
        XCTAssertEqual(
            WorkspaceBindingRegistry.activeOverrides.chord(for: "pane.splitRight")?.canonical,
            "shift+cmd+e",
        )
    }

    func testRegistryResolvesOverrideElseDefault() {
        // Default: split-right is ⌘D.
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChord(for: .splitRight, overrides: KeybindingPreferences()),
            KeyChord(character: "d", [.command]),
        )
        // With an override, the resolved chord is the override (⌘E here), NOT the default.
        let overrides = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true),
        ])
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChord(for: .splitRight, overrides: overrides),
            KeyChord(character: "e", [.command]),
        )
        // An unrelated action is unaffected by the override.
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChord(for: .closePane, overrides: overrides),
            KeyChord(character: "w", [.command]),
        )
    }

    func testResolvedChordTableRoutesTheOverrideChord() {
        let overrides = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true),
        ])
        let table = WorkspaceBindingRegistry.resolvedChordTable(overrides: overrides)
        // The NEW chord routes to splitRight; the OLD default chord no longer does (it's now free).
        XCTAssertEqual(table[KeyChord(character: "e", [.command])], .splitRight)
        XCTAssertNil(table[KeyChord(character: "d", [.command])], "the old default chord is freed by the override")
    }

    func testMalformedOverrideFallsBackToTheDefault() {
        // An override whose key can't map to a registry chord (empty / multi-char) is IGNORED →
        // the registry default stands (validate-then-default, never traps).
        let overrides = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "", command: true), // empty key → unmappable
        ])
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChord(for: .splitRight, overrides: overrides),
            KeyChord(character: "d", [.command]), "an unmappable override falls back to the default",
        )
    }

    func testNamedKeyOverrideMapsToTheRegistryKey() {
        // A named-key override (e.g. rebinding focus-left to ⌘⇧↩) maps to the registry's Key case.
        let chord = KeybindingPreferences.KeyChord(key: "return", command: true, shift: true)
        XCTAssertEqual(chord.asRegistryChord, KeyChord(.return, [.command, .shift]))
        let left = KeybindingPreferences.KeyChord(key: "left", command: true, option: true)
        XCTAssertEqual(left.asRegistryChord, KeyChord(.leftArrow, [.option, .command]))
    }
}
