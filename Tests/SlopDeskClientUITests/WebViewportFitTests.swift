// WebViewportFitTests — the arithmetic that shapes the host's browser like the space DevTools gives
// its page. Pure: nothing here opens a socket or a web view.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class WebViewportFitTests: XCTestCase {
    func testAWideColumnIsMatchedOneToOne() {
        // Wide enough that the legibility floor never binds, so the viewport is exactly the column
        // minus what DevTools keeps for the device frame and its navigation bar.
        let size = WebViewportFit.viewportSize(column: CGSize(width: 744, height: 971))
        XCTAssertEqual(size?.width, 700)
        XCTAssertEqual(size?.height, 900)
    }

    func testTheWidthFloorIsPaidForInHEIGHT() {
        // A 176-point page is a column of wrapped characters, not a site. Taking the floor without
        // stretching the height to match would hand back a shape that is not the column's, and the
        // empty band the whole exercise removes would come straight back.
        let column = CGSize(width: 220, height: 900)
        guard let size = WebViewportFit.viewportSize(column: column) else {
            XCTFail("expected a fit")
            return
        }
        XCTAssertEqual(size.width, WebViewportFit.minimumViewportWidth)
        let usable = CGSize(width: 220 - 44, height: 900 - 71)
        XCTAssertEqual(
            size.height / size.width, usable.height / usable.width, accuracy: 0.01,
            "the viewport's aspect is the column's",
        )
    }

    func testAColumnTooSmallToBeAPageIsNotFitted() {
        // A collapsed panel, or a frontend measured before it has laid out. Overriding the page to
        // one of those leaves it absurd once the panel opens again — and an override the panel set
        // is one no later session can clear.
        XCTAssertNil(WebViewportFit.viewportSize(column: CGSize(width: 40, height: 900)))
        XCTAssertNil(WebViewportFit.viewportSize(column: CGSize(width: 220, height: 60)))
        XCTAssertNil(WebViewportFit.viewportSize(column: .zero))
    }

    func testJitterIsNotAResize() {
        let fitted = CGSize(width: 220, height: 900)
        XCTAssertFalse(WebViewportFit.isWorthRefitting(CGSize(width: 226, height: 908), fitted: fitted))
        XCTAssertTrue(WebViewportFit.isWorthRefitting(CGSize(width: 240, height: 900), fitted: fitted))
        XCTAssertTrue(WebViewportFit.isWorthRefitting(CGSize(width: 220, height: 940), fitted: fitted))
        XCTAssertTrue(WebViewportFit.isWorthRefitting(fitted, fitted: .zero), "the first fit always runs")
    }
}
#endif
