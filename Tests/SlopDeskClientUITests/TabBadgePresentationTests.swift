// TabBadgePresentationTests — pins the pure view-side status map. A sidebar row never mounts a
// lifecycle glyph in the SLOT — lifecycle is the trailing ring mark's hue, the attention hues
// coming from `StatusPresentation.attentionInk` (all static hard cuts) —
// and ONLY the privilege modifiers (`#`/`∞`) occupy the trailing slot
// (`StatusPresentation.tabBadge`). `tabBadgeLabel` gives every kind a distinct non-empty AX/tooltip
// string. Headless VALUE assertions — no SwiftUI render, no video/Metal/SCStream. (Ink colours are
// deliberately NOT asserted against tokens — `Color` equality is provider-fragile; the ink/glyph/nil
// CLASS of each kind is the load-bearing spec.)

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class TabBadgePresentationTests: XCTestCase {
    private let allKinds: [TabBadgeKind] = [
        .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
        .caffeinate, .sudo,
    ]

    /// THE hue contract: a kind carries attention ink EXACTLY when it is attention-class — the
    /// states that wait on you put a hue on the ring mark, and nothing else does (running rings
    /// accent/muted, privilege is slot text, so the hue budget can never double-book a row).
    func testAttentionInkCoversExactlyTheAttentionClass() {
        for kind in allKinds {
            if kind.needsAttention {
                XCTAssertNotNil(
                    StatusPresentation.attentionInk(kind),
                    "\(kind) waits on the user — its ring must wear the attention ink",
                )
            } else {
                XCTAssertNil(
                    StatusPresentation.attentionInk(kind),
                    "\(kind) is not attention-class — the title keeps the resting ink ladder",
                )
            }
        }
    }

    /// No lifecycle state mounts trailing slot TEXT — attention is ink, running is the ring mark,
    /// so the slot stays free for the shell label on every non-privilege row.
    func testLifecycleStatesMountNoSlotGlyph() {
        let lifecycle: [TabBadgeKind] = [
            .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
        ]
        for kind in lifecycle {
            XCTAssertNil(
                StatusPresentation.tabBadge(kind),
                "\(kind) must not occupy the trailing slot — status speaks through the title",
            )
        }
    }

    /// The privilege markers are the ONLY slot glyphs — otty's shield and duotone cup (modifiers,
    /// not lifecycle states). They used to be the mono characters `#` and `∞`, which asked the
    /// reader to know a legend; a shield and a cup ask nothing (docs/DECISIONS.md round 23).
    @MainActor
    func testPrivilegeMarkersAreTheOnlySlotGlyphs() {
        XCTAssertEqual(StatusPresentation.tabBadge(.sudo)?.art, .symbol(.shieldFill))
        XCTAssertEqual(StatusPresentation.tabBadge(.caffeinate)?.art, .vector(OttyIcon.coffee))
    }

    /// The compact agent surfaces (iOS toolbar, Peek & Reply header) speak the `StatusGlyph`
    /// vocabulary: each `ClaudeStatus` maps onto the shared reading set, and only "no agent"
    /// renders nothing.
    func testAgentStatusesShareTheGlyphVocabulary() {
        XCTAssertNil(StatusPresentation.agentReading(.none))
        XCTAssertEqual(StatusPresentation.agentReading(.idle), .resting)
        XCTAssertEqual(StatusPresentation.agentReading(.working), .working)
        XCTAssertEqual(StatusPresentation.agentReading(.done), .done)
        XCTAssertEqual(StatusPresentation.agentReading(.needsPermission), .awaiting)
    }

    /// The agent spinner's cadence, pinned headlessly off the pure phase function: the hole walks one
    /// full lap of the cell per period, phase locked to the fixed epoch (so a mark's lap is a function
    /// of the CLOCK, not of when it was mounted), linear, and the SAME instant always yields the same
    /// phase — which is what makes a re-render land mid-lap instead of snapping back to the start.
    func testSpinnerWalksOneLapPerPeriodFromTheFixedEpoch() {
        let period = StatusDot.lapPeriod
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(AgentSpinner.phase(at: epoch), 0, accuracy: 0.0001, "the epoch starts the lap")
        for lap in 1...3 {
            XCTAssertEqual(
                AgentSpinner.phase(at: epoch.addingTimeInterval(period * Double(lap))), 0,
                accuracy: 0.0001,
                "lap \(lap) must close exactly — the phase is the clock, not a counter",
            )
        }
        for step in 1..<8 {
            let fraction = Double(step) / 8
            XCTAssertEqual(
                AgentSpinner.phase(at: epoch.addingTimeInterval(period * fraction)), fraction,
                accuracy: 0.0001, "the walk is LINEAR — an eased spinner reads as a stutter",
            )
        }
        // Before the reference epoch the remainder goes negative; the phase must not.
        XCTAssertEqual(
            AgentSpinner.phase(at: epoch.addingTimeInterval(-period / 4)), 0.75, accuracy: 0.0001,
            "dates before the epoch wrap forward, never to a negative phase",
        )
        let mid = epoch.addingTimeInterval(3.14)
        XCTAssertEqual(
            AgentSpinner.phase(at: mid), AgentSpinner.phase(at: mid),
            "same instant ⇒ same phase — a re-mount can't restart the walk",
        )
    }

    /// The per-mount tempo roll (⚠️ an experiment — see `StatusDot.lapPeriodRange`): the range has to
    /// be a real spread around the settled middle, and BOTH ends have to keep the lap a lap — a
    /// non-positive period would divide the phase by zero, and the guard returning 0 would leave a
    /// working row frozen on dot 0 while claiming to be alive.
    func testTheTempoRangeStraddlesTheSettledPeriodAndStaysPositive() {
        let range = StatusDot.lapPeriodRange
        XCTAssertGreaterThan(range.lowerBound, 0, "a zero-or-negative lap would freeze the mark")
        XCTAssertTrue(
            range.contains(StatusDot.lapPeriod),
            "the still/frozen/pinned period must be inside the range the live marks roll from",
        )
        XCTAssertGreaterThan(
            range.upperBound, range.lowerBound,
            "a collapsed range is the old single tempo — the roll would be a no-op",
        )
        XCTAssertEqual(
            range.lowerBound, StatusDot.herdrLapPeriod, accuracy: 0.0001,
            "the quick end IS herdr's own tempo — fine as an end of a spread, rejected as the only one",
        )
        for period in [range.lowerBound, StatusDot.lapPeriod, range.upperBound] {
            let epoch = Date(timeIntervalSinceReferenceDate: 0)
            XCTAssertEqual(
                AgentSpinner.phase(at: epoch.addingTimeInterval(period / 2), period: period), 0.5,
                accuracy: 0.0001, "a \(period)s lap is half done at \(period / 2)s",
            )
        }
        // The guard, not the crash: a degenerate period parks the phase instead of dividing by zero.
        XCTAssertEqual(AgentSpinner.phase(at: Date(timeIntervalSinceReferenceDate: 3), period: 0), 0)
    }

    /// The hole is ``StatusDot/holeWidth`` dots WIDE and that width is CONSERVED — at every instant
    /// the cell has lost exactly that much ink, wherever the centre happens to sit. ⚠️ This is the
    /// invariant that keeps the walk from pulsing: a gap that gains and loses darkness as it moves
    /// reads as a mark breathing, which is a different state's vocabulary in this column.
    func testTheHoleKeepsItsWidthWhereverItSits() {
        for step in 0..<40 {
            let hole = Double(step) / 5
            let missing = (0..<BrailleCell.dotCount)
                .map { 1 - AgentSpinner.lit($0, hole: hole) }
                .reduce(0, +)
            XCTAssertEqual(
                missing, StatusDot.holeWidth, accuracy: 0.0001,
                "the cell is short exactly \(StatusDot.holeWidth) dots' ink with the hole at \(hole)",
            )
        }
    }

    /// Parked between two dots, the hole is exactly those two — fully out, everything else at FULL
    /// ink. Nothing in between: braille has no half-lit dot, and a gap that is merely dimmer than its
    /// neighbours is not a gap.
    func testAParkedHoleIsWholeDotsFullyOutAndTheRestFullyLit() {
        XCTAssertEqual(StatusDot.holeWidth, 2, "two dots wide — the user-directed cut")
        for first in 0..<BrailleCell.dotCount {
            let second = (first + 1) % BrailleCell.dotCount
            // Centred on the seam BETWEEN the pair, which is where whole dots go out together.
            let inks = (0..<BrailleCell.dotCount).map { AgentSpinner.lit($0, hole: Double(first) + 0.5) }
            XCTAssertEqual(inks[first], StatusDot.holeFloor, accuracy: 0.0001, "dot \(first) is out")
            XCTAssertEqual(inks[second], StatusDot.holeFloor, accuracy: 0.0001, "dot \(second) is out")
            for index in 0..<BrailleCell.dotCount where index != first && index != second {
                XCTAssertEqual(
                    inks[index], 1, accuracy: 0.0001,
                    "dot \(index) is outside the hole — a lit cell dot is FULL ink",
                )
            }
        }
    }

    /// Between those parked positions the darkness SLIDES rather than hops: roll the centre onto a
    /// dot and that dot is out with half a dot's worth spilling either side. This is the one thing
    /// drawing buys over the typed frames — and it has to hold across the wrap, or the lap would
    /// visibly stutter once per turn.
    func testTheHoleGlidesBetweenDotsAndAcrossTheWrap() {
        let last = BrailleCell.dotCount - 1
        // Centred ON dot 1: it is out, and dots 0 and 2 are half-dark.
        XCTAssertEqual(AgentSpinner.lit(1, hole: 1), StatusDot.holeFloor, accuracy: 0.0001)
        XCTAssertEqual(AgentSpinner.lit(0, hole: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AgentSpinner.lit(2, hole: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AgentSpinner.lit(3, hole: 1), 1, accuracy: 0.0001, "only the pair either side dims")
        // The seam: past the last dot the hole runs back onto the first ones.
        XCTAssertEqual(AgentSpinner.lit(last, hole: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AgentSpinner.lit(0, hole: 0), StatusDot.holeFloor, accuracy: 0.0001)
        XCTAssertEqual(
            AgentSpinner.lit(0, hole: Double(BrailleCell.dotCount)), StatusDot.holeFloor,
            accuracy: 0.0001, "a whole lap lands the hole back where it started",
        )
    }

    /// The hole walks DOWN the right column then UP the left — CLOCKWISE. ⚠️ That is the REVERSE of
    /// what decoding `⣾⣽⣻⢿⡿⣟⣯⣷` gives (dots 1·2·3·7 then 8·6·5·4), which shipped first and was
    /// reversed on hardware: which way a spinner turns is judged by eye, not derived from a bitmask.
    /// Pinned as values because the walk order IS the mark — a column-major slip draws a plausible
    /// cell whose hole jumps diagonally, and a sign slip silently restores the rejected direction.
    func testTheHoleWalksDownTheRightColumnAndUpTheLeft() {
        let walk = BrailleCell.walk
        XCTAssertEqual(walk.count, BrailleCell.dotCount, "every dot is visited exactly once")
        XCTAssertEqual(walk.map(\.column), [1, 1, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(walk.map(\.row), [0, 1, 2, 3, 3, 2, 1, 0])

        // The block is CENTRED in the mark's column — it shares that column with the Ø10 resting
        // ring, and an off-centre cell reads as a row whose mark shifted when the agent woke up.
        let box = CGSize(width: StatusDot.footprint, height: StatusDot.footprint)
        let points = (0..<BrailleCell.dotCount).map { BrailleCell.position(of: $0, in: box, zoom: 1) }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        XCTAssertEqual(
            ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, box.width / 2, accuracy: 0.0001,
            "the cell is centred across",
        )
        XCTAssertEqual(
            ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2, box.height / 2, accuracy: 0.0001,
            "the cell is centred down",
        )
        // Dots plus their own radius stay inside the footprint the rail budgets for the mark.
        let radius = StatusDot.dotDiameter / 2
        XCTAssertGreaterThanOrEqual((xs.min() ?? 0) - radius, 0)
        XCTAssertGreaterThanOrEqual((ys.min() ?? 0) - radius, 0)
        XCTAssertLessThanOrEqual((xs.max() ?? 0) + radius, box.width)
        XCTAssertLessThanOrEqual((ys.max() ?? 0) + radius, box.height)
    }

    /// The collapsed group's roll-up: the header count borrows the STRONGEST attention ink among
    /// the hidden rows' fused badges — a waiting question outranks an error outranks an unread
    /// finish (the resolver's own precedence) — and stays `nil` when nothing inside waits, so the
    /// count keeps the muted metadata ink. Assertions are SELF-consistent against `attentionInk`
    /// (never absolute colour values, per the header note).
    func testAttentionRollupInkFollowsBadgePrecedence() {
        XCTAssertNil(StatusPresentation.attentionRollupInk([]))
        XCTAssertNil(
            StatusPresentation.attentionRollupInk([nil, .running, .sudo, .commandBusy]),
            "busy/privilege tiers roll up to no ink — only attention states colour the count",
        )
        XCTAssertEqual(
            StatusPresentation.attentionRollupInk([nil, .finished]),
            StatusPresentation.attentionInk(.finished),
        )
        XCTAssertEqual(
            StatusPresentation.attentionRollupInk([.completed, .error, nil, .running]),
            StatusPresentation.attentionInk(.error),
            "an error outranks an unread finish",
        )
        XCTAssertEqual(
            StatusPresentation.attentionRollupInk([.error, .awaitingInput, .finished]),
            StatusPresentation.attentionInk(.awaitingInput),
            "a waiting question outranks everything",
        )
    }

    /// Every kind carries a non-empty, distinct AX/tooltip label so the colour-spoken state stays
    /// legible and testable.
    func testEveryKindHasADistinctNonEmptyLabel() {
        let labels = allKinds.map { StatusPresentation.tabBadgeLabel($0) }
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "no blank badge labels")
        XCTAssertEqual(Set(labels).count, allKinds.count, "labels are distinct per kind")
    }
}
