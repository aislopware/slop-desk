// StatusDotTests — pins the trailing status dot, the T3 Code thread-status port. Two pure maps:
// the RESOLVER's ladder (a working agent pulses on the accent and outranks every badge; the
// attention states borrow the title's own ink EXACTLY and hold still; a running command pulses
// muted; idle and privilege-only rows mount nothing) and the PULSE CLOCK (the duty-cycled stepped
// opacity: hold → step → hold → step, phase a function of the wall clock off the fixed epoch).
// Headless VALUE assertions — no render. Ink identity is asserted SELF-consistently against the
// presentation maps (never absolute colour values — `Color` equality is provider-fragile).

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class StatusDotTests: XCTestCase {
    // MARK: - Resolver ladder

    /// A WORKING AGENT's dot pulses and outranks every badge underneath it — the same raw-working
    /// key the shimmer uses, so the badge gate can never kill the dot either. The `.running`
    /// badge route (gate ON) must read identically to the raw route.
    @MainActor
    func testWorkingAgentPulsesAndOutranksEveryBadge() {
        let raw = StatusPresentation.statusDot(working: true, badge: nil)
        XCTAssertEqual(raw?.pulses, true, "a thinking agent's dot is alive")
        for badge: TabBadgeKind? in [.commandBusy, .error, .awaitingInput, .finished, .sudo] {
            XCTAssertEqual(
                StatusPresentation.statusDot(working: true, badge: badge), raw,
                "working outranks \(String(describing: badge)) — one accent pulse, always",
            )
        }
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: .running), raw,
            "the badge-routed agent tier and the raw-working route are ONE reading",
        )
    }

    /// Each attention kind's dot holds STILL and wears EXACTLY the title's attention ink — the
    /// dot and the title can never disagree about one pane.
    @MainActor
    func testAttentionDotsBorrowTheTitleInkAndHoldStill() {
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed, .finished] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertEqual(dot?.pulses, false, "\(kind) waits — a waiting state is not motion")
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind)'s dot must wear the title's own attention ink",
            )
        }
    }

    /// A running command's dot pulses on the MUTED ink — alive, but spending no hue — and reads
    /// differently from the agent tier's accent pulse.
    @MainActor
    func testCommandBusyPulsesMutedDistinctFromTheAgentTier() {
        let agent = StatusPresentation.statusDot(working: true, badge: nil)
        for kind: TabBadgeKind in [.commandBusy, .commandRunning] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertEqual(dot?.pulses, true, "\(kind) is alive — the dot must pulse")
            XCTAssertNotEqual(dot?.ink, agent?.ink, "\(kind) must not borrow the agent accent")
            XCTAssertNil(
                StatusPresentation.attentionInk(kind),
                "busy is not attention-class — the title keeps the resting ink while the dot pulses",
            )
        }
    }

    /// Idle and privilege-only rows mount NOTHING — T3 Code renders null; the resting rail is bare.
    @MainActor
    func testIdleAndPrivilegeOnlyRowsMountNoDot() {
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: nil))
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .sudo))
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .caffeinate))
    }

    // MARK: - Pulse clock

    /// The duty cycle, pinned off the pure clock function: high hold, ONE intermediate step down,
    /// low hold, ONE step up, wrap — hard cuts only, symmetric holds (the T3 Code 2s cadence).
    func testPulseOpacityDutyCycleAndWrap() {
        func opacity(_ t: TimeInterval) -> Double {
            StatusDot.pulseOpacity(at: StatusDot.epoch.addingTimeInterval(t))
        }
        XCTAssertEqual(opacity(0), 1)
        XCTAssertEqual(opacity(0.85), 1, "high hold runs to the step slot")
        XCTAssertEqual(opacity(0.95), StatusDot.midOpacity, "one mechanical step down")
        XCTAssertEqual(opacity(1.05), StatusDot.lowOpacity)
        XCTAssertEqual(opacity(1.85), StatusDot.lowOpacity, "low hold mirrors the high hold")
        XCTAssertEqual(opacity(1.95), StatusDot.midOpacity, "one mechanical step back up")
        XCTAssertEqual(opacity(2.05), 1, "the cycle wraps into the next high hold")
    }

    /// Phase is the WALL CLOCK's, not the mount's: the same instant always yields the same
    /// opacity, whole cycles apart land identically, and a pre-epoch date folds into the same
    /// cycle instead of going negative.
    func testPulsePhaseIsWallClockDerived() {
        let mid = StatusDot.epoch.addingTimeInterval(1.23)
        XCTAssertEqual(StatusDot.pulseOpacity(at: mid), StatusDot.pulseOpacity(at: mid))
        XCTAssertEqual(
            StatusDot.pulseOpacity(at: mid),
            StatusDot.pulseOpacity(at: mid.addingTimeInterval(3 * StatusDot.cycle)),
            "whole cycles apart ⇒ the same phase",
        )
        XCTAssertEqual(
            StatusDot.pulseOpacity(at: StatusDot.epoch.addingTimeInterval(-0.15)),
            StatusDot.lowOpacity,
            "a pre-epoch date folds into the cycle — never a negative phase",
        )
    }
}
