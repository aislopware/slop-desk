import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskWorkspaceCore

/// E1 WI-3 — the BEHAVIORAL dispatch of the active-pane font-size + viewport-scroll store hooks
/// (``WorkspaceStore/increaseFontInActivePane()`` / `decreaseFontInActivePane` / `resetFontInActivePane` /
/// ``WorkspaceStore/scrollActivePane(_:)``), observed on a ``RecordingTerminalPaneSession`` that carries a
/// REAL ``TerminalViewModel`` whose `surface` is a recording ``TerminalSurfaceActions``.
///
/// The SCROLL hooks pin the EXACT libghostty named binding action (`scroll_page_fractional:-0.9`,
/// `scroll_to_top`, …) — a swapped page sign would fail here. The FONT hooks (E15 item 9) no longer touch the
/// surface: they route ⌘±/⌘0 through the ``WorkspaceStore/onFontSizeStep`` seam to the single source of truth
/// (`PreferencesStore.terminal.fontSize`, the Settings "Size" stepper's value), so they are pinned on the
/// seam + the persisted size. They drive the store methods DIRECTLY (the registry routing is pinned elsewhere).
///
/// HANG-SAFE: the recording session uses a headless ``RecordingSurfaceActions`` (no `GhosttySurface` /
/// VideoToolbox / Metal / SCStream) — the hang-safety rule holds.
@MainActor
final class FontScrollHookTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store backed by the recording (terminal-model-carrying) session seam.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The active pane's recording session.
    private func activeSession(_ store: WorkspaceStore) throws -> RecordingTerminalPaneSession {
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        return try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
    }

    /// The recording surface backing the active pane's terminal model.
    private func activeRecorder(_ store: WorkspaceStore) throws -> RecordingSurfaceActions {
        try XCTUnwrap(activeSession(store).surfaceRecorder)
    }

    // MARK: - Font size (ES-E1-4 / E15 item 9 — single source of truth)

    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "FontScrollHookTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// The three font hooks route ⌘=/⌘-/⌘0 through the ``WorkspaceStore/onFontSizeStep`` seam, in call order —
    /// NOT libghostty's internal `increase_font_size` (which the Settings stepper can't see → the desync this
    /// fixes). The surface receives NO font action now: the font size is driven by the single source of truth
    /// (`PreferencesStore.terminal.fontSize`) instead. Revert-to-confirm-fail vs the old surface-action path.
    func testFontHooksRouteThroughTheFontSizeSeamInOrder() throws {
        let store = makeStore()
        let recorder = try activeRecorder(store)
        var steps: [FontSizeStep] = []
        store.onFontSizeStep = { steps.append($0) }

        store.increaseFontInActivePane()
        store.decreaseFontInActivePane()
        store.resetFontInActivePane()

        XCTAssertEqual(steps, [.increase, .decrease, .reset], "font hooks route the zoom intents in order")
        XCTAssertTrue(recorder.actions.isEmpty, "font zoom no longer drives libghostty's internal font size")
    }

    /// THE item-9 regression test: a ⌘±/⌘0 zoom UPDATES the persisted Settings font size (the single source of
    /// truth the "Size" stepper binds), so the two never desync. Wires the seam to a live ``PreferencesStore``
    /// exactly as the app shell does. ⌘+ bumps +1, ⌘- back, ⌘0 resets to the default size.
    func testFontZoomUpdatesPreferencesFontSizeSingleSourceOfTruth() {
        let store = makeStore()
        let prefs = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        store.onFontSizeStep = { step in
            switch step {
            case .increase: prefs.increaseFontSize()
            case .decrease: prefs.decreaseFontSize()
            case .reset: prefs.resetFontSize()
            }
        }
        let base = prefs.terminal.fontSize

        store.increaseFontInActivePane()
        XCTAssertEqual(prefs.terminal.fontSize, base + 1, "⌘+ bumps the persisted Settings font size")
        store.decreaseFontInActivePane()
        XCTAssertEqual(prefs.terminal.fontSize, base, "⌘- steps it back — stepper stays in sync")

        prefs.terminal.fontSize = 20
        store.resetFontInActivePane()
        XCTAssertEqual(prefs.terminal.fontSize, TerminalPreferences().fontSize, "⌘0 resets to the default size")
    }

    // MARK: - Viewport scroll (ES-E1-3)

    /// Each ``ScrollAction`` fires its mapped action string — pins the page up/down SIGN (negative = up
    /// toward older scrollback) and the top/bottom buffer-end actions. A swapped page sign fails here.
    func testScrollHooksFireMappedActionsWithCorrectPageSign() throws {
        let store = makeStore()
        let recorder = try activeRecorder(store)

        store.scrollActivePane(.pageUp)
        store.scrollActivePane(.pageDown)
        store.scrollActivePane(.top)
        store.scrollActivePane(.bottom)

        XCTAssertEqual(
            recorder.actions,
            [
                "scroll_page_fractional:-0.9", // pageUp = negative = older
                "scroll_page_fractional:0.9", // pageDown = positive = newer
                "scroll_to_top",
                "scroll_to_bottom",
            ],
            "scroll hooks map to the page-fractional (≈ a page) + buffer-end actions with the up=negative sign",
        )
    }

    /// The ``ScrollAction/libghosttyAction`` mapping is the single source of truth — pin it independently of
    /// the store so a refactor of the store hook can't silently re-map the intent.
    func testScrollActionMappingIsStable() {
        XCTAssertEqual(ScrollAction.pageUp.libghosttyAction, "scroll_page_fractional:-0.9")
        XCTAssertEqual(ScrollAction.pageDown.libghosttyAction, "scroll_page_fractional:0.9")
        XCTAssertEqual(ScrollAction.top.libghosttyAction, "scroll_to_top")
        XCTAssertEqual(ScrollAction.bottom.libghosttyAction, "scroll_to_bottom")
    }

    // MARK: - Graceful no-op (non-terminal active pane)

    /// A non-terminal active pane (`.remoteGUI`) has no terminal model / no seam, so every font + scroll hook
    /// is a clean no-op — nothing is recorded and nothing traps. Mirrors the block hooks' graceful
    /// degradation; this is what makes the hooks safe to bind unconditionally.
    func testFontScrollAreNoOpOnNonTerminalActivePane() throws {
        let store = makeStore()
        // Replace the active leaf's session with a non-terminal one by splitting in a `.remoteGUI` pane and
        // focusing it; the recorder of the ORIGINAL terminal pane must stay empty after we act on the GUI pane.
        store.splitActivePane(axis: .horizontal, kind: .remoteGUI)
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let guiSession = try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
        XCTAssertNil(guiSession.terminalModel, "the active pane is non-terminal (no model)")
        var fontSteps = 0
        store.onFontSizeStep = { _ in fontSteps += 1 }

        // None of these trap or touch a (non-existent) seam.
        store.increaseFontInActivePane()
        store.decreaseFontInActivePane()
        store.resetFontInActivePane()
        store.scrollActivePane(.pageUp)
        store.scrollActivePane(.pageDown)
        store.scrollActivePane(.top)
        store.scrollActivePane(.bottom)

        XCTAssertEqual(fontSteps, 0, "⌘± is a no-op off-terminal — the font-size seam never fires")
        XCTAssertNil(guiSession.surfaceRecorder, "a non-terminal pane has no recording surface to fire into")
    }
}
