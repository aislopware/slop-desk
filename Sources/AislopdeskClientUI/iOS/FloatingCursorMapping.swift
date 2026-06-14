import Foundation

/// Maps a floating-cursor horizontal drag into left/right arrow-key byte sequences
/// (doc 17 §2.5 — on an iPhone with no hardware keyboard this is the *only* way to move the
/// terminal cursor).
///
/// iOS calls `UITextInput.updateFloatingCursor(at:)` continuously while the user long-presses
/// the spacebar and drags. SwiftTerm's verified behaviour: every **5pt** of accumulated
/// horizontal travel emits one arrow key (← for leftward, → for rightward); vertical drag is
/// ignored (SwiftTerm only gates vertical in alt-screen, and even then conservatively — we
/// drop it entirely for the terminal cursor case). This type is the pure, stateful
/// delta→arrow accumulator the iOS view wrapper drives; it holds no UIKit type and is
/// unit-tested on macOS.
///
/// ### Threshold semantics (the assertable contract)
/// The mapping is **quantised, not rounded**: it accumulates raw travel and emits one arrow
/// per whole `threshold` crossed, carrying the sub-threshold remainder forward so a slow drag
/// of many small deltas still produces the correct total. For a single delta `d` from rest:
/// `|d| < threshold` → 0 arrows; `threshold ≤ |d| < 2·threshold` → 1 arrow; etc. The sign of
/// the (consumed) travel picks the direction.
public struct FloatingCursorMapping: Sendable, Equatable {
    /// Travel (points) per emitted arrow. SwiftTerm-verified 5pt.
    public let threshold: Double

    /// Accumulated, not-yet-emitted horizontal travel (points), signed.
    public private(set) var accumulated: Double = 0

    public init(threshold: Double = 5.0) {
        precondition(threshold > 0, "threshold must be positive")
        self.threshold = threshold
    }

    /// The arrow direction a step emits.
    public enum Arrow: Sendable, Equatable {
        case left
        case right
    }

    /// Feeds a horizontal delta (points; positive = rightward). Returns the arrow keys to
    /// emit for the whole-thresholds this delta completed, leaving the remainder accumulated.
    ///
    /// Pure-but-mutating (`mutating`): the accumulator persists across calls so a sequence of
    /// small drags sums correctly. Returns e.g. `[]` for a 4pt nudge, `[.right]` for +6pt,
    /// `[.left, .left]` for −12pt (two whole 5pt steps; 2pt remainder retained).
    public mutating func feed(deltaX: Double) -> [Arrow] {
        // A non-finite delta (NaN / ±Infinity from a hostile or degenerate UITextInput point) would
        // poison `accumulated` — +Infinity makes `accumulated >= threshold` loop forever (Inf − threshold
        // = Inf), NaN wedges it permanently. Drop it, keeping the accumulator clean (R13).
        guard deltaX.isFinite else { return [] }
        accumulated += deltaX
        var arrows: [Arrow] = []
        // Emit one arrow per whole threshold crossed, preserving sign + remainder.
        while accumulated >= threshold {
            arrows.append(.right)
            accumulated -= threshold
        }
        while accumulated <= -threshold {
            arrows.append(.left)
            accumulated += threshold
        }
        return arrows
    }

    /// Clears the accumulated remainder (cursor lifted / drag ended).
    public mutating func reset() {
        accumulated = 0
    }

    // MARK: - Byte encoding

    /// The DECCKM-normal (cursor-key mode reset) byte sequence for an arrow. The remote PTY's
    /// libghostty owns true DECCKM state; for the floating-cursor synthetic-input path we emit
    /// the standard `ESC [ C` / `ESC [ D` (CUF/CUB) which every line editor + the alt-screen
    /// app interpret as right/left. Routed to `AislopdeskClient.sendInput`.
    public static func bytes(for arrow: Arrow) -> [UInt8] {
        switch arrow {
        case .right: [0x1B, 0x5B, 0x43] // ESC [ C
        case .left: [0x1B, 0x5B, 0x44] // ESC [ D
        }
    }

    /// Encodes a run of arrows into a single byte buffer (for one `sendInput`).
    public static func bytes(for arrows: [Arrow]) -> [UInt8] {
        arrows.flatMap { bytes(for: $0) }
    }
}
