import Foundation
import SlopDeskTerminal
import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - CopyModeTests (the PURE keyboard copy-mode state machine)

/// Exercises ``TerminalViewModel/handleCopyModeKey(_:)`` — the modal keyboard copy-mode dispatch — entirely
/// in-memory: an abstract ``TerminalViewModel/CopyModeKey`` in, a recording ``TerminalSurfaceActions`` mock
/// out. NO `NSEvent`, NO `GhosttySurface`, NO window server (the hang-safety rule). Each test asserts the
/// EXACT libghostty binding-action string the key maps to (or the find/copy/exit side effect), so a key →
/// action regression is caught here, not on hardware.
@MainActor
final class CopyModeTests: XCTestCase {
    /// A model with a recording surface attached; returns both so a test can assert recorded actions.
    private func makeModel() -> (TerminalViewModel, RecordingSurfaceActions) {
        let recorder = RecordingSurfaceActions()
        let model = TerminalViewModel(surface: recorder)
        return (model, recorder)
    }

    // MARK: Navigation — the scroll/jump binding-action mapping

    func testLineDownKeysScrollOneLineDown() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("j", control: false, shift: false))
        model.handleCopyModeKey(.down)
        XCTAssertEqual(rec.actions, ["scroll_page_lines:1", "scroll_page_lines:1"], "j / ↓ scroll one line DOWN")
    }

    func testLineUpKeysScrollOneLineUp() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("k", control: false, shift: false))
        model.handleCopyModeKey(.up)
        XCTAssertEqual(rec.actions, ["scroll_page_lines:-1", "scroll_page_lines:-1"], "k / ↑ scroll one line UP")
    }

    func testHalfPageKeys() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("d", control: true, shift: false))
        model.handleCopyModeKey(.char("u", control: true, shift: false))
        XCTAssertEqual(
            rec.actions, ["scroll_page_fractional:0.5", "scroll_page_fractional:-0.5"],
            "Ctrl-D down half-page, Ctrl-U up half-page",
        )
    }

    func testFullPageKeys() {
        // ⌃f = full page DOWN (toward newer = positive), ⌃b = full page UP (toward older = negative). `0.9` is
        // the SAME "≈ a page" magnitude the PageDown/PageUp scroll hooks use. Revert-to-confirm-fail: before
        // the fix neither key was wired — ⌃f fell to `default` (swallowed, no action) and ⌃b likewise.
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("f", control: true, shift: false))
        model.handleCopyModeKey(.char("b", control: true, shift: false))
        XCTAssertEqual(
            rec.actions, ["scroll_page_fractional:0.9", "scroll_page_fractional:-0.9"],
            "Ctrl-F down a full page, Ctrl-B up a full page",
        )
    }

    /// `f` WITHOUT Control stays Hint Mode (it must NOT alias onto the new ⌃f full-page scroll): a plain `f`
    /// arms hint mode (no scroll action) while `⌃f` scrolls — the control modifier is load-bearing.
    func testPlainFIsHintModeNotFullPageScroll() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("f", control: false, shift: false))
        XCTAssertTrue(rec.actions.isEmpty, "plain f arms Hint Mode, never a scroll action")
    }

    func testTopAndBottomKeys() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("g", control: false, shift: false))
        model.handleCopyModeKey(.char("G", control: false, shift: true))
        XCTAssertEqual(rec.actions, ["scroll_to_top", "scroll_to_bottom"], "g top, G bottom")
    }

    func testPromptJumpKeys() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("[", control: false, shift: false))
        model.handleCopyModeKey(.char("]", control: false, shift: false))
        XCTAssertEqual(rec.actions, ["jump_to_prompt:-1", "jump_to_prompt:1"], "[ prev prompt, ] next prompt")
    }

    // MARK: Search — reuses the find engine (no second search impl)

    func testSlashOpensFindBarAndDoesNotScroll() {
        let (model, rec) = makeModel()
        var findRequested = 0
        model.onRequestFind = { findRequested += 1 }
        model.handleCopyModeKey(.char("/", control: false, shift: false))
        XCTAssertEqual(findRequested, 1, "/ fires onRequestFind (reuses the existing find bar)")
        XCTAssertTrue(rec.actions.isEmpty, "/ must NOT emit a scroll action")
    }

    func testSearchNavigationKeys() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("n", control: false, shift: false))
        model.handleCopyModeKey(.char("N", control: false, shift: true))
        XCTAssertEqual(
            rec.actions, ["navigate_search:next", "navigate_search:previous"],
            "n next match, N previous match",
        )
    }

    // MARK: Copy — reads libghostty's selection truth (never a client-guessed position)

    func testCopyWithSelectionCopiesSelectionAndConfirms() {
        let recorder = RecordingSurfaceActions()
        recorder.selectionText = "selected text"
        let model = TerminalViewModel(surface: recorder)
        var copied: String?
        var confirmations = 0
        model.copyToPasteboard = { copied = $0 }
        model.onCopyConfirmation = { confirmations += 1 }

        model.handleCopyModeKey(.char("y", control: false, shift: false))
        XCTAssertEqual(copied, "selected text", "y copies the existing libghostty selection")
        XCTAssertEqual(confirmations, 1, "a copy flashes the 'copied' confirmation")
        // It must NOT silently select-all when a selection already exists.
        XCTAssertFalse(recorder.actions.contains("select_all"), "never auto select_all over an existing selection")
    }

    func testCopyWithoutSelectionFallsBackToScrollback() {
        let recorder = RecordingSurfaceActions()
        recorder.selectionText = nil
        recorder.scrollbackLines = ["line one", "line two", "line three"]
        let model = TerminalViewModel(surface: recorder)
        var copied: String?
        model.copyToPasteboard = { copied = $0 }

        model.handleCopyModeKey(.enter)
        XCTAssertEqual(copied, "line one\nline two\nline three", "Enter with no selection copies the scrollback text")
    }

    func testCopyWithNothingToCopyDoesNotConfirm() {
        let recorder = RecordingSurfaceActions()
        recorder.selectionText = nil
        recorder.scrollbackLines = []
        let model = TerminalViewModel(surface: recorder)
        var copied: String?
        var confirmations = 0
        model.copyToPasteboard = { copied = $0 }
        model.onCopyConfirmation = { confirmations += 1 }

        model.handleCopyModeKey(.char("y", control: false, shift: false))
        XCTAssertNil(copied, "nothing to copy → no pasteboard write")
        XCTAssertEqual(confirmations, 0, "nothing copied → no confirmation flash")
    }

    // MARK: Mode lifecycle (enter / exit)

    func testEnterCopyModeSetsFlagAndFiresHook() {
        let (model, _) = makeModel()
        var requests = 0
        model.onRequestCopyMode = { requests += 1 }
        model.enterCopyMode()
        XCTAssertTrue(model.isCopyMode, "enterCopyMode arms the mode")
        XCTAssertEqual(requests, 1, "enterCopyMode fires onRequestCopyMode (drives the overlay @State)")
    }

    func testExitKeysClearTheMode() {
        let (model, _) = makeModel()
        for exitKey in [TerminalViewModel.CopyModeKey.char("q", control: false, shift: false), .escape] {
            model.isCopyMode = true
            var requests = 0
            model.onRequestCopyMode = { requests += 1 }
            model.handleCopyModeKey(exitKey)
            XCTAssertFalse(model.isCopyMode, "\(exitKey) exits copy-mode")
            XCTAssertEqual(requests, 1, "exit fires onRequestCopyMode to dismiss the overlay")
        }
    }

    func testUnmappedKeyIsSwallowedAndDoesNothing() {
        let (model, rec) = makeModel()
        model.isCopyMode = true
        model.handleCopyModeKey(.char("z", control: false, shift: false))
        XCTAssertTrue(rec.actions.isEmpty, "an unmapped key is swallowed (consumed in-mode), emits no action")
        XCTAssertTrue(model.isCopyMode, "an unmapped key does not exit the mode")
    }

    /// A Ctrl-modified nav key (other than the explicit Ctrl-D/Ctrl-U half-page) is a CLEAN no-op — it must
    /// NOT alias onto the plain nav action (Ctrl-J must not scroll, Ctrl-N must not navigate_search). It is
    /// still swallowed (consumed in-mode), just emits nothing.
    func testControlModifiedNavKeyIsSwallowedNotAliased() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("j", control: true, shift: false))
        model.handleCopyModeKey(.char("n", control: true, shift: false))
        model.handleCopyModeKey(.char("g", control: true, shift: false))
        XCTAssertTrue(rec.actions.isEmpty, "Ctrl-<navkey> is swallowed, never aliased onto a nav binding action")
    }

    /// `exitCopyMode` is idempotent and `enterCopyMode` does not re-fire once already armed — the model is the
    /// single source of truth, so a double-exit (q then Esc) can't re-arm.
    func testEnterAndExitAreIdempotent() {
        let (model, _) = makeModel()
        var requests = 0
        model.onRequestCopyMode = { requests += 1 }
        model.enterCopyMode()
        model.enterCopyMode() // already armed → no re-arm, no second hook fire
        XCTAssertTrue(model.isCopyMode)
        XCTAssertEqual(requests, 1, "enterCopyMode is a no-op once armed")
        model.exitCopyMode()
        XCTAssertFalse(model.isCopyMode)
        model.exitCopyMode() // already exited → still dismisses cleanly, never re-arms
        XCTAssertFalse(model.isCopyMode, "a second exit never re-arms (no inverting toggle)")
    }

    // MARK: Registry — chord pin + routing through the production seam

    func testCopyModeChordIsTheDocumentedDefault() {
        XCTAssertEqual(
            WorkspaceBindingRegistry.binding(for: .toggleCopyMode)?.chord,
            KeyChord(character: "c", [.command, .shift]),
            "copy mode = ⌘⇧C",
        )
    }

    func testCopyModeRequiresActivePane() {
        XCTAssertTrue(WorkspaceAction.toggleCopyMode.requiresActivePane, "copy mode targets the active pane")
    }

    /// Routing `.toggleCopyMode` through the production seam reaches the active pane's
    /// `onRequestCopyMode` (the hook `TerminalScreenView` wires to arm the mode + show the overlay).
    func testToggleCopyModeRoutesToActivePaneHook() throws {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let session = try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
        let model = try XCTUnwrap(session.terminalModel)
        var requested = 0
        // Mimic TerminalScreenView's PRODUCTION wiring: the model is the single source of truth (the store
        // route calls enter/exitCopyMode, which flip `isCopyMode`); the hook is a PURE observer that only
        // OBSERVES the model — it must NOT independently toggle the flag (the old inverting toggle could
        // desync and re-arm on exit). So the closure here just counts + reads, never writes.
        model.onRequestCopyMode = { requested += 1 }

        WorkspaceBindingRegistry.route(.toggleCopyMode, to: store)
        XCTAssertEqual(requested, 1, "⌘⇧C reaches the active pane's copy-mode hook")
        XCTAssertTrue(model.isCopyMode, "the mode is armed by the store's enterCopyMode route")
        XCTAssertTrue(store.isCopyMode(for: active), "the store badge helper reflects the armed pane")

        WorkspaceBindingRegistry.route(.toggleCopyMode, to: store)
        XCTAssertEqual(requested, 2, "routing again fires the hook")
        XCTAssertFalse(model.isCopyMode, "the store's exitCopyMode route disarms the mode")
        XCTAssertFalse(store.isCopyMode(for: active), "the badge clears on exit")
    }

    // MARK: CopyModeKey value mapping (the abstract enum is the testable boundary)

    func testCopyModeKeyEquatable() {
        XCTAssertEqual(
            TerminalViewModel.CopyModeKey.char("j", control: false, shift: false),
            .char("j", control: false, shift: false),
        )
        XCTAssertNotEqual(
            TerminalViewModel.CopyModeKey.char("d", control: true, shift: false),
            .char("d", control: false, shift: false),
        )
    }
}
