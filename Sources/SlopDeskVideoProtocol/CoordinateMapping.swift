import CSlopDeskFFI

/// The one coordinate conversion the host performs for every injected pointer event
/// (doc 18 §B, doc 05 §2).
///
/// The client streams **normalised (0..1) window coordinates**, never raw pixels, which removes the
/// pixel-versus-point ambiguity entirely — and leaves exactly one mapping to do here:
/// `target = windowBounds.origin + n * windowBounds.size`, computed in **CG top-left** space.
/// `kCGWindowBounds` and CGEvent mouse positions share that space, so the click coordinate needs
/// **no Y flip**; flipping here is the common mistake. The Retina `backingScaleFactor` does not
/// enter the math either — both sides are points.
///
/// The arithmetic lives in `slopdesk-video`, where the multiply and the add are kept separate: the
/// `coordWindowPoint` golden vector pins the result as raw `f64` bit patterns, and a fused
/// multiply-add moves them.
public enum CoordinateMapping {
    /// Maps a normalised (0..1) window point to a host-window point in **CG top-left** space, ready
    /// for `CGEvent(mouseCursorPosition:)` / `CGWarpMouseCursorPosition`.
    ///
    /// - Parameters:
    ///   - normalized: the click position within the window, x/y each in 0..1
    ///     (0,0 = window top-left, 1,1 = window bottom-right).
    ///   - windowBounds: `kCGWindowBounds` — the window rect in CG top-left points.
    /// - Returns: the absolute CG-space point to post the event at.
    public static func windowPoint(normalized: VideoPoint, windowBounds: VideoRect) -> VideoPoint {
        let point = slopdesk_coord_window_point(
            normalized.x,
            normalized.y,
            windowBounds.origin.x,
            windowBounds.origin.y,
            windowBounds.size.width,
            windowBounds.size.height,
        )
        return VideoPoint(x: point.x, y: point.y)
    }
}
