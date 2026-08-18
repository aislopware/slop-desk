import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING behind "Undo at prompt": three flags out in the right slots, and the door's `-1`
/// refusal read back as `nil` rather than as a byte. The rule itself — the prompt-zone gate, the redo
/// omission, the choice of control code — is `slopdesk_terminal::surface::prompt_edit_byte`'s, and its
/// truth table is tested there rather than mirrored here.
final class PromptEditPolicyTests: XCTestCase {
    /// Each flag reaches its own parameter: only the (undo, in-prompt) corner emits, and the two ways to
    /// refuse — off the prompt, and a redo — both come back as no bytes rather than as byte `0` or `255`.
    func testEachFlagLandsInItsOwnSlot() {
        XCTAssertEqual(PromptEditPolicy.bytes(forUndo: true, redo: false, inPromptZone: true), [0x1F])
        XCTAssertNil(PromptEditPolicy.bytes(forUndo: true, redo: false, inPromptZone: false))
        XCTAssertNil(PromptEditPolicy.bytes(forUndo: false, redo: true, inPromptZone: true))
        XCTAssertNil(PromptEditPolicy.bytes(forUndo: false, redo: false, inPromptZone: true))
    }

    /// The emitted byte is the readline Ctrl-`_` control code, derived independently from the underscore's
    /// ASCII value (`0x5F & 0x1F == 0x1F`) — so the literal the door returns is tied to the Ctrl-`_`
    /// semantics rather than to itself.
    func testUndoByteIsControlUnderscore() {
        let underscore = Character("_").asciiValue
        XCTAssertEqual(underscore, 0x5F)
        let ctrlUnderscore = (underscore ?? 0) & 0x1F
        XCTAssertEqual(PromptEditPolicy.bytes(forUndo: true, redo: false, inPromptZone: true), [ctrlUnderscore])
    }
}
