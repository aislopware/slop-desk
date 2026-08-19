import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins what is left on THIS side of the OSC-22 pointer-shape crossing: the ``PointerShapeToken``
/// discriminants.
///
/// The table itself — which of libghostty's thirty-four shapes has a native cursor, which nineteen keep
/// the current one, and that an unknown raw value behaves like an unsupported shape — is
/// `slopdesk_terminal::pointer`'s, tested there and through the door in `slopdesk-ffi`. Repeating it here
/// would be the mirror `CLAUDE.md` bans; what cannot be tested there is that Swift's enum receives the
/// number Rust sends, so that is what this asserts.
///
/// A case reordered in ``PointerShapeToken`` is a cursor silently swapped for another cursor: nothing
/// fails to compile, nothing crashes, and a resize handle starts showing a hand. These fifteen equalities
/// are the only thing standing between that edit and a shipped build.
final class PointerShapeMappingTests: XCTestCase {
    /// Every shape with a native `NSCursor`, by the raw `ghostty_action_mouse_shape_e` the GUI hands over.
    func testEverySupportedShapeArrivesAsItsToken() {
        let expected: [Int32: PointerShapeToken] = [
            0: .arrow, // default — the reset a full-screen program leaves behind
            1: .contextMenu,
            3: .pointer,
            7: .crosshair,
            8: .text,
            9: .verticalText,
            14: .notAllowed,
            15: .grab,
            16: .grabbing,
            20: .resizeUp, // n-resize
            21: .resizeRight, // e-resize
            22: .resizeDown, // s-resize
            23: .resizeLeft, // w-resize
            28: .resizeLeftRight, // ew-resize
            29: .resizeUpDown, // ns-resize
        ]
        for (raw, token) in expected {
            XCTAssertEqual(PointerShapeMapping.token(forRawValue: raw), token, "raw \(raw)")
        }
        XCTAssertEqual(expected.count, PointerShapeToken.allCases.count, "every token is reachable")
    }

    /// A shape upstream ignores and a value no libghostty emits both mean KEEP the current cursor, so the
    /// surface needs one branch rather than two.
    func testUnsupportedAndUnknownBothKeepTheCurrentCursor() {
        for raw: Int32 in [2, 4, 5, 6, 10, 11, 12, 13, 17, 18, 19, 24, 25, 26, 27, 30, 31, 32, 33] {
            XCTAssertNil(PointerShapeMapping.token(forRawValue: raw), "unsupported shape \(raw)")
        }
        for raw: Int32 in [-1, 34, 9999, .min, .max] {
            XCTAssertNil(PointerShapeMapping.token(forRawValue: raw), "unknown raw \(raw)")
        }
    }
}
