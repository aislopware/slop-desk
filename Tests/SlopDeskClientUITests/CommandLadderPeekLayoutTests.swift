// CommandLadderPeekLayoutTests — pins where the ladder's hover-peek card opens. The card is placed
// from a DECLARED height rather than a measured one (a measured height would put it at the wrong y
// for one frame), so the height rule and the clamp are both solvable — and pinned here.
//
// The clamp is the point: the newest tick sits at the very bottom of the rail, so a card centred on
// it would hang out of the island entirely. It must ride up instead.

import SlopDeskWorkspaceCore
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class CommandLadderPeekLayoutTests: XCTestCase {
    private let margin = Slate.Metric.ladderInset

    func testACardWithRoomOpensCentredOnItsTick() {
        let height = CommandLadderPeekLayout.cardHeight(lineCount: 8, hasFooter: true)
        let top = CommandLadderPeekLayout.cardTop(
            tickCenterY: 400, cardHeight: height, available: 800,
        )
        XCTAssertEqual(top + height / 2, 400, accuracy: 0.0001)
    }

    /// The newest tick is the one the eye reaches for, and it is the LAST one — a card centred on it
    /// would hang below the pane. It rides up to the margin instead.
    func testACardOpenedFromTheNewestTickRidesUpInsteadOfHangingOut() {
        let available: CGFloat = 800
        let height = CommandLadderPeekLayout.cardHeight(lineCount: 8, hasFooter: true)
        let top = CommandLadderPeekLayout.cardTop(
            tickCenterY: available - margin, cardHeight: height, available: available,
        )
        XCTAssertEqual(top + height, available - margin, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(top + height, available - margin)
    }

    func testACardOpenedFromTheOldestTickDropsInsteadOfHangingOut() {
        let height = CommandLadderPeekLayout.cardHeight(lineCount: 8, hasFooter: false)
        let top = CommandLadderPeekLayout.cardTop(
            tickCenterY: margin, cardHeight: height, available: 800,
        )
        XCTAssertEqual(top, margin, accuracy: 0.0001)
    }

    /// A short pane cannot hold the card at all — it pins to the top rather than splitting its
    /// overflow across both edges (where it would cover the pane's first row AND its last).
    func testACardTallerThanThePanePinsToTheTop() {
        let height = CommandLadderPeekLayout.cardHeight(lineCount: 8, hasFooter: true)
        let top = CommandLadderPeekLayout.cardTop(
            tickCenterY: 30, cardHeight: height, available: height,
        )
        XCTAssertEqual(top, margin, accuracy: 0.0001)
    }

    func testTheCardNeverLeavesThePaneAtAnyTickPosition() {
        let available: CGFloat = 600
        for lines in 1...8 {
            for footer in [false, true] {
                let height = CommandLadderPeekLayout.cardHeight(lineCount: lines, hasFooter: footer)
                for center in stride(from: 0.0, through: available, by: 7.0) {
                    let top = CommandLadderPeekLayout.cardTop(
                        tickCenterY: center, cardHeight: height, available: available,
                    )
                    XCTAssertGreaterThanOrEqual(top, margin - 0.0001)
                    XCTAssertLessThanOrEqual(top + height, available - margin + 0.0001)
                }
            }
        }
    }

    /// The height grows by exactly one row per excerpt line and one for the footer — the property the
    /// placement above rests on.
    func testHeightGrowsOneRowPerLine() {
        let one = CommandLadderPeekLayout.cardHeight(lineCount: 1, hasFooter: false)
        let two = CommandLadderPeekLayout.cardHeight(lineCount: 2, hasFooter: false)
        let twoWithFooter = CommandLadderPeekLayout.cardHeight(lineCount: 2, hasFooter: true)
        XCTAssertEqual(two - one, Slate.Metric.ladderPeekLine, accuracy: 0.0001)
        XCTAssertEqual(twoWithFooter - two, Slate.Metric.ladderPeekLine, accuracy: 0.0001)
    }

    /// One excerpt row of unstyled text — these pin the card's GEOMETRY, so the runs' styles are
    /// beside the point here.
    private func row(_ text: String) -> [AnsiRun] { [AnsiRun(text: text, style: .plain)] }

    /// Every entry state draws at least one row, so the card never collapses to a bare header while a
    /// fetch is in flight (a card that changes height as the reply lands reads as a glitch).
    func testEveryPeekStateDrawsAtLeastOneRow() {
        let states: [CommandLadderPeekEntry] = [
            .loading,
            .unavailable,
            .ready(BlockOutputPreview(lines: [], hiddenCount: 0, fromTail: false)),
            .ready(BlockOutputPreview(lines: [row("a"), row("b")], hiddenCount: 4, fromTail: true)),
        ]
        for state in states { XCTAssertGreaterThanOrEqual(state.lineCount, 1) }
        XCTAssertFalse(CommandLadderPeekEntry.loading.hasFooter)
        XCTAssertTrue(
            CommandLadderPeekEntry
                .ready(BlockOutputPreview(lines: [row("a")], hiddenCount: 1, fromTail: false)).hasFooter,
        )
    }

    /// The dwell is what makes the peek a MODE rather than an accident: sweeping across the rail must
    /// not open anything, and the grace must be short enough that the mode never outlives the reading.
    func testTheDwellAndGraceAreTheDeclaredBeats() {
        XCTAssertEqual(CommandLadderPeekLayout.dwell, .seconds(1))
        XCTAssertEqual(CommandLadderPeekLayout.grace, .milliseconds(400))
        XCTAssertLessThan(CommandLadderPeekLayout.grace, CommandLadderPeekLayout.dwell)
    }
}
