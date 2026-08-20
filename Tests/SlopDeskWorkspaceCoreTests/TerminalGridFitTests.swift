import CoreGraphics
import Foundation
import SlopDeskProtocol
import SlopDeskTerminal
import XCTest

/// A phone shows a grid it did not choose (docs/45 §8.3): iOS is size-passive HOST-side, so the
/// resolved grid is whatever the Macs on the pane folded to, and the phone's job is to place it
/// honestly rather than reflow it.
///
/// Both halves are pure values so they carry the tests the iOS view itself cannot: `check-ios.sh`
/// proves the SwiftUI path type-checks under the iOS triple, and these prove it places the right
/// rectangle and says the right thing.
final class TerminalGridFitTests: XCTestCase {
    // MARK: - The letterbox

    /// A grid too wide for the container shrinks to fit and centres, leaving equal bars. The scale
    /// is the WIDTH ratio because that is the tighter constraint.
    func testAGridWiderThanTheContainerShrinksAndCentres() throws {
        let fit = try XCTUnwrap(TerminalLetterbox.fit(
            cols: 120, rows: 40,
            cellWidth: 8, cellHeight: 16,
            in: CGSize(width: 480, height: 1280),
        ))
        // natural 960×640; width ratio 0.5, height ratio 2 → 0.5 wins.
        XCTAssertEqual(fit.scale, 0.5, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.width, 480, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.height, 320, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.origin.y, 480, accuracy: 1e-9, "centred: (1280 − 320) / 2")
        XCTAssertTrue(fit.isLetterboxed)
    }

    /// A grid SMALLER than the container is NOT magnified. The renderer draws at its natural cell
    /// size and the remainder is bars — blowing a terminal up past its cell metrics is blur, and a
    /// scaled-up glyph grid is exactly the thing a coding tool must not ship.
    func testASmallGridIsCentredRatherThanMagnified() throws {
        let fit = try XCTUnwrap(TerminalLetterbox.fit(
            cols: 40, rows: 12,
            cellWidth: 8, cellHeight: 16,
            in: CGSize(width: 800, height: 600),
        ))
        XCTAssertEqual(fit.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.width, 320, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.height, 192, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.origin.x, 240, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.origin.y, 204, accuracy: 1e-9)
        XCTAssertTrue(fit.isLetterboxed, "bars on all four sides")
    }

    /// An exact fit has no bars — the letterbox must not draw one for a pane that is already right,
    /// or every Mac pane would gain a hairline it did not ask for.
    func testAnExactFitIsNotLetterboxed() throws {
        let fit = try XCTUnwrap(TerminalLetterbox.fit(
            cols: 100, rows: 30,
            cellWidth: 8, cellHeight: 16,
            in: CGSize(width: 800, height: 480),
        ))
        XCTAssertEqual(fit.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect, CGRect(x: 0, y: 0, width: 800, height: 480))
        XCTAssertFalse(fit.isLetterboxed)
    }

    /// Degenerate inputs place NOTHING rather than a zero-area or infinite rect: a pre-layout pass,
    /// a headless surface with no cell metrics, and a pane whose grid the host has not resolved all
    /// arrive here, and the honest answer is "render as you always did".
    func testDegenerateInputsPlaceNothing() {
        let container = CGSize(width: 480, height: 800)
        XCTAssertNil(TerminalLetterbox.fit(cols: 0, rows: 40, cellWidth: 8, cellHeight: 16, in: container))
        XCTAssertNil(TerminalLetterbox.fit(cols: 120, rows: 0, cellWidth: 8, cellHeight: 16, in: container))
        XCTAssertNil(TerminalLetterbox.fit(cols: 120, rows: 40, cellWidth: 0, cellHeight: 16, in: container))
        XCTAssertNil(TerminalLetterbox.fit(cols: 120, rows: 40, cellWidth: 8, cellHeight: 0, in: container))
        XCTAssertNil(TerminalLetterbox.fit(
            cols: 120, rows: 40, cellWidth: 8, cellHeight: 16, in: CGSize(width: 0, height: 800),
        ))
        XCTAssertNil(TerminalLetterbox.fit(
            cols: 120, rows: 40, cellWidth: 8, cellHeight: 16, in: CGSize(width: 480, height: 0),
        ))
    }

    // MARK: - The readout

    private func attachment(_ id: UUID, cols: UInt16, rows: UInt16, contributes: Bool = true)
        -> WorkspaceRosterPane.Attachment
    {
        WorkspaceRosterPane.Attachment(
            clientInstanceID: id, contributes: contributes, cols: cols, rows: rows,
        )
    }

    /// §8.3 rule 7's readout, verbatim: the grid, and who clamped it there. Without it a phone shows
    /// a pane that is the wrong size for no stated reason.
    func testTheReadoutNamesTheContributorThatClampedTheGrid() {
        let mac = UUID()
        let phone = UUID()
        let pane = WorkspaceRosterPane(
            paneID: UUID(), resolvedCols: 120, resolvedRows: 40,
            attachments: [
                attachment(mac, cols: 120, rows: 40),
                attachment(phone, cols: 60, rows: 20, contributes: false),
            ],
        )
        XCTAssertEqual(
            TerminalGridReadout.text(
                for: pane, labels: [mac: "MacBook Pro", phone: "iPhone"], selfClientInstanceID: phone,
            ),
            "120×40 · sized by MacBook Pro",
        )
    }

    /// The client that IS clamping needs no explanation — it chose the grid. Naming yourself reads
    /// as a bug report about your own window.
    func testTheClampingClientIsToldOnlyTheGrid() {
        let mac = UUID()
        let pane = WorkspaceRosterPane(
            paneID: UUID(), resolvedCols: 120, resolvedRows: 40,
            attachments: [attachment(mac, cols: 120, rows: 40)],
        )
        XCTAssertEqual(
            TerminalGridReadout.text(for: pane, labels: [mac: "mac-studio"], selfClientInstanceID: mac),
            "120×40",
        )
    }

    /// A contributor with no roster label is the `slopdesk-client` CLI — the join legitimately
    /// misses. It still gets named, neutrally: "somebody else sized this" is the useful half, and
    /// dropping the whole suffix would make the clamp look like it came from nowhere.
    func testAnUnlabelledContributorIsNamedNeutrally() {
        let cli = UUID()
        let pane = WorkspaceRosterPane(
            paneID: UUID(), resolvedCols: 80, resolvedRows: 24,
            attachments: [attachment(cli, cols: 80, rows: 24)],
        )
        XCTAssertEqual(
            TerminalGridReadout.text(for: pane, labels: [:], selfClientInstanceID: UUID()),
            "80×24 · sized by another client",
        )
    }

    /// Nobody's standing offer matches the resolved grid — a ctl-spawned pane, or one that kept its
    /// last size after its contributors left (§8.3 rule 4). The grid is still worth saying; the
    /// attribution is not, because there is none.
    func testNoMatchingContributorReadsAsTheGridAlone() {
        let pane = WorkspaceRosterPane(
            paneID: UUID(), resolvedCols: 80, resolvedRows: 24, attachments: [],
        )
        XCTAssertEqual(
            TerminalGridReadout.text(for: pane, labels: [:], selfClientInstanceID: UUID()), "80×24",
        )
    }

    /// A pane the host has not resolved (0×0) says nothing at all rather than "0×0".
    func testAnUnresolvedGridSaysNothing() {
        let pane = WorkspaceRosterPane(
            paneID: UUID(), resolvedCols: 0, resolvedRows: 0, attachments: [],
        )
        XCTAssertNil(TerminalGridReadout.text(for: pane, labels: [:], selfClientInstanceID: UUID()))
    }

    /// Two contributors folded to the same grid: the readout picks ONE and stays picked. A readout
    /// that reordered on every roster frame would flicker between two names.
    func testTiedContributorsResolveDeterministically() throws {
        let a = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"))
        let b = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000BB"))
        let pane = WorkspaceRosterPane(
            paneID: UUID(), resolvedCols: 100, resolvedRows: 30,
            attachments: [attachment(b, cols: 100, rows: 30), attachment(a, cols: 100, rows: 30)],
        )
        let readout = TerminalGridReadout.text(
            for: pane, labels: [a: "alpha", b: "beta"], selfClientInstanceID: UUID(),
        )
        XCTAssertEqual(readout, "100×30 · sized by beta", "the roster's own order decides, once")
    }
}
