#if os(macOS)
import CSlopDeskFFI
import XCTest
@testable import SlopDeskVideoHost

/// The `CGVirtualDisplay*` existence gate (finding #41). Pure runtime check —
/// `objc2::runtime::AnyClass::get` on the far side, no CoreGraphics IPC, NEVER instantiates a
/// display (hang-safety). On every macOS this repo currently targets the four private classes are
/// present, so the gate must read `true`; a `false` here would silently wedge every VD-enabled host
/// onto the 1× fallback even on a fully capable OS, which would be its own regression.
///
/// NOT `@MainActor`: the gate is a class lookup, answerable from any thread, and the face that
/// carries it is no longer main-actor bound.
final class VirtualDisplayPrivateClassGateTests: XCTestCase {
    func testPrivateClassesAvailableOnCurrentOS() {
        XCTAssertTrue(
            VirtualDisplay.privateClassesAvailable,
            "the four private CGVirtualDisplay* classes must resolve on a supported macOS — "
                + "if this fails on a real OS bump, the VD feature correctly (but silently) degrades to 1×",
        )
    }

    /// The Swift property is a FACE over the door and nothing else — one lookup, cached for the
    /// process lifetime on the far side. Asserting both keeps the face from growing a second opinion.
    func testTheFaceReportsExactlyWhatTheDoorDoes() {
        XCTAssertEqual(
            slopdesk_virtual_display_private_classes_available(), 1,
            "the door itself must resolve the classes on a supported macOS",
        )
        XCTAssertEqual(
            VirtualDisplay.privateClassesAvailable,
            slopdesk_virtual_display_private_classes_available() == 1,
            "the face may not decide anything the door has not",
        )
    }
}
#endif
