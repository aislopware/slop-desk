// SlateDesign — the minimalist design-token layer.
//
// A THIN, headless token layer: no separate SPM target (`SlopDeskDesignSystem` stays deleted) — just
// `Color`/`CGFloat`/`Animation` constants compiled into `SlopDeskClientUI`. Source of truth for the tokens:
// the theme structs below, the Monokai Pro filter seeds, and `Slate.Anim`'s timing curves (no
// springs anywhere).
//
// Design DNA — "clean / modern / minimalist", FLAT, relit by MERIDIAN L5:
//   - FLAT pane: the terminal viewport fills its leaf edge-to-edge, NO corner radius, NO card; adjacent
//     split panes are separated only by the hairline `PaneDivider`.
//   - MERIDIAN L5 (depth by light, not lines): the SIDEBAR column sits ONE luminance step BELOW the pane
//     surface (`card`/`content` = the seed background) — pane = lit face, sidebar = unlit housing. The step
//     IS the structure; no divider between. SCOPE: the CONTENT column is lit end-to-end — its titlebar band
//     paints the pane tone, because panes sit flush under it (no gap/radius) and a darker strip there would
//     read as a mispainted header. `window` (== sidebar tone) stays the ground of AUXILIARY windows
//     (Settings / first-launch / overlays), which are chrome, not pane.
//   - 8pt grid; ultra-thin structure: borders ~6% opacity, hover ~4–5% — low contrast = minimalist.
//   - Minimal palette: three text levels + an accent used ONLY for active state.
//
// MULTI-THEME: `SlateTheme` ships the six Monokai Pro filters and NOTHING ELSE (`.monokaiProClassic` — the
// DEFAULT — plus Light / Octagon / Machine / Ristretto / Spectrum). `Slate.*` accessors
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
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A full colour theme (every chrome role). Every shipped instance is a Monokai Pro filter, built from a
/// ``MonokaiSeed`` — so every theme has the SAME six chromatics available, which is what lets chrome reach
/// past the status quartet (see ``Slate/Chroma``) without inventing a colour some theme cannot supply.
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

    // The two remaining filter chromatics. Every Monokai Pro filter ships six chromatics; the status
    // quartet spends four (green / yellow / red / cyan) and these are the other two. They reached only
    // the terminal's ANSI palette before — surfaced here so chrome that needs a fifth or sixth
    // DISTINGUISHABLE hue (the sidebar's git readout) can take one from the filter instead of inventing
    // a colour outside it. Not statuses: no urgency attaches to them, the consumer assigns the meaning.
    let chromaOrange: Color
    let chromaPurple: Color

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
    /// Selection highlight background (`selection-background`), bare 6-hex opaque RGB. Paired with
    /// libghostty `selection-foreground = cell-foreground` so glyph colours stay under the fill (not an
    /// invert). `nil` ⇒ no `selection-background` line. (libghostty `Color` is RGB-only — no alpha.)
    let selectionBackgroundHex: String?
    /// Cursor block colour (`cursor-color`), 6-hex no `#`; `nil` ⇒ follow the foreground.
    let cursorHex: String?
    /// Glyph-under-cursor colour (`cursor-text`), 6-hex no `#`; `nil` ⇒ follow the background.
    let cursorTextHex: String?

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
        // filter's own hue (teal-white Machine, warm-rose Ristretto, cool-violet Spectrum) instead of a flat
        // `Color.white` shared by all five, which would read as a hardcoded white divider regardless of the
        // filter. Light filters keep a near-black structure line.
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
            // Dark filters carry the fg tint one step brighter than the other structure lines —
            // at 0.07 the seam sat barely above the ground tone, more shadow than line
            // (user-flagged, 2026-08-03). 0.10 keeps it a quiet hairline that still reads LIGHT.
            divider: line.opacity(s.isLight ? 0.08 : 0.10),
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
            chromaOrange: Color(slateHex: s.orange),
            chromaPurple: Color(slateHex: s.purple),
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
            // Solid elevated fill (opaque — libghostty Color is RGB-only). Glyph colours stay via
            // selection-foreground=cell-foreground so this is a highlight, not an invert.
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

    // navigator `sidebar` is brighter and a hair warmer than the seed's raw dimmed tone would give — kept
    // HUE-PRESERVING (the seed's rose R>G>B ratio, closer to `background`) so it reads as warm paper, not
    // grey/cool. Only `sidebar` carries this nudge; `background` / `elevated` (flat backdrop + active-tab
    // card) stay untouched, so no other surface ripples.
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
    /// AppKit lifecycle hook (all MainActor). ``ThemeStore``'s default (`.monokaiProClassic`) means a
    /// headless / no-store render still resolves a real, deterministic palette.
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
        /// The ACTIVE tab card's cast shadow — `black 4%, r2, y1` on a LIGHT theme only. Dark
        /// themes cast nothing: at-rest depth there is the surface ladder (fill + hairline), and a
        /// dark-on-dark shadow reads as a smudged edge, not lift (MERIDIAN L5).
        static var cardShadow: Color { Slate.theme.isLight ? .black.opacity(0.04) : .clear }
    }

    /// The two filter chromatics outside the status quartet — a fifth and sixth hue for chrome that needs
    /// more DISTINGUISHABLE inks than `ok`/`warn`/`err`/`info` provide, taken from the active filter so a
    /// theme swap repoints them like every other token. Carries no urgency of its own: unlike ``Status``,
    /// the meaning lives entirely at the call site.
    @MainActor
    enum Chroma {
        static var orange: Color { Slate.theme.chromaOrange }
        static var purple: Color { Slate.theme.chromaPurple }
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

        /// FIXED sync-amber — theme-INDEPENDENT, same rationale as ``secureInput``: the `⚠ SYNC INPUT`
        /// pill flags a MODE where every keystroke fans into multiple shells, so it must read as the
        /// same unmistakable amber on every theme and never collapse into a theme accent (the default
        /// Monokai Pro seed's `statusWarn` yellow sits in the accent family). A mid amber keeps white
        /// pill text legible on BOTH light and dark themes. Never re-route this through the theme.
        static let syncInput = Color(slateHex: 0xD97A1F)
    }

    /// Geometry — theme-independent. Radii + the 8pt grid + chrome dimensions.
    enum Metric {
        // Radii (from design-tokens.css)
        static let radiusCard: CGFloat = 8
        /// A FLOATING panel's corner — the notification card, and any future free-standing panel. One rung
        /// softer than ``radiusCard``, which is tuned for content INSET into a surface: at the notification's
        /// 320pt × ~46pt an 8pt corner reads boxy, and 16 starts sliding toward ``radiusPill``. 12 was picked
        /// by rendering 8 / 10 / 12 / 16 at true size side by side.
        static let radiusPanel: CGFloat = 12
        static let radiusTab: CGFloat = 6 // tab / sidebar-row card — rides the control-radius family
        static let radiusControl: CGFloat = 6
        static let radiusItem: CGFloat = 6
        static let radiusSmall: CGFloat = 4 // small inner plate (e.g. tab close-button hover)
        static let radiusPill: CGFloat = 20

        // 8pt spacing grid
        static let space1: CGFloat = 4
        static let space2: CGFloat = 8
        static let space3: CGFloat = 12
        static let space4: CGFloat = 16

        /// The STATE DOT: a filled circle that qualifies the text beside it (unsaved changes, a
        /// live indicator) rather than standing on its own. Sized to sit under a footnote's
        /// x-height so it reads as punctuation, not as a badge.
        static let dot: CGFloat = 6

        // The HEIGHT LADDER (MERIDIAN C1) — the closed vertical rhythm, every step a multiple of 4.
        // View code picks a rung, never a raw `frame(height: N)` literal (`check-ds-leaks.sh` enforces it).
        /// Popover/menu rows, chips, the titlebar clusters, plate buttons.
        static let heightControl: CGFloat = 24
        /// Bars: the pane header, title-menu rows.
        static let heightBar: CGFloat = 28
        /// The standard single-line list row (palette results, footers).
        static let heightRow: CGFloat = 32
        /// The ROOMY single-line row — a list read at a GLANCE rather than scanned. One rung above
        /// `heightRow`, and above `heightStrip` so a row can never be mistaken for chrome.
        static let heightRowTall: CGFloat = 44
        /// The TWO-REGISTER row: an identity with its place set under it (the ⌃⇥ switcher). Two type
        /// sizes stacked (13 over 11) come to ~29pt of ink, so this rung is that plus a breath either
        /// side — one step above `heightRowTall`, which is the same row with only one thing to say.
        static let heightRowStacked: CGFloat = 48
        /// The sidebar TAB row — the standard single-line row rung (`heightRow`), so the tab list
        /// keeps the ladder's beat: denser than a lounge list, taller than a menu row.
        static let heightTabRow: CGFloat = heightRow
        /// The tab row's horizontal content inset — `space3`, which is ALSO the section header's
        /// chevron-gutter width: with the list inset (`space2`) both land every text run (header
        /// name, git line, row titles) on ONE left rail, chevron hanging in the gutter before it.
        static let tabRowInset: CGFloat = space3
        /// The sidebar project-group header row (gutter chevron + name). 24pt + the list's 2pt row
        /// spacing on both sides = the 28pt inter-group band; the air IS the separator.
        static let heightSectionHeader: CGFloat = 24
        /// Chrome strips: the titlebar / traffic-light band.
        static let heightStrip: CGFloat = 40
        /// The overlay search-input strip (palette / navigator / global search / open-quickly).
        static let heightInput: CGFloat = 48
        /// A drawer that shares a column with the thing it is about (the simulator console under the
        /// device). Fixed rather than proportional: the drawer is a reading surface and a share-of-the
        /// -column would make its row count depend on the window height, so the same log would show
        /// four lines on a laptop and twenty on a display. Six rows plus the drawer's own strip.
        static let heightDrawer: CGFloat = 180

        // Floating-card insets — the card is inset from the window so the backdrop wraps around it.
        static let cardMargin = EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16)

        /// A FORM card's fixed width (connect, peek-reply) — one width for every dialog-shaped overlay,
        /// so two cards summoned in a row read as the same object at the same distance. List overlays
        /// (palette / open-quickly / global search) size to their own content instead.
        static let cardFormWidth: CGFloat = 460
        /// A PORT number's field on a form card — five digits wide, never the card's width: a field's
        /// width is part of what it says about its answer.
        static let portFieldWidth: CGFloat = 96

        // The floating GLASS card's cast shadow (``SlateGlassCard``) — soft and low, so the card reads as
        // hovering a short way above the workspace rather than pasted onto a far wall. Tokens because every
        // overlay now shares one surface: a card that cast a different shadow would read as a different
        // depth, which is exactly the drift this vocabulary exists to stop.
        static let panelShadowRadius: CGFloat = 12
        static let panelShadowY: CGFloat = 4

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
        /// pane's TOP-LEFT corner (Warp-style), not a box/bracket/underline/dot/top-bar outline and not
        /// dimming the unfocused panes — a small corner mark signals focus without adding a border to the
        /// FLAT pane or making idle panes look disabled.
        static let focusCornerSize: CGFloat = 12

        // Control plate (PlateIconButton) — rides the ladder's control rung.
        static let plate: CGFloat = heightControl
        static let iconSize: CGFloat = 13
        /// The host-identity monogram plate (``SlateMonogram``) — sized to sit inside a control-height row.
        static let monogram: CGFloat = 18

        // Settings option CARDS (`SettingsOptionCards`) — the illustrated radio group used where the choice
        // has a SHAPE (cursor caret, tab position, key layout, window geometry, theme). ONE size for all of
        // them: a card that is bigger in one group than another reads as a different control.
        /// The illustration band inside one option card: the drawing area above the label. Two control
        /// rungs (2 × `heightControl`) — enough for a legible mini-diagram (including the theme swatch's
        /// title bar + three code lines), still a card and not a panel.
        static let settingsCardArt: CGFloat = heightControl * 2
        /// One option card's width — FIXED, not a minimum. The grid wraps at this width rather than
        /// stretching its columns, so every card in Settings is the same size (a theme swatch is exactly as
        /// wide as a caret card). 116 fits the longest card label ("Classic Light") without truncating.
        static let settingsCardWidth: CGFloat = 116

        // Simulator DEVICE cards + the device list's columns (`SimulatorDeviceList`). A right panel is
        // ~700pt wide and a device name is ~180 of it, so both of these exist to stop a list of names
        // from being drawn one-per-line across a surface four times wider than anything on it.
        /// The screen box inside a running device's card — the live thumbnail's height. This is the one
        /// place the panel SHOWS a device rather than naming it, so it is sized to be read, and matched
        /// to what the server actually sends: its scale-6 capture is 202 × 438 (measured 2026-08-04),
        /// which at 2× is exactly a 200pt-tall box. Bigger would be upscaling; smaller would be paying
        /// for pixels and then throwing them away.
        static let deviceCardArt: CGFloat = 200
        /// A device card's width — FIXED, like the Settings option card and for the same reason: an
        /// adaptive column stretches, so a single running device would be one 700pt-wide card with a
        /// 92pt phone floating in the middle of it. A portrait phone at ``deviceCardArt`` is the narrow
        /// case (92) and an iPad the wide one (150); both centre in this, so the two shapes read true
        /// against each other, and the caption under them still fits a name and its verb.
        static let deviceCardWidth: CGFloat = 180
        /// ``AndroidRobotMark``'s box in a tab plate — the ONE mark in the app that is a drawn path
        /// rather than an SF Symbol, and therefore the one that needs a number of its own.
        ///
        /// The number came from measuring ink rather than ems. A tab's mark is drawn at a point size
        /// and READ at whatever height that produces, and the two are different quantities: an early
        /// pass sized the platform marks by em (14 against the shapes' 11) on the theory that a brand
        /// needs more room than a symbol, and measured on the drawn pixels `apple.logo` then stood
        /// 13.50 tall against the robot's 8.75 — the pair that reads as a pair had become the two
        /// extremes of the strip. At ONE em the SF Symbols already agree, because agreeing is what
        /// Apple's optical grid is for: at 13, `folder` measures 11.88, `apple.logo` 12.50, `display`
        /// 13.12 and `arrow.clockwise` 13.88.
        ///
        /// The robot cannot join that band on both axes — a dome under splayed antennae is 1.57 times
        /// as wide as it is tall at any size — so this is the size where it misses each by about the
        /// same amount: 16.75 × 10.62. 19 equalises the ink heights and the robot then outweighs
        /// everything beside it; lengthening the antennae fixes the ratio arithmetically and reads as
        /// ears. The number survived the tabs gaining labels (`1f06cd0a` → the round after it): a
        /// mark beside its own word is no longer compared with the mark two tabs over, so the width
        /// this costs stopped mattering, and nothing recommended changing what the ink says.
        static let androidMark: CGFloat = 17
        /// ``ChromeMark``'s box. Measured the same way as the robot above, and it lands the OTHER
        /// side of the em: the wheel is a filled disc, so at the symbols' 13 its ink is a solid
        /// 13 × 13 against `folder`'s 11.88 × 10 of strokes, and it reads as the heaviest thing in
        /// the strip. Backing off to 12 puts its silhouette inside the band the SF Symbols occupy —
        /// a disc is the one shape whose bounding box IS its ink, so it has to be the smaller number
        /// rather than the larger one the robot needed.
        static let chromeMark: CGFloat = 12
        /// The device-family mark's column (`SimulatorFamilyMark`). One control rung wide because the
        /// five silhouettes are NOT one width: measured at 13pt type the phone is 13 across, the
        /// landscape pad 20 and the vision headset 23. Sized to the narrowest, the wide ones spill into
        /// the gap and touch the name; sized to the widest, every name in the list starts on one rail
        /// no matter which family the row belongs to.
        static let deviceMarkWidth: CGFloat = heightControl
        /// A device ROW's minimum column width in the list's grid. Fits the longest device name this
        /// server serves ("iPad Pro 13-inch (M5)") plus its verb without truncating, and wraps to two
        /// columns at panel width instead of stranding a triangle 500pt from the name it belongs to.
        static let deviceRowWidth: CGFloat = 240

        /// A popover's content width. FIXED for the same reason the notification card is: a popover that
        /// hugs its content is a popover whose width is decided by whichever row happens to hold the
        /// longest string, so the same control opens at a different size on different data. 260 is the
        /// sidebar's own working width — a popover anchored in the sidebar reads as belonging to it
        /// rather than as a window that happened to land there.
        static let popoverWidth: CGFloat = 260

        // Notification stack (`ToastStackView`) — a notification is a pane speaking from off-screen, so it
        // is a small card in the corner, never a sheet.
        /// One notification card's width — UNIFORM across the stack, and deliberately so. Cards that hug
        /// their own content were tried first (a short notice as a small chip, a long one as a wide card)
        /// and rendered as a ragged staircase: right-aligned in the corner, every left edge landing
        /// somewhere different, and the width tracking TITLE LENGTH rather than importance — the widest
        /// card in a burst was whichever happened to have the longest name. A single column edge is what
        /// lets a stack read as one stack. 320 (down from the old 340) with the ✕ no longer holding a
        /// permanent slot, so a short title no longer stares across a gutter at a button.
        static let toastWidth: CGFloat = 320
    }

    /// Typography scale — one named role per size; UI = system, instrument/rail = JetBrains Mono (SF Mono
    /// when absent). A closed scale (no raw `.font(.system(size:))` literals in view code —
    /// `scripts/check-ds-leaks.sh` enforces it).
    enum Typeface {
        /// Large empty-state / placeholder glyph (build-status / empty pane).
        static let display: CGFloat = 40
        /// A floating card's TITLE — one rung above ``body``, the only size in the overlay family that
        /// outranks the content it names.
        static let title: CGFloat = 15
        /// Primary content + the command input field — the slightly-larger reading size.
        static let body: CGFloat = 13
        /// Default UI label size.
        static let base: CGFloat = 12
        /// Secondary labels, chips, pills, tab titles.
        static let footnote: CGFloat = 11
        /// Captions, kbd hints, tab subtext.
        static let small: CGFloat = 10
        /// The instrument face: the same family libghostty embeds as the terminal's default, so the
        /// chrome's mono voice IS the pane's voice.
        static let mono = "JetBrains Mono"

        /// Whether ``mono`` is actually resolvable on this machine — `Font.custom` with a missing
        /// family falls back to the PROPORTIONAL system face silently (no mono at all), so the
        /// instrument accessor degrades to SF Mono (`design: .monospaced`) instead. Checked once:
        /// fonts don't appear mid-session.
        private static let monoInstalled: Bool = {
            #if canImport(AppKit)
            NSFontManager.shared.availableFontFamilies.contains(mono)
            #else
            UIFont.familyNames.contains(mono)
            #endif
        }()

        /// MERIDIAN L2 (typography is the only ornament) — the INSTRUMENT voice: the sidebar rail
        /// (titles + readouts included), every number, caps micro-label, keycap and technical line
        /// (cwd / git line / host-app / telemetry) renders in the mono face — the terminal's own
        /// register, so the chrome reads like terminal text. Numbers stay tabular by the face itself.
        /// Prose OUTSIDE the rail (menus, sentences, dialogs) keeps the system face.
        static func instrument(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            monoInstalled
                ? .custom(mono, size: size).weight(weight)
                : .system(size: size, weight: weight, design: .monospaced)
        }

        /// Tracking (pt) for caps micro-labels set in the instrument voice — wide enough to read as
        /// engraving, applied ONLY to all-caps labels.
        static let instrumentTracking: CGFloat = 1.2
        /// Tracking (pt) for the SIDEBAR's caps labels ("TABS", project headers) — the otty
        /// measurement (`.tracking(0.6)` on the system face), narrower than the instrument engraving.
        static let capsTracking: CGFloat = 0.6
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
        /// A whole COLUMN reflowing (toast spine expand/collapse shifts every sibling card, not just the
        /// hovered one) — a shade longer than `standard`, gentle symmetric ease so the reverse (mouse-out)
        /// reads as calm as the forward. EaseInEaseOut 0.28s.
        static let stackReflow = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.28)
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
