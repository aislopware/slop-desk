import CSlopDeskFFI

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
/// A face over `client_gestures`, holding the pin as the two flags that carry it — a value, not a
/// handle, because the view that owns it is copied by SwiftUI at will.
public struct ScrollRoutePinner: Sendable {
    private var state = slopdesk_scroll_pin_new()

    public init() {}

    /// Decides where THIS event routes (`true` = forward to the remote window) and maintains
    /// the per-gesture pin. `liveRemote` is the caller's current would-be decision
    /// (`isActive && !⌥` — WITHOUT the read-only gate, which stays live at the call site).
    public mutating func route(liveRemote: Bool, scrollPhase: UInt8, momentumPhase: UInt8) -> Bool {
        let answer = slopdesk_scroll_pin_route(state, liveRemote, scrollPhase, momentumPhase)
        state = answer.state
        return answer.remote
    }
}
