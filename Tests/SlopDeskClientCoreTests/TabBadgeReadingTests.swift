// TabBadgeReadingTests — the WORD and the URGENCY a fused badge carries, below either UI.
//
// Split out of the view layer with docs/56 stage D. The colours stay up there
// (``StatusPresentation.attentionInk``); what is pinned here is the part no palette can supply — the
// word VoiceOver reads and which of the three attention roles a state carries. Three surfaces read
// it (AppKit rows, SwiftUI rows, the collapsed strip), and a word spelled twice is a state read two
// ways on two devices.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

final class TabBadgeReadingTests: XCTestCase {
    // MARK: - The word

    /// Every kind has a word, and no two share one — a label is what the state is CALLED, and a
    /// duplicate would make two states indistinguishable to a reader who cannot see the hue.
    func testEveryKindHasItsOwnNonEmptyWord() {
        // Spelled out rather than `allCases` — `TabBadgeKind` is not `CaseIterable`, and a new state
        // that arrives without a line here is exactly the one worth noticing.
        let everyKind: [TabBadgeKind] = [
            .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
            .caffeinate, .sudo,
        ]
        var seen: Set<String> = []
        for kind in everyKind {
            let word = TabBadgeReading.label(kind)
            XCTAssertFalse(word.isEmpty, "\(kind) is spoken as nothing")
            XCTAssertTrue(seen.insert(word).inserted, "\(kind) reuses the word \"\(word)\"")
        }
    }

    // MARK: - The role

    /// BUSY IS NOT ATTENTION. A spinning agent, a loading command and a privileged shell are all
    /// saying "something is happening", not "someone is waiting on you" — the whole point of the
    /// attention set is that it stays small enough to mean something.
    func testBusyAndPrivilegedStatesCarryNoAttention() {
        for kind in [TabBadgeKind.running, .commandRunning, .commandBusy, .caffeinate, .sudo] {
            XCTAssertNil(TabBadgeReading.attention(kind), "\(kind) is busy, not waiting")
        }
    }

    func testTheThreeWaitingStatesMapToTheirRoles() {
        XCTAssertEqual(TabBadgeReading.attention(.awaitingInput), .awaiting)
        XCTAssertEqual(TabBadgeReading.attention(.error), .failed)
        // The completed/finished split is the FRESHNESS machinery's, not the reader's: a fresh flash
        // and a settled unread finish are the same news at two ages.
        XCTAssertEqual(TabBadgeReading.attention(.completed), .finished)
        XCTAssertEqual(TabBadgeReading.attention(.finished), .finished)
    }

    /// A FINISH is deliberately absent from the urgent set: green is the "nothing is wrong, come look
    /// when you can" end of the ramp, and spending a whole row title on it would leave the urgent
    /// pair nothing louder to be.
    func testUrgentIsTheWaitingPairAndNeverTheFinish() {
        XCTAssertEqual(TabBadgeReading.urgent(.awaitingInput), .awaiting)
        XCTAssertEqual(TabBadgeReading.urgent(.error), .failed)
        XCTAssertNil(TabBadgeReading.urgent(.finished))
        XCTAssertNil(TabBadgeReading.urgent(.completed))
        XCTAssertNil(TabBadgeReading.urgent(.running))
    }

    // MARK: - The collapsed group's roll-up

    /// A waiting question outranks a failure outranks an unread finish — ``AttentionRole``'s own
    /// declaration order, so both halves of the UI pick the same loudest one.
    func testRollupPicksTheLoudestRolePresent() {
        XCTAssertEqual(TabBadgeReading.rollup([.finished, .error, .awaitingInput]), .awaiting)
        XCTAssertEqual(TabBadgeReading.rollup([.finished, .error]), .failed)
        XCTAssertEqual(TabBadgeReading.rollup([.finished]), .finished)
    }

    /// Order in, order out — the roll-up ranks by ROLE, never by which row happened to come first.
    func testRollupIsIndependentOfRowOrder() {
        XCTAssertEqual(
            TabBadgeReading.rollup([.awaitingInput, .error, .finished]),
            TabBadgeReading.rollup([.finished, .error, .awaitingInput]),
        )
    }

    /// Nothing waiting ⇒ no ink, so the collapsed header's count keeps the muted metadata rung.
    /// Folding a group must never hide an agent that needs the eye, and must never invent one either.
    func testRollupIsNilWhenNothingInsideWaits() {
        XCTAssertNil(TabBadgeReading.rollup([]))
        XCTAssertNil(TabBadgeReading.rollup([nil, nil]))
        XCTAssertNil(TabBadgeReading.rollup([.running, .commandBusy, .sudo, nil]))
    }
}
