import Foundation

// MARK: - E8 WI-8 (H6): mouse-over-to-focus decision

/// The PURE, headless decision behind "Mouse-over-to-focus" / `focus-follows-mouse` (H6): given the
/// live setting and whether THIS pane is already the focused one, should hovering it claim the workspace
/// focus?
///
/// WHY this lives in slopdesk and not libghostty: libghostty's OWN `focus-follows-mouse` config key only
/// relays focus inside ghostty's INTERNAL split tree, but each slopdesk pane is a SEPARATE `GhosttySurface`
/// (the panes are tiled at the SwiftUI layer, not by ghostty), so the cross-pane focus relay must be ours.
/// The GUI view (`GhosttyTerminalView`, compile-only behind `#if canImport(CGhostty)`) is the thin actuator:
/// its `mouseEntered` / `mouseMoved` consult this policy and, on `true`, fire `TerminalViewModel.onRequestFocus`.
///
/// The ``shouldRequestFocus(focusFollowsMouse:isAlreadyFocused:)`` AND-gate's `!isAlreadyFocused` term is the
/// LOAD-BEARING short-circuit the plan calls out: `mouseMoved` fires on every pointer motion, so without it
/// an already-focused pane would re-fire `onRequestFocus` on every move, thrashing the workspace focus and
/// redrawing the title bar (the "flicker"). Pinned by `FocusFollowsMousePolicyTests` so a refactor that drops
/// the short-circuit fails the suite — the GUI view itself is outside the headless build and cannot be tested.
public enum FocusFollowsMousePolicy {
    /// Whether a hover over this pane should request the workspace focus.
    ///
    /// - Parameters:
    ///   - focusFollowsMouse: the live `focus-follows-mouse` setting (read by the view from
    ///     ``SettingsKey/focusFollowsMouseEnabled`` so a Settings toggle takes effect on the next hover).
    ///   - isAlreadyFocused: whether THIS pane is already the workspace's focused pane.
    /// - Returns: `true` only when the setting is ON **and** the pane is NOT already focused — the
    ///   already-focused short-circuit that prevents the per-`mouseMoved` title-bar flicker.
    public static func shouldRequestFocus(focusFollowsMouse: Bool, isAlreadyFocused: Bool) -> Bool {
        focusFollowsMouse && !isAlreadyFocused
    }
}
