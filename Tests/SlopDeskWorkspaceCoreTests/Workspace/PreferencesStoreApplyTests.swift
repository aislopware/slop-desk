import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// The ``PreferencesStore`` APPLY paths (live env overlay, sidecar, terminal broadcast, keybinding
/// overrides) + the ``WorkspaceBindingRegistry`` consulting ``KeybindingPreferences``.
///
/// Every case drives the store the way the app does: by handing it a resolved ``AppConfig``. The
/// store has no setters any more — a setting is the FILE's, and the store's whole job is turning one
/// reading into an effect — so a case that used to write `store.video = …` states the same thing as
/// `config.setting("video.qp-sharp", 22)` and re-reads.
@MainActor
final class PreferencesStoreApplyTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "PreferencesStoreApplyTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// A store over `config`, with the two process-wide side effects isolated: an isolated defaults
    /// suite and (unless a case asks for one) NO sidecar.
    private func makeStore(
        _ config: AppConfig = .compiledDefaults,
        sidecar: URL? = nil,
        applyOnInit: Bool = true,
        _ name: String = #function,
    ) -> PreferencesStore {
        PreferencesStore(
            defaults: makeIsolatedDefaults(name),
            sidecarURL: sidecar,
            applyOnInit: applyOnInit,
            config: config,
        )
    }

    override func tearDown() {
        // Restore the process-wide overlays the apply paths mutate so a later test isn't polluted.
        // The nonisolated XCTestCase override runs on the main thread — enter the actor for the state it touches.
        MainActor.assumeIsolated {
            EnvConfig.overlay = [:]
            WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
            AppearanceApplier.resolveTerminalColors = nil
        }
        super.tearDown()
    }

    // MARK: Live env overlay

    /// The GOLDEN CANARY: an untouched install resolves every video and agent key to ABSENT, so the
    /// overlay is empty and the 43-key corpus does not move. This is why those rows are declared
    /// without a default rather than with today's number written in.
    func testDefaultConfigLeavesTheOverlayEmpty() {
        EnvConfig.overlay = [:]
        _ = makeStore()
        XCTAssertTrue(EnvConfig.overlay.isEmpty, "a config file nobody wrote produces no overlay at all")
    }

    func testVideoKeysAndTheEnvTableFoldIntoEnvConfigOverlay() {
        EnvConfig.overlay = [:]
        _ = makeStore(
            AppConfig.compiledDefaults
                .setting("video.qp-sharp", 22)
                .setting("video.fec-m", 2),
        )
        XCTAssertEqual(EnvConfig.overlay["SLOPDESK_QP_SHARP"], "22")
        XCTAssertEqual(EnvConfig.overlay["SLOPDESK_FEC_M"], "2")
    }

    /// The `[env]` table folds LAST, so a hand-written `SLOPDESK_*` line beats the typed key that maps
    /// to the same variable — and carries a variable no typed key names at all.
    func testTheEnvTableWinsOverTheTypedKey() {
        EnvConfig.overlay = [:]
        _ = makeStore(
            AppConfig.compiledDefaults
                .setting("video.qp-sharp", 22)
                .withEnv(["SLOPDESK_QP_SHARP": "18", "SLOPDESK_CUSTOM": "x"]),
        )
        XCTAssertEqual(EnvConfig.overlay["SLOPDESK_QP_SHARP"], "18", "[env] wins over the typed key")
        XCTAssertEqual(EnvConfig.overlay["SLOPDESK_CUSTOM"], "x")
    }

    func testEnvConfigResolvesTheOverlayValueAfterApply() {
        _ = makeStore(AppConfig.compiledDefaults.setting("agent.prevent-sleep", true))
        // The prevent-sleep gate is default-OFF (== "1"); an explicit ON writes "1" into the overlay,
        // which `EnvConfig` then resolves.
        XCTAssertEqual(EnvConfig.string("SLOPDESK_AGENT_PREVENT_SLEEP"), "1")
        XCTAssertTrue(EnvConfig.boolDefaultOff("SLOPDESK_AGENT_PREVENT_SLEEP"))
    }

    // MARK: Sidecar (video-prefs.json)

    private func temporarySidecar() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-prefs-test-\(UUID().uuidString).json")
    }

    func testVideoKeysReachTheSidecar() {
        let tmp = temporarySidecar()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = makeStore(
            AppConfig.compiledDefaults.setting("video.fec-m", 3).setting("video.fec-k", 6),
            sidecar: tmp,
        )
        let sidecar = EnvBridge.readSidecar(at: tmp)
        XCTAssertEqual(sidecar?.video.fecM, 3)
        XCTAssertEqual(sidecar?.video.fecK, 6)
        // Its env contribution matches the typed keys.
        XCTAssertEqual(sidecar?.toEnv()["SLOPDESK_FEC_M"], "3")
    }

    /// The `[env]` table is serialised into the sidecar the HOST daemon reads — not only the client's
    /// in-process overlay — so a host-only knob actually reaches the daemon.
    func testTheEnvTableReachesTheSidecar() {
        let tmp = temporarySidecar()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = makeStore(
            AppConfig.compiledDefaults
                .setting("video.fec-m", 2)
                .withEnv(["SLOPDESK_FEC_M": "4", "SLOPDESK_HOST_ONLY": "z"]),
            sidecar: tmp,
        )
        let sidecar = EnvBridge.readSidecar(at: tmp)
        XCTAssertEqual(sidecar?.rawOverrides, ["SLOPDESK_FEC_M": "4", "SLOPDESK_HOST_ONLY": "z"])
        // Last-wins: the `[env]` line beats the typed key for the shared variable in the sidecar's overlay.
        XCTAssertEqual(sidecar?.toEnv()["SLOPDESK_FEC_M"], "4")
        XCTAssertEqual(sidecar?.toEnv()["SLOPDESK_HOST_ONLY"], "z")
    }

    // MARK: Terminal broadcast

    func testTerminalKeysReachTheBroadcaster() {
        let before = TerminalConfigBroadcaster.shared.generation
        _ = makeStore(
            AppConfig.compiledDefaults
                .setting("terminal.font-family", "Menlo")
                .setting("terminal.font-size", 16.0),
        )
        XCTAssertGreaterThan(TerminalConfigBroadcaster.shared.generation, before, "init publishes once")
        XCTAssertEqual(TerminalConfigBroadcaster.shared.fontFamily, "Menlo")
        XCTAssertEqual(TerminalConfigBroadcaster.shared.fontSize, 16)
    }

    /// ⌘± moves the LIVE size without touching the file — the one ephemeral thing the store holds.
    /// ⌘0 puts it back, and the file's own answer is what it goes back TO.
    func testFontSizeZoomIsEphemeralAndReturnsToTheFilesAnswer() {
        let store = makeStore(AppConfig.compiledDefaults.setting("terminal.font-size", 14.0))
        XCTAssertEqual(store.effectiveFontSize, 14)
        store.increaseFontSize()
        XCTAssertEqual(store.effectiveFontSize, 15)
        XCTAssertEqual(TerminalConfigBroadcaster.shared.fontSize, 15)
        store.resetFontSize()
        XCTAssertEqual(store.effectiveFontSize, 14, "⌘0 returns to the size the config file states")
        XCTAssertEqual(store.fontSizeDelta, 0)
    }

    /// `applyTerminal()` publishes every value it had to RESOLVE, and `refreshTerminalControls()`
    /// re-publishes them live. The plain toggles are NOT here on purpose — a toggle resolves to
    /// itself, so it is read at the point of use through `SettingsKey` rather than carried.
    ///
    /// Asserts a non-factory reading arrives, which is what a dropped read would lose —
    /// revert-to-confirm-fail.
    func testTerminalBroadcastCarriesEveryResolvedValue() {
        let store = makeStore(
            AppConfig.compiledDefaults
                .setting("terminal.scrollback-limit", 4321)
                .setting("terminal.cursor-style", "bar")
                .setting("terminal.cursor-color", "FF0000")
                .setting("terminal.cursor-opacity", 0.5),
        )
        let afterInit = TerminalConfigBroadcaster.shared.generation
        store.refreshTerminalControls()
        XCTAssertGreaterThan(TerminalConfigBroadcaster.shared.generation, afterInit, "refresh re-publishes")
        XCTAssertEqual(TerminalConfigBroadcaster.shared.scrollbackLines, 4321)
        XCTAssertEqual(TerminalConfigBroadcaster.shared.cursorStyle, 1, "bar is the door's 1")
        XCTAssertEqual(TerminalConfigBroadcaster.shared.cursorColor, 0xFF0000)
        XCTAssertEqual(TerminalConfigBroadcaster.shared.cursorOpacity, 0.5)
    }

    /// With NO app palette installed — headless, pre-launch, the golden and `ImageRenderer` paths —
    /// the two colours the config file states are what the cells wear. The seam's doc has promised
    /// this all along; nothing was reading the file for it, so `nil` went to the door and the surface
    /// kept the ENGINE's defaults, ignoring both the theme and the file.
    ///
    /// The palette stays EMPTY (the file names no ANSI ladder) and the selection is the per-channel
    /// midpoint — which is also the assertion that catches the precedence trap in `midpoint`, where
    /// Swift's `<<` outranks `/` and a missing pair of parentheses divides red by 131 072.
    func testWithNoAppPaletteTheFilesOwnTwoColoursReachTheBroadcaster() {
        AppearanceApplier.resolveTerminalColors = nil
        _ = makeStore(
            AppConfig.compiledDefaults
                .setting("terminal.background", "202030")
                .setting("terminal.foreground", "E0E0F0"),
        )
        let theme = TerminalConfigBroadcaster.shared.themeWords
        XCTAssertEqual(theme?.background, 0x0020_2030)
        XCTAssertEqual(theme?.foreground, 0x00E0_E0F0)
        XCTAssertEqual(theme?.palette, [], "the file names no ANSI ladder, so all sixteen stay engine-side")
        XCTAssertEqual(theme?.selection, 0x0080_8090, "the per-channel midpoint, every channel halved")
    }

    // MARK: Keybinding overrides → the registry

    /// The `[keybind]` table folds into the registry overrides at init — a named action resolved
    /// through the registry, not a chord string the store keeps.
    func testTheKeybindTableReachesTheRegistry() {
        _ = makeStore(AppConfig.compiledDefaults.withKeybinds(["shift+cmd+e": "split_right"]))
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
