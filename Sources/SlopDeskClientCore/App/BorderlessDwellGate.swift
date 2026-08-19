// BorderlessDwellGate — the dwell policy behind borderless-fullscreen's local-menu-bar reveal (the
// Parallels model; docs/DECISIONS.md 2026-07-22 "dwell-gated borderless fullscreen").
//
// The top-edge conflict: in a fullscreen remote desktop the pointer at the very top must reach the
// REMOTE menu bar first — but macOS's own auto-hide reveals the LOCAL menu bar on a bare touch,
// stealing the click. The researched best-in-class answer (Parallels) is a DWELL: a passing touch
// stays remote; holding the pointer against the top edge for ~half a second is the deliberate
// "I want my Mac's menu bar" gesture.
//
// The policy lives in `slopdesk_workspace::chrome`, beside the other rules about what the window
// shows around its panes. What is left here is the phase the window layer switches over and the
// value fold across the door — the gate is five numbers, so it crosses whole in both directions
// rather than living behind a handle nothing would own. The AppKit layer feeds it pointer
// distance-from-top plus a clock and maps the phase onto `NSApplication.presentationOptions`
// (hidden ⇒ `.hideMenuBar`, revealed ⇒ `.autoHideMenuBar`).

import CSlopDeskFFI
import Foundation

/// The three-phase dwell state machine. Pointer positions are DISTANCE FROM THE SCREEN'S TOP EDGE
/// in points (0 = pressed against it) — orientation-free, so the caller owns the one coordinate
/// flip. Pure value type: no clock reads (the caller passes `now`), fully headless-testable.
package struct BorderlessDwellGate: Sendable {
    package enum Phase: Equatable, Sendable {
        /// Local menu bar hidden — the resting state; top-edge input is the remote's.
        case hidden
        /// Pointer is pressed against the top edge; the dwell clock is running.
        case arming(since: TimeInterval)
        /// Dwell satisfied — the local menu bar may auto-reveal.
        case revealed
    }

    /// The gate as the door holds it: the phase code, the running clock and the three distances.
    private var gate: SlopDeskWsDwellGate

    /// The resting gate, built with the dwell, the arming zone and the conceal zone the decision
    /// named — the numbers themselves are the door's, so neither language spells them.
    package init() {
        gate = slopdesk_ws_dwell_gate()
    }

    /// A gate with its own three distances, for the tests that pin the gesture's shape.
    package init(dwellSeconds: TimeInterval, revealZonePoints: Double, concealZonePoints: Double) {
        gate = slopdesk_ws_dwell_gate()
        gate.dwell_seconds = dwellSeconds
        gate.reveal_zone_points = revealZonePoints
        gate.conceal_zone_points = concealZonePoints
    }

    package var phase: Phase {
        switch gate.phase {
        case UInt8(SLOPDESK_WS_DWELL_ARMING): .arming(since: gate.since)
        case UInt8(SLOPDESK_WS_DWELL_REVEALED): .revealed
        default: .hidden
        }
    }

    /// How long the pointer must hold the top edge before the local menu bar reveals.
    package var dwellSeconds: TimeInterval { gate.dwell_seconds }
    /// The arming zone: distance from the top edge (points) that counts as "pressed against it".
    package var revealZonePoints: Double { gate.reveal_zone_points }
    /// The conceal threshold: how far DOWN a revealed gate's pointer must travel to re-hide.
    package var concealZonePoints: Double { gate.conceal_zone_points }

    /// Folds one pointer observation. Call on every pointer move AND once at ``armingDeadline``
    /// (a stationary pointer produces no move events, so the dwell must be completed by a timer
    /// re-feeding the last position).
    @discardableResult
    package mutating func update(pointerYFromTop y: Double, now: TimeInterval) -> Phase {
        gate = slopdesk_ws_dwell_update(gate, y, now)
        return phase
    }

    /// When the running dwell completes (absolute time), or `nil` when not arming — the caller
    /// schedules its one-shot timer here so a motionless pointer still completes the dwell.
    package var armingDeadline: TimeInterval? {
        var deadline = 0.0
        guard slopdesk_ws_dwell_deadline(gate, &deadline) else { return nil }
        return deadline
    }

    package var isRevealed: Bool { phase == .revealed }
}
