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

    /// The agent spinner's cadence, pinned headlessly off the pure phase function: the caravan
    /// walks one full lap per period, phase locked to the fixed epoch (so every mount is at the same
    /// point of the lap), linear, and the SAME instant always yields the same phase — which is what
    /// makes a re-render land mid-lap instead of snapping back to the start.
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

    /// The head dot leads and the ones behind it step DOWN — the only thing that names which way the
    /// line is walking, since braille itself has no fade to copy.
    func testTheCaravanHeadLeadsAndTheTailStepsDown() {
        let dims = (0..<StatusDot.dotCount).map(AgentSpinner.dim)
        XCTAssertEqual(dims.first, 1, "the head is full ink")
        XCTAssertEqual(dims, dims.sorted(by: >), "every dot behind the head is dimmer than it")
        XCTAssertGreaterThan(dims.last ?? 0, 0, "no dot in the caravan is invisible")
    }

    /// The track is a RECTANGLE and the walk goes CLOCKWISE from the top-left, so a frozen mark sits
    /// where herdr's own frame 0 lights up. Corners are pinned as VALUES: the geometry is the whole
    /// mark, and a sign error in the arc maths draws a plausible-looking shape in the wrong place.
    func testTheTrackWalksClockwiseFromTheTopLeft() {
        // A square with no corner rounding — perimeter 40, one side per quarter lap.
        let square = CGRect(origin: .zero, size: CGSize(width: 10, height: 10))
        let corners: [(Double, CGPoint)] = [
            (0, .zero),
            (0.25, CGPoint(x: 10, y: 0)),
            (0.5, CGPoint(x: 10, y: 10)),
            (0.75, CGPoint(x: 0, y: 10)),
        ]
        for (fraction, expected) in corners {
            let point = RectTrack.point(at: fraction, in: square, radius: 0)
            XCTAssertEqual(point.x, expected.x, accuracy: 0.001, "x at \(fraction)")
            XCTAssertEqual(point.y, expected.y, accuracy: 0.001, "y at \(fraction)")
        }
        // The lap closes, and a fraction outside 0..<1 wraps rather than flying off the track.
        for (fraction, same) in [(1.0, 0.0), (1.25, 0.25), (-0.25, 0.75)] {
            let wrapped = RectTrack.point(at: fraction, in: square, radius: 0)
            let plain = RectTrack.point(at: same, in: square, radius: 0)
            XCTAssertEqual(wrapped.x, plain.x, accuracy: 0.001, "\(fraction) wraps to \(same)")
            XCTAssertEqual(wrapped.y, plain.y, accuracy: 0.001, "\(fraction) wraps to \(same)")
        }
        // Every point of a rounded track stays inside the track's own bounds.
        let track = CGRect(
            origin: .zero,
            size: CGSize(width: StatusDot.trackWidth, height: StatusDot.trackHeight),
        )
        for step in 0..<64 {
            let point = RectTrack.point(
                at: Double(step) / 64, in: track, radius: StatusDot.trackRadius,
            )
            XCTAssertTrue(
                track.insetBy(dx: -0.001, dy: -0.001).contains(point),
                "step \(step) left the track at \(point)",
            )
        }
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
