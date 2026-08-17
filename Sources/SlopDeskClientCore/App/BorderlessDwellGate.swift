// BorderlessDwellGate — the PURE dwell policy behind borderless-fullscreen's local-menu-bar reveal
// (the Parallels model; docs/DECISIONS.md 2026-07-22 "dwell-gated borderless fullscreen").
//
// The top-edge conflict: in a fullscreen remote desktop the pointer at the very top must reach the
// REMOTE menu bar first — but macOS's own auto-hide reveals the LOCAL menu bar on a bare touch,
// stealing the click. The researched best-in-class answer (Parallels) is a DWELL: a passing touch
// stays remote; holding the pointer against the top edge for ~half a second is the deliberate
// "I want my Mac's menu bar" gesture. This gate is that policy, free of AppKit: the window layer
// feeds it pointer distance-from-top + a clock and maps the phase onto
// `NSApplication.presentationOptions` (hidden ⇒ `.hideMenuBar`, revealed ⇒ `.autoHideMenuBar`).

import Foundation

/// The three-phase dwell state machine. Pointer positions are DISTANCE FROM THE SCREEN'S TOP EDGE
/// in points (0 = pressed against it) — orientation-free, so the caller owns the one coordinate
/// flip. Pure value type: no clock reads (the caller passes `now`), fully headless-testable.
package struct BorderlessDwellGate: Equatable, Sendable {
    package enum Phase: Equatable, Sendable {
        /// Local menu bar hidden — the resting state; top-edge input is the remote's.
        case hidden
        /// Pointer is pressed against the top edge; the dwell clock is running.
        case arming(since: TimeInterval)
        /// Dwell satisfied — the local menu bar may auto-reveal.
        case revealed
    }

    package private(set) var phase: Phase = .hidden

    /// How long the pointer must hold the top edge before the local menu bar reveals.
    package let dwellSeconds: TimeInterval
    /// The arming zone: distance from the top edge (points) that counts as "pressed against it".
    /// Tight on purpose — remote work near the top of the screen must not arm the gate.
    package let revealZonePoints: Double
    /// The conceal threshold: once revealed, the pointer must travel this far DOWN from the top
    /// edge to re-hide. Wider than the arming zone (hysteresis) so using the revealed menu bar —
    /// whose items sit ~12–24 pt down — doesn't flicker the gate shut.
    package let concealZonePoints: Double

    package init(
        dwellSeconds: TimeInterval = 0.5,
        revealZonePoints: Double = 2,
        concealZonePoints: Double = 36,
    ) {
        self.dwellSeconds = dwellSeconds
        self.revealZonePoints = revealZonePoints
        self.concealZonePoints = concealZonePoints
    }

    /// Folds one pointer observation. Call on every pointer move AND once at ``armingDeadline``
    /// (a stationary pointer produces no move events, so the dwell must be completed by a timer
    /// re-feeding the last position).
    @discardableResult
    package mutating func update(pointerYFromTop y: Double, now: TimeInterval) -> Phase {
        switch phase {
        case .hidden:
            if y <= revealZonePoints {
                phase = dwellSeconds <= 0 ? .revealed : .arming(since: now)
            }
        case let .arming(since):
            if y > revealZonePoints {
                phase = .hidden // left the edge before the dwell — a passing touch stays remote
            } else if now - since >= dwellSeconds {
                phase = .revealed
            }
        case .revealed:
            if y >= concealZonePoints {
                phase = .hidden // moved back into the stream — re-arm (the next reveal dwells again)
            }
        }
        return phase
    }

    /// When the running dwell completes (absolute time), or `nil` when not arming — the caller
    /// schedules its one-shot timer here so a motionless pointer still completes the dwell.
    package var armingDeadline: TimeInterval? {
        if case let .arming(since) = phase { return since + dwellSeconds }
        return nil
    }

    package var isRevealed: Bool { phase == .revealed }
}
