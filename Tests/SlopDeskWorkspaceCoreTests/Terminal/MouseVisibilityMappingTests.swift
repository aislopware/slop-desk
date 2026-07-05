import XCTest
@testable import SlopDeskWorkspaceCore

/// E8 (H9, ES-E8-6): pins the pure ``MouseVisibilityMapping`` decision that the GUI surface
/// (`GhosttyTerminalView`, compile-only behind `#if canImport(CGhostty)`) uses to actuate
/// `mouse-hide-while-typing`. libghostty's `mouse-hide-while-typing` config only DECIDES to hide the
/// pointer; it delegates the hide/show to the embedder via a `GHOSTTY_ACTION_MOUSE_VISIBILITY` action, so
/// the embedder MUST read that action's enum and drive `NSCursor`. This pins the load-bearing enum read.
///
/// None of these assertions is tautological — they encode the `ghostty_action_mouse_visibility_e` C enum's
/// raw ordering and the explicit (non-`{0,1}`-assuming) read, not the function's own derivation.
final class MouseVisibilityMappingTests: XCTestCase {
    /// The raw values MUST match the `ghostty_action_mouse_visibility_e` declaration order
    /// (`CGhostty/ghostty.h:709-713`), because the GUI hands us the C enum's integer payload directly.
    func testRawValuesMatchCEnumDeclarationOrder() {
        XCTAssertEqual(MouseVisibility.visible.rawValue, 0)
        XCTAssertEqual(MouseVisibility.hidden.rawValue, 1)
        // The C enum has exactly two cases; a new one must be added deliberately.
        XCTAssertEqual(MouseVisibility.allCases.count, 2)
    }

    /// The explicit `hidden` value hides; the explicit `visible` value shows.
    func testKnownValuesResolve() {
        XCTAssertFalse(MouseVisibilityMapping.isVisible(forRawValue: 1)) // hidden
        XCTAssertTrue(MouseVisibilityMapping.isVisible(forRawValue: 0)) // visible
    }

    /// {0,1}-ASSUMPTION GUARD (the core of this fix): the read compares against the `hidden` case, so any
    /// unknown / corrupt / future raw int FAILS SAFE to VISIBLE — a bad value can never strand the pointer
    /// permanently hidden. A naive `raw != 0` ("anything non-zero is hidden") read would FAIL these.
    func testUnknownValuesFailSafeToVisible() {
        XCTAssertTrue(MouseVisibilityMapping.isVisible(forRawValue: 2))
        XCTAssertTrue(MouseVisibilityMapping.isVisible(forRawValue: 7))
        XCTAssertTrue(MouseVisibilityMapping.isVisible(forRawValue: -1))
        XCTAssertTrue(MouseVisibilityMapping.isVisible(forRawValue: 9999))
    }
}
