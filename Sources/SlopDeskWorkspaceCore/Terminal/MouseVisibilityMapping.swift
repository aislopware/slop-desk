import CSlopDeskFFI

// MARK: - mouse-hide-while-typing visibility mapping

/// The mouse-visibility face.
///
/// `mouse-hide-while-typing = true` (default ON) only makes libghostty DECIDE to hide the pointer; it
/// then delegates the hide/show to the embedder via `GHOSTTY_ACTION_MOUSE_VISIBILITY` (`Surface.zig`
/// `hideMouse`/`showMouse`). The GUI surface (`GhosttyTerminalView`, compile-only behind
/// `#if canImport(CGhostty)`) reads the raw `ghostty_action_mouse_visibility_e` and asks here.
public enum MouseVisibilityMapping {
    /// Whether the pointer should be VISIBLE.
    ///
    /// Only the explicit hidden value hides — every other input, including any unknown, corrupt or
    /// future one, shows the pointer. The two failures are not symmetrical: a pointer wrongly shown is
    /// a cosmetic miss during typing, and a pointer wrongly hidden is a person moving a mouse they
    /// cannot see, with no gesture that brings it back. The rule lives in
    /// `slopdesk_terminal::pointer`, next to the shape table that arrives through the same callback.
    public static func isVisible(forRawValue raw: Int32) -> Bool {
        slopdesk_pointer_mouse_visible(raw)
    }
}
