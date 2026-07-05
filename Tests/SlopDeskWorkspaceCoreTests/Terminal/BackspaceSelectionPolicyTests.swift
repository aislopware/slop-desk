import XCTest
@testable import SlopDeskWorkspaceCore

/// E8 WI-10 (I7, ES-E8-2): pins the pure ``BackspaceSelectionPolicy`` — the testable heart of the
/// "Backspace deletes selection" feature. The GUI surface (`GhosttyTerminalView`, compile-only behind
/// `#if canImport(CGhostty)`) is a thin actuator that applies the DEL-count / fallback per the documented
/// geometry ceiling, so the 3-way decision (incl. the prompt-zone + alt-screen gates) is pinned here.
///
/// None of these assertions is tautological — they encode the spec's gate ORDER + safe defaults, not the
/// function's own derivation. A naive implementation that ignored a gate fails a specific case: e.g. one
/// that always deletes when there is a selection fails ``testAltScreenForwardsEvenWithSelectionAndSetting``
/// (the vim passthrough) and ``testFeatureOffForwards``; one that drops the prompt-zone gate fails
/// ``testSettingOnPrimaryButOffPromptClearsThenSingle``.
final class BackspaceSelectionPolicyTests: XCTestCase {
    /// No selection → always an ordinary Backspace, regardless of every other input. (Sweeps the other
    /// three booleans so a regression that special-cased a no-selection Backspace anywhere fails here.)
    func testNoSelectionAlwaysForwards() {
        for setting in [true, false] {
            for alt in [true, false] {
                for prompt in [true, false] {
                    XCTAssertEqual(
                        BackspaceSelectionPolicy.action(
                            hasSelection: false,
                            setting: setting,
                            isAlternateScreen: alt,
                            isPromptZone: prompt,
                        ),
                        .forward,
                        "no selection must forward (setting=\(setting) alt=\(alt) prompt=\(prompt))",
                    )
                }
            }
        }
    }

    /// Feature OFF + a selection at the prompt → ordinary Backspace (libghostty's clear-on-typing clears the
    /// highlight; the policy adds nothing). The guard that distinguishes "feature off" from the delete path.
    func testFeatureOffForwards() {
        XCTAssertEqual(
            BackspaceSelectionPolicy.action(
                hasSelection: true,
                setting: false,
                isAlternateScreen: false,
                isPromptZone: true,
            ),
            .forward,
        )
    }

    /// The headline feature: selection + setting on + primary screen + editable prompt → delete the whole run.
    func testSettingOnAtPromptDeletesSelection() {
        XCTAssertEqual(
            BackspaceSelectionPolicy.action(
                hasSelection: true,
                setting: true,
                isAlternateScreen: false,
                isPromptZone: true,
            ),
            .deleteSelection,
        )
    }

    /// The vim/TUI passthrough (ES-E8-2): even with a selection AND the feature on, a full-screen / foreground
    /// program owning the screen must get the Backspace itself — NEVER delete the selection. The alt-screen
    /// gate takes precedence over the prompt-zone value (a TUI is `.running`, so prompt would be false anyway,
    /// but the gate is asserted independent of it here).
    func testAltScreenForwardsEvenWithSelectionAndSetting() {
        for prompt in [true, false] {
            XCTAssertEqual(
                BackspaceSelectionPolicy.action(
                    hasSelection: true,
                    setting: true,
                    isAlternateScreen: true,
                    isPromptZone: prompt,
                ),
                .forward,
                "alt-screen must forward (prompt=\(prompt))",
            )
        }
    }

    /// Setting on + selection + primary screen but NOT at the editable prompt (e.g. a disconnected pane, or a
    /// non-alt foreground state) → the safe fallback: clear the selection + a single Backspace. A wrong
    /// implementation that dropped the prompt-zone gate would return `.deleteSelection` here and fire DEL bytes
    /// where they can't faithfully map to the selection — exactly what the fallback prevents.
    func testSettingOnPrimaryButOffPromptClearsThenSingle() {
        XCTAssertEqual(
            BackspaceSelectionPolicy.action(
                hasSelection: true,
                setting: true,
                isAlternateScreen: false,
                isPromptZone: false,
            ),
            .clearThenSingle,
        )
    }

    /// Exhaustive truth table over all 16 (hasSelection, setting, isAlternateScreen, isPromptZone) combos —
    /// the single source of truth for the gate order, so any future refactor that reshuffles the guards is
    /// caught against the spec, not against the implementation's own derivation.
    func testFullTruthTable() {
        func expected(_ hasSelection: Bool, _ setting: Bool, _ alt: Bool, _ prompt: Bool) -> BackspaceAction {
            if !hasSelection { return .forward }
            if !setting { return .forward }
            if alt { return .forward }
            return prompt ? .deleteSelection : .clearThenSingle
        }
        for hasSelection in [true, false] {
            for setting in [true, false] {
                for alt in [true, false] {
                    for prompt in [true, false] {
                        XCTAssertEqual(
                            BackspaceSelectionPolicy.action(
                                hasSelection: hasSelection,
                                setting: setting,
                                isAlternateScreen: alt,
                                isPromptZone: prompt,
                            ),
                            expected(hasSelection, setting, alt, prompt),
                            "case hasSelection=\(hasSelection) setting=\(setting) alt=\(alt) prompt=\(prompt)",
                        )
                    }
                }
            }
        }
    }

    // MARK: - leadingDeleteCount: the geometry-ceiling data-loss guard (ES-E8-2)

    /// THE data-loss fix: the GUI cannot prove a selection ends at the cursor against the pinned libghostty
    /// fork (no cursor-geometry API), so it calls `leadingDeleteCount(…, selectionEndsAtCursor: false)`.
    /// That MUST return 0 — pre-sending DEL bytes for a run that does not end at the cursor (a word selected
    /// in the MIDDLE of a typed command) would erase the WRONG characters. A naive implementation that
    /// ignored `selectionEndsAtCursor` and always returned `count − 1` for a single line (the old optimistic
    /// actuation) returns 9 here and fails — the revert-to-confirm-fail oracle for this bug.
    func testUnprovenSelectionPreSendsNothing() {
        XCTAssertEqual(
            BackspaceSelectionPolicy.leadingDeleteCount(selection: "rm -rf foo", selectionEndsAtCursor: false),
            0,
        )
    }

    /// The faithful future path (dormant until a libghostty geometry API can prove the trailing run): a
    /// single-line run KNOWN to end at the cursor pre-sends `count − 1` leading DELs, so `count` DEL total
    /// (with the fall-through Backspace) erases the whole run.
    func testProvenTrailingSelectionPreSendsCountMinusOne() {
        XCTAssertEqual(
            BackspaceSelectionPolicy.leadingDeleteCount(selection: "foo", selectionEndsAtCursor: true),
            2,
        )
    }

    /// A multi-line selection can't map to a contiguous DEL run → 0, even when proven to end at the cursor.
    func testMultiLineSelectionPreSendsNothing() {
        XCTAssertEqual(
            BackspaceSelectionPolicy.leadingDeleteCount(selection: "a\nb", selectionEndsAtCursor: true),
            0,
        )
        XCTAssertEqual(
            BackspaceSelectionPolicy.leadingDeleteCount(selection: "a\rb", selectionEndsAtCursor: true),
            0,
        )
    }

    /// An empty selection → 0 (no run to erase), regardless of the proof flag.
    func testEmptySelectionPreSendsNothing() {
        for proven in [true, false] {
            XCTAssertEqual(
                BackspaceSelectionPolicy.leadingDeleteCount(selection: "", selectionEndsAtCursor: proven),
                0,
            )
        }
    }

    /// A single-character proven run pre-sends 0 leading DELs — the lone fall-through Backspace erases it.
    func testSingleCharProvenSelectionPreSendsNothing() {
        XCTAssertEqual(
            BackspaceSelectionPolicy.leadingDeleteCount(selection: "x", selectionEndsAtCursor: true),
            0,
        )
    }
}
