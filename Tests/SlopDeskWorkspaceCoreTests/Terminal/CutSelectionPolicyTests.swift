import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the pure ``CutSelectionPolicy`` — the testable heart of the terminal's Cut (⌘X). The GUI surface
/// (`GhosttyTerminalView`, compile-only behind `#if canImport(CGhostty)`) is a thin actuator: it always
/// performs `copy_to_clipboard` for a non-`.none` decision and on `.copyAndDelete` sends the
/// geometry-ceiling DEL count.
///
/// These assertions encode the spec's gate ORDER + safe defaults, not the function's own derivation: an
/// implementation that always deleted when there is a selection fails ``testAltScreenCopyOnly`` (a
/// full-screen program's input would be corrupted) and ``testReadOnlyScrollbackCopyOnly`` (read-only
/// fallback); one that never copied fails ``testNoSelectionIsNone`` boundary / the copy paths.
final class CutSelectionPolicyTests: XCTestCase {
    /// No selection → `.none`, regardless of every other input (⌘X has nothing to cut).
    func testNoSelectionIsNone() {
        for alt in [true, false] {
            for prompt in [true, false] {
                XCTAssertEqual(
                    CutSelectionPolicy.action(hasSelection: false, isAlternateScreen: alt, isPromptZone: prompt),
                    .none,
                    "no selection must be .none (alt=\(alt) prompt=\(prompt))",
                )
            }
        }
    }

    /// The headline feature: a selection at an editable prompt (primary screen) → copy AND delete.
    func testEditablePromptCopiesAndDeletes() {
        XCTAssertEqual(
            CutSelectionPolicy.action(hasSelection: true, isAlternateScreen: false, isPromptZone: true),
            .copyAndDelete,
        )
    }

    /// A full-screen / foreground program owns the screen → copy only, NEVER delete (the program's input
    /// must not get stray DEL bytes). Even if `isPromptZone` is somehow also set, the alt-screen gate wins.
    func testAltScreenCopyOnly() {
        XCTAssertEqual(
            CutSelectionPolicy.action(hasSelection: true, isAlternateScreen: true, isPromptZone: false),
            .copyOnly,
        )
        XCTAssertEqual(
            CutSelectionPolicy.action(hasSelection: true, isAlternateScreen: true, isPromptZone: true),
            .copyOnly,
            "alt-screen must win over a (contradictory) prompt-zone input",
        )
    }

    /// Read-only scrollback (selection, primary screen, NOT at the prompt) → copy only (the spec's fallback).
    func testReadOnlyScrollbackCopyOnly() {
        XCTAssertEqual(
            CutSelectionPolicy.action(hasSelection: true, isAlternateScreen: false, isPromptZone: false),
            .copyOnly,
        )
    }

    // MARK: deleteCount — the geometry ceiling

    /// The pinned-fork reality: the embedder cannot prove the run ends at the cursor, so it passes `false`
    /// and NO DEL bytes are sent — the cut degrades to copy-only (no wrong-character data loss).
    func testDeleteCountZeroWhenCannotProveEndsAtCursor() {
        XCTAssertEqual(CutSelectionPolicy.deleteCount(selection: "abc", selectionEndsAtCursor: false), 0)
    }

    /// When the run CAN be proven to end at the cursor (a future libghostty geometry API), the FULL selection
    /// length is sent (not `count - 1` — Cut has no fall-through Backspace key, unlike backspace-deletes).
    func testDeleteCountFullLengthWhenProvable() {
        XCTAssertEqual(CutSelectionPolicy.deleteCount(selection: "abc", selectionEndsAtCursor: true), 3)
    }

    /// Multi-line / empty selections can't map to a contiguous DEL run → 0 even when provably trailing.
    func testDeleteCountZeroForMultilineOrEmpty() {
        XCTAssertEqual(CutSelectionPolicy.deleteCount(selection: "a\nb", selectionEndsAtCursor: true), 0)
        XCTAssertEqual(CutSelectionPolicy.deleteCount(selection: "a\rb", selectionEndsAtCursor: true), 0)
        XCTAssertEqual(CutSelectionPolicy.deleteCount(selection: "", selectionEndsAtCursor: true), 0)
    }
}
