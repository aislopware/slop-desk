// OttyDesign — the "clean like otty.sh" design-token layer (REBUILD-V2, L5/L6).
//
// A THIN, headless token layer (no separate SPM target — the deleted `AislopdeskDesignSystem` stays
// deleted; these are just `Color`/`CGFloat`/`Animation` constants compiled into `AislopdeskClientUI`).
//
// SOURCE OF TRUTH: the reverse-engineering at /Volumes/Lacie/Workspace/oss/otty-reversed —
//   • `Assets/design-tokens.css`        → the dark + light token table (extracted from the binary's CSS).
//   • `Sources/UI/ReplicaKit.swift` `RC` → the "Paper" light palette MEASURED from the real app.
//   • `Sources/UI/ReplicaKit.swift` `Anim` + Docs/07 → the exact timing curves (no springs anywhere).
//
// Design DNA — "clean / modern / minimalist" (NOT flat):
//   - Floating rounded CARD: the terminal viewport is a radius-8 card inset from the window edges, over a
//     single shared material/glass backdrop that wraps around the card's margin.
//   - ONE backdrop: sidebar + titlebar + the margin strip share one material (no per-section fills).
//   - 8pt grid; ultra-thin structure: borders ~6% opacity, hover ~4–5% — low contrast = minimalist.
//   - Minimal palette: three text levels + an accent used ONLY for active state.
//
// DUAL-THEME: `OttyTheme` carries both `.paper` (default) and `.dark`. The static `Otty.*` accessors read
// `Otty.theme` (= .paper). Runtime switching (a later layer) repoints `theme` via a ThemeStore injected into
// each NSHostingController — Environment does NOT cross the AppKit split-controller boundary, so the tokens
// are intentionally static, matching the existing `NativePaneColor` pattern.

#if canImport(SwiftUI)
import SwiftUI

/// A full otty colour theme (every chrome role). Two instances ship: `.paper` (light, default) and `.dark`.
struct OttyTheme {
    // Surfaces (back → front)
    let window: Color // titlebar + margin backdrop (the "bg")
    let sidebar: Color // navigator / tabs panel
    let content: Color // the area behind the floating card
    let card: Color // the floating terminal card surface
    let element: Color // inset controls (search field, kbd, chips)

    // Text
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let icon: Color

    // Lines / borders
    let divider: Color // hairline separators
    let cardBorder: Color // the card's 1px border
    let border: Color // subtle control border (~6%)
    let borderActive: Color // active/hover control border (~15%)

    // Interaction
    let hover: Color // hover background plate
    let selected: Color // selected row background
    let header: Color // section header text
    let accent: Color // active-state accent (Paper = green, Dark = system blue)
    let accentMuted: Color // active-state background wash
    let panelShadow: Color // floating-card / panel drop shadow

    /// Whether this theme is light (drives `.preferredColorScheme` for the window).
    let isLight: Bool

    // Status / signal (theme-tuned)
    let statusOK: Color
    let statusWarn: Color
    let statusErr: Color
    let statusInfo: Color

    /// "Paper" — the real otty default, MEASURED from the app (`ReplicaKit.RC`). Warm off-white + green.
    static let paper = Self(
        window: Color(ottyHex: 0xFCFBF9),
        sidebar: Color(ottyHex: 0xF5F4F0),
        content: Color(ottyHex: 0xFCFBF9),
        card: .white,
        element: Color(ottyHex: 0xF0EFEA),
        textPrimary: Color(ottyHex: 0x37352F),
        textSecondary: Color(ottyHex: 0xB8B5AE),
        textTertiary: Color(ottyHex: 0xC9C6BE),
        icon: Color(ottyHex: 0x9A978F),
        divider: Color(ottyHex: 0xE0DFD5),
        cardBorder: Color(ottyHex: 0xEAE8E2),
        border: .black.opacity(0.05),
        borderActive: .black.opacity(0.15),
        hover: Color(ottyHex: 0xECEAE4),
        selected: Color(ottyHex: 0xE7E5DF),
        header: Color(ottyHex: 0xC9C6BE),
        accent: Color(ottyHex: 0x2B5A38), // green (ui-accent, measured)
        accentMuted: .black.opacity(0.06),
        panelShadow: .black.opacity(0.12),
        isLight: true,
        statusOK: Color(ottyHex: 0x2B5A38),
        statusWarn: Color(ottyHex: 0xB87A1E),
        statusErr: Color(ottyHex: 0xC0392B),
        statusInfo: Color(ottyHex: 0x007AFF),
    )

    /// otty Dark — from `design-tokens.css` (neutral grays + system-blue accent, opacity-based structure).
    static let dark = Self(
        window: Color(ottyHex: 0x161616),
        sidebar: Color(ottyHex: 0x1C1C1C),
        content: Color(ottyHex: 0x121212),
        card: Color(ottyHex: 0x1A1A1A),
        element: Color(ottyHex: 0x262626),
        textPrimary: Color(ottyHex: 0xEEEEEE),
        textSecondary: Color(ottyHex: 0x888888),
        textTertiary: Color(ottyHex: 0x8A8A8A),
        icon: Color(ottyHex: 0x8A8A8A),
        divider: .white.opacity(0.06),
        cardBorder: .white.opacity(0.06),
        border: .white.opacity(0.06),
        borderActive: .white.opacity(0.15),
        hover: .white.opacity(0.05),
        selected: .white.opacity(0.08),
        header: Color(ottyHex: 0x8A8A8A),
        accent: Color(ottyHex: 0x007AFF), // system blue
        accentMuted: .white.opacity(0.08),
        panelShadow: .black.opacity(0.40),
        isLight: false,
        statusOK: Color(ottyHex: 0x34C759),
        statusWarn: Color(ottyHex: 0xE5C07B),
        statusErr: Color(ottyHex: 0xE06C75),
        statusInfo: Color(ottyHex: 0x007AFF),
    )
}

/// Static token namespace. Colours read the active `theme` (default Paper); metrics/anim are theme-free.
enum Otty {
    /// The active theme. Default Paper; a later ThemeStore repoints this for runtime dark switching.
    static let theme: OttyTheme = .paper

    /// The preferred SwiftUI colour scheme for the active theme (drives `.preferredColorScheme`).
    static var colorScheme: ColorScheme { theme.isLight ? .light : .dark }

    enum Surface {
        static var window: Color { Otty.theme.window }
        static var sidebar: Color { Otty.theme.sidebar }
        static var content: Color { Otty.theme.content }
        static var card: Color { Otty.theme.card }
        static var element: Color { Otty.theme.element }
    }

    enum Text {
        static var primary: Color { Otty.theme.textPrimary }
        static var secondary: Color { Otty.theme.textSecondary }
        static var tertiary: Color { Otty.theme.textTertiary }
        static var icon: Color { Otty.theme.icon }
    }

    enum Line {
        static var divider: Color { Otty.theme.divider }
        static var card: Color { Otty.theme.cardBorder }
        static var subtle: Color { Otty.theme.border }
        static var active: Color { Otty.theme.borderActive }
    }

    enum State {
        static var hover: Color { Otty.theme.hover }
        static var selected: Color { Otty.theme.selected }
        static var accent: Color { Otty.theme.accent }
        static var accentMuted: Color { Otty.theme.accentMuted }
        static var header: Color { Otty.theme.header }
        static var shadow: Color { Otty.theme.panelShadow }
    }

    enum Status {
        static var ok: Color { Otty.theme.statusOK }
        static var warn: Color { Otty.theme.statusWarn }
        static var err: Color { Otty.theme.statusErr }
        static var info: Color { Otty.theme.statusInfo }
    }

    /// Geometry — theme-independent. Radii + the 8pt grid + chrome dimensions.
    enum Metric {
        // Radii (from design-tokens.css)
        static let radiusCard: CGFloat = 8
        static let radiusControl: CGFloat = 6
        static let radiusItem: CGFloat = 6
        static let radiusPill: CGFloat = 20

        // 8pt spacing grid
        static let space1: CGFloat = 4
        static let space2: CGFloat = 8
        static let space3: CGFloat = 12
        static let space4: CGFloat = 16

        // Floating-card insets — the card is inset from the window so the backdrop wraps around it.
        static let cardMargin = EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16)

        // Chrome dimensions
        static let paneHeaderHeight: CGFloat = 28
        static let sidebarWidth: CGFloat = 220
        static let hairline: CGFloat = 1
        static let cardBorderWidth: CGFloat = 1
        static let dividerHoverWidth: CGFloat = 2

        // Control plate (PlateIconButton)
        static let plate: CGFloat = 24
        static let iconSize: CGFloat = 13
    }

    /// Typography — base 12 / small 10; UI = system, code = JetBrains Mono.
    enum Typeface {
        static let base: CGFloat = 12
        static let small: CGFloat = 10
        static let mono = "JetBrains Mono"
    }

    /// Animation timing — extracted verbatim from `ReplicaKit.Anim` (cubic-bezier, NO springs anywhere).
    enum Anim {
        /// Relayout / panel / tab-select / indicator slide — EaseInEaseOut 0.20s.
        static let standard = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.20)
        /// animateIn / row reflow / toggle thumb — EaseOut 0.18s.
        static let fadeSlideIn = Animation.timingCurve(0, 0, 0.58, 1, duration: 0.18)
        /// Hover reveal / panel-toggle show — EaseOut 0.15s.
        static let reveal = Animation.timingCurve(0, 0, 0.58, 1, duration: 0.15)
        /// animateOut — EaseIn 0.14s.
        static let fadeOut = Animation.timingCurve(0.42, 0, 1, 1, duration: 0.14)
        /// Scroll fade / link pill / hover plate — EaseOut 0.12s.
        static let smallFade = Animation.timingCurve(0, 0, 0.58, 1, duration: 0.12)
        /// Divider / plate hover — EaseInEaseOut 0.16s.
        static let dividerHover = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.16)

        /// Titlebar hover-reveal DWELL before fade-out (seconds) — keeps controls clickable on exit.
        static let titlebarDwell: Double = 0.40
        /// Unfocused-pane dim opacity (`⌘D` split — non-focused panes fade to this).
        static let unfocusedPaneOpacity: Double = 0.6
    }
}

extension Color {
    /// 24-bit RGB hex literal initializer, e.g. `Color(ottyHex: 0xFC_FB_F9)`.
    init(ottyHex hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
#endif
