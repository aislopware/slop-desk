import SlopDeskVideoProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The BEHAVIORAL dispatch of the active-pane font-size + viewport-scroll store hooks
/// (``WorkspaceStore/increaseFontInActivePane()`` / `decreaseFontInActivePane` / `resetFontInActivePane` /
/// ``WorkspaceStore/scrollActivePane(_:)``), observed on a ``RecordingTerminalPaneSession`` that carries a
/// REAL ``TerminalViewModel`` whose `surface` is a recording ``TerminalSurfaceActions``.
///
/// The SCROLL hooks pin the EXACT libghostty-vt named binding action (`scroll_page_fractional:-0.9`,
/// `scroll_to_top`, …) — a swapped page sign would fail here. The FONT hooks no longer touch the
/// surface: they route ⌘±/⌘0 through the ``WorkspaceStore/onFontSizeStep`` seam to the single source of truth
/// (`PreferencesStore.terminal.fontSize`, the Settings "Size" stepper's value), so they are pinned on the
/// seam + the persisted size. They drive the store methods DIRECTLY (the registry routing is pinned elsewhere).
///
/// HANG-SAFE: the recording session uses a headless ``RecordingSurfaceActions`` (no `TerminalSurfaceDriver` /
/// VideoToolbox / Metal / SCStream) — the hang-safety rule holds.
@MainActor
final class FontScrollHookTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store backed by the recording (terminal-model-carrying) session seam.
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            makeSession: { seed in RecordingTerminalPaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
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

    // MARK: - Font size (single source of truth)

    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "FontScrollHookTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// The three font hooks route ⌘=/⌘-/⌘0 through the ``WorkspaceStore/onFontSizeStep`` seam, in call order —
    /// NOT libghostty-vt's internal `increase_font_size` (which the Settings stepper can't see → the desync this
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

    /// THE regression test: a ⌘±/⌘0 zoom UPDATES the persisted Settings font size (the single source of
    /// truth the "Size" stepper binds), so the two never desync. Wires the seam to a live ``PreferencesStore``
    /// exactly as the app shell does. ⌘+ bumps +1, ⌘- back, ⌘0 resets to the default size.
    func testFontZoomMovesTheEffectiveSizeAndResetsToTheFilesAnswer() {
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
        XCTAssertEqual(prefs.effectiveFontSize, base + 1, "⌘+ bumps the size every terminal renders at")
        store.decreaseFontInActivePane()
        XCTAssertEqual(prefs.effectiveFontSize, base, "⌘- steps it back")

        // ⌘0 drops the runtime delta, so the size goes back to the FILE's answer — not to a compiled
        // constant, and not to whatever ⌘+ last left. The delta is deliberately not persisted: zooming is
        // something you do to read a stack trace, not a preference you are stating.
        store.increaseFontInActivePane()
        store.increaseFontInActivePane()
        XCTAssertNotEqual(prefs.fontSizeDelta, 0, "precondition: zoomed away from the file's size")
        store.resetFontInActivePane()
        XCTAssertEqual(prefs.fontSizeDelta, 0)
        XCTAssertEqual(prefs.effectiveFontSize, base, "⌘0 resets to the configured size")
    }

    // MARK: - Viewport scroll

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

    /// The ``ScrollAction/wire`` mapping is the single source of truth — pin it independently of
    /// the store so a refactor of the store hook can't silently re-map the intent.
    func testScrollActionMappingIsStable() {
        XCTAssertEqual(ScrollAction.pageUp.wire, "scroll_page_fractional:-0.9")
        XCTAssertEqual(ScrollAction.pageDown.wire, "scroll_page_fractional:0.9")
        XCTAssertEqual(ScrollAction.top.wire, "scroll_to_top")
        XCTAssertEqual(ScrollAction.bottom.wire, "scroll_to_bottom")
    }

    // MARK: - Graceful no-op (non-terminal active pane)

    /// A non-terminal active pane (`.desktop`) has no terminal model / no seam, so every font + scroll hook
    /// is a clean no-op — nothing is recorded and nothing traps. Mirrors the block hooks' graceful
    /// degradation; this is what makes the hooks safe to bind unconditionally.
    func testFontScrollAreNoOpOnNonTerminalActivePane() throws {
        let store = makeStore()
        // Video never enters the tree through the store's public surface (docs/DECISIONS.md
        // 2026-07-23), so graft a `.desktop` leaf DIRECTLY into the DOCUMENT — pinning the
        // defensive contract for a tree that somehow carries one; the recorder of the ORIGINAL
        // terminal pane must stay empty after we act on the GUI pane.
        let seed = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let (next, grafted) = TreeIntent.splitPane(
            seed, axis: .horizontal, newSpec: PaneSpec(kind: .desktop, title: "Desktop"), in: store.tree,
        )
        _ = grafted
        try store.graftDocumentTree(next)
        store.reconcileTree()
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
