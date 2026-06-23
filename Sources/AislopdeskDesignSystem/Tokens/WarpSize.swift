// WarpSize — component/chrome dimensions (warp-tokens-layout.md §3 + warp-window-chrome.md).

import CoreGraphics

public enum WarpSize {
    // MARK: Controls (warp-tokens-layout.md §3a)

    /// Default control height (button/params.rs:128) — input/pill row basis.
    public static let controlHeight: CGFloat = 32
    /// Compact control height (button/params.rs:145) — tab-row / bottom-pill basis.
    public static let controlHeightSmall: CGFloat = 24
    /// kb-shortcut pill height (builder.rs:52).
    public static let pillHeight: CGFloat = 24
    /// Switch thumb diameter (switch.rs:47); track = 2× (switch.rs:101).
    public static let switchThumb: CGFloat = 18
    public static let switchTrack: CGFloat = 36
    /// Radio outer circle (radio_buttons.rs:23).
    public static let radioDiameter: CGFloat = 20
    /// Checkbox box (builder.rs:670).
    public static let checkbox: CGFloat = 12

    // MARK: Icons (warp-window-chrome.md §4)

    /// Icon button touch target (icons.rs:6, buttons.rs:72).
    public static let iconButton: CGFloat = 24
    /// Icon button inset padding (buttons.rs:10).
    public static let iconButtonPadding: CGFloat = 4
    /// Effective icon glyph area = 24 − 2×4 (derived).
    public static let iconGlyph: CGFloat = 16

    // MARK: Chrome (warp-window-chrome.md §2/§3/§5/§7/§13)

    /// Title/tab bar height (view.rs:544) + 1pt border (tab.rs:57) = 35 total (view.rs:556).
    public static let titleBarHeight: CGFloat = 34
    public static let titleBarBorder: CGFloat = 1
    public static let titleBarTotalHeight: CGFloat = 35

    /// macOS traffic-light reserved width (traffic_lights.rs:74) and the tab-bar left inset
    /// (= 64 + 16) at zoom 1 (view.rs:20731-20750).
    public static let trafficLightWidth: CGFloat = 64
    public static let trafficLightInset: CGFloat = 80
    /// Full-screen left padding when traffic lights hidden (view.rs:20739-20741).
    public static let tabBarPadLeft: CGFloat = 4

    /// Omnibar pill max width (view.rs:552, 20147).
    public static let omnibarMaxWidth: CGFloat = 320

    /// Vertical-tabs rail (vertical_tabs.rs:87-89).
    public static let railWidth: CGFloat = 248
    public static let railMinWidth: CGFloat = 200
    /// Legacy non-VT rail default (resizable_data.rs:13).
    public static let railWidthLegacy: CGFloat = 240
    /// Rail/content divider width (view.rs:22043-22051).
    public static let railDivider: CGFloat = 1
    /// Panel surface margin (view.rs:22036) + scrollbar width (vertical_tabs.rs:1638).
    public static let panelMargin: CGFloat = 2
    public static let scrollbarWidth: CGFloat = 4

    /// Avatar circle (view.rs:21001-21002).
    public static let avatarCircle: CGFloat = 20
    /// Notification unread badge (view.rs:20589-20612).
    public static let badge: CGFloat = 6
}
