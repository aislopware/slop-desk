import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the pure ``PromptEditPolicy`` — the testable heart of "Undo at prompt". The
/// GUI surface (`GhosttyTerminalView`, compile-only behind `#if canImport(CGhostty)`) is a thin actuator that
/// maps the NSEvent → the (undo, redo) flags and sends the returned bytes, so the decision (incl. the
/// prompt-zone gate and the redo omission) is pinned here.
///
/// None of these assertions is tautological — they encode the spec's behaviour, not the function's own
/// derivation: undo → the readline Ctrl-`_` control code (independently derived from the underscore's ASCII
/// value), redo → nothing (the documented omit), and the prompt-zone gate that keeps ⌘Z out of `vim`.
final class PromptEditPolicyTests: XCTestCase {
    /// The headline feature: ⌘Z at the editable prompt emits the readline undo byte (Ctrl-`_`, `0x1F`).
    func testUndoInPromptZoneEmitsReadlineUndo() {
        XCTAssertEqual(
            PromptEditPolicy.bytes(forUndo: true, redo: false, inPromptZone: true),
            [0x1F],
        )
    }

    /// The "⌘Z in vim passes through" leg: off the editable prompt (a full-screen program owns the screen, or
    /// the pane is mid-command / disconnected) an undo gesture produces NO bytes — the chord falls through and
    /// the foreground program keeps its own undo. A wrong implementation that dropped the gate would emit the
    /// undo byte here and corrupt the program's input.
    func testUndoOutsidePromptZoneForwards() {
        XCTAssertNil(PromptEditPolicy.bytes(forUndo: true, redo: false, inPromptZone: false))
    }

    /// Redo is a DOCUMENTED OMIT (no portable readline redo): even at the prompt, ⌘⇧Z / ⌘Y produces no bytes.
    /// A naive implementation that aliased redo to undo would return `[0x1F]` here and fail.
    func testRedoIsOmittedInPromptZone() {
        XCTAssertNil(PromptEditPolicy.bytes(forUndo: false, redo: true, inPromptZone: true))
    }

    /// Redo off the prompt is likewise nothing.
    func testRedoOutsidePromptZoneForwards() {
        XCTAssertNil(PromptEditPolicy.bytes(forUndo: false, redo: true, inPromptZone: false))
    }

    /// Neither intent (a defensive call with both flags false) → nothing, regardless of the zone.
    func testNeitherIntentForwards() {
        for prompt in [true, false] {
            XCTAssertNil(
                PromptEditPolicy.bytes(forUndo: false, redo: false, inPromptZone: prompt),
                "neither undo nor redo must forward (prompt=\(prompt))",
            )
        }
    }

    /// The emitted byte is the readline Ctrl-`_` control code, derived independently from the underscore's
    /// ASCII value (`0x5F & 0x1F == 0x1F`) — so the magic number is tied to the Ctrl-`_` semantics, not to
    /// its own literal.
    func testUndoByteIsControlUnderscore() {
        let underscore = Character("_").asciiValue
        XCTAssertEqual(underscore, 0x5F)
        let ctrlUnderscore = (underscore ?? 0) & 0x1F
        XCTAssertEqual(PromptEditPolicy.readlineUndo, ctrlUnderscore)
        XCTAssertEqual(PromptEditPolicy.bytes(forUndo: true, redo: false, inPromptZone: true), [ctrlUnderscore])
    }

    /// Exhaustive truth table over all (undo, redo, inPromptZone) combos — the single source of truth for the
    /// gate, so a future refactor that reshuffles it is caught against the spec, not the implementation.
    func testFullTruthTable() {
        func expected(_ undo: Bool, _ redo: Bool, _ prompt: Bool) -> [UInt8]? {
            guard prompt else { return nil }
            if redo { return nil }
            return undo ? [0x1F] : nil
        }
        for undo in [true, false] {
            for redo in [true, false] {
                for prompt in [true, false] {
                    XCTAssertEqual(
                        PromptEditPolicy.bytes(forUndo: undo, redo: redo, inPromptZone: prompt),
                        expected(undo, redo, prompt),
                        "case undo=\(undo) redo=\(redo) prompt=\(prompt)",
                    )
                }
            }
        }
    }
}
