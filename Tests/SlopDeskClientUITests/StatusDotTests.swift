// StatusDotTests — pins the trailing status mark, the T3 Code SidebarV2 port. The resolver's
// ladder is the spec: a working agent DASH-RINGS on the accent (the same raw-working key the
// working reading uses); the unread finish is the SOLID ring in the title's own green; a running
// command dash-rings muted; and the WAITING states (question / failure) mount NOTHING — T3 Code
// renders no icon for approval/input/failed, the tinted label alone carries them, which here is
// the title's attention ink. The shape grammar — broken outline = in flight, closed outline =
// done — and the STATIC contract (nothing in the mark animates) are what these tests hold.
// Headless VALUE assertions — no render. Ink identity is asserted SELF-consistently against the
// presentation maps (never absolute colour values — `Color` equality is provider-fragile).

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class StatusDotTests: XCTestCase {
    /// A WORKING AGENT's mark is the accent DASHED ring and outranks every badge underneath it —
    /// keyed on the raw working status, so the badge gate can never kill the mark. The `.running`
    /// badge route (gate ON) must read identically to the raw route.
    @MainActor
    func testWorkingAgentRingsAndOutranksEveryBadge() {
        let raw = StatusPresentation.statusDot(working: true, badge: nil)
        XCTAssertEqual(raw?.shape, .dashedRing, "a thinking agent is IN FLIGHT — the broken outline")
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

    /// The unread finish CLOSES the ring — solid, wearing EXACTLY the title's attention ink, so
    /// the mark and the green title can never disagree about one pane.
    @MainActor
    func testUnreadFinishClosesTheRingInTheTitleInk() {
        for kind: TabBadgeKind in [.completed, .finished] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertEqual(dot?.shape, .solidRing, "\(kind) is a closed loop — the solid ring")
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
            XCTAssertEqual(dot?.shape, .dashedRing, "\(kind) is in flight — the broken outline")
            XCTAssertNotEqual(dot?.ink, agent?.ink, "\(kind) must not borrow the agent accent")
            XCTAssertNil(
                StatusPresentation.attentionInk(kind),
                "busy is not attention-class — the title keeps the resting ink beside the ring",
            )
        }
    }

    /// The WAITING states mount NO mark — T3 Code renders no icon for approval/input/failed; the
    /// tinted title (the attention ink, which must exist for them) is the whole rendering. Idle
    /// and privilege-only rows also mount nothing: the resting rail is bare.
    @MainActor
    func testWaitingIdleAndPrivilegeOnlyRowsMountNoMark() {
        for kind: TabBadgeKind in [.awaitingInput, .error] {
            XCTAssertNil(
                StatusPresentation.statusDot(working: false, badge: kind),
                "\(kind) is the title ink's job — no mark rides beside the tinted label",
            )
            XCTAssertNotNil(
                StatusPresentation.attentionInk(kind),
                "\(kind) must still recolour the title — dropping the mark can't mute the state",
            )
        }
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
