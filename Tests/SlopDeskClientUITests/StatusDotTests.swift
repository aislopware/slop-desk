// StatusDotTests — pins the trailing status mark, the T3 Code SidebarV2 port. The resolver's
// ladder is the spec: a working agent RINGS on the accent and outranks every badge (the same
// raw-working key the shimmer uses); the attention states FILL with the title's own ink exactly;
// a running command rings muted; idle and privilege-only rows mount nothing. The shape grammar —
// dashed ring = in flight, filled dot = settled-and-waiting — and the STATIC contract (nothing
// in the mark animates) are what these tests hold. Headless VALUE assertions — no render. Ink
// identity is asserted SELF-consistently against the presentation maps (never absolute colour
// values — `Color` equality is provider-fragile).

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class StatusDotTests: XCTestCase {
    /// A WORKING AGENT's mark is the accent RING and outranks every badge underneath it — the
    /// same raw-working key the shimmer uses, so the badge gate can never kill the mark either.
    /// The `.running` badge route (gate ON) must read identically to the raw route.
    @MainActor
    func testWorkingAgentRingsAndOutranksEveryBadge() {
        let raw = StatusPresentation.statusDot(working: true, badge: nil)
        XCTAssertEqual(raw?.shape, .ring, "a thinking agent is IN FLIGHT — the outline shape")
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

    /// Each attention kind's mark is the FILLED dot wearing EXACTLY the title's attention ink —
    /// the mark and the title can never disagree about one pane.
    @MainActor
    func testAttentionMarksFillWithTheTitleInk() {
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed, .finished] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertEqual(dot?.shape, .fill, "\(kind) is settled — the filled shape")
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind)'s mark must wear the title's own attention ink",
            )
        }
    }

    /// A running command's mark is the muted RING — in flight, spending no hue — distinct from
    /// the agent tier's accent ring, and never attention-class.
    @MainActor
    func testCommandBusyRingsMutedDistinctFromTheAgentTier() {
        let agent = StatusPresentation.statusDot(working: true, badge: nil)
        for kind: TabBadgeKind in [.commandBusy, .commandRunning] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertEqual(dot?.shape, .ring, "\(kind) is in flight — the outline shape")
            XCTAssertNotEqual(dot?.ink, agent?.ink, "\(kind) must not borrow the agent accent")
            XCTAssertNil(
                StatusPresentation.attentionInk(kind),
                "busy is not attention-class — the title keeps the resting ink beside the ring",
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
