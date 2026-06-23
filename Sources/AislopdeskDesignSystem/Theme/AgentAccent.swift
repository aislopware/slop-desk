// AgentAccent + fixed status literals — the theme-INDEPENDENT color constants
// (warp-tokens-color.md §3a, ORCH-DECISIONS F1).
//
// IMPORTANT distinction (warp-tokens-color.md §2a note + §5): the terminal/theme accent is teal
// `#19AAD8`. The orange in the agentic/Claude UI is a SEPARATE brand color, applied independently of
// the theme. We expose BOTH Claude tints:
//   - `claudeOrange` `#E8704E`  — the model/brand orange (`color::CLAUDE_ORANGE`, `color/mod.rs:15-21`)
//   - `footerBrand`  `#D97757`  — the agent/Claude BOTTOM-BAR brand tint (bottom-bar spec); the footer
//                                  uses this value, distinct from the terminal accent.

import Foundation

/// Theme-independent agent/brand accents.
public enum AgentAccent {
    /// Claude model/brand orange `#E8704E` (warp-tokens-color.md §3a, `color/mod.rs:15-21`).
    public static let claudeOrange = ColorU(u32: 0xE870_4EFF)

    /// Claude bottom-bar/footer brand tint `#D97757` (ORCH-DECISIONS F1; separate from the terminal accent).
    public static let footerBrand = ColorU(u32: 0xD977_57FF)
}

/// Fixed `ui_*` semantic literals — theme-INDEPENDENT (warp-tokens-color.md §3a, §6 point 3).
public enum UIStatus {
    /// `ui_warning_color()` `#C28000` (`color.rs:135-137`).
    public static let warning = ColorU(u32: 0xC280_00FF)
    /// `ui_error_color()` `#BC362A` (`color.rs:139-141`).
    public static let error = ColorU(u32: 0xBC36_2AFF)
    /// `ui_yellow_color()` `#E5A01A` (`color.rs:143-145`).
    public static let yellow = ColorU(u32: 0xE5A0_1AFF)
    /// `ui_green_color()` `#1CA05A` (`color.rs:147-149`).
    public static let green = ColorU(u32: 0x1CA0_5AFF)
    /// `Fill::success()` `#008E41` (`theme/mod.rs:308-311`).
    public static let success = ColorU(u32: 0x008E_41FF)

    /// `text_selection_color()` `rgba(118,167,250,102)` = `#76A7FA @ 40%` — fixed blue, NOT themed
    /// (warp-tokens-color.md §3a/§5, `color.rs:300-302`).
    public static let textSelection = ColorU(r: 118, g: 167, b: 250, a: 102)

    /// `Fill::blur()` `rgba(0,0,0,179)` (≈70% black blur backdrop) (`theme/mod.rs:303-306`).
    public static let blurBackdrop = ColorU(r: 0, g: 0, b: 0, a: 179)
}
