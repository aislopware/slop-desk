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
// Design DNA — "clean / modern / minimalist", FLAT:
//   - FLAT pane: the terminal viewport fills its leaf edge-to-edge with NO corner radius and NO card — its
//     surface (`card`) is the SAME colour as the backdrop beneath it (`window`/`content`), so a pane never
//     reads as a floating panel. Adjacent split panes are separated only by the hairline `PaneDivider`.
//   - ONE backdrop: sidebar + titlebar + the pane area share one flat background (no per-section fills).
//   - 8pt grid; ultra-thin structure: borders ~6% opacity, hover ~4–5% — low contrast = minimalist.
//   - Minimal palette: three text levels + an accent used ONLY for active state.
//
// MULTI-THEME: `OttyTheme` ships the six Monokai Pro filters (`.monokaiProClassic` — the DEFAULT — plus
// Light / Octagon / Machine / Ristretto / Spectrum) and keeps the legacy `.paper` / `.dark`. The `Otty.*`
// accessors read `Otty.theme`, which (D3) indirects through `ThemeStore.shared.active` (default
// `.monokaiProClassic`) so runtime switching repoints every token live. Each theme also carries the
// `terminalBackgroundHex`/`terminalForegroundHex` that pin the libghostty cells to the same flat palette.
// SwiftUI `@Environment`/`.preferredColorScheme` does NOT cross the
// AppKit split-controller boundary into the column `NSHostingController`s, so the runtime theme rides this
// `@Observable` store + an `NSWindow.appearance` re-pin (in `AislopdeskSplitViewController`) instead — the
// `ThemeStore`-backed `@MainActor` accessors keep the `NativePaneColor` injection pattern.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import SwiftUI

/// A full otty colour theme (every chrome role). Two instances ship: `.paper` (light, default) and `.dark`.
struct OttyTheme {
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
    /// The active-state accent as a canonical 6-hex string (no `#`) — MIRRORS ``accent``'s colour. Carried so
    /// the Theme-editor Duplicate path can re-emit the SOURCE theme's accent into the new `.ottytheme` instead
    /// of letting ``OttyTheme/init(document:)``'s bg/fg derivation fall through to the (wrong-hue) ANSI
    /// "blue"-slot — e.g. so a duplicated Monokai keeps its cyan accent, not the filter's orange.
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
    /// background as the chrome (otty flat design: terminal content and pane backdrop are one colour). Applied
    /// via ``TerminalConfigBuilder`` through the ``AppearanceApplier`` terminal-colour hook.
    let terminalBackgroundHex: String
    /// The libghostty terminal `foreground` colour (6-hex, no `#`).
    let terminalForegroundHex: String

    /// The 16 ANSI terminal colours (indices 0–15: 0=black … 7=white, 8–15 = bright). 6-hex, no `#`. Reaches
    /// the terminal CELLS via ``TerminalConfigBuilder`` `palette = N=<hex>` and the Appearance swatch grid (the
    /// 16-dot two-row grid in `dark-mode-theme.png`). Built-ins ship a canonical palette; a custom theme's
    /// comes straight from its ``ThemeDocument``.
    let ansiPalette: [String]
    /// Selection highlight background (`selection-background`), 6-hex no `#`; `nil` ⇒ let the renderer pick.
    let selectionBackgroundHex: String?
    /// Cursor block colour (`cursor-color`), 6-hex no `#`; `nil` ⇒ follow the foreground.
    let cursorHex: String?
    /// Glyph-under-cursor colour (`cursor-text`), 6-hex no `#`; `nil` ⇒ follow the background.
    let cursorTextHex: String?

    /// "Paper" — the original otty light palette, MEASURED from the app (`ReplicaKit.RC`). Warm off-white +
    /// green; kept as a selectable theme (the default is now Monokai Pro Classic).
    static let paper = Self(
        window: Color(ottyHex: 0xFCFBF9),
        sidebar: Color(ottyHex: 0xF5F4F0),
        content: Color(ottyHex: 0xFCFBF9),
        card: Color(ottyHex: 0xFCFBF9), // terminal surface = warm paper (RC.bg) — otty's flush, borderless panel
        selectedCard: .white, // active-tab card = pure white on paper (RC.card)
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
        accentHex: "2B5A38",
        accentMuted: .black.opacity(0.06),
        panelShadow: .black.opacity(0.12),
        isLight: true,
        statusOK: Color(ottyHex: 0x2B5A38),
        statusWarn: Color(ottyHex: 0xB87A1E),
        statusErr: Color(ottyHex: 0xC0392B),
        statusInfo: Color(ottyHex: 0x007AFF),
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

    /// otty Dark — from `design-tokens.css` (neutral grays + system-blue accent, opacity-based structure).
    static let dark = Self(
        window: Color(ottyHex: 0x161616),
        sidebar: Color(ottyHex: 0x1C1C1C),
        content: Color(ottyHex: 0x121212),
        card: Color(ottyHex: 0x161616), // FLAT: pane surface == window backdrop (otty flat design, no card)
        selectedCard: Color(ottyHex: 0x2A2A2A), // active-tab card = slightly elevated panel on the dark sidebar
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
        accentHex: "007AFF",
        accentMuted: .white.opacity(0.08),
        panelShadow: .black.opacity(0.40),
        isLight: false,
        statusOK: Color(ottyHex: 0x34C759),
        statusWarn: Color(ottyHex: 0xE5C07B),
        statusErr: Color(ottyHex: 0xE06C75),
        statusInfo: Color(ottyHex: 0x007AFF),
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

    /// The seed colours a Monokai Pro filter contributes; every other otty role is DERIVED from these with
    /// the shared structure opacities, so all variants have identical chrome geometry — only the hues change.
    /// FLAT by construction: `window == content == card == background`, so a pane's surface matches the
    /// backdrop beneath it (otty flat-design — no floating card, no corner radius).
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

    /// Build a full ``OttyTheme`` from a Monokai ``MonokaiSeed`` — structural opacities (borders / hover /
    /// selection) are shared and keyed only on light/dark; the colour roles come from the seed.
    private static func monokai(_ s: MonokaiSeed) -> Self {
        let line: Color = s.isLight ? .black : .white
        return Self(
            window: Color(ottyHex: s.background),
            sidebar: Color(ottyHex: s.sidebar),
            content: Color(ottyHex: s.background),
            card: Color(ottyHex: s.background), // FLAT: pane surface == backdrop
            selectedCard: Color(ottyHex: s.elevated),
            element: Color(ottyHex: s.elevated),
            textPrimary: Color(ottyHex: s.foreground),
            textSecondary: Color(ottyHex: s.secondary),
            textTertiary: Color(ottyHex: s.tertiary),
            icon: Color(ottyHex: s.secondary),
            divider: line.opacity(s.isLight ? 0.08 : 0.07),
            cardBorder: line.opacity(s.isLight ? 0.08 : 0.07),
            border: line.opacity(s.isLight ? 0.05 : 0.06),
            borderActive: line.opacity(0.15),
            hover: line.opacity(s.isLight ? 0.045 : 0.05),
            selected: line.opacity(s.isLight ? 0.07 : 0.09),
            header: Color(ottyHex: s.tertiary),
            accent: Color(ottyHex: s.accent),
            accentHex: hex6(s.accent),
            accentMuted: line.opacity(s.isLight ? 0.06 : 0.10),
            panelShadow: Color.black.opacity(s.isLight ? 0.12 : 0.40),
            isLight: s.isLight,
            statusOK: Color(ottyHex: s.ok),
            statusWarn: Color(ottyHex: s.warn),
            statusErr: Color(ottyHex: s.err),
            statusInfo: Color(ottyHex: s.info),
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

    /// Monokai Pro Light (Classic Light) — the warm off-white light filter.
    static let monokaiProClassicLight = monokai(MonokaiSeed(
        name: "classic-light", background: 0xFAF4F2, sidebar: 0xEDE7E5, elevated: 0xFFFFFF,
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

// MARK: - OttyTheme ← ThemeDocument (E15 WI-1: a scanned custom theme → a full chrome theme)

extension OttyTheme {
    /// Build a full ``OttyTheme`` from a parsed ``ThemeDocument`` (a scanned `.ottytheme`). The chrome roles
    /// are DERIVED from the document's `background`/`foreground`/`accent` with the SAME structural opacities
    /// the ``monokai(_:)`` factory uses (so a custom theme has identical chrome geometry — only the hues
    /// differ), then OVERLAID by any explicit `[ui]`/`[window]`/`[sidebar]`/`[tab]`/`[panel]` hexes the file
    /// declares. Status colours map from the ANSI palette (red/green/yellow/blue → err/ok/warn/info). The
    /// terminal-cell hexes are re-emitted from the parsed background/foreground so a `"none"` (transparent)
    /// background still yields a valid 6-hex pin for the libghostty cells. Built-ins stay FLAT (radius 0); a
    /// custom `[container] radius` is parsed but applied by a later container-styling pass, not here.
    init(document doc: ThemeDocument) {
        let light = doc.mode == .light
        let bg = Self.rgb24(doc.background) ?? (light ? 0xFFFFFF : 0x000000)
        let fg = Self.rgb24(doc.foreground) ?? (light ? 0x000000 : 0xFFFFFF)

        // Derived chrome surfaces: sidebar a touch off the backdrop; the elevated surface is white in light
        // mode and a slight raise in dark mode; secondary/tertiary text interpolate foreground → background.
        let sidebarHex = Self.rgb24(doc.sidebar) ?? Self.mix(bg, 0x000000, light ? 0.05 : 0.06)
        let elevatedHex = light ? 0xFFFFFF : Self.mix(bg, 0xFFFFFF, 0.10)
        let secondaryHex = Self.mix(fg, bg, 0.50)
        let tertiaryHex = Self.mix(fg, bg, 0.65)

        // Status + accent map off the ANSI palette (idx 1=red, 2=green, 3=yellow, 4=blue); the `[token] accent`
        // wins when present, else the blue slot, else the foreground.
        func paletteEntry(_ index: Int) -> UInt32? {
            guard doc.palette.indices.contains(index) else { return nil }
            return Self.rgb24(doc.palette[index])
        }
        let accentHex = Self.rgb24(doc.accent) ?? paletteEntry(4) ?? fg
        let errHex = paletteEntry(1) ?? secondaryHex
        let okHex = paletteEntry(2) ?? secondaryHex
        let warnHex = paletteEntry(3) ?? secondaryHex
        let infoHex = paletteEntry(4) ?? accentHex

        let line: Color = light ? .black : .white
        self.init(
            window: Self.color(doc.window, fallback: Color(ottyHex: bg)),
            sidebar: Color(ottyHex: sidebarHex),
            content: Color(ottyHex: bg),
            card: Color(ottyHex: bg), // FLAT: pane surface == backdrop
            selectedCard: Self.color(doc.tab, fallback: Color(ottyHex: elevatedHex)),
            element: Self.color(doc.panel, fallback: Color(ottyHex: elevatedHex)),
            textPrimary: Color(ottyHex: fg),
            textSecondary: Color(ottyHex: secondaryHex),
            textTertiary: Color(ottyHex: tertiaryHex),
            icon: Color(ottyHex: secondaryHex),
            divider: line.opacity(light ? 0.08 : 0.07),
            cardBorder: line.opacity(light ? 0.08 : 0.07),
            border: line.opacity(light ? 0.05 : 0.06),
            borderActive: line.opacity(0.15),
            hover: line.opacity(light ? 0.045 : 0.05),
            selected: line.opacity(light ? 0.07 : 0.09),
            header: Color(ottyHex: tertiaryHex),
            accent: Color(ottyHex: accentHex),
            accentHex: Self.hex6(accentHex),
            accentMuted: line.opacity(light ? 0.06 : 0.10),
            panelShadow: Color.black.opacity(light ? 0.12 : 0.40),
            isLight: light,
            statusOK: Color(ottyHex: okHex),
            statusWarn: Color(ottyHex: warnHex),
            statusErr: Color(ottyHex: errHex),
            statusInfo: Color(ottyHex: infoHex),
            id: "custom-\(doc.slug)",
            terminalBackgroundHex: Self.hex6(bg),
            terminalForegroundHex: Self.hex6(fg),
            ansiPalette: doc.palette,
            selectionBackgroundHex: doc.selectionBackground,
            cursorHex: doc.cursor,
            cursorTextHex: doc.cursorText,
        )
    }

    /// Parse a 6-hex colour string (tolerating one leading `#`) into a 24-bit RGB literal, or `nil` when it is
    /// absent / malformed — the caller then substitutes a derived fallback (validate-then-default).
    private static func rgb24(_ hex: String?) -> UInt32? {
        guard var s = hex else { return nil }
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return value
    }

    /// A ``Color`` from a (possibly absent / malformed) 6-hex string, falling back to `fallback`.
    private static func color(_ hex: String?, fallback: Color) -> Color {
        guard let value = rgb24(hex) else { return fallback }
        return Color(ottyHex: value)
    }

    /// Linearly interpolate two 24-bit RGB colours by `t` (0 ⇒ `a`, 1 ⇒ `b`), per channel. The channel math is
    /// PLAIN `*`/`+` (NEVER fused / `addingProduct` — the package-wide codec/controller convention) and clamps
    /// with ordered, NaN-faithful `Double.minimum`/`Double.maximum`.
    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let clampedT = Double.minimum(1, Double.maximum(0, t))
        func lane(_ shift: UInt32) -> UInt32 {
            let av = Double((a >> shift) & 0xFF)
            let bv = Double((b >> shift) & 0xFF)
            let blended = av * (1 - clampedT) + bv * clampedT
            let clamped = Double.minimum(255, Double.maximum(0, blended.rounded()))
            return UInt32(clamped) & 0xFF
        }
        return (lane(16) << 16) | (lane(8) << 8) | lane(0)
    }
}

/// Static token namespace. Colours read the active `theme` (default Monokai Pro Classic); metrics/anim are
/// theme-free.
enum Otty {
    /// The active theme. Indirected through ``ThemeStore/shared`` (D3) so runtime theme switching repoints
    /// every token live — `@MainActor` because the store is, and every read site is a SwiftUI `body` /
    /// AppKit lifecycle hook (all MainActor). Default Paper (the store's default) ⇒ a headless / no-store
    /// render resolves the SAME palette as the old `static let theme = .paper`, byte-identical.
    @MainActor static var theme: OttyTheme { ThemeStore.shared.active }

    /// The preferred SwiftUI colour scheme for the active theme (drives `.preferredColorScheme`).
    @MainActor static var colorScheme: ColorScheme { theme.isLight ? .light : .dark }

    // The colour namespaces are `@MainActor` because they read the runtime ``ThemeStore`` via
    // ``Otty/theme`` (D3) — every read site is a SwiftUI `body` / AppKit lifecycle hook (all MainActor).
    @MainActor
    enum Surface {
        static var window: Color { Otty.theme.window }
        static var sidebar: Color { Otty.theme.sidebar }
        static var content: Color { Otty.theme.content }
        static var card: Color { Otty.theme.card }
        static var selectedCard: Color { Otty.theme.selectedCard }
        static var element: Color { Otty.theme.element }
    }

    @MainActor
    enum Text {
        static var primary: Color { Otty.theme.textPrimary }
        static var secondary: Color { Otty.theme.textSecondary }
        static var tertiary: Color { Otty.theme.textTertiary }
        static var icon: Color { Otty.theme.icon }
    }

    @MainActor
    enum Line {
        static var divider: Color { Otty.theme.divider }
        static var card: Color { Otty.theme.cardBorder }
        static var subtle: Color { Otty.theme.border }
        static var active: Color { Otty.theme.borderActive }
    }

    @MainActor
    enum State {
        static var hover: Color { Otty.theme.hover }
        static var selected: Color { Otty.theme.selected }
        static var accent: Color { Otty.theme.accent }
        static var accentMuted: Color { Otty.theme.accentMuted }
        static var header: Color { Otty.theme.header }
        static var shadow: Color { Otty.theme.panelShadow }
    }

    @MainActor
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

        // Floating-card insets — the card is inset from the window so the backdrop wraps around it.
        static let cardMargin = EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16)

        // Chrome dimensions
        static let paneHeaderHeight: CGFloat = 28
        /// The hover-reveal titlebar strip height — the content area reserves this at its top so the
        /// terminal starts BELOW the titlebar (otty's resting silhouette), not under the centred title.
        static let titlebarHeight: CGFloat = 40
        static let sidebarWidth: CGFloat = 220
        /// The Settings window's left navigator column (otty's two-column Settings layout — wider than the
        /// workspace sidebar so the icon+label section rows + the search pill sit comfortably).
        static let settingsSidebarWidth: CGFloat = 260
        static let hairline: CGFloat = 1
        static let cardBorderWidth: CGFloat = 1
        static let dividerHoverWidth: CGFloat = 2

        // Control plate (PlateIconButton)
        static let plate: CGFloat = 24
        static let iconSize: CGFloat = 13
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
        /// Titlebar chrome fade-out duration (seconds) after the dwell — otty's `PanelToggleButton.hide`.
        static let titlebarFadeOut: Double = 0.20
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
