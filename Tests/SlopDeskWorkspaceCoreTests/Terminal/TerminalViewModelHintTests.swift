import Foundation
import SlopDeskTerminal
import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - TerminalViewModelHintTests (E10 WI-9 / ES-E10-6 — the Hint Mode key-dispatch orchestration)

/// Exercises the PURE Hint Mode key dispatch on ``TerminalViewModel`` — `beginHint` → `handleHintKey`
/// (type → confirm) → `confirmHintTarget` / `cancelHintMode` — entirely in-memory: a fake surface
/// conforming to ``TerminalSurface`` + ``TerminalViewportSnapshotting`` feeds `beginHint` canned viewport
/// rows, then abstract ``TerminalViewModel/HintKey`` cases drive the dispatch. NO `NSEvent`, NO
/// `GhosttySurface`, NO window server (the hang-safety rule). `HintLabelAssigner.filter` itself is pinned by
/// ``HintLabelAssignerTests``; THIS suite covers the orchestration the lower-level engine cannot: that a
/// fully-typed label fires ``onHintConfirmed`` EXACTLY ONCE with the matching target + intent, a non-matching
/// second key is ignored (no fire, prefix kept, never leaks), `.escape` cancels, `.delete` undoes one letter,
/// and the iOS `confirmHintTarget` tap path fires once and exits.
///
/// Each assertion is revert-to-confirm-fail: it targets behaviour that breaks if the corresponding branch of
/// `handleHintKey` / `confirmHintTarget` is removed (verified by breaking the handler before finalizing).
@MainActor
final class TerminalViewModelHintTests: XCTestCase {
    /// A headless ``TerminalSurface`` that ALSO conforms to ``TerminalViewportSnapshotting`` so `beginHint`
    /// can read canned viewport rows + geometry without a real `GhosttySurface` (which hangs without a window
    /// server — the hang-safety rule). Inert as a renderer; it only vends the snapshot the overlay seam reads.
    private final class HintViewportSurface: TerminalSurface, TerminalViewportSnapshotting, @unchecked Sendable {
        var onWrite: ((Data) -> Void)?
        private let rows: [String]
        private let metrics: TerminalCellMetrics

        init(rows: [String], metrics: TerminalCellMetrics) {
            self.rows = rows
            self.metrics = metrics
        }

        // TerminalSurface (inert — hint tests never feed bytes through here).
        func feed(_: Data) {}
        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}

        // TerminalViewportSnapshotting (the overlay-geometry seam beginHint reads).
        func viewportTextRows() -> [String] { rows }
        func cellMetrics() -> TerminalCellMetrics? { metrics }
    }

    /// Strong hold on the fake surface for the test lifetime — ``TerminalViewModel/surface`` is `weak`, so
    /// without this the fake would deallocate the instant ``makeModel()`` returns and `beginHint`'s
    /// `surface as? TerminalViewportSnapshotting` would see `nil`.
    private var retainedSurface: HintViewportSurface?

    /// One viewport row with TWO detectable absolute-path links (`/usr/local/bin/tool`, `/etc/hosts`), so
    /// `beginHint` assigns two collision-free 2-letter labels. Returns the model; the fake is retained by
    /// ``retainedSurface`` for the whole test.
    private func makeModel() -> TerminalViewModel {
        let surface = HintViewportSurface(
            rows: ["see /usr/local/bin/tool and /etc/hosts"],
            metrics: TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 80, rows: 24),
        )
        retainedSurface = surface
        return TerminalViewModel(surface: surface)
    }

    /// The label assigned to the `/usr/local/bin/tool` target — looked up by raw text so the test is robust to
    /// label ORDER (the assigner spreads first letters across targets). `throws` so an unexpected absence fails
    /// loudly rather than force-unwrapping (CLAUDE.md: never `!` on derived data).
    private func labelForTool(_ model: TerminalViewModel) throws -> (label: String, index: Int) {
        let index = try XCTUnwrap(
            model.hintTargets.firstIndex { $0.raw == "/usr/local/bin/tool" },
            "the /usr/local/bin/tool path must be a detected hint target",
        )
        let label = model.hintLabels[index]
        XCTAssertEqual(label.count, 2, "every Vimium label is exactly 2 letters")
        return (label, index)
    }

    // MARK: beginHint arms the session

    /// `beginHint` over rows with two link targets arms the mode + populates two labelled targets. A NO-OP on
    /// an empty/alt-screen/no-surface pane is covered implicitly — here the live snapshot yields targets.
    func testBeginHintArmsModeWithDetectedTargets() {
        let model = makeModel()
        XCTAssertNil(model.hintMode, "fresh pane is not in hint mode")
        model.beginHint(.open)
        XCTAssertEqual(model.hintMode, .open, "beginHint arms the intent")
        XCTAssertEqual(model.hintTargets.count, 2, "both path links are hintable targets")
        XCTAssertEqual(model.hintLabels.count, 2, "each target gets a label")
        XCTAssertEqual(Set(model.hintLabels).count, 2, "labels are collision-free")
        XCTAssertEqual(model.hintTyped, "", "no keys typed yet")
    }

    // MARK: type → confirm (first letter dims, second confirms with NO Enter)

    /// Typing a label's two letters confirms it: the FIRST letter only accumulates (no fire), the SECOND fires
    /// ``onHintConfirmed`` EXACTLY ONCE with the matching target + the armed intent, and exits hint mode — no
    /// Enter. Revert-to-confirm-fail: a handler that fired on the first key, or never fired, or fired the wrong
    /// target, fails the count / target asserts.
    func testTypingLabelConfirmsExactlyOnceWithMatchingTargetAndIntent() throws {
        let model = makeModel()
        var confirmed: [(target: HintTarget, intent: HintIntent)] = []
        model.onHintConfirmed = { confirmed.append((target: $0, intent: $1)) }

        model.beginHint(.open)
        let (label, _) = try labelForTool(model)
        let chars = Array(label)

        model.handleHintKey(.character(chars[0]))
        XCTAssertEqual(confirmed.count, 0, "the first letter dims — it never confirms")
        XCTAssertEqual(model.hintTyped, String(chars[0]).lowercased(), "the first letter is accumulated")
        XCTAssertEqual(model.hintMode, .open, "still armed after one letter")

        model.handleHintKey(.character(chars[1]))
        XCTAssertEqual(confirmed.count, 1, "the second letter confirms exactly once — no Enter")
        XCTAssertEqual(confirmed.first?.target.raw, "/usr/local/bin/tool", "the matching target is delivered")
        XCTAssertEqual(confirmed.first?.intent, .open, "the armed intent is carried through")
        XCTAssertNil(model.hintMode, "a confirm exits hint mode")
        XCTAssertEqual(model.hintTyped, "", "exiting clears the typed prefix")
    }

    // MARK: a non-matching second key is ignored (no fire, prefix kept, never leaks)

    /// After one letter, a second key that completes NO label is IGNORED: no ``onHintConfirmed``, the typed
    /// prefix is KEPT (not corrupted), and the mode stays armed (the key is swallowed, never leaked to the
    /// shell). Revert-to-confirm-fail: a handler that appended the stray key would leave `hintTyped` 2 chars
    /// long; one that confirmed would fire.
    func testNonMatchingSecondKeyIsIgnoredAndPrefixKept() throws {
        let model = makeModel()
        var confirmed = 0
        model.onHintConfirmed = { _, _ in confirmed += 1 }

        model.beginHint(.open)
        let (label, _) = try labelForTool(model)
        let first = Array(label)[0]
        let firstLower = String(first).lowercased()
        model.handleHintKey(.character(first))
        XCTAssertEqual(model.hintTyped, firstLower)

        // A second letter that forms no label (`firstLower + nonMatching` is not in the label set).
        let nonMatching = try XCTUnwrap(
            HintLabelAssigner.defaultAlphabet.first { !model.hintLabels.contains(firstLower + String($0)) },
            "with only two labels there is always a non-completing second letter",
        )
        model.handleHintKey(.character(nonMatching))

        XCTAssertEqual(confirmed, 0, "a non-matching second key never confirms")
        XCTAssertEqual(model.hintTyped, firstLower, "the typed prefix is kept — the stray key is not accumulated")
        XCTAssertEqual(model.hintMode, .open, "the mode stays armed (the stray key is swallowed, not leaked)")
    }

    // MARK: Esc cancels

    /// `.escape` cancels the mode and clears the session state (no confirm). Revert-to-confirm-fail: dropping
    /// the `.escape` branch leaves `hintMode` non-nil.
    func testEscapeCancelsHintMode() {
        let model = makeModel()
        var confirmed = 0
        model.onHintConfirmed = { _, _ in confirmed += 1 }

        model.beginHint(.copy)
        XCTAssertEqual(model.hintMode, .copy)
        model.handleHintKey(.escape)

        XCTAssertNil(model.hintMode, "Esc cancels the mode")
        XCTAssertEqual(model.hintTyped, "", "Esc clears the typed prefix")
        XCTAssertTrue(model.hintTargets.isEmpty, "Esc clears the session targets")
        XCTAssertTrue(model.hintLabels.isEmpty, "Esc clears the session labels")
        XCTAssertEqual(confirmed, 0, "Esc never confirms a target")
    }

    // MARK: Backspace undoes one letter

    /// `.delete` undoes exactly one typed letter and stays in the mode; a `.delete` with an empty prefix is a
    /// clean no-op. Revert-to-confirm-fail: a handler that exited on delete, or cleared the whole prefix, fails.
    func testBackspaceUndoesOneLetterAndStaysArmed() throws {
        let model = makeModel()
        model.beginHint(.open)
        let (label, _) = try labelForTool(model)
        let first = Array(label)[0]

        model.handleHintKey(.character(first))
        XCTAssertEqual(model.hintTyped, String(first).lowercased(), "one letter typed")

        model.handleHintKey(.delete)
        XCTAssertEqual(model.hintTyped, "", "Backspace undoes the one typed letter")
        XCTAssertEqual(model.hintMode, .open, "Backspace does NOT exit the mode")

        // Backspace on an empty prefix is a clean no-op (no crash, no underflow).
        model.handleHintKey(.delete)
        XCTAssertEqual(model.hintTyped, "", "Backspace on an empty prefix is a no-op")
        XCTAssertEqual(model.hintMode, .open)
    }

    // MARK: confirmHintTarget (the iOS tap path)

    /// `confirmHintTarget` (the iOS tap-on-label fallback) fires ``onHintConfirmed`` EXACTLY ONCE with the
    /// tapped target + the armed intent, then exits. Revert-to-confirm-fail: dropping the `cancelHintMode()` /
    /// fire in `confirmHintTarget` fails the count or the still-armed assert.
    func testConfirmHintTargetFiresOnceAndExits() throws {
        let model = makeModel()
        var confirmed: [(target: HintTarget, intent: HintIntent)] = []
        model.onHintConfirmed = { confirmed.append((target: $0, intent: $1)) }

        model.beginHint(.reveal)
        let target = try XCTUnwrap(model.hintTargets.first, "the session has at least one target")
        model.confirmHintTarget(target)

        XCTAssertEqual(confirmed.count, 1, "a tap confirms exactly once")
        XCTAssertEqual(confirmed.first?.target, target, "the tapped target is delivered")
        XCTAssertEqual(confirmed.first?.intent, .reveal, "the armed intent is carried through")
        XCTAssertNil(model.hintMode, "a tap-confirm exits hint mode")
    }

    /// `confirmHintTarget` while NOT in hint mode is a clean no-op (the guard) — a stray tap after the mode
    /// already closed never fires a phantom action.
    func testConfirmHintTargetWhileNotArmedIsNoOp() {
        let model = makeModel()
        var confirmed = 0
        model.onHintConfirmed = { _, _ in confirmed += 1 }
        // No beginHint — not armed.
        model.confirmHintTarget(HintTarget(row: 0, colStart: 0, colEnd: 1, raw: "x", kind: .gitHash))
        XCTAssertEqual(confirmed, 0, "confirm without an armed mode is a no-op")
    }

    /// `handleHintKey` while NOT in hint mode is a clean no-op (the guard) — a key that races the mode close
    /// neither confirms nor accumulates.
    func testHandleHintKeyWhileNotArmedIsNoOp() {
        let model = makeModel()
        var confirmed = 0
        model.onHintConfirmed = { _, _ in confirmed += 1 }
        model.handleHintKey(.character("a"))
        XCTAssertEqual(model.hintTyped, "", "a key while not armed does not accumulate")
        XCTAssertEqual(confirmed, 0, "a key while not armed never confirms")
    }

    // MARK: vi-mode `f` enters Hint Mode (the spec's keyboard-driven link clicking)

    /// The vi-mode spec lists `f` → Enter Hint Mode (keyboard-driven link clicking). Pressing `f` in copy-mode
    /// must arm Hint Mode over the live viewport via the SAME `beginHint(.open)` seam the ⌘⇧J chord uses — Hint
    /// Mode is a separate E10 overlay, NOT blocked by the libghostty cursor-move ceiling. Revert-to-confirm-fail:
    /// before the `f` case was added to `handleCopyModeKey`, `f` hit `default: break` and was swallowed, so
    /// `hintMode` stayed `nil` and the targets/labels were never populated — every assert below fails.
    func testCopyModeFKeyEntersHintMode() {
        let model = makeModel()
        XCTAssertNil(model.hintMode, "fresh pane is not in hint mode")

        model.handleCopyModeKey(.char("f", control: false, shift: false))

        XCTAssertEqual(model.hintMode, .open, "vi `f` arms Hint Mode with the open intent")
        XCTAssertEqual(model.hintTargets.count, 2, "both viewport link targets are detected")
        XCTAssertEqual(model.hintLabels.count, 2, "each target gets a label")
    }

    /// Belt-and-braces: `f` over a pane on the ALT screen (a TUI) is a clean no-op — `beginHint` guards on the
    /// alt screen so `f` never fights a full-screen app. Confirms the `f` case routes through the SAME guarded
    /// seam (not a bypass that would arm an empty mode).
    func testCopyModeFKeyIsNoOpOnAltScreen() {
        let model = makeModel()
        model.ingestOutput(Data("\u{1B}[?1049h".utf8)) // DECSET 1049 → enter the alternate screen
        XCTAssertTrue(model.isAlternateScreen, "the DECSET sequence parks the pane on the alt screen")
        model.handleCopyModeKey(.char("f", control: false, shift: false))
        XCTAssertNil(model.hintMode, "`f` does not arm Hint Mode while on the alt screen")
    }
}
