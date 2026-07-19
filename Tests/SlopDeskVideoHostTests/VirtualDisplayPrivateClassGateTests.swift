#if os(macOS)
import XCTest
@testable import SlopDeskVideoHost

/// The weak-linked `CGVirtualDisplay*` existence gate (finding #41). Pure runtime check —
/// `NSClassFromString` only, no CoreGraphics IPC, NEVER instantiates a display (hang-safety). On
/// every macOS this repo currently targets the four private classes are present, so the gate must
/// read `true`; a `false` here would silently wedge every VD-enabled host onto the 1× fallback
/// even on a fully capable OS, which would be its own regression.
final class VirtualDisplayPrivateClassGateTests: XCTestCase {
    @MainActor
    func testPrivateClassesAvailableOnCurrentOS() {
        XCTAssertTrue(
            VirtualDisplay.privateClassesAvailable,
            "the four private CGVirtualDisplay* classes must resolve on a supported macOS — "
                + "if this fails on a real OS bump, the VD feature correctly (but silently) degrades to 1×",
        )
    }
}
#endif
