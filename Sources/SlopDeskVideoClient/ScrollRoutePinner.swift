import Foundation

/// Pins the remote-forward vs canvas-pan routing choice for the LIFETIME of one trackpad
/// gesture (doc 05 §8's scroll-routing rule).
///
/// The choice used to be re-derived per event from the LIVE `isActive`/⌥ state — so a focus
/// flip mid-gesture rerouted the gesture's momentum TAIL: a background pane's inertia suddenly
/// swallowed by a newly-focused remote window, or a focused pane's coast bleeding into a canvas
/// pan. A gesture is one intent; its destination is decided where it STARTS (began/mayBegin)
/// and held through the coast.
///
/// Deliberately NOT pinned: the read-only `inputEnabled` gate stays a LIVE per-event check at
/// the call site — locking a pane must stop host relay immediately, mid-gesture included. And
/// phase-less wheel ticks (classic mice: scrollPhase 0, momentumPhase 0) have no began to pin
/// at, so they keep the live decision every tick.
///
/// Pure value type (headless-testable): the view feeds it the already-mapped CG phase codes.
public struct ScrollRoutePinner: Sendable {
    private var pinnedRemote: Bool?

    public init() {}

    /// Decides where THIS event routes (`true` = forward to the remote window) and maintains
    /// the per-gesture pin. `liveRemote` is the caller's current would-be decision
    /// (`isActive && !⌥` — WITHOUT the read-only gate, which stays live at the call site).
    public mutating func route(liveRemote: Bool, scrollPhase: UInt8, momentumPhase: UInt8) -> Bool {
        let routed: Bool
        if scrollPhase == 1 || scrollPhase == 128 { // began / mayBegin — a fresh gesture pins
            pinnedRemote = liveRemote
            routed = liveRemote
        } else if scrollPhase != 0 || momentumPhase != 0, let pinned = pinnedRemote {
            routed = pinned // mid-gesture (on-glass or coasting): the pin owns the route
        } else {
            // Phase-less wheel tick, or a mid-gesture event with no pin (the began predates
            // this view / the pin was cleared) — fall back to the live decision.
            routed = liveRemote
        }
        if scrollPhase == 8 || momentumPhase == 3 { // cancelled / momentum end — gesture over
            pinnedRemote = nil
        }
        return routed
    }
}
