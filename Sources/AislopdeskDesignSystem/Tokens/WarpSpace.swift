// WarpSpace — spacing tokens (warp-tokens-layout.md §2). Warp has no named spacing scale; spacing is
// per-component literals on a loose 4-ish grid (2/3/4/5/8/10/12/15/24). We name the recurring values.

import CoreGraphics

public enum WarpSpace {
    // Generic 4-ish grid.
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 3
    public static let s: CGFloat = 4
    public static let m: CGFloat = 8
    public static let l: CGFloat = 10
    public static let xl: CGFloat = 12
    public static let xxl: CGFloat = 16

    /// `base_styles` padding — shared by buttons/radio/checkbox/span/list (builder.rs:89-94).
    public static let basePadVertical: CGFloat = 5
    public static let basePadHorizontal: CGFloat = 15

    /// Text-input uniform padding (builder.rs:117-122).
    public static let textInputPad: CGFloat = 10

    /// Dialog `BASE_PADDING` and its 2× horizontal inset (dialog.rs:24,27).
    public static let dialogBase: CGFloat = 12
    public static let dialogHorizontal: CGFloat = 24

    /// Default button horizontal padding (button/params.rs:135) / small (params.rs:152).
    public static let buttonPadHorizontal: CGFloat = 12
    public static let buttonPadHorizontalSmall: CGFloat = 8

    /// kb-shortcut: space between key caps (3), pill inner pad (4) (keyboard_shortcut.rs:38,52).
    public static let keyCapGap: CGFloat = 3
    public static let pillPad: CGFloat = 4

    /// Chip padding (chip.rs:77-78).
    public static let chipPadHorizontal: CGFloat = 4
    public static let chipPadVertical: CGFloat = 2

    // Chrome-specific (warp-window-chrome.md §13).
    /// Omnibar slot padding each side (view.rs:553).
    public static let omnibarSlotPad: CGFloat = 8
    /// Omnibar pill padding (view.rs:20141-20144).
    public static let omnibarPadHorizontal: CGFloat = 16
    public static let omnibarPadVertical: CGFloat = 4
    /// Tab-bar icon gap between buttons (view.rs:558).
    public static let tabBarIconGap: CGFloat = 4
    /// Tab-bar right padding (view.rs:551).
    public static let tabBarPadRight: CGFloat = 8
    /// Window content inset on all sides (WORKSPACE_PADDING) (view.rs:533).
    public static let workspacePadding: CGFloat = 1
}
