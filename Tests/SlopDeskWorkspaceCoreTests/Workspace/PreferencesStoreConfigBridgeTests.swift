import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// E20 config review fix — the PURE ``PreferencesStore`` render-config bridge the `slopdesk config
/// get/set/unset/show` CLI drives. These pin that a `set` mutates the LIVE typed model (reflowing the
/// terminal — proven by the ``TerminalConfigBroadcaster`` generation bump), a `get` reflects the live
/// value (round-tripping the set), and an unknown key / unparseable value is honestly REJECTED (`false`),
/// not a silent success. Headless: an isolated `UserDefaults`, no sidecar, no GUI / ThemeStore (theme is
/// the backend's job — see `WorkspaceControlBackendConfigTests`).
@MainActor
final class PreferencesStoreConfigBridgeTests: XCTestCase {
    private func makeStore(_ name: String = #function) -> PreferencesStore {
        let suite = "PreferencesStoreConfigBridgeTests." + name
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
    }

    override func tearDown() {
        AppearanceApplier.apply = nil
        AppearanceApplier.resolveTerminalColors = nil
        AppearanceApplier.resolveActiveThemeSlug = nil
        super.tearDown()
    }

    // MARK: - set drives the live model AND reflows the terminal

    func testSetFontSizeMutatesModelAndReflows() {
        let store = makeStore()
        let before = TerminalConfigBroadcaster.shared.generation

        XCTAssertTrue(store.setRenderConfig("14", forKey: "font-size"))
        XCTAssertEqual(store.terminal.fontSize, 14, "the live model is mutated, not a dead namespace")
        XCTAssertGreaterThan(
            TerminalConfigBroadcaster.shared.generation, before,
            "a font-size set rebuilds + republishes the terminal config (live reflow)",
        )
        // Round-trips as an integral string (no trailing .0).
        XCTAssertEqual(store.renderConfigValue(forKey: "font-size"), "14")
    }

    func testFontSizeKeepsARealFraction() {
        let store = makeStore()
        XCTAssertTrue(store.setRenderConfig("13.5", forKey: "font-size"))
        XCTAssertEqual(store.renderConfigValue(forKey: "font-size"), "13.5")
    }

    func testSetFontFamilyTrimsAndReflows() {
        let store = makeStore()
        XCTAssertTrue(store.setRenderConfig("  JetBrains Mono  ", forKey: "font-family"))
        XCTAssertEqual(store.terminal.fontFamily, "JetBrains Mono")
        XCTAssertEqual(store.renderConfigValue(forKey: "font-family"), "JetBrains Mono")
    }

    func testSetCursorStyleAndBlink() {
        let store = makeStore()
        XCTAssertTrue(store.setRenderConfig("bar", forKey: "cursor-style"))
        XCTAssertEqual(store.terminal.cursorStyle, .bar)
        XCTAssertEqual(store.renderConfigValue(forKey: "cursor-style"), "bar")

        XCTAssertTrue(store.setRenderConfig("on", forKey: "cursor-style-blink"))
        XCTAssertEqual(store.terminal.cursorBlink, .on)
        XCTAssertEqual(store.renderConfigValue(forKey: "cursor-style-blink"), "on")
    }

    func testSetScrollbackAndDensity() {
        let store = makeStore()
        XCTAssertTrue(store.setRenderConfig("5000", forKey: "scrollback-limit"))
        XCTAssertEqual(store.terminal.scrollbackLines, 5000)
        XCTAssertEqual(store.renderConfigValue(forKey: "scrollback-limit"), "5000")

        XCTAssertTrue(store.setRenderConfig("Compact", forKey: SettingsKey.density))
        XCTAssertEqual(store.appearance.density, "Compact")
        XCTAssertEqual(store.renderConfigValue(forKey: SettingsKey.density), "Compact")
    }

    // MARK: - honest rejection (never a lying success)

    func testUnknownKeyIsRejected() {
        let store = makeStore()
        XCTAssertFalse(store.setRenderConfig("x", forKey: "no.such.key"))
        XCTAssertNil(store.renderConfigValue(forKey: "no.such.key"))
    }

    func testUnparseableValuesAreRejected() {
        let store = makeStore()
        XCTAssertFalse(store.setRenderConfig("abc", forKey: "font-size"), "non-numeric font size")
        XCTAssertFalse(store.setRenderConfig("0", forKey: "font-size"), "non-positive font size")
        XCTAssertFalse(store.setRenderConfig("-3", forKey: "scrollback-limit"), "negative scrollback")
        XCTAssertFalse(store.setRenderConfig("triangle", forKey: "cursor-style"), "unknown cursor style")
        XCTAssertFalse(store.setRenderConfig("maybe", forKey: "cursor-style-blink"), "unknown blink mode")
        XCTAssertFalse(store.setRenderConfig("   ", forKey: "font-family"), "blank font family")
        // The model is untouched by a rejected set.
        XCTAssertEqual(store.terminal.fontSize, TerminalPreferences().fontSize)
        XCTAssertEqual(store.terminal.scrollbackLines, TerminalPreferences().scrollbackLines)
    }

    // MARK: - unset resets to the model default

    func testUnsetResetsToDefault() {
        let store = makeStore()
        XCTAssertTrue(store.setRenderConfig("22", forKey: "font-size"))
        XCTAssertTrue(store.unsetRenderConfig(forKey: "font-size"))
        XCTAssertEqual(store.terminal.fontSize, TerminalPreferences().fontSize)

        XCTAssertTrue(store.setRenderConfig("Compact", forKey: SettingsKey.density))
        XCTAssertTrue(store.unsetRenderConfig(forKey: SettingsKey.density))
        XCTAssertNil(store.appearance.density)

        XCTAssertFalse(store.unsetRenderConfig(forKey: "no.such.key"))
    }

    // MARK: - reload re-applies without mutating the model

    func testReapplyLiveSettingsRepublishesWithoutMutating() {
        let store = makeStore()
        store.terminal.fontFamily = "Menlo"
        let snapshot = store.terminal
        let before = TerminalConfigBroadcaster.shared.generation

        store.reapplyLiveSettings()
        XCTAssertGreaterThan(TerminalConfigBroadcaster.shared.generation, before, "reload republishes")
        XCTAssertEqual(store.terminal, snapshot, "reload re-applies; it does not mutate the model")
    }
}
