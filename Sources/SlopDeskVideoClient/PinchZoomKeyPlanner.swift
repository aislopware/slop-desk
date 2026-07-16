import Foundation

/// Turns the trackpad pinch (`NSEvent.magnification` deltas) into discrete ⌘= / ⌘− zoom steps.
///
/// There is NO public API to synthesise a real `magnify` gesture on the host (only scroll wheels
/// and mouse/key events have public CGEvent constructors), and the private byte-blob route is
/// broken in Chromium apps — so the pinch is TRANSLATED client-side into the near-universal
/// zoom key equivalents and rides the existing key path (no wire change). See
/// docs/05-input-window-control.md §"Trackpad gestures".
///
/// Pure value type: the view feeds it magnification deltas and emits one ⌘=/⌘− pair per step
/// returned. Accumulation carries across events within one pinch and RESETS on gesture begin,
/// so residual never leaks between pinches.
public struct PinchZoomKeyPlanner: Sendable {
    /// Accumulated |magnification| per zoom step. A full two-finger pinch sweep sums to ~±1.0,
    /// so this yields ~5 steps ≈ the 10–25%-per-step zoom ladder browsers/editors use.
    public static let stepThreshold: Double = 0.2
    /// Per-event cap on emitted steps: one wild delta (or a burst coalesced by AppKit) must not
    /// machine-gun the host with keystrokes.
    public static let maxStepsPerEvent = 3

    private var residual: Double = 0

    public init() {}

    /// Resets accumulation — call when a new pinch begins (`NSEvent.phase == .began`).
    public mutating func begin() { residual = 0 }

    /// Feeds one magnification delta; returns the SIGNED zoom steps to emit now
    /// (+n → n × zoom-in (⌘=), −n → n × zoom-out (⌘−), 0 → keep accumulating).
    public mutating func ingest(magnification: Double) -> Int {
        // Non-finite deltas (defensive: NSEvent shouldn't produce them) are dropped, not folded.
        guard magnification.isFinite else { return 0 }
        residual += magnification
        var steps = 0
        while residual >= Self.stepThreshold, steps < Self.maxStepsPerEvent {
            residual -= Self.stepThreshold
            steps += 1
        }
        while residual <= -Self.stepThreshold, steps > -Self.maxStepsPerEvent {
            residual += Self.stepThreshold
            steps -= 1
        }
        return steps
    }
}
