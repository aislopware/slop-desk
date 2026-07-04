// SlateDesign — the CANVAS theme engine (native-chrome migration, 2026-07-03; see docs/DECISIONS.md).
//
// The window chrome is native SwiftUI now (system semantic colors / materials / text styles) — this file
// no longer styles chrome. What it owns is the terminal/video CANVAS: the `SlateTheme` palettes (the six
// Monokai Pro filters — `.monokaiProClassic` the DEFAULT — plus the legacy `.paper`/`.dark`), whose
// `terminalBackgroundHex`/`terminalForegroundHex`/`ansiPalette`/cursor fields pin the libghostty CELLS,
// and whose surface roles paint the canvas FABRIC around them (the pane surface, the pane hairline
// divider, the build-status placeholder). FLAT HAIRLINE CANVAS (2026-07-04 v2, replacing the one-day
// card-canvas — docs/research/ui-restructure-2026-07-04.md): panes tile ONE continuous `Surface.card`
// surface edge-to-edge; adjacent split panes are separated by a resting `Line.divider` hairline; focus
// reads as the unfocused-sibling dim, not chrome. The chrome around the canvas follows the OS.
//
// The surviving `Slate.*` accessors read `Slate.theme`, which (D3) indirects through
// `ThemeStore.shared.active` so a runtime theme switch repoints the canvas live (one SwiftUI hierarchy now
// — plain `@Observable` observation is all it takes; the old `NSWindow.appearance` re-pin died with the
// AppKit split shell).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import SwiftUI

/// A full colour theme (every chrome role). Two instances ship: `.paper` (light, default) and `.dark`.
struct SlateTheme: Equatable {
    // Surfaces (back → front)
    let window: Color // titlebar + margin backdrop (the "bg")
    let sidebar: Color // navigator / tabs panel
    let content: Color // the area behind the floating card
    let card: Color // the terminal surface — flush paper (RC.bg), NOT a brighter-white card
    let selectedCard: Color // the active sidebar-tab card fill (white-on-paper, RC.card)
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
    /// The active-state accent as a canonical 6-hex string (no `#`) — MIRRORS ``accent``'s colour.
    let accentHex: String
    let accentMuted: Color // active-state background wash
    let panelShadow: Color // floating-card / panel drop shadow

    /// Whether this theme is light (drives `.preferredColorScheme` for the window).
    let isLight: Bool

    // Status / signal (theme-tuned)
    let statusOK: Color
    let statusWarn: Color
    let statusErr: Color
    let statusInfo: Color

    /// Stable identity for change-detection — distinguishes a real theme switch from an idempotent re-apply
    /// so a SAME-LIGHTNESS variant change (e.g. Monokai Classic → Spectrum) still posts the cross-boundary
    /// repaint. Pure discriminator, never a colour.
    let id: String

    /// The libghostty terminal `background` colour (6-hex, no `#`) — pins the terminal CELLS to the SAME flat
    /// background as the chrome (flat design: terminal content and pane backdrop are one colour). Applied
    /// via ``TerminalConfigBuilder`` through the ``AppearanceApplier`` terminal-colour hook.
    let terminalBackgroundHex: String
    /// The libghostty terminal `foreground` colour (6-hex, no `#`).
    let terminalForegroundHex: String

    /// The 16 ANSI terminal colours (indices 0–15: 0=black … 7=white, 8–15 = bright). 6-hex, no `#`. Reaches
    /// the terminal CELLS via ``TerminalConfigBuilder`` `palette = N=<hex>`. Built-ins ship a canonical palette.
    let ansiPalette: [String]
    /// Selection highlight background (`selection-background`), 6-hex no `#`; `nil` ⇒ let the renderer pick.
    let selectionBackgroundHex: String?
    /// Cursor block colour (`cursor-color`), 6-hex no `#`; `nil` ⇒ follow the foreground.
    let cursorHex: String?
    /// Glyph-under-cursor colour (`cursor-text`), 6-hex no `#`; `nil` ⇒ follow the background.
    let cursorTextHex: String?

    /// "Paper" — the original warm off-white + green light palette; kept as a selectable theme (the default
    /// is now Monokai Pro Classic).
    static let paper = Self(
        window: Color(slateHex: 0xFCFBF9),
        sidebar: Color(slateHex: 0xF5F4F0),
        content: Color(slateHex: 0xFCFBF9),
        card: Color(slateHex: 0xFCFBF9), // terminal surface = warm paper — flush, borderless panel (flat: no card look)
        selectedCard: .white, // active-tab card = pure white on paper (RC.card)
        element: Color(slateHex: 0xF0EFEA),
        textPrimary: Color(slateHex: 0x37352F),
        textSecondary: Color(slateHex: 0xB8B5AE),
        textTertiary: Color(slateHex: 0xC9C6BE),
        icon: Color(slateHex: 0x9A978F),
        divider: Color(slateHex: 0xE0DFD5),
        cardBorder: Color(slateHex: 0xEAE8E2),
        border: .black.opacity(0.05),
        borderActive: .black.opacity(0.15),
        hover: Color(slateHex: 0xECEAE4),
        selected: Color(slateHex: 0xE7E5DF),
        header: Color(slateHex: 0xC9C6BE),
        accent: Color(slateHex: 0x2B5A38), // green (ui-accent, measured)
        accentHex: "2B5A38",
        accentMuted: .black.opacity(0.06),
        panelShadow: .black.opacity(0.12),
        isLight: true,
        statusOK: Color(slateHex: 0x2B5A38),
        statusWarn: Color(slateHex: 0xB87A1E),
        statusErr: Color(slateHex: 0xC0392B),
        statusInfo: Color(slateHex: 0x007AFF),
        id: "paper",
        terminalBackgroundHex: "FCFBF9",
        terminalForegroundHex: "37352F",
        // Warm light-terminal ANSI set (matches the two-row swatch grid in `dark-mode-theme.png`'s Paper
        // preview): normal 0–7 then the lighter bright 8–15.
        ansiPalette: [
            "37352F", "B23B3B", "2E6B3E", "C2731A", "3D7A99", "3C2E66", "2E7D6E", "C9C6BE",
            "8A8780", "C57A7A", "7FAE84", "D6A35C", "8AAAC2", "9387B5", "7FC4B5", "E8E6DE",
        ],
        selectionBackgroundHex: "E7E5DF",
        cursorHex: "37352F",
        cursorTextHex: nil,
    )

    /// Dark — neutral grays + system-blue accent, opacity-based structure.
    static let dark = Self(
        window: Color(slateHex: 0x161616),
        sidebar: Color(slateHex: 0x1C1C1C),
        content: Color(slateHex: 0x121212),
        card: Color(slateHex: 0x161616), // FLAT: pane surface == window backdrop (flat design, no card)
        selectedCard: Color(slateHex: 0x2A2A2A), // active-tab card = slightly elevated panel on the dark sidebar
        element: Color(slateHex: 0x262626),
        textPrimary: Color(slateHex: 0xEEEEEE),
        textSecondary: Color(slateHex: 0x888888),
        textTertiary: Color(slateHex: 0x8A8A8A),
        icon: Color(slateHex: 0x8A8A8A),
        // Derive the structure hairlines from the theme's own text tone (0xEEEEEE) rather than a flat
        // `Color.white`, so the dark divider matches the palette instead of reading as a white outlier.
        divider: Color(slateHex: 0xEEEEEE).opacity(0.06),
        cardBorder: Color(slateHex: 0xEEEEEE).opacity(0.06),
        border: .white.opacity(0.06),
        borderActive: .white.opacity(0.15),
        hover: .white.opacity(0.05),
        selected: .white.opacity(0.08),
        header: Color(slateHex: 0x8A8A8A),
        accent: Color(slateHex: 0x007AFF), // system blue
        accentHex: "007AFF",
        accentMuted: .white.opacity(0.08),
        panelShadow: .black.opacity(0.40),
        isLight: false,
        statusOK: Color(slateHex: 0x34C759),
        statusWarn: Color(slateHex: 0xE5C07B),
        statusErr: Color(slateHex: 0xE06C75),
        statusInfo: Color(slateHex: 0x007AFF),
        id: "dark",
        terminalBackgroundHex: "161616",
        terminalForegroundHex: "EEEEEE",
        // Neutral dark-terminal ANSI set (One-Dark-style — a clean general-purpose dark palette to match the
        // grey chrome + system-blue accent).
        ansiPalette: [
            "2A2A2A", "E06C75", "98C379", "E5C07B", "61AFEF", "C678DD", "56B6C2", "ABB2BF",
            "5C6370", "E06C75", "98C379", "E5C07B", "61AFEF", "C678DD", "56B6C2", "FFFFFF",
        ],
        selectionBackgroundHex: "2A2A2A",
        cursorHex: "EEEEEE",
        cursorTextHex: nil,
    )

    // MARK: - Monokai Pro filters (palette from monokai.pro/contribute; cross-verified across 4 ports)

    /// The seed colours a Monokai Pro filter contributes; every other chrome role is DERIVED from these with
    /// the shared structure opacities, so all variants have identical chrome geometry — only the hues change.
    /// FLAT by construction (re-affirmed by the flat hairline canvas, 2026-07-04 v2): `window == content ==
    /// card == background`, so a pane's surface matches the backdrop beneath it — one continuous field, no
    /// floating card, no corner radius.
    private struct MonokaiSeed {
        let name: String
        let background: UInt32 // window + content + card (the one flat background)
        let sidebar: UInt32 // bg-dimmed-1 — the navigator panel, a touch off the backdrop
        let elevated: UInt32 // active-tab card + inset controls (dimmed-5 dark / white light)
        let foreground: UInt32 // primary text
        let secondary: UInt32 // dimmed-2 — secondary text + icons
        let tertiary: UInt32 // dimmed-3 — tertiary text + section headers
        let accent: UInt32 // active-state accent (the filter's blue/cyan) — ANSI cyan (idx 6/14)
        let ok: UInt32 // status OK (green) — ANSI green (idx 2/10)
        let warn: UInt32 // status warn (yellow) — ANSI yellow (idx 3/11)
        let err: UInt32 // status error (red) — ANSI red (idx 1/9)
        let info: UInt32 // status info (blue) — usually == accent
        let orange: UInt32 // the filter's orange — Monokai's ANSI "blue" slot (idx 4/12)
        let purple: UInt32 // the filter's purple — ANSI magenta (idx 5/13)
        let isLight: Bool
    }

    /// Build a full ``SlateTheme`` from a Monokai ``MonokaiSeed`` — structural opacities (borders / hover /
    /// selection) are shared and keyed only on light/dark; the colour roles come from the seed.
    private static func monokai(_ s: MonokaiSeed) -> Self {
        // Structure tints (divider / borders / hover / selection) DERIVE from the theme palette, not a
        // hardcoded black/white: a DARK filter seeds them from its FOREGROUND so every variant's hairline
        // carries that filter's own hue (teal-white for Machine, warm-rose for Ristretto, cool-violet for
        // Spectrum) instead of one flat `Color.white` outlier shared by all five — the "divider của dark
        // theme đang màu trắng / hardcode" report. Light filters keep a near-black structure line.
        let line = Color(slateHex: s.isLight ? 0x000000 : s.foreground)
        return Self(
            window: Color(slateHex: s.background),
            sidebar: Color(slateHex: s.sidebar),
            content: Color(slateHex: s.background),
            card: Color(slateHex: s.background), // FLAT: pane surface == backdrop
            selectedCard: Color(slateHex: s.elevated),
            element: Color(slateHex: s.elevated),
            textPrimary: Color(slateHex: s.foreground),
            textSecondary: Color(slateHex: s.secondary),
            textTertiary: Color(slateHex: s.tertiary),
            icon: Color(slateHex: s.secondary),
            divider: line.opacity(s.isLight ? 0.08 : 0.07),
            cardBorder: line.opacity(s.isLight ? 0.08 : 0.07),
            border: line.opacity(s.isLight ? 0.05 : 0.06),
            borderActive: line.opacity(0.15),
            hover: line.opacity(s.isLight ? 0.045 : 0.05),
            selected: line.opacity(s.isLight ? 0.07 : 0.09),
            header: Color(slateHex: s.tertiary),
            accent: Color(slateHex: s.accent),
            accentHex: hex6(s.accent),
            accentMuted: line.opacity(s.isLight ? 0.06 : 0.10),
            panelShadow: Color.black.opacity(s.isLight ? 0.12 : 0.40),
            isLight: s.isLight,
            statusOK: Color(slateHex: s.ok),
            statusWarn: Color(slateHex: s.warn),
            statusErr: Color(slateHex: s.err),
            statusInfo: Color(slateHex: s.info),
            id: "monokai-\(s.name)",
            terminalBackgroundHex: hex6(s.background),
            terminalForegroundHex: hex6(s.foreground),
            // Canonical Monokai Pro terminal palette: color0 = background (Monokai's quirk), the 6 filter
            // chromatics in ANSI order (red/green/yellow, then orange in the "blue" slot, purple, cyan),
            // white = foreground; the bright row 8–15 repeats the chromatics with bright-black = dimmed grey.
            ansiPalette: [
                hex6(s.background), hex6(s.err), hex6(s.ok), hex6(s.warn),
                hex6(s.orange), hex6(s.purple), hex6(s.accent), hex6(s.foreground),
                hex6(s.tertiary), hex6(s.err), hex6(s.ok), hex6(s.warn),
                hex6(s.orange), hex6(s.purple), hex6(s.accent), hex6(s.foreground),
            ],
            selectionBackgroundHex: hex6(s.elevated),
            cursorHex: hex6(s.foreground),
            cursorTextHex: nil,
        )
    }

    /// 6-hex uppercase string (no `#`) for a 24-bit RGB literal — the libghostty `background`/`foreground`
    /// config value format. Manual (no `String(format:)`) to stay allocation-cheap and trap-free.
    private static func hex6(_ v: UInt32) -> String {
        func pair(_ x: UInt32) -> String {
            let s = String(x & 0xFF, radix: 16, uppercase: true)
            return (x & 0xFF) < 0x10 ? "0" + s : s
        }
        return pair(v >> 16) + pair(v >> 8) + pair(v)
    }

    /// Monokai Pro (Classic) — the DEFAULT theme (dark). bg #2D2A2E, the canonical Monokai Pro filter.
    static let monokaiProClassic = monokai(MonokaiSeed(
        name: "classic", background: 0x2D2A2E, sidebar: 0x221F22, elevated: 0x403E41,
        foreground: 0xFCFCFA, secondary: 0x939293, tertiary: 0x727072,
        accent: 0x78DCE8, ok: 0xA9DC76, warn: 0xFFD866, err: 0xFF6188, info: 0x78DCE8,
        orange: 0xFC9867, purple: 0xAB9DF2, isLight: false,
    ))

    // P5 (Phase-C GUI audit): the navigator `sidebar` was a touch dim/cool vs the intended warm cream/paper. Nudged
    // 0xEDE7E5 → 0xF1EBE8 — brighter + a hair warmer, HUE-PRESERVING (keeps the seed's rose R>G>B ratio, just
    // closer to the warm `background`) so the navigator reads as warm paper, not grey. Only `sidebar` moves —
    // `background`/`elevated` (the flat backdrop + active-tab card) are untouched, so no surface ripples.
    /// Monokai Pro Light (Classic Light) — the warm off-white light filter.
    static let monokaiProClassicLight = monokai(MonokaiSeed(
        name: "classic-light", background: 0xFAF4F2, sidebar: 0xF1EBE8, elevated: 0xFFFFFF,
        foreground: 0x29242A, secondary: 0x918C8E, tertiary: 0xA59FA0,
        accent: 0x1C8CA8, ok: 0x269D69, warn: 0xCC7A0A, err: 0xE14775, info: 0x1C8CA8,
        orange: 0xD4572B, purple: 0x7058BE, isLight: true,
    ))

    /// Monokai Pro (Filter Octagon) — cool blue-purple dark filter. bg #282A3A.
    static let monokaiProOctagon = monokai(MonokaiSeed(
        name: "octagon", background: 0x282A3A, sidebar: 0x1E1F2B, elevated: 0x3A3D4B,
        foreground: 0xEAF2F1, secondary: 0x888D94, tertiary: 0x696D77,
        accent: 0x9CD1BB, ok: 0xBAD761, warn: 0xFFD76D, err: 0xFF657A, info: 0x9CD1BB,
        orange: 0xFF9B5E, purple: 0xC39AC9, isLight: false,
    ))

    /// Monokai Pro (Filter Machine) — teal-green dark filter. bg #273136.
    static let monokaiProMachine = monokai(MonokaiSeed(
        name: "machine", background: 0x273136, sidebar: 0x1D2528, elevated: 0x3A4449,
        foreground: 0xF2FFFC, secondary: 0x8B9798, tertiary: 0x6B7678,
        accent: 0x7CD5F1, ok: 0xA2E57B, warn: 0xFFED72, err: 0xFF6D7E, info: 0x7CD5F1,
        orange: 0xFFB270, purple: 0xBAA0F8, isLight: false,
    ))

    /// Monokai Pro (Filter Ristretto) — warm coffee dark filter. bg #2C2525.
    static let monokaiProRistretto = monokai(MonokaiSeed(
        name: "ristretto", background: 0x2C2525, sidebar: 0x211C1C, elevated: 0x403838,
        foreground: 0xFFF1F3, secondary: 0x948A8B, tertiary: 0x72696A,
        accent: 0x85DACC, ok: 0xADDA78, warn: 0xF9CC6C, err: 0xFD6883, info: 0x85DACC,
        orange: 0xF38D70, purple: 0xA8A9EB, isLight: false,
    ))

    /// Monokai Pro (Filter Spectrum) — neutral near-black dark filter. bg #222222.
    static let monokaiProSpectrum = monokai(MonokaiSeed(
        name: "spectrum", background: 0x222222, sidebar: 0x191919, elevated: 0x363537,
        foreground: 0xF7F1FF, secondary: 0x8B888F, tertiary: 0x69676C,
        accent: 0x5AD4E6, ok: 0x7BD88F, warn: 0xFCE566, err: 0xFC618D, info: 0x5AD4E6,
        orange: 0xFD9353, purple: 0x948AE3, isLight: false,
    ))
}

/// The CANVAS token namespace (native-chrome migration, 2026-07-03): the window chrome is native SwiftUI
/// (system semantic colors / materials / text styles) and no longer reads tokens; what survives here is
/// exactly what the terminal/video CANVAS FABRIC needs — the theme-driven backdrops the panes/dividers/
/// placeholder sit on, plus the few theme-legible roles that must render over them (a system semantic
/// color could land dark-on-dark when the OS appearance and the canvas theme disagree).
enum Slate {
    /// The active theme. Indirected through ``ThemeStore/shared`` (D3) so runtime theme switching repoints
    /// every token live — `@MainActor` because the store is, and every read site is a SwiftUI `body`
    /// (all MainActor).
    @MainActor static var theme: SlateTheme { ThemeStore.shared.active }

    // The colour namespaces are `@MainActor` because they read the runtime ``ThemeStore`` via
    // ``Slate/theme`` (D3). Only the CANVAS-consumed roles survive — chrome roles (hover/selected/header/
    // shadow/element/…) were deleted with their last consumers; the underlying ``SlateTheme`` struct keeps
    // every field (it is the theme DATA, shipped per theme and read by the terminal-colour resolution).
    @MainActor
    enum Surface {
        /// THE canvas surface (flat hairline canvas, 2026-07-04 v2): the one continuous theme
        /// background every pane, column and the detail region render on — matches the libghostty
        /// terminal cells' background, so pane content and canvas fabric are a single field.
        static var card: Color { Slate.theme.card }
    }

    @MainActor
    enum Text {
        // Theme-legible text over the canvas backdrop (BuildStatusPlaceholderView) — a system semantic
        // color would follow the OS appearance and could vanish against a dark themed canvas.
        static var primary: Color { Slate.theme.textPrimary }
        static var secondary: Color { Slate.theme.textSecondary }
    }

    @MainActor
    enum Line {
        /// The resting 1pt hairline between two split panes / the two workspace columns (flat hairline
        /// canvas, 2026-07-04 v2) — theme-derived so it carries the filter's own hue over the canvas
        /// (never a flat system gray that would clash with a warm/tinted filter).
        static var divider: Color { Slate.theme.divider }
    }

    @MainActor
    enum State {
        /// The theme accent — the pane divider's active-drag hairline (canvas-adjacent).
        static var accent: Color { Slate.theme.accent }
    }

    @MainActor
    enum Status {
        /// Theme-legible "live" dot on the canvas placeholder (BuildStatusPlaceholderView).
        static var ok: Color { Slate.theme.statusOK }
        /// The theme info tone — kept as the counter-example ``SecureInputPillColorTests`` pins
        /// ``secureInput`` against (re-routing the pill back to a theme tone is the guarded regression).
        static var info: Color { Slate.theme.statusInfo }

        /// FIXED security-blue — theme-INDEPENDENT (NOT derived from `Slate.theme`), unlike ``info``. The
        /// secure-input pill must read as the SAME vivid royal-blue on every theme so it can never be confused
        /// with the theme accent: under the default Monokai Pro seed `statusInfo` collapses to the cyan accent
        /// (`info == accent == 0x78DCE8`), which would make a theme-derived security badge indistinguishable
        /// from the accent. Pinned to `secure-input.png`'s royal-blue (#2D6FE8) — a mid royal-blue that keeps
        /// white pill text legible on BOTH light and dark themes. Never re-route this through the theme.
        static let secureInput = Color(slateHex: 0x2D6FE8)
    }

    /// Geometry — theme-independent. Only the canvas-consumed dimension survives (chrome geometry is
    /// native SwiftUI literals now; the card-era `paneCornerRadius`/`paneGap` died with the flat
    /// hairline canvas, 2026-07-04 v2 — panes tile edge-to-edge).
    enum Metric {
        /// The pane divider's thicker active-drag hairline (PaneDivider).
        static let dividerHoverWidth: CGFloat = 2
    }

    /// Typography — only the canvas placeholder's sizes survive (chrome text is system text styles now).
    enum Typeface {
        /// Large empty-state / placeholder glyph (BuildStatusPlaceholderView).
        static let display: CGFloat = 40
        /// The placeholder's primary line.
        static let body: CGFloat = 13
        /// The placeholder's secondary/mono line.
        static let footnote: CGFloat = 11
    }

    /// Animation timing — only the pane divider's hover curve survives (chrome animation is native
    /// `.easeOut`/`.easeInOut` literals now; still NO springs anywhere).
    enum Anim {
        /// Divider hover/drag — EaseInEaseOut 0.16s.
        static let dividerHover = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.16)
    }
}

extension Color {
    /// 24-bit RGB hex literal initializer, e.g. `Color(slateHex: 0xFC_FB_F9)`.
    init(slateHex hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
#endif
