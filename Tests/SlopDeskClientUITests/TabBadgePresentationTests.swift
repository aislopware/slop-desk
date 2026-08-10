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

    /// The agent spinner's cadence, pinned headlessly off the pure turn function: the comet sweeps
    /// one full revolution per period, phase locked to the fixed epoch (so every mount is at the
    /// same angle), monotonic within a turn, and the SAME instant always yields the same angle —
    /// which is what makes a re-render land mid-turn instead of snapping back to 12 o'clock.
    func testSpinnerTurnsOncePerPeriodFromTheFixedEpoch() {
        let period = StatusDot.cometPeriod
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(AgentSpinner.turn(at: epoch), 0, accuracy: 0.001, "the epoch is 12 o'clock")
        for turn in 1...3 {
            let full = epoch.addingTimeInterval(period * Double(turn))
            XCTAssertEqual(
                AgentSpinner.turn(at: full), 0, accuracy: 0.001,
                "turn \(turn) must close the circle exactly — the phase is the clock, not a counter",
            )
        }
        for step in 1..<8 {
            let fraction = Double(step) / 8
            XCTAssertEqual(
                AgentSpinner.turn(at: epoch.addingTimeInterval(period * fraction)),
                fraction * 360, accuracy: 0.001,
                "the sweep is LINEAR — an eased spinner reads as a stutter",
            )
        }
        // Before the reference epoch the remainder goes negative; the angle must not.
        XCTAssertEqual(
            AgentSpinner.turn(at: epoch.addingTimeInterval(-period / 4)), 270, accuracy: 0.001,
            "dates before the epoch wrap forward, never to a negative angle",
        )
        let mid = epoch.addingTimeInterval(3.14)
        XCTAssertEqual(
            AgentSpinner.turn(at: mid), AgentSpinner.turn(at: mid),
            "same instant ⇒ same angle — a re-mount can't restart the turn",
        )
    }

    /// The comet is a COMET, not a ring: it must leave a gap the eye can watch travel. herdr's
    /// braille arc lights at most four of six perimeter dots (240°); ours opens to 270° and the
    /// remaining quarter-turn of clearance is the thing that makes the rotation legible at Ø10.
    func testCometLeavesAGapToWatchTravel() {
        XCTAssertLessThanOrEqual(
            StatusDot.cometSweep, 300,
            "a sweep this close to a full circle reads as a ring vibrating, not an arc turning",
        )
        XCTAssertEqual(
            StatusDot.cometDiameter, StatusDot.ringDiameter,
            "the working comet and the resting ring are ONE circle — only the motion differs",
        )
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
