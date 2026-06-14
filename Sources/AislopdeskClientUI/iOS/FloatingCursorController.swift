#if os(iOS)
import UIKit

/// Bridges `UITextInput.updateFloatingCursor(at:)` to left/right arrow byte sequences,
/// using the pure ``FloatingCursorMapping`` for the assertable delta→arrow logic (doc 17 §2.5).
///
/// While the user long-presses the spacebar and drags, iOS streams cursor positions; we track
/// the horizontal travel since the last position and, every 5pt crossed, emit a ← / → arrow
/// (the SwiftTerm-verified threshold). On an iPhone with no hardware keyboard this is the only
/// way to move the terminal cursor.
///
/// This controller is the thin UIKit glue: it tracks the last position and feeds the X delta to
/// the mapping, then hands the resulting arrow bytes to ``onArrows``. All the threshold/sign
/// logic is in the unit-tested ``FloatingCursorMapping``.
public final class FloatingCursorController {
    private var mapping: FloatingCursorMapping
    private var lastPoint: CGPoint?

    /// Fires with the encoded arrow bytes (one `ESC [ C` / `ESC [ D` per whole 5pt step).
    public var onArrows: (([UInt8]) -> Void)?

    public init(threshold: Double = 5.0) {
        mapping = FloatingCursorMapping(threshold: threshold)
    }

    /// Begin a floating-cursor gesture at `point`.
    public func begin(at point: CGPoint) {
        lastPoint = point
        mapping.reset()
    }

    /// Update with the latest floating-cursor `point`; emits arrow bytes for any whole 5pt
    /// horizontal steps crossed since the last update.
    public func update(at point: CGPoint) {
        guard let last = lastPoint else { begin(at: point)
            return
        }
        let deltaX = Double(point.x - last.x)
        lastPoint = point
        let arrows = mapping.feed(deltaX: deltaX)
        guard !arrows.isEmpty else { return }
        onArrows?(FloatingCursorMapping.bytes(for: arrows))
    }

    /// End the gesture (cursor lifted).
    public func end() {
        lastPoint = nil
        mapping.reset()
    }
}
#endif
