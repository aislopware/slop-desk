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

    /// The tempo WANDERS, and it stays inside the band it wanders through. ⚠️ This is the invariant
    /// the whole cadence rests on: the swells' shares sum to exactly one, so the speed reaches the
    /// slow end and turns back from it. Push the shares past one (a fourth swell added without
    /// re-dividing them, a share nudged for feel) and the rate goes through zero — the mark would
    /// STALL mid-lap and then run BACKWARDS, which reads as a bug rather than as a pause.
    func testTheTempoStaysInsideItsBandAndNeverStalls() {
        XCTAssertEqual(
            StatusDot.tempoSwells.map(\.share).reduce(0, +), 1, accuracy: 0.0001,
            "the shares ARE the bound — anything over 1 reverses the spinner at the slow end",
        )
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        for step in 0..<12000 {
            let rate = AgentSpinner.rate(at: epoch.addingTimeInterval(Double(step) / 20))
            XCTAssertGreaterThanOrEqual(
                rate, StatusDot.slowRate - 0.0001, "the mark may dwell, never stall or reverse",
            )
            XCTAssertLessThanOrEqual(
                rate, StatusDot.quickRate + 0.0001, "nothing quicker than herdr's own tempo",
            )
        }
    }

    /// The wander has to be VISIBLE, and visible soon — a drift too slight or too slow to notice is
    /// the constant tempo it replaces, at more cost. Half a minute of watching must cover most of the
    /// band, and the mean over a long window must sit at the middle of it (a wander that spent its
    /// time at one end would just be a different constant tempo).
    func testTheWanderCoversMostOfItsBandWithinHalfAMinuteAndAveragesTheMiddle() {
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        var quickest = -Double.infinity
        var slowest = Double.infinity
        for step in 0...3000 {
            let rate = AgentSpinner.rate(at: epoch.addingTimeInterval(Double(step) / 100))
            quickest = Swift.max(quickest, rate)
            slowest = Swift.min(slowest, rate)
        }
        XCTAssertGreaterThan(
            (quickest - slowest) / (2 * StatusDot.rateSwing), 0.7,
            "30s must show most of the band — a wander you have to look for is not a wander",
        )
        var total = 0.0
        let samples = 60000
        for step in 0..<samples { total += AgentSpinner.rate(at: epoch.addingTimeInterval(Double(step) / 100)) }
        XCTAssertEqual(
            total / Double(samples), StatusDot.midRate, accuracy: 0.01,
            "the long-run tempo is the MIDDLE of the band, not one of its ends",
        )
    }

    /// The drawn phase IS the integral of that tempo — pinned by differencing it at a display's own
    /// frame rate. ⚠️ The two are written separately (a sine on the speed, a cosine on the position),
    /// so a sign slip or a dropped factor in either would leave a mark that turns smoothly at the
    /// WRONG times, which no still can show. It also pins that the hole always moves FORWARD.
    func testThePhaseIsTheIntegralOfTheTempo() {
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        let frame = 1.0 / 120
        for step in 0..<36000 {
            let time = Double(step) * frame
            var advance = AgentSpinner.phase(at: epoch.addingTimeInterval(time + frame))
                - AgentSpinner.phase(at: epoch.addingTimeInterval(time))
            if advance < 0 { advance += 1 }
            XCTAssertGreaterThan(advance, 0, "every frame moves the hole ON — never back, never stuck")
            XCTAssertEqual(
                advance / frame, AgentSpinner.rate(at: epoch.addingTimeInterval(time + frame / 2)),
                accuracy: 0.001, "the position and the speed must be the same function",
            )
        }
    }

    /// What the wall clock buys, unchanged by the wander: the same instant is the same phase, so a
    /// re-render lands mid-lap instead of snapping back to the start, and instants before the
    /// reference epoch wrap forward rather than to a negative phase.
    func testThePhaseIsAPureFunctionOfTheClock() {
        let mid = Date(timeIntervalSinceReferenceDate: 3.14)
        XCTAssertEqual(
            AgentSpinner.phase(at: mid), AgentSpinner.phase(at: mid),
            "same instant ⇒ same phase — a re-mount can't restart the walk",
        )
        for step in 1...200 {
            let phase = AgentSpinner.phase(at: Date(timeIntervalSinceReferenceDate: -Double(step) / 7))
            XCTAssertGreaterThanOrEqual(phase, 0, "a date before the epoch must not wrap to a negative phase")
            XCTAssertLessThan(phase, 1, "the phase is a fraction of one lap")
        }
    }

    /// Two mounts wander INDEPENDENTLY. Every mark obeys one tempo law and rolls its own offset into
    /// it (`StatusDot.tempoSeedSpan`); without that offset a whole rail of thinking agents would
    /// hurry and dwell in step, which reads as the application hitching rather than as agents
    /// thinking — the one thing the old per-mount tempo roll did buy, kept.
    func testTwoMountsWanderOutOfStepWithEachOther() {
        let instant = Date(timeIntervalSinceReferenceDate: 12.5)
        XCTAssertGreaterThan(StatusDot.tempoSeedSpan, 0, "a zero span puts every mark back in lockstep")
        XCTAssertNotEqual(
            AgentSpinner.rate(at: instant, seed: 0), AgentSpinner.rate(at: instant, seed: 3.7),
            accuracy: 0.001, "seeded marks are at different points of the wander at the same instant",
        )
        XCTAssertNotEqual(
            AgentSpinner.phase(at: instant, seed: 0), AgentSpinner.phase(at: instant, seed: 3.7),
            accuracy: 0.001, "…and their holes are in different places too",
        )
    }

    /// The band itself: the ends are the ones already judged on hardware, and the middle the stills
    /// are drawn at lies inside them. ⚠️ The quick end IS herdr's own tempo — rejected as the ONLY
    /// tempo, which is not the same as rejected: as the fast extreme of a wander, it is exactly the
    /// hurry the mark needs to have somewhere.
    func testTheTempoBandKeepsTheEndsThatWereJudged() {
        let range = StatusDot.lapPeriodRange
        XCTAssertGreaterThan(range.lowerBound, 0, "a zero-or-negative lap would freeze the mark")
        XCTAssertGreaterThan(
            range.upperBound, range.lowerBound, "a collapsed band is a constant tempo again",
        )
        XCTAssertEqual(
            range.lowerBound, StatusDot.herdrLapPeriod, accuracy: 0.0001,
            "the quick end IS herdr's own tempo — fine as an end of a spread, rejected as the only one",
        )
        XCTAssertTrue(
            range.contains(StatusDot.lapPeriod),
            "the middle every still and every frozen mark is drawn at must lie inside the band",
        )
        XCTAssertEqual(
            StatusDot.lapPeriod, 1 / StatusDot.midRate, accuracy: 0.0001,
            "the middle is the middle in RATE — averaging seconds-per-lap would dwell far too long",
        )
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

    /// Parked ON a dot, the hole is exactly that ONE dot — fully out, every other dot at FULL ink.
    /// Nothing in between: braille has no half-lit dot, and a gap that is merely dimmer than its
    /// neighbours is not a gap. ⚠️ The width pin is the point of this test: a two-dot hole shipped
    /// for part of 2026-08-10 and was reversed (a quarter of the cell out at once reads as a broken
    /// cell), and at `1` every parked frame is one the braille set itself draws.
    func testAParkedHoleIsOneWholeDotOutAndTheRestFullyLit() {
        XCTAssertEqual(StatusDot.holeWidth, 1, "one dot wide — back to `⣾⣽⣻⢿⡿⣟⣯⣷`, user-directed")
        for dark in 0..<BrailleCell.dotCount {
            let inks = (0..<BrailleCell.dotCount).map { AgentSpinner.lit($0, hole: Double(dark)) }
            XCTAssertEqual(inks[dark], StatusDot.holeFloor, accuracy: 0.0001, "dot \(dark) is out")
            for index in 0..<BrailleCell.dotCount where index != dark {
                XCTAssertEqual(
                    inks[index], 1, accuracy: 0.0001,
                    "dot \(index) is outside the hole — a lit cell dot is FULL ink",
                )
            }
        }
    }

    /// Between those parked positions the darkness SLIDES rather than hops: park the centre on the
    /// seam between two dots and each of the pair carries half the hole. This is the one thing
    /// drawing buys over the typed frames — and it has to hold across the wrap, or the lap would
    /// visibly stutter once per turn.
    func testTheHoleGlidesBetweenDotsAndAcrossTheWrap() {
        let last = BrailleCell.dotCount - 1
        // Centred on the seam between dots 1 and 2: both are half-dark, and nothing else moves.
        XCTAssertEqual(AgentSpinner.lit(1, hole: 1.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AgentSpinner.lit(2, hole: 1.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AgentSpinner.lit(0, hole: 1.5), 1, accuracy: 0.0001, "only the pair it lies between dims")
        XCTAssertEqual(AgentSpinner.lit(3, hole: 1.5), 1, accuracy: 0.0001, "only the pair it lies between dims")
        // The seam: past the last dot the hole runs back onto the first one.
        XCTAssertEqual(AgentSpinner.lit(last, hole: Double(last) + 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AgentSpinner.lit(0, hole: Double(last) + 0.5), 0.5, accuracy: 0.0001)
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
