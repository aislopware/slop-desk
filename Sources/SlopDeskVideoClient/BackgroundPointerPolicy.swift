// BackgroundPointerPolicy — the pure decisions behind "background interaction": a SATELLITE window
// (the dedicated remote desktop / a ⌥⌘P pop-out) keeps taking POINTER input while it is NOT the key
// window, so the user hovers/scrolls/clicks the remote desktop while typing stays in the window they
// are working in. The AppKit mechanics live in `MetalLayerBackedView` (tracking-area activation scope,
// `acceptsFirstMouse` / `shouldDelayWindowOrdering` / `preventWindowOrdering`); the decisions live
// here so they are pinned headlessly — the video view itself is never instantiated in tests
// (hang-safety: no Metal/VT in unit tests).

/// Pure gate decisions for pointer input on a video surface whose window may not be key.
/// `backgroundPointer` = "this surface sits in a satellite window AND the user setting is ON" —
/// threaded through the `RemotePaneContext` seam. Canvas panes always pass `false`, preserving the
/// "only the active pane swallows pointer" rule there.
public enum BackgroundPointerPolicy {
    /// Whether pointer MOTION (hover `mouseMoved`, the enter-warp shape resync, the edge-pan
    /// re-forward, the host-shape local cursor) may forward to the host: the ACTIVE pane as ever, or
    /// any background-pointer surface. The read-only gate (`inputEnabled`) stays a separate,
    /// downstream check on every relay.
    public static func forwardsPointer(isActive: Bool, backgroundPointer: Bool) -> Bool {
        isActive || backgroundPointer
    }

    /// Whether a mouse-down is a BACKGROUND click: forwarded to the host with the local window left
    /// un-activated (`preventWindowOrdering`) and the local pane activation (`onActivate`) skipped —
    /// local focus must not move at all. A KEY window always takes the normal activate path:
    /// background mode changes only the not-key case.
    public static func backgroundClick(backgroundPointer: Bool, windowIsKey: Bool) -> Bool {
        backgroundPointer && !windowIsKey
    }
}
