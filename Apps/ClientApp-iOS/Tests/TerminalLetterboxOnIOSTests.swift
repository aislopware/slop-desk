import CoreGraphics
import SlopDeskTerminal
import XCTest

/// The letterbox, at the geometry it exists for (docs/45 §8.3 rule 7).
///
/// `TerminalLetterbox` is a pure value so its arithmetic can be tested anywhere, and
/// `Tests/SlopDeskWorkspaceCoreTests/TerminalGridFitTests` does that. What only the iOS triple can say is
/// that the numbers a PHONE actually feeds it produce a letterbox rather than a degenerate rect — the
/// only caller is inside `#if os(iOS)` and is compiled by nothing else.
///
/// Deliberately named by PLATFORM rather than by caller: the SwiftUI `TerminalLetterboxContainer` this
/// header used to name was deleted in the UIKit rebuild and the arithmetic did not move, so a header
/// pinned to a view's name went stale while every assertion below stayed correct.
final class TerminalLetterboxOnIOSTests: XCTestCase {
    /// An iPhone 17 Pro's pane, in POINTS, portrait, minus the status/home insets. The exact figure
    /// does not matter — that it is far narrower than a Mac's 120-column grid is the whole point.
    private let phonePane = CGSize(width: 402, height: 780)
    /// A 13″ monospace cell at the app's default size. Also points.
    private let cell = CGSize(width: 8.4, height: 17.0)

    /// A Mac's grid on a phone's pane SHRINKS and centres — it is never cropped and never magnified.
    func testAMacsGridOnAPhoneShrinksAndCentres() throws {
        let fit = try XCTUnwrap(TerminalLetterbox.fit(
            cols: 120, rows: 40, cellWidth: cell.width, cellHeight: cell.height, in: phonePane,
        ))
        XCTAssertLessThan(fit.scale, 1, "120 columns do not fit a phone at natural metrics")
        XCTAssertGreaterThan(fit.scale, 0)
        XCTAssertTrue(fit.isLetterboxed, "…so there are bars, and the caption has somewhere to sit")
        XCTAssertLessThanOrEqual(fit.contentRect.width, phonePane.width + 0.001)
        XCTAssertLessThanOrEqual(fit.contentRect.height, phonePane.height + 0.001)
        // Centred: the two margins match on each axis.
        XCTAssertEqual(
            fit.contentRect.minX, phonePane.width - fit.contentRect.maxX, accuracy: 0.001,
        )
        XCTAssertEqual(
            fit.contentRect.minY, phonePane.height - fit.contentRect.maxY, accuracy: 0.001,
        )
    }

    /// A grid SMALLER than the phone's pane is centred at natural metrics, never blown up. Magnifying
    /// a glyph grid is blur, and the point of a coding tool is that the text is exact.
    func testASmallGridIsNeverMagnifiedOnAPhone() throws {
        let fit = try XCTUnwrap(TerminalLetterbox.fit(
            cols: 20, rows: 5, cellWidth: cell.width, cellHeight: cell.height, in: phonePane,
        ))
        XCTAssertEqual(fit.scale, 1, "shrink-to-fit, never magnify")
        XCTAssertEqual(fit.contentRect.width, cell.width * 20, accuracy: 0.001)
        XCTAssertEqual(fit.contentRect.height, cell.height * 5, accuracy: 0.001)
    }
}
