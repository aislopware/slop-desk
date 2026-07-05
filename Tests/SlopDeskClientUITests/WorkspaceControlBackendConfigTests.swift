// WorkspaceControlBackendConfigTests — pins the E20 `config get/set/unset/show/reload` path on the REAL
// `WorkspaceControlBackend` (not the dispatcher's FAKE backend). The pre-fix backend wrote
// `EnvConfig.overlay[key]` plus a dead `slopdesk.cli.config.*` UserDefaults namespace and ALWAYS
// returned `true`, so `config set theme <X>` reported success while the GUI never retinted, and
// `config get theme` returned the catalog default ("System"), not the live theme. Each assertion below
// fails on that pre-fix backend (the theme never changes / the unknown key lyingly succeeds), so none is
// tautological.
//
// Hang-safe (CLAUDE.md rule #6): a tree-model store over the `MountTestPaneSession` fake, an isolated
// `PreferencesStore`, a temp-file `FolderFrecencyStore`, and the GUI apply hook wired exactly as the app
// does at launch (so a model change retints `ThemeStore`) — no socket, no window, no video/SCStream/Metal.
//
// NOTE: `WorkspaceControlBackend` holds its store / preferences / folders WEAKLY (the app owns them), so
// every test keeps all three in locals for the backend's lifetime.

import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class WorkspaceControlBackendConfigTests: XCTestCase {
    /// A backend plus the three dependencies it holds weakly — the caller binds the whole tuple so they
    /// outlive the backend.
    private struct Harness {
        let backend: WorkspaceControlBackend
        let store: WorkspaceStore
        let preferences: PreferencesStore
        let folders: FolderFrecencyStore
    }

    private func makeHarness(_ name: String) -> Harness {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        let suite = "WorkspaceControlBackendConfigTests." + name
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        let folders = FolderFrecencyStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("frecency-\(UUID().uuidString).json"),
        )
        let backend = WorkspaceControlBackend(store: store, preferences: preferences, folders: folders)
        return Harness(backend: backend, store: store, preferences: preferences, folders: folders)
    }

    override func setUp() {
        super.setUp()
        // Wire the GUI apply hook exactly as `SlopDeskClientUI` does at launch, so mutating the live
        // `PreferencesStore.appearance` retints the shared `ThemeStore` — the mechanism `config set theme`
        // relies on to drive the running app.
        AppearanceApplier.apply = { ThemeStore.shared.apply(appearance: $0) }
        // Deterministic OS-appearance probe (no NSApp in a test). Dark ⇒ the unset/default slot resolves to
        // Monokai Pro Classic — the product default the finding expects `config get theme` to report.
        ThemeStore.shared.osIsDark = { true }
        ThemeStore.shared.apply(appearance: AppearancePreferences()) // reset to the default theme
    }

    override func tearDown() {
        AppearanceApplier.apply = nil
        AppearanceApplier.resolveTerminalColors = nil
        AppearanceApplier.resolveActiveThemeSlug = nil
        ThemeStore.shared.osIsDark = { ThemeStore.systemIsDark() }
        ThemeStore.shared.apply(appearance: AppearancePreferences()) // leave the singleton at its default
        super.tearDown()
    }

    // MARK: - config set theme drives the running app (the headline fix)

    func testConfigSetThemeChangesActiveTheme() {
        let h = makeHarness(#function)

        // Default live theme = Monokai Pro Classic, NOT the catalog default "System".
        XCTAssertEqual(h.backend.configGet(key: "theme"), "monokai-classic")
        XCTAssertEqual(ThemeStore.shared.active.id, "monokai-classic")

        // A built-in id (as listed by `theme list`) switches the ACTIVE theme + round-trips via `config get`.
        XCTAssertTrue(h.backend.configSet(key: "theme", value: "paper", transient: false))
        XCTAssertEqual(ThemeStore.shared.active.id, "paper", "config set theme retints the running app")
        XCTAssertEqual(h.backend.configGet(key: "theme"), "paper", "config get theme reflects the live theme")
        XCTAssertEqual(h.preferences.appearance.theme, .paper, "the selection is persisted to the typed model")

        XCTAssertTrue(h.backend.configSet(key: "theme", value: "dark", transient: false))
        XCTAssertEqual(ThemeStore.shared.active.id, "dark")
    }

    func testConfigSetThemeAcceptsAChoiceRawValueAndRejectsUnknown() {
        let h = makeHarness(#function)
        // The ThemeChoice raw value also resolves (e.g. an explicit Monokai filter by its raw name).
        XCTAssertTrue(h.backend.configSet(key: "theme", value: "monokaiProOctagon", transient: false))
        XCTAssertEqual(ThemeStore.shared.active.id, "monokai-octagon")

        // An unknown theme name is an HONEST error (false), not a silent success, and leaves the theme put.
        XCTAssertFalse(h.backend.configSet(key: "theme", value: "Dracula", transient: false))
        XCTAssertEqual(ThemeStore.shared.active.id, "monokai-octagon", "a rejected theme set does not change it")
    }

    func testConfigUnsetThemeRestoresDefault() {
        let h = makeHarness(#function)
        XCTAssertTrue(h.backend.configSet(key: "theme", value: "paper", transient: false))
        XCTAssertEqual(ThemeStore.shared.active.id, "paper")

        XCTAssertTrue(h.backend.configUnset(key: "theme", transient: false))
        XCTAssertEqual(ThemeStore.shared.active.id, "monokai-classic", "unset restores the default theme")
    }

    // MARK: - render keys + honest rejection of non-live keys

    func testConfigSetGetFontSizeRoundTrips() {
        let h = makeHarness(#function)
        XCTAssertTrue(h.backend.configSet(key: "font-size", value: "16", transient: false))
        XCTAssertEqual(h.preferences.terminal.fontSize, 16, "the live terminal model is mutated")
        XCTAssertEqual(h.backend.configGet(key: "font-size"), "16")
    }

    func testConfigSetUnknownKeyIsHonestlyRejected() {
        let h = makeHarness(#function)
        // No live binding ⇒ false (the dispatcher turns this into `config set rejected`), NOT a lying ok.
        XCTAssertFalse(h.backend.configSet(key: "totally.made.up", value: "x", transient: false))
        XCTAssertFalse(h.backend.configSet(key: "font-size", value: "not-a-number", transient: false))
    }

    func testConfigShowReportsLiveValues() {
        let h = makeHarness(#function)
        XCTAssertTrue(h.backend.configSet(key: "theme", value: "dark", transient: false))
        XCTAssertTrue(h.backend.configSet(key: "font-size", value: "15", transient: false))

        let shown = h.backend.configShow()
        XCTAssertEqual(shown.first { $0.key == "theme" }?.value, "dark", "config show reflects the live theme")
        XCTAssertEqual(shown.first { $0.key == "font-size" }?.value, "15", "config show reflects the live size")
    }

    // MARK: - --transient is honestly rejected (never silently persists)

    /// The pre-fix backend IGNORED `transient` and wrote the typed model identically to a persisted set,
    /// returning `true` while the dispatcher echoed `transient:true` — a lie (the "try it without saving"
    /// value was permanently changed). slopdesk has no apply-without-persist render layer (the model the
    /// renderer reads IS the one that persists), so a transient set is now an honest reject (`false`) AND
    /// must NOT mutate the live value. Revert-to-confirm-fail: on the pre-fix backend the first assertion
    /// returns `true` and the second observes a mutated `fontSize`.
    func testConfigSetTransientIsRejectedAndDoesNotApply() {
        let h = makeHarness(#function)
        let before = h.preferences.terminal.fontSize
        XCTAssertFalse(
            h.backend.configSet(key: "font-size", value: "22", transient: true),
            "--transient is honestly rejected, not silently persisted",
        )
        XCTAssertEqual(
            h.preferences.terminal.fontSize,
            before,
            "a rejected transient set must NOT mutate the live value",
        )
        // A transient theme set is likewise rejected and leaves the theme put.
        let theme = ThemeStore.shared.active.id
        XCTAssertFalse(h.backend.configSet(key: "theme", value: "paper", transient: true))
        XCTAssertEqual(ThemeStore.shared.active.id, theme)
    }

    func testConfigUnsetTransientIsRejected() {
        let h = makeHarness(#function)
        XCTAssertTrue(h.backend.configSet(key: "font-size", value: "18", transient: false))
        XCTAssertFalse(h.backend.configUnset(key: "font-size", transient: true), "--transient unset is rejected")
        XCTAssertEqual(h.preferences.terminal.fontSize, 18, "a rejected transient unset leaves the value put")
    }

    // MARK: - `font apply "<name>"` routes through the config-set font-family path

    /// `slopdesk font apply "<name>"` is documented to write the font family. The CLI routes it through the
    /// SAME running-app config path as `config set font-family` (no separate font-apply backend method), so
    /// this pins that the route mutates the live terminal font family + round-trips via `config get`.
    func testFontApplyRoutesToFontFamilyConfig() {
        let h = makeHarness(#function)
        XCTAssertTrue(
            h.backend.configSet(key: "font-family", value: "Menlo", transient: false),
            "font apply routes to the config-set font-family path",
        )
        XCTAssertEqual(h.preferences.terminal.fontFamily, "Menlo", "the live terminal font family is set")
        XCTAssertEqual(h.backend.configGet(key: "font-family"), "Menlo", "config get reflects the applied font")
    }
}
