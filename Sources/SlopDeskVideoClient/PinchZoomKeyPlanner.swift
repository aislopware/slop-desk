import CSlopDeskFFI

/// Turns the trackpad pinch (`NSEvent.magnification` deltas) into discrete ⌘= / ⌘− zoom steps.
///
/// There is NO public API to synthesise a real `magnify` gesture on the host (only scroll wheels
/// and mouse/key events have public CGEvent constructors), and the private byte-blob route is
/// broken in Chromium apps — so the pinch is TRANSLATED client-side into the near-universal
/// zoom key equivalents and rides the existing key path (no wire change). See
/// docs/05-input-window-control.md §"Trackpad gestures".
///
/// A face over `client_gestures`, carrying the one number that IS the accumulation. It crosses by
/// VALUE rather than as a handle because its owner is a SwiftUI view the framework copies whenever
/// it pleases, and a handle two copies shared would be one accumulator serving two gestures.
public struct PinchZoomKeyPlanner: Sendable {
    private var state = slopdesk_pinch_planner_new()

    public init() {}

    /// Resets accumulation — call when a new pinch begins (`NSEvent.phase == .began`). A fresh
    /// planner IS what a gesture begins with, so no residual can leak between pinches.
    public mutating func begin() { state = slopdesk_pinch_planner_new() }

    /// Feeds one magnification delta; returns the SIGNED zoom steps to emit now
    /// (+n → n × zoom-in (⌘=), −n → n × zoom-out (⌘−), 0 → keep accumulating). A non-finite delta
    /// is dropped rather than folded, over there, so one bad event cannot poison the gesture.
    public mutating func ingest(magnification: Double) -> Int {
        let plan = slopdesk_pinch_planner_plan(state, magnification)
        state = plan.state
        return Int(plan.steps)
    }
}
