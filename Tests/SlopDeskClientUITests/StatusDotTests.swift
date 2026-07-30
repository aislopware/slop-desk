// StatusDotTests — pins the trailing status mark, the T3 Code SidebarV2 port. ONE static circle and
// the HUE is (almost) the whole grammar — the single exception being that an unread FINISH draws the
// ring CLOSED where every open state keeps it dashed. The resolver's ladder is the spec: a
// working agent rings on the accent (the same raw-working key liveness uses, outranking every
// badge); a RESTING CODE AGENT rings muted; the attention states ring on their attention ink — the
// title never recolours, so the mark's hue is those states' entire rendering; a plain running
// command, a bare idle shell and privilege-only rows mount nothing. The STATIC contract (nothing
// in the mark animates) rides the geometry pins. Headless VALUE assertions — no render. Ink
// identity is asserted SELF-consistently against the presentation maps (never absolute colour
// values — `Color` equality is provider-fragile).

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

    /// Each attention kind's ring wears EXACTLY its attention ink — with a neutral title, the
    /// mark's hue is the state's whole rendering, so it can never drift off the hue budget
    /// (green unread finish, amber question, red failure).
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

    /// ⚠️ An unread FINISH is the ONLY state that closes the ring — a whole circle for work that
    /// ended, the broken one for everything still open (working, resting, waiting on a human,
    /// failed). Both finish tiers close it: the `.completed` flash and the settled `.finished`
    /// unread are the same reading, since that split is semantic and never visual.
    ///
    /// This is also the only SHAPE distinction the column is allowed. A previous round gave each
    /// state its own silhouette (raised hand, warning triangle, `?`, `!`, filled dot) and pulled
    /// every one for reading as fussy detail at 8pt (docs/DECISIONS.md rounds 19–20); closed-versus-
    /// broken survives because it needs no legend and is legible at any size.
    @MainActor
    func testOnlyTheUnreadFinishClosesTheRing() {
        for kind: TabBadgeKind in [.completed, .finished] {
            XCTAssertTrue(
                StatusPresentation.closesTheRing(kind), "\(kind) is work that ENDED — whole circle",
            )
            XCTAssertEqual(
                StatusPresentation.statusDot(working: false, badge: kind)?.closed, true,
                "\(kind) must resolve to the closed ring, not merely be classified as one",
            )
        }
        for kind: TabBadgeKind in [.awaitingInput, .error, .running, .commandBusy, .sudo] {
            XCTAssertFalse(
                StatusPresentation.closesTheRing(kind), "\(kind) is still open — broken ring",
            )
        }
        // The three non-badge routes keep the dashed ring too: working, resting, and the badge-routed
        // agent tier are all "still open".
        XCTAssertEqual(StatusPresentation.statusDot(working: true, badge: nil)?.closed, false)
        XCTAssertEqual(StatusPresentation.statusDot(working: false, badge: .running)?.closed, false)
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: nil, agentIdle: true)?.closed, false,
        )
        // A closed ring is STILL the same circle — the distinction may cost hue nothing and geometry
        // nothing. (Its ink is the finish green, exactly as the dashed tiers wear their own.)
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: .finished)?.ink,
            StatusPresentation.attentionInk(.finished),
            "closing the ring must not change what the mark says",
        )
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
    /// continuous stroke — so there is exactly one geometry and one stroke weight in this column and
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
