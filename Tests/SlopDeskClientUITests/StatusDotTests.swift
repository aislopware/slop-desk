// StatusDotTests — pins the trailing status mark, the T3 Code SidebarV2 port. The HUE names the
// STATE and the geometry names the SPEAKER: the ring is the AGENT's (dashed while its work is open,
// CLOSED once its turn ended), the small filled dot is a COMMAND's OUTCOME. The resolver's ladder is
// the spec: a working agent rings on the accent (the same raw-working key liveness uses, outranking
// every badge); a RESTING CODE AGENT rings muted; the attention states wear their attention ink —
// the title never recolours, so the mark's hue is those states' entire rendering; a plain running
// command, a bare idle shell and privilege-only rows mount nothing. The STATIC contract (nothing
// in the mark animates) rides the geometry pins. Headless VALUE assertions — no render. Ink
// identity is asserted SELF-consistently against the presentation maps (never absolute colour
// values — `Color` equality is provider-fragile).

import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class StatusDotTests: XCTestCase {
    /// A WORKING AGENT's mark is the accent ring and outranks every badge underneath it — keyed
    /// on the raw working status, so the badge gate can never kill the mark. The `.running`
    /// badge route (gate ON) must read identically to the raw route.
    @MainActor
    func testWorkingAgentRingsAndOutranksEveryBadge() {
        let raw = StatusPresentation.statusDot(working: true, badge: nil)
        XCTAssertNotNil(raw, "a thinking agent always mounts the mark")
        for badge: TabBadgeKind? in [.commandBusy, .error, .awaitingInput, .finished, .sudo] {
            XCTAssertEqual(
                StatusPresentation.statusDot(working: true, badge: badge), raw,
                "working outranks \(String(describing: badge)) — one accent ring, always",
            )
        }
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: .running), raw,
            "the badge-routed agent tier and the raw-working route are ONE reading",
        )
    }

    /// Each attention kind's mark wears EXACTLY its attention ink — with a neutral title, the
    /// mark's hue is the state's whole rendering, so it can never drift off the hue budget
    /// (green unread finish, amber question, red failure). Ring or dot, the hue is the same one.
    @MainActor
    func testAttentionKindsRingOnTheirAttentionInk() {
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed, .finished] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertNotNil(dot, "\(kind) must mount the mark — the neutral title can't say it")
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind)'s ring must wear its own attention ink",
            )
        }
    }

    /// A RESTING CODE AGENT's ring is muted — present, spending no hue — distinct from both the
    /// agent tier's accent and the attention hues. The muted ring is the agent's alone.
    @MainActor
    func testRestingAgentRingsMutedDistinctFromEveryHuedTier() {
        let working = StatusPresentation.statusDot(working: true, badge: nil)
        // The claude pane at its prompt keeps the shell busy for its whole lifetime, so it
        // arrives with either no badge or the `.commandBusy` tier — both read the same.
        for badge: TabBadgeKind? in [nil, .commandBusy] {
            let dot = StatusPresentation.statusDot(
                working: false, badge: badge, agentIdle: true,
            )
            XCTAssertNotNil(dot, "a resting agent mounts the muted ring")
            XCTAssertNotEqual(dot?.ink, working?.ink, "resting must not borrow the working accent")
            XCTAssertEqual(dot?.ink, Slate.Text.secondary, "resting spends no hue")
        }
    }

    /// A plain running COMMAND — no code agent in the pane — mounts NOTHING: the muted ring is
    /// reserved for a resting agent, so `npm run dev` no longer decorates the rail.
    @MainActor
    func testPlainRunningCommandMountsNoMark() {
        for kind: TabBadgeKind in [.commandBusy, .commandRunning] {
            XCTAssertNil(
                StatusPresentation.statusDot(working: false, badge: kind),
                "\(kind) without an agent must leave the rail bare",
            )
        }
    }

    /// An attention state OUTRANKS the resting-agent ring: a finished/blocked/failed agent keeps
    /// its attention ink even though the same pane is also a resting agent.
    @MainActor
    func testAttentionOutranksTheRestingAgentRing() {
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed, .finished] {
            XCTAssertEqual(
                StatusPresentation.statusDot(working: false, badge: kind, agentIdle: true)?.ink,
                StatusPresentation.attentionInk(kind),
                "\(kind) keeps its attention ink over the muted resting ring",
            )
        }
    }

    /// Idle and privilege-only rows mount NOTHING — T3 Code renders null; the resting rail is bare.
    @MainActor
    func testIdleAndPrivilegeOnlyRowsMountNoMark() {
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: nil))
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .sudo))
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .caffeinate))
    }

    /// ⚠️ Only the AGENT's own finish closes the ring — a whole circle for a turn that ended, the
    /// broken one for everything still open (working, resting, waiting on a human). Both finish
    /// tiers close it: the `.completed` flash and the settled `.finished` unread are the same
    /// reading, since that split is semantic and never visual.
    ///
    /// A shape may only say what a hue cannot — whether the work is over, and who did it. A previous
    /// round gave each state its own silhouette (raised hand, warning triangle, `?`, `!`) and pulled
    /// every one for reading as fussy detail at 8pt (docs/DECISIONS.md rounds 19–21).
    @MainActor
    func testOnlyTheAgentsOwnFinishClosesTheRing() {
        for kind: TabBadgeKind in [.completed, .finished] {
            XCTAssertEqual(
                StatusPresentation.mark(for: kind, agentFinish: true), .closedRing,
                "\(kind) from the AGENT is a turn that ENDED — whole circle",
            )
            XCTAssertEqual(
                StatusPresentation.statusDot(working: false, badge: kind, agentFinish: true)?.mark,
                .closedRing,
                "\(kind) must RESOLVE to the closed ring, not merely be classified as one",
            )
        }
        for kind: TabBadgeKind in [.awaitingInput, .running, .commandBusy, .sudo] {
            XCTAssertEqual(
                StatusPresentation.mark(for: kind, agentFinish: true), .openRing,
                "\(kind) is a session still mid-turn — broken ring",
            )
        }
        // The three non-badge routes keep the dashed ring too: working, resting, and the badge-routed
        // agent tier are all "still open".
        XCTAssertEqual(StatusPresentation.statusDot(working: true, badge: nil)?.mark, .openRing)
        XCTAssertEqual(StatusPresentation.statusDot(working: false, badge: .running)?.mark, .openRing)
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: nil, agentIdle: true)?.mark, .openRing,
        )
        // A closed ring is STILL the same circle on the same ink — the geometry says the work ended,
        // never what the state is.
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: .finished, agentFinish: true)?.ink,
            StatusPresentation.attentionInk(.finished),
            "closing the ring must not change what the mark says",
        )
    }

    /// ⚠️ A COMMAND's outcome takes the DOT, never the agent's ring: a failure ALWAYS (`.error` can
    /// only come from a non-zero exit or a held-red `OSC 9;4;2` — `ClaudeStatus` has no error case,
    /// so the agent never speaks red), and a clean finish whenever the finish is not the agent's.
    /// The hue is untouched by the split — a command's green is the same green — so the column keeps
    /// ONE hue budget and the geometry alone says who is speaking.
    @MainActor
    func testACommandsOutcomeTakesTheDotOnTheSameInk() {
        XCTAssertEqual(
            StatusPresentation.mark(for: .error, agentFinish: true), .dot,
            "a non-zero exit is a COMMAND's fact even in an agent pane",
        )
        for kind: TabBadgeKind in [.completed, .finished] {
            XCTAssertEqual(
                StatusPresentation.mark(for: kind, agentFinish: false), .dot,
                "\(kind) with no agent finish behind it is a background command's receipt",
            )
        }
        // Resolved, not merely classified — and on EXACTLY the ink the ring would have worn.
        for kind: TabBadgeKind in [.error, .completed, .finished] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind, agentFinish: false)
            XCTAssertEqual(dot?.mark, .dot, "\(kind) must resolve to the outcome dot")
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind)'s dot wears the state's own hue — the split costs the hue budget nothing",
            )
        }
        // The dot is the QUIETER of the two marks — a finished `make` must not outshout a live agent
        // — and it fits inside the RING'S OWN APERTURE (`ringDiameter - ringLineWidth`), so both
        // marks live in one envelope: the column can never widen depending on which one a row draws.
        // 4 is the floor at which it stops reading as a stray pixel (measured at true size, round 21).
        XCTAssertGreaterThanOrEqual(StatusDot.dotDiameter, 4, "below 4pt it reads as a speck")
        XCTAssertLessThanOrEqual(
            StatusDot.dotDiameter, StatusDot.ringDiameter - StatusDot.ringLineWidth,
            "the dot fits within the ring's aperture — one envelope, one column",
        )
    }

    /// The finish's OWNER comes from one shared predicate: a live agent `.done` or the client's
    /// unread latch, and ONLY on a finish badge. The same call gates the row's agent FINAL LINE, so
    /// the row that shows the agent's last words is exactly the row that draws the closed ring — a
    /// command's exit can neither borrow the agent's line nor its ring.
    @MainActor
    func testTheFinishOwnerIsOnePredicateForLineAndRing() {
        for status: ClaudeStatus in [.done, .idle] {
            for unseen in [true, false] {
                let agents = RailRowsBuilder.finishIsAgents(
                    badge: .finished, status: status, unseenDone: unseen,
                )
                XCTAssertEqual(
                    agents, status == .done || unseen,
                    "a live `.done` OR the unread latch owns the finish (\(status), unseen=\(unseen))",
                )
                // Whatever the predicate says, the mark must follow it — never diverge.
                XCTAssertEqual(
                    StatusPresentation.statusDot(
                        working: false, badge: .finished, agentFinish: agents,
                    )?.mark,
                    agents ? .closedRing : .dot,
                )
            }
        }
        // A NON-finish badge is never the agent's finish, however done the agent looks — an error or
        // a busy tier must not be read as a completed turn.
        for kind: TabBadgeKind? in [.error, .commandBusy, .awaitingInput, .running, nil] {
            XCTAssertFalse(
                RailRowsBuilder.finishIsAgents(badge: kind, status: .done, unseenDone: true),
                "\(String(describing: kind)) is not a finish badge",
            )
        }
    }

    /// The ring's dash pattern tiles the circumference EXACTLY — `ringDashCount` whole periods,
    /// so the dashes stay evenly spread with no seam where the stroke closes.
    func testRingDashTilesTheCircumferenceEvenly() {
        let dash = StatusDot.ringDash
        XCTAssertEqual(dash.count, 2, "one dash length, one gap length")
        let period = dash[0] + dash[1]
        let circumference = CGFloat.pi * StatusDot.ringDiameter
        XCTAssertEqual(
            Double(period * CGFloat(StatusDot.ringDashCount)), Double(circumference),
            accuracy: 1e-9, "whole periods around the ring — no seam",
        )
        XCTAssertGreaterThan(dash[0], dash[1], "drawn beats gap — the ring reads as a circle")
    }

    /// The CLOSED ring is the same draw with the dash pattern withheld — an empty array is a
    /// continuous stroke — so the two ring readings share one geometry and one stroke weight, with
    /// no second code path to drift out of alignment with the dashed one.
    func testTheClosedRingIsTheDashedRingWithoutItsPattern() {
        XCTAssertTrue(
            StatusDot.ringDash.count == 2 && !StatusDot.ringDash.isEmpty,
            "the open state has a pattern…",
        )
        XCTAssertEqual(StatusDot.ringDiameter, 8, "…and the closed state shares its diameter")
        XCTAssertEqual(StatusDot.ringLineWidth, 1.5, "…and its stroke weight")
        XCTAssertGreaterThanOrEqual(
            StatusDot.footprint, StatusDot.ringDiameter, "…inside one fixed column",
        )
    }
}
