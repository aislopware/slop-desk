import AislopdeskTerminal
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

// MARK: - TerminalViewModelViMotionTests (E17 ES-E17-2/3 — vi repeat-count + ? backward + visual-mode)

/// Exercises the E17 WI-4 extensions to ``TerminalViewModel/handleCopyModeKey(_:)`` — the PURE vi
/// repeat-count accumulation, the `?` backward-find bias, and the `v`/`V`/`⌃v` visual modes (+ their
/// `adjust_selection` selection-extend) — entirely in-memory: an abstract ``TerminalViewModel/CopyModeKey``
/// in, a recording ``TerminalSurfaceActions`` mock out. NO `NSEvent`, NO `GhosttySurface`, NO window server
/// (the hang-safety rule). Each test asserts the EXACT binding-action string(s) and the observable pill
/// mirrors (``viPendingCount`` / ``viVisualMode``), so a key → action regression is caught here, not on
/// hardware. These are the WI-4 counterparts to ``CopyModeTests`` (the base nav/copy/exit mapping).
@MainActor
final class TerminalViewModelViMotionTests: XCTestCase {
    /// A model with a recording surface attached; returns both so a test can assert recorded actions.
    private func makeModel() -> (TerminalViewModel, RecordingSurfaceActions) {
        let recorder = RecordingSurfaceActions()
        let model = TerminalViewModel(surface: recorder)
        return (model, recorder)
    }

    // MARK: Repeat-count (digits accumulate, scale the motion, then clear)

    /// A digit shows live in the pill (``viPendingCount``) and the NEXT line motion scales the scroll —
    /// `5j` → `scroll_page_lines:5` (one action, not five). Revert-to-fail: the un-fixed code swallows the
    /// `5` and emits `scroll_page_lines:1`.
    func testRepeatCountScalesLineScroll() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("5", control: false, shift: false))
        XCTAssertEqual(model.viPendingCount, 5, "the pending count shows live in the pill before the motion")
        model.handleCopyModeKey(.char("j", control: false, shift: false))
        XCTAssertEqual(rec.actions, ["scroll_page_lines:5"], "5j scrolls five lines down in one scaled action")
        XCTAssertNil(model.viPendingCount, "the count clears after the motion (applies to exactly one motion)")
    }

    /// Digits accumulate left-to-right and `0` EXTENDS a pending count — `1` then `0` → 10. `10k` scrolls ten
    /// lines UP (negative sign). Proves multi-digit accumulation, not a per-digit reset.
    func testMultiDigitRepeatCountAccumulates() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("1", control: false, shift: false))
        model.handleCopyModeKey(.char("0", control: false, shift: false)) // 1 then 0 → 10
        XCTAssertEqual(model.viPendingCount, 10, "digits accumulate (10); 0 extends an existing count")
        model.handleCopyModeKey(.char("k", control: false, shift: false))
        XCTAssertEqual(rec.actions, ["scroll_page_lines:-10"], "10k scrolls ten lines up")
        XCTAssertNil(model.viPendingCount)
    }

    /// A bare `0` (no pending count) is the line-start motion (a documented column-motion ceiling), NOT a
    /// count of zero — it must not start a count and must emit nothing (rather than scroll).
    func testZeroWithoutPendingCountDoesNotStartACount() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("0", control: false, shift: false))
        XCTAssertNil(model.viPendingCount, "a bare 0 is line-start, not a count of zero")
        XCTAssertTrue(rec.actions.isEmpty, "a bare 0 emits nothing (column motion is a documented ceiling)")
    }

    /// The count SCALES a parameterized prompt jump too: `3]` → `jump_to_prompt:3`, `2[` → `jump_to_prompt:-2`.
    func testRepeatCountScalesPromptJump() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("3", control: false, shift: false))
        model.handleCopyModeKey(.char("]", control: false, shift: false))
        model.handleCopyModeKey(.char("2", control: false, shift: false))
        model.handleCopyModeKey(.char("[", control: false, shift: false))
        XCTAssertEqual(
            rec.actions, ["jump_to_prompt:3", "jump_to_prompt:-2"],
            "3] jumps forward three prompts, 2[ back two (count scales the magnitude)",
        )
    }

    /// A motion with NO pending count is a single step (count defaults to 1) — the base behavior the
    /// repeat-count layer must not regress.
    func testBareMotionUsesCountOfOne() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("j", control: false, shift: false))
        XCTAssertEqual(rec.actions, ["scroll_page_lines:1"], "a motion with no pending count is a single step")
    }

    /// An absurd accumulated count is clamped (no `Int` overflow / runaway scroll).
    func testRepeatCountClampsAtCeiling() {
        let (model, _) = makeModel()
        for _ in 0..<8 { model.handleCopyModeKey(.char("9", control: false, shift: false)) }
        XCTAssertEqual(model.viPendingCount, 9999, "an absurd count is clamped to the ceiling")
    }

    /// `n`/`N` are directional (no magnitude), so the count REPEATS the action — `2n` steps two matches. With
    /// NO find bar wired (the headless fallback: ``onRequestFindNext`` nil) `n` drives libghostty's own forward
    /// nav, so `2n` records two `navigate_search:next` on the surface.
    func testSearchNavRepeatsUnderCount() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("2", control: false, shift: false))
        model.handleCopyModeKey(.char("n", control: false, shift: false))
        XCTAssertEqual(
            rec.actions, ["navigate_search:next", "navigate_search:next"], "2n steps two matches forward",
        )
    }

    /// E17 WI-5 — when a find bar IS wired, vi `n`/`N` route through the DIRECTION-AWARE find-next/prev seam
    /// (the same hooks ⌘G / ⇧⌘G use → the bar's `next()`/`previous()`, which bias on `searchBackward`), NOT a
    /// hardcoded forward `navigate_search:next` on the surface. This is what lets a `?`-opened backward search
    /// make `n` walk up and `N` walk down: the bar owns the concrete direction. The count still repeats the
    /// step. Revert-to-confirm-fail: the pre-fix handler called `actions.performBindingAction("navigate_search:
    /// next")` directly, so it NEVER invoked these hooks and DID record on the surface — both `XCTAssertEqual`
    /// on the counters AND the `rec.actions.isEmpty` assert fail on the un-fixed code.
    func testViNextPrevRouteThroughDirectionAwareFindHooks() {
        let (model, rec) = makeModel()
        var nextCalls = 0
        var prevCalls = 0
        model.onRequestFindNext = { nextCalls += 1 }
        model.onRequestFindPrev = { prevCalls += 1 }
        model.handleCopyModeKey(.char("2", control: false, shift: false))
        model.handleCopyModeKey(.char("n", control: false, shift: false)) // 2n → two forward-direction steps
        model.handleCopyModeKey(.char("N", control: false, shift: true)) // N → one against-direction step
        XCTAssertEqual(nextCalls, 2, "2n steps the find-next seam twice (the bar owns the concrete direction)")
        XCTAssertEqual(prevCalls, 1, "N steps the find-prev seam once")
        XCTAssertTrue(
            rec.actions.isEmpty,
            "vi n/N must route through the find bar, never bypass it with a hardcoded navigate_search",
        )
    }

    /// The count also clears on Esc (which EXITS vi mode): a pending count never survives the session.
    func testRepeatCountClearsOnEscExit() {
        let (model, _) = makeModel()
        model.enterCopyMode()
        model.handleCopyModeKey(.char("5", control: false, shift: false))
        XCTAssertEqual(model.viPendingCount, 5)
        model.handleCopyModeKey(.escape)
        XCTAssertNil(model.viPendingCount, "Esc (exit) clears the pending count")
        XCTAssertFalse(model.isCopyMode, "Esc exits vi mode")
    }

    // MARK: `/` forward vs `?` backward (reuse the find bar — no second search impl)

    /// `/` fires the forward find hook ONLY, and emits no scroll action.
    func testSlashOpensForwardFind() {
        let (model, rec) = makeModel()
        var forward = 0
        var backward = 0
        model.onRequestFind = { forward += 1 }
        model.onRequestFindBackward = { backward += 1 }
        model.handleCopyModeKey(.char("/", control: false, shift: false))
        XCTAssertEqual(forward, 1, "/ opens the find bar forward")
        XCTAssertEqual(backward, 0, "/ never triggers the backward bias")
        XCTAssertTrue(rec.actions.isEmpty, "/ must not emit a scroll action")
    }

    /// `?` fires the BACKWARD find hook (not the forward one) when the backward bias is wired. Revert-to-fail:
    /// the un-fixed code has no `?` case, so the backward hook never fires.
    func testQuestionOpensBackwardFind() {
        let (model, rec) = makeModel()
        var forward = 0
        var backward = 0
        model.onRequestFind = { forward += 1 }
        model.onRequestFindBackward = { backward += 1 }
        model.handleCopyModeKey(.char("?", control: false, shift: true))
        XCTAssertEqual(backward, 1, "? opens the find bar BACKWARD")
        XCTAssertEqual(forward, 0, "? does not fire the forward hook when the backward bias is wired")
        XCTAssertTrue(rec.actions.isEmpty, "? must not emit a scroll action")
    }

    /// `?` still opens the SAME find bar via ``onRequestFind`` when the backward hook is not (yet) wired — so
    /// the key is never dead before the GUI adds the backward bias (WI-5).
    func testQuestionFallsBackToForwardHookWhenBackwardUnwired() {
        let (model, _) = makeModel()
        var forward = 0
        model.onRequestFind = { forward += 1 }
        // onRequestFindBackward intentionally left nil (GUI backward bias not yet wired)
        model.handleCopyModeKey(.char("?", control: false, shift: true))
        XCTAssertEqual(forward, 1, "? falls back to onRequestFind when no backward hook is wired")
    }

    // MARK: Visual modes (v / V / ⌃v) + selection extend

    func testVisualModePillLabels() {
        XCTAssertNil(TerminalViewModel.VisualMode.none.pillLabel, "plain nav has no visual-mode label")
        XCTAssertEqual(TerminalViewModel.VisualMode.char.pillLabel, "VISUAL")
        XCTAssertEqual(TerminalViewModel.VisualMode.line.pillLabel, "VISUAL LINE")
        XCTAssertEqual(TerminalViewModel.VisualMode.block.pillLabel, "VISUAL BLOCK")
    }

    /// `v`/`V`/`⌃v` set the observable visual mode; the SAME key toggles back to plain navigation, a DIFFERENT
    /// key switches (vim parity). Revert-to-fail: the un-fixed code swallows `v`/`V`/`⌃v` and `viVisualMode`
    /// never leaves `.none`.
    func testVisualModesSetAndSwitchTheObservableMode() {
        let (model, _) = makeModel()
        model.handleCopyModeKey(.char("v", control: false, shift: false))
        XCTAssertEqual(model.viVisualMode, .char, "v → character visual")
        model.handleCopyModeKey(.char("V", control: false, shift: true))
        XCTAssertEqual(model.viVisualMode, .line, "V switches char → line visual")
        model.handleCopyModeKey(.char("v", control: true, shift: false))
        XCTAssertEqual(model.viVisualMode, .block, "⌃v switches to block visual")
        model.handleCopyModeKey(.char("v", control: true, shift: false))
        XCTAssertEqual(model.viVisualMode, .none, "the same mode key toggles back to plain navigation")
    }

    /// In a visual mode the line motions EXTEND the selection (`adjust_selection:<dir>`) instead of scrolling.
    /// Revert-to-fail: the un-fixed code always emits `scroll_page_lines:…`.
    func testVisualModeMotionsExtendSelection() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("v", control: false, shift: false)) // char-visual
        model.handleCopyModeKey(.char("j", control: false, shift: false))
        model.handleCopyModeKey(.up)
        XCTAssertEqual(
            rec.actions, ["adjust_selection:down", "adjust_selection:up"],
            "in a visual mode, j/k EXTEND the selection instead of scrolling",
        )
    }

    /// A repeat-count in a visual mode REPEATS the directional `adjust_selection` (it takes no magnitude) —
    /// `3j` extends the selection down three rows.
    func testVisualModeRepeatCountRepeatsAdjustSelection() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("V", control: false, shift: true)) // line-visual
        model.handleCopyModeKey(.char("3", control: false, shift: false))
        model.handleCopyModeKey(.char("j", control: false, shift: false))
        XCTAssertEqual(
            rec.actions,
            ["adjust_selection:down", "adjust_selection:down", "adjust_selection:down"],
            "3j extends the selection down three rows (count repeats the directional action)",
        )
    }

    /// `o` (anchor-swap) is a documented no-op — the pinned libghostty fork exposes no swap-ends action — so it
    /// emits NOTHING and does not leave the visual mode (the char-range ceiling, see DECISIONS.md).
    func testAnchorSwapIsADocumentedNoOp() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(.char("v", control: false, shift: false))
        rec.resetActions()
        model.handleCopyModeKey(.char("o", control: false, shift: false))
        XCTAssertTrue(rec.actions.isEmpty, "o (anchor-swap) emits no faked action — the documented ceiling")
        XCTAssertEqual(model.viVisualMode, .char, "o stays in the visual mode")
    }

    /// Exiting vi mode clears the visual-selection state (per-session; a re-entry starts in plain navigation).
    func testExitClearsVisualState() {
        let (model, _) = makeModel()
        model.enterCopyMode()
        model.handleCopyModeKey(.char("v", control: false, shift: false))
        XCTAssertEqual(model.viVisualMode, .char)
        model.exitCopyMode()
        XCTAssertEqual(model.viVisualMode, .none, "exiting vi mode clears the visual selection state")
    }

    // MARK: Yank exits (spec: y / Enter copy AND exit vi mode)

    /// `y` still copies the mouse-made selection AND now EXITS vi mode (otty spec). Revert-to-fail: the
    /// un-fixed code copies but leaves `isCopyMode == true`.
    func testYankExitsViMode() {
        let recorder = RecordingSurfaceActions()
        recorder.selectionText = "selected"
        let model = TerminalViewModel(surface: recorder)
        var copied: String?
        model.copyToPasteboard = { copied = $0 }
        model.enterCopyMode()
        XCTAssertTrue(model.isCopyMode)
        model.handleCopyModeKey(.char("y", control: false, shift: false))
        XCTAssertEqual(copied, "selected", "y still copies the mouse-made selection")
        XCTAssertFalse(model.isCopyMode, "y yanks AND exits vi mode (spec)")
    }

    /// `Enter` likewise copies (the scrollback fallback) AND exits.
    func testEnterYankExitsViMode() {
        let recorder = RecordingSurfaceActions()
        recorder.selectionText = nil
        recorder.scrollbackLines = ["one", "two"]
        let model = TerminalViewModel(surface: recorder)
        var copied: String?
        model.copyToPasteboard = { copied = $0 }
        model.enterCopyMode()
        model.handleCopyModeKey(.enter)
        XCTAssertEqual(copied, "one\ntwo", "Enter copies the scrollback fallback when there is no selection")
        XCTAssertFalse(model.isCopyMode, "Enter copies AND exits vi mode (spec)")
    }

    // MARK: Key-hint bar (⌘/ contextual toggle; off by default, reset on exit)

    /// ``toggleViKeyHints()`` flips ``showViKeyHints`` and fires ``onRequestViKeyHints``; leaving vi mode
    /// resets the hint bar (per-session, off by default).
    func testKeyHintsToggleAndResetOnExit() {
        let (model, _) = makeModel()
        var requests = 0
        model.onRequestViKeyHints = { requests += 1 }
        XCTAssertFalse(model.showViKeyHints, "the hint bar is off by default")
        model.toggleViKeyHints()
        XCTAssertTrue(model.showViKeyHints, "⌘/ shows the hint bar")
        XCTAssertEqual(requests, 1, "the toggle fires onRequestViKeyHints")
        model.toggleViKeyHints()
        XCTAssertFalse(model.showViKeyHints, "⌘/ again hides it")
        XCTAssertEqual(requests, 2)

        model.enterCopyMode()
        model.toggleViKeyHints()
        XCTAssertTrue(model.showViKeyHints)
        model.exitCopyMode()
        XCTAssertFalse(model.showViKeyHints, "leaving vi mode resets the hint bar (per-session)")
    }

    /// Entering a fresh copy-mode session starts clean: no pending count, plain navigation, hint bar off.
    func testEnterCopyModeStartsCleanViState() {
        let (model, _) = makeModel()
        // Dirty the state outside a session, then enter — entry must reset it. (Set the visual mode FIRST:
        // entering a visual mode drops any pending count, so the count digit comes after.)
        model.handleCopyModeKey(.char("v", control: false, shift: false))
        model.handleCopyModeKey(.char("5", control: false, shift: false))
        model.toggleViKeyHints()
        XCTAssertEqual(model.viPendingCount, 5)
        XCTAssertEqual(model.viVisualMode, .char)
        XCTAssertTrue(model.showViKeyHints)

        model.enterCopyMode()
        XCTAssertNil(model.viPendingCount, "a fresh session has no pending count")
        XCTAssertEqual(model.viVisualMode, .none, "a fresh session starts in plain navigation")
        XCTAssertFalse(model.showViKeyHints, "a fresh session's hint bar is off")
    }
}
