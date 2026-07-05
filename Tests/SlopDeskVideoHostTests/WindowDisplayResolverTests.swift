#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskVideoHost

/// The PURE display-pick math behind the host-window-resize feature (2026-06-30): pick the display a
/// window sits on so the host can report its point-size MAX (the `displayMax` popover cap) and re-anchor
/// the window at the display ORIGIN before an AX resize. CG global points throughout.
final class WindowDisplayResolverTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondary = CGRect(x: 1920, y: 0, width: 3840, height: 2160) // a larger 1× external to the right

    func testPicksDisplayContainingWindowCentre() {
        // A window wholly inside the main display resolves to it.
        let win = CGRect(x: 200, y: 150, width: 800, height: 600)
        XCTAssertEqual(WindowDisplayResolver.display(forWindowFrame: win, displays: [main, secondary]), main)
        // A window on the secondary display resolves to the secondary (its centre is at x≈2920).
        let onSecondary = CGRect(x: 2400, y: 300, width: 1040, height: 700)
        XCTAssertEqual(
            WindowDisplayResolver.display(forWindowFrame: onSecondary, displays: [main, secondary]),
            secondary,
        )
    }

    func testStraddlingWindowResolvesByCentreNotCorner() {
        // A window mostly on the main display with a sliver overhanging the secondary: centre (x≈940) is on
        // the main display, so it resolves to main even though its right edge crosses the boundary.
        let straddling = CGRect(x: 540, y: 100, width: 1600, height: 900)
        XCTAssertEqual(WindowDisplayResolver.display(forWindowFrame: straddling, displays: [main, secondary]), main)
    }

    func testWindowOffEveryDisplayFallsBackToLargest() {
        // A window whose centre lands in a gap between displays falls back to the LARGEST screen (so a resize
        // can still reach a sensible maximum) rather than nil/the first.
        let inGap = CGRect(x: 9000, y: 9000, width: 200, height: 200)
        XCTAssertEqual(
            WindowDisplayResolver.display(forWindowFrame: inGap, displays: [main, secondary]),
            secondary,
            "off-screen window falls back to the largest display by area",
        )
    }

    func testNoDisplaysReturnsNil() {
        let win = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(WindowDisplayResolver.display(forWindowFrame: win, displays: []))
    }
}
#endif
