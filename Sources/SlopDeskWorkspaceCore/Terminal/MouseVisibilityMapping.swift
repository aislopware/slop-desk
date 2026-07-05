import Foundation

// MARK: - E8 (H9 / ES-E8-6): mouse-hide-while-typing visibility mapping

/// Swift mirror of libghostty's `ghostty_action_mouse_visibility_e` C enum (`apprt.action.MouseVisibility`,
/// `CGhostty/ghostty.h:709-713`). The raw values are pinned to the C enum's declaration order so an `Int32`
/// delivered by a `GHOSTTY_ACTION_MOUSE_VISIBILITY` action maps 1:1 WITHOUT importing `CGhostty` into this
/// headless, AppKit-free module — keeping the visibility decision unit-testable.
///
/// `mouse-hide-while-typing = true` (H9, default ON) only makes libghostty DECIDE to hide the pointer;
/// it then delegates the actual hide/show to the embedder via this action (`Surface.zig` `hideMouse`/
/// `showMouse` → `performAction(.mouse_visibility, .hidden/.visible)`). The GUI surface
/// (`GhosttyTerminalView`, compile-only behind `#if canImport(CGhostty)`) reads the raw int and asks
/// ``MouseVisibilityMapping`` whether the pointer should be visible, then drives `NSCursor`.
public enum MouseVisibility: Int32, CaseIterable, Sendable, Equatable {
    case visible = 0
    case hidden = 1
}

/// The PURE, headless mouse-visibility decision (H9). Reads the raw `ghostty_action_mouse_visibility_e`
/// value the C `action_cb` hands across as an `Int32` and resolves whether the pointer should be VISIBLE.
public enum MouseVisibilityMapping {
    /// Resolve a raw `ghostty_action_mouse_visibility_e` value to whether the pointer should be VISIBLE.
    ///
    /// Reads the enum EXPLICITLY (compares against the `hidden` case) rather than assuming a `{0,1}` layout:
    /// ONLY the explicit `hidden` value hides; every other value — `visible` AND any unknown / corrupt /
    /// future int — resolves to VISIBLE. That is the safe default (validate-then-drop): a bad value can never
    /// strand the pointer permanently hidden, only fail-safe to shown.
    public static func isVisible(forRawValue raw: Int32) -> Bool {
        MouseVisibility(rawValue: raw) != .hidden
    }
}
