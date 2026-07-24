// StatusDotTests — pins the trailing status mark, the T3 Code SidebarV2 port. ONE shape (the
// static dashed ring) and the HUE is the whole grammar, the resolver's ladder being the spec: a
// working agent rings on the accent (the same raw-working key liveness uses, outranking every
// badge); a running command rings muted; the attention states ring on their attention ink — the
// title never recolours, so the mark's hue is those states' entire rendering; idle and
// privilege-only rows mount nothing. The STATIC contract (nothing in the mark animates) rides
// the geometry pins. Headless VALUE assertions — no render. Ink identity is asserted
// SELF-consistently against the presentation maps (never absolute colour values — `Color`
// equality is provider-fragile).

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

    /// A running command's ring is muted — in flight, spending no hue — distinct from both the
    /// agent tier's accent and the attention hues.
    @MainActor
    func testCommandBusyRingsMutedDistinctFromEveryHuedTier() {
        let agent = StatusPresentation.statusDot(working: true, badge: nil)
        for kind: TabBadgeKind in [.commandBusy, .commandRunning] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertNotNil(dot, "\(kind) is in flight — the ring mounts")
            XCTAssertNotEqual(dot?.ink, agent?.ink, "\(kind) must not borrow the agent accent")
            XCTAssertNil(
                StatusPresentation.attentionInk(kind),
                "busy is not attention-class — its ring stays off the hue budget",
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
}
