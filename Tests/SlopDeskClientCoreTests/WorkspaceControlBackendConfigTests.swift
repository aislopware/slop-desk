// WorkspaceControlBackendConfigTests — pins the E20 `config get/set/unset/show/reload` path on the REAL
// `WorkspaceControlBackend` (not the dispatcher's FAKE backend). The pre-fix backend wrote
// `EnvConfig.overlay[key]` plus a dead `slopdesk.cli.config.*` UserDefaults namespace and ALWAYS
// returned `true`, so a `config set` reported success while the GUI never changed and `config get`
// returned the catalog default rather than the live value. Each assertion below fails on that pre-fix
// backend (the live model never changes / the unknown key lyingly succeeds), so none is tautological.
//
// Hang-safe (CLAUDE.md rule #6): a tree-model store over the `MountTestPaneSession` fake, an isolated
// `PreferencesStore` and a temp-file `FolderFrecencyStore` — no socket, no window, no
// video/SCStream/Metal.
//
// NOTE: `WorkspaceControlBackend` holds its store / preferences / folders WEAKLY (the app owns them), so
// every test keeps all three in locals for the backend's lifetime.

import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientCore
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
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
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
        XCTAssertTrue(h.backend.configSet(key: "font-size", value: "15", transient: false))

        let shown = h.backend.configShow()
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
        // A key with no live binding is likewise rejected under `--transient`.
        XCTAssertFalse(h.backend.configSet(key: "totally.made.up", value: "x", transient: true))
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
