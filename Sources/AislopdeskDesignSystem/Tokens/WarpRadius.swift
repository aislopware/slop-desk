// WarpRadius — corner radii (warp-tokens-layout.md §3c).

import CoreGraphics

public enum WarpRadius {
    /// Standard control radius — buttons/inputs/tooltip/dialog-footer ctrls/links (builder.rs:96).
    public static let control: CGFloat = 4
    /// Dialog/sheet card radius (dialog.rs:18); also the panel-surface corner (view.rs:680).
    public static let dialog: CGFloat = 8
    /// kb-shortcut / segmented pill radius (keyboard_shortcut.rs:187).
    public static let pill: CGFloat = 3
    /// Checkbox box radius (builder.rs:674).
    public static let checkbox: CGFloat = 2
    /// Full pill / circle (Radius::Percentage(50.)) — switch/slider/radio/avatar.
    public static let full: CGFloat = .infinity
}

public enum WarpBorder {
    /// Standard 1px hairline — buttons/base/text-input/tooltip/dialog/pill (builder.rs:95).
    public static let width: CGFloat = 1
    /// Radio outer ring stroke (radio_buttons.rs:20).
    public static let radioWidth: CGFloat = 1.5
}
