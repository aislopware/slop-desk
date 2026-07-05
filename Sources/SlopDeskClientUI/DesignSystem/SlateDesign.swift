// SlateDesign — the minimalist design-token layer (REBUILD-V2, L5/L6).
//
// A THIN, headless token layer: no separate SPM target (`SlopDeskDesignSystem` stays deleted) — just
// `Color`/`CGFloat`/`Animation` constants compiled into `SlopDeskClientUI`. Source of truth for the tokens:
// the theme structs below, `.paper`'s hand-tuned light palette, and `Slate.Anim`'s timing curves (no
// springs anywhere).
//
// Design DNA — "clean / modern / minimalist", FLAT, relit by MERIDIAN L5 (2026-07-04):
//   - FLAT pane: the terminal viewport fills its leaf edge-to-edge, NO corner radius, NO card; adjacent
//     split panes are separated only by the hairline `PaneDivider`.
//   - MERIDIAN L5 (depth by light, not lines): the SIDEBAR column sits ONE luminance step BELOW the pane
//     surface (`card`/`content` = the seed background) — pane = lit face, sidebar = unlit housing. The step
//     IS the structure; no divider between. SCOPE (user report "title màu khác với pane… lạc quẻ"): the
//     CONTENT column is lit end-to-end — its titlebar band paints the pane tone, because panes sit flush
//     under it (no gap/radius) and a darker strip there reads as a mispainted header. `window` (== sidebar
//     tone) stays the ground of AUXILIARY windows (Settings / first-launch / overlays), which are chrome,
//     not pane.
//   - 8pt grid; ultra-thin structure: borders ~6% opacity, hover ~4–5% — low contrast = minimalist.
//   - Minimal palette: three text levels + an accent used ONLY for active state.
//
// MULTI-THEME: `SlateTheme` ships the six Monokai Pro filters (`.monokaiProClassic` — the DEFAULT — plus
// Light / Octagon / Machine / Ristretto / Spectrum) plus the legacy `.paper` / `.dark`. `Slate.*` accessors
// read `Slate.theme`, which (D3) indirects through `ThemeStore.shared.active` (default `.monokaiProClassic`)
// so runtime switching repoints every token live. Each theme carries the
// `terminalBackgroundHex`/`terminalForegroundHex` that pin the libghostty cells to the same flat palette.
// SwiftUI `@Environment`/`.preferredColorScheme` does NOT cross the AppKit split-controller boundary into
// the column `NSHostingController`s, so the runtime theme rides this `@Observable` store + an
// `NSWindow.appearance` re-pin (in `SlopDeskSplitViewController`) — the `ThemeStore`-backed `@MainActor`
// accessors keep the `NativePaneColor` injection pattern.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import SwiftUI

/// A full colour theme (every chrome role). Two instances ship: `.paper` (light, default) and `.dark`.
struct SlateTheme: Equatable {
    // Surfaces — the 3-rung ladder (MERIDIAN C1). Exactly three names, each REAL in every theme (a rung
    // that collapses to another gets DELETED, not kept as aspirational vocabulary):
    //   ground → chrome housing: sidebar column + auxiliary windows (Settings / overlays' backdrop)
    //   face   → the lit pane surface: terminal cells, the content column, sheet/popover grounds
    //   raised → one step lifted: active row card, popover panels, inset controls (search / kbd / chips)
    let ground: Color
    let face: Color
    let raised: Color

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

    /// "Paper" — the original warm off-white + green light palette; a selectable theme (default is now
    /// Monokai Pro Classic).
    static let paper = Self(
        // MERIDIAN L5: chrome recedes onto the `ground` tone; the pane keeps the brighter paper (`face`).
        ground: Color(slateHex: 0xF5F4F0),
        face: Color(slateHex: 0xFCFBF9), // terminal surface = warm paper — flush, borderless panel (flat: no card look)
        raised: .white, // active-tab card / popover / inset controls = pure white on paper (RC.card)
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
        // MERIDIAN L5: chrome DARKER than the pane surface (0x161616) — inverted from the old
        // sidebar-lighter-than-window layout so the pane reads as the lit face.
        ground: Color(slateHex: 0x111111),
        face: Color(slateHex: 0x161616),
        raised: Color(slateHex: 0x2A2A2A), // active-tab card / popover / inset controls, one step lifted
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
        // Neutral dark-terminal ANSI set (One-Dark-style) matching the grey chrome + system-blue accent.
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
    /// MERIDIAN L5: `content == card == background` (the lit pane face) while `window == sidebar` (the
    /// dimmed chrome housing) — one luminance step, no divider, no floating card, no corner radius.
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
        // Structure tints (divider / borders / hover / selection) DERIVE from the palette, not a hardcoded
        // black/white: a DARK filter seeds them from its FOREGROUND so every variant's hairline carries that
        // filter's own hue (teal-white Machine, warm-rose Ristretto, cool-violet Spectrum) instead of one
        // flat `Color.white` outlier shared by all five — the "divider của dark theme đang màu trắng /
        // hardcode" report. Light filters keep a near-black structure line.
        let line = Color(slateHex: s.isLight ? 0x000000 : s.foreground)
        return Self(
            // MERIDIAN L5 (depth by light, not lines): chrome `ground` (sidebar column; auxiliary windows)
            // recedes onto the seed's dimmed `sidebar` tone while the PANE surface (`face` / terminal bg)
            // keeps the brighter seed `background`. The workspace CONTENT column paints `face`, not `ground`
            // (see ContentColumn).
            ground: Color(slateHex: s.sidebar),
            face: Color(slateHex: s.background),
            raised: Color(slateHex: s.elevated),
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

    // P5 (Phase-C GUI audit): navigator `sidebar` read dim/cool vs the intended warm cream. Nudged
    // 0xEDE7E5 → 0xF1EBE8 — brighter + a hair warmer, HUE-PRESERVING (keeps the seed's rose R>G>B ratio,
    // closer to `background`) so it reads as warm paper, not grey. Only `sidebar` moves; `background` /
    // `elevated` (flat backdrop + active-tab card) untouched, so no surface ripples.
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

/// Static token namespace. Colours read the active `theme` (default Monokai Pro Classic); metrics/anim are
/// theme-free.
enum Slate {
    /// The active theme. Indirected through ``ThemeStore/shared`` (D3) so runtime theme switching repoints
    /// every token live — `@MainActor` because the store is, and every read site is a SwiftUI `body` /
    /// AppKit lifecycle hook (all MainActor). Default Paper (the store's default) ⇒ a headless / no-store
    /// render resolves the SAME palette as the old `static let theme = .paper`, byte-identical.
    @MainActor static var theme: SlateTheme { ThemeStore.shared.active }

    /// The preferred SwiftUI colour scheme for the active theme (drives `.preferredColorScheme`).
    @MainActor static var colorScheme: ColorScheme { theme.isLight ? .light : .dark }

    // The colour namespaces are `@MainActor` because they read the runtime ``ThemeStore`` via
    // ``Slate/theme`` (D3) — every read site is a SwiftUI `body` / AppKit lifecycle hook (all MainActor).
    /// The 3-rung surface ladder (MERIDIAN C1) — the ONLY surface vocabulary view code speaks:
    /// `ground` (chrome housing) → `face` (the lit pane) → `raised` (one step lifted).
    @MainActor
    enum Surface {
        static var ground: Color { Slate.theme.ground }
        static var face: Color { Slate.theme.face }
        static var raised: Color { Slate.theme.raised }
    }

    @MainActor
    enum Text {
        static var primary: Color { Slate.theme.textPrimary }
        static var secondary: Color { Slate.theme.textSecondary }
        static var tertiary: Color { Slate.theme.textTertiary }
        static var icon: Color { Slate.theme.icon }
    }

    @MainActor
    enum Line {
        static var divider: Color { Slate.theme.divider }
        static var card: Color { Slate.theme.cardBorder }
        static var subtle: Color { Slate.theme.border }
        static var active: Color { Slate.theme.borderActive }
    }

    @MainActor
    enum State {
        static var hover: Color { Slate.theme.hover }
        static var selected: Color { Slate.theme.selected }
        static var accent: Color { Slate.theme.accent }
        static var accentMuted: Color { Slate.theme.accentMuted }
        static var header: Color { Slate.theme.header }
        static var shadow: Color { Slate.theme.panelShadow }
    }

    @MainActor
    enum Status {
        static var ok: Color { Slate.theme.statusOK }
        static var warn: Color { Slate.theme.statusWarn }
        static var err: Color { Slate.theme.statusErr }
        static var info: Color { Slate.theme.statusInfo }

        /// FIXED security-blue — theme-INDEPENDENT (NOT derived from `Slate.theme`), unlike ``info``. The
        /// secure-input pill must read as the SAME vivid royal-blue on every theme so it can never be confused
        /// with the theme accent: under the default Monokai Pro seed `statusInfo` collapses to the cyan accent
        /// (`info == accent == 0x78DCE8`), which would make a theme-derived security badge indistinguishable
        /// from the accent. Pinned to `secure-input.png`'s royal-blue (#2D6FE8) — a mid royal-blue that keeps
        /// white pill text legible on BOTH light and dark themes. Never re-route this through the theme.
        static let secureInput = Color(slateHex: 0x2D6FE8)
    }

    /// Geometry — theme-independent. Radii + the 8pt grid + chrome dimensions.
    enum Metric {
        // Radii (from design-tokens.css)
        static let radiusCard: CGFloat = 8
        static let radiusTab: CGFloat = 7 // the measured tab / sidebar-row card radius
        static let radiusControl: CGFloat = 6
        static let radiusItem: CGFloat = 6
        static let radiusSmall: CGFloat = 4 // small inner plate (e.g. tab close-button hover)
        static let radiusPill: CGFloat = 20

        // 8pt spacing grid
        static let space1: CGFloat = 4
        static let space2: CGFloat = 8
        static let space3: CGFloat = 12
        static let space4: CGFloat = 16

        // The HEIGHT LADDER (MERIDIAN C1) — the closed vertical rhythm, every step a multiple of 4.
        // View code picks a rung, never a raw `frame(height: N)` literal (`check-ds-leaks.sh` enforces it).
        /// Popover/menu rows, chips, the titlebar clusters, plate buttons.
        static let heightControl: CGFloat = 24
        /// Bars: the pane header, title-menu rows.
        static let heightBar: CGFloat = 28
        /// The standard single-line list row (sidebar tabs, palette results, footers).
        static let heightRow: CGFloat = 32
        /// Chrome strips: the titlebar / traffic-light band.
        static let heightStrip: CGFloat = 40
        /// The two-line list row (title + subtitle) and chooser cards.
        static let heightRowTall: CGFloat = 44
        /// The overlay search-input strip (palette / navigator / global search / open-quickly).
        static let heightInput: CGFloat = 48

        // Floating-card insets — the card is inset from the window so the backdrop wraps around it.
        static let cardMargin = EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16)

        // Chrome dimensions (semantic aliases INTO the height ladder — never a sixth literal)
        static let paneHeaderHeight: CGFloat = heightBar
        /// The hover-reveal titlebar strip height — the content area reserves this at its top so the
        /// terminal starts BELOW the titlebar (the resting silhouette), not under the centred title.
        static let titlebarHeight: CGFloat = heightStrip
        static let sidebarWidth: CGFloat = 220
        /// The Settings window's left navigator column (a two-column Settings layout — wider than the
        /// workspace sidebar so the icon+label section rows + the search pill sit comfortably).
        static let settingsSidebarWidth: CGFloat = 260
        static let hairline: CGFloat = 1
        static let cardBorderWidth: CGFloat = 1
        static let dividerHoverWidth: CGFloat = 2
        /// Active-pane focus marker: leg length (points) of the small FILLED accent triangle in the focused
        /// pane's TOP-LEFT corner (Warp-style — the kept treatment after box / bracket / underline / dot /
        /// top-bar iterations, replacing the old unfocused-dim).
        static let focusCornerSize: CGFloat = 12

        // Control plate (PlateIconButton) — rides the ladder's control rung.
        static let plate: CGFloat = heightControl
        static let iconSize: CGFloat = 13
        /// The host-identity monogram plate (``SlateMonogram``) — sized to sit inside a control-height row.
        static let monogram: CGFloat = 18
    }

    /// Typography scale — one named role per size; UI = system, code = JetBrains Mono. A closed scale (no
    /// raw `.font(.system(size:))` literals in view code — `scripts/check-ds-leaks.sh` enforces it).
    enum Typeface {
        /// Large empty-state / placeholder glyph (build-status / empty pane).
        static let display: CGFloat = 40
        /// Primary content + the command input field — the slightly-larger reading size.
        static let body: CGFloat = 13
        /// Default UI label size.
        static let base: CGFloat = 12
        /// Secondary labels, chips, pills, tab titles.
        static let footnote: CGFloat = 11
        /// Captions, kbd hints, tab subtext.
        static let small: CGFloat = 10
        static let mono = "JetBrains Mono"

        /// MERIDIAN L2 (typography is the only ornament) — the INSTRUMENT voice: every number, caps
        /// micro-label, keycap and technical subtitle (cwd / git line / host-app / telemetry) renders in the
        /// mono face, the "engraved on the tool" register that separates data from prose. Numbers stay
        /// tabular by the face itself. Prose (titles, menus, sentences) keeps the system face.
        static func instrument(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom(mono, size: size).weight(weight)
        }

        /// Tracking (pt) for caps micro-labels set in the instrument voice ("TABS", section headers,
        /// status captions) — wide enough to read as engraving, applied ONLY to all-caps labels.
        static let instrumentTracking: CGFloat = 1.2
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
        /// MERIDIAN L4 "needle" — the mechanical settle used for the ONE orchestrated moment (the connect
        /// handshake's colour-in). Fast attack, long decel, no overshoot (no springs anywhere).
        static let needle = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.24)
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
