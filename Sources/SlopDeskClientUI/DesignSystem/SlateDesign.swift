// SlateDesign — the minimalist design-token layer.
//
// A THIN, headless token layer: no separate SPM target (`SlopDeskDesignSystem` stays deleted) — just
// `Color`/`CGFloat`/`Animation` constants compiled into `SlopDeskClientUI`. Source of truth for the tokens:
// the theme structs below, the FOUNDRY seeds, and `Slate.Anim`'s timing curves (no
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
// MULTI-THEME: `SlateTheme` ships the four FOUNDRY seeds and NOTHING ELSE (`.foundryEmber` — the
// DEFAULT — plus Ember Light / Dusk / Graphite). Every seed is generated OFFLINE by the FOUNDRY theme
// engine (OKLCH specs + APCA-W3 audit; generator of record lives with `.impeccable/design.json`'s
// `themeEngine` block) — no hex below was hand-picked, and a colour the engine cannot generate does not
// ship (DESIGN.md, the Seeded-Engine Rule). `Slate.*` accessors
// read `Slate.theme`, which (D3) indirects through `ThemeStore.shared.active` (default `.foundryEmber`)
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

/// A full colour theme (every chrome role). Every shipped instance is a FOUNDRY seed, built from a
/// ``FoundrySeed`` — so every theme has the SAME eight chromatics and eight identity hues available, which
/// is what lets chrome reach past the status quartet (see ``Slate/Chroma``) and colour a project fleet
/// (see ``Slate/Identity``) without inventing a colour some theme cannot supply.
struct SlateTheme: Equatable {
    // Surfaces — the 5-rung FOUNDRY ladder. Exactly five names, each REAL in every theme (a rung
    // that collapses to another gets DELETED, not kept as aspirational vocabulary):
    //   void   → deepest chrome: the 1px seams between panes + auxiliary-window backdrops
    //   ground → chrome housing: sidebar column
    //   face   → the lit pane surface: terminal cells, the content column, sheet/popover grounds
    //   raised → one step lifted: active row card, popover panels, inset controls (search / kbd / chips)
    //   lift   → hover/pressed on raised, the terminal selection fill, ANSI slot 0
    let void: Color
    let ground: Color
    let face: Color
    let raised: Color
    let lift: Color

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

    // The chromatics outside the status quartet. Every FOUNDRY seed ships eight equal-loudness
    // chromatics; the status quartet spends three (green / amber / red — info rides the accent) and
    // these are the rest — surfaced here so chrome that needs another DISTINGUISHABLE hue (the
    // sidebar's git readout) can take one from the seed instead of inventing a colour outside it.
    // Not statuses: no urgency attaches to them, the consumer assigns the meaning.
    let chromaOrange: Color
    let chromaPurple: Color
    let chromaBlue: Color
    let chromaMagenta: Color

    /// The accent's deep band — the fill/badge variant (darker, more chromatic) for surfaces where the
    /// text-sized accent would be a pastel wash (filled pills, progress fills).
    let accentDeep: Color

    /// The IDENTITY register — 8 equal-weight project hues (one lightness, one chroma, engine-spaced).
    /// A project keeps its hue for life; spent ONLY as a 2px spine + a ≤5% wash (DESIGN.md, the
    /// Three-Registers Rule) — never per-row plates, never text recolouring.
    let identity: [Color]

    /// Stable identity for change-detection — distinguishes a real theme switch from an idempotent re-apply
    /// so a SAME-LIGHTNESS variant change (e.g. Ember → Graphite) still posts the cross-boundary
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

    // MARK: - FOUNDRY seeds (generated: OKLCH specs + APCA-W3 audit — see .impeccable/design.json `themeEngine`)

    /// The colours a FOUNDRY seed contributes; every other chrome role is DERIVED from these with the
    /// shared structure opacities, so all seeds have identical chrome geometry — only temperature and
    /// accent voice change. Values are GENERATED (pinned OKLCH lightness/chroma per role, gamut-clipped by
    /// chroma only, APCA-audited: ink ≥ 84, secondary ≥ 52, chromatics ≥ 57 on `face`) — never hand-edited.
    private struct FoundrySeed {
        let name: String
        let void: UInt32 // deepest chrome: pane seams + aux-window backdrops
        let ground: UInt32 // sidebar housing
        let face: UInt32 // the lit pane (terminal cells + content column)
        let raised: UInt32 // cards, popovers, active rows, inset controls
        let lift: UInt32 // hover/pressed on raised, terminal selection, ANSI 0
        let ink: UInt32 // primary text (Lc ~85 on face — moderate by design)
        let ink2: UInt32 // secondary text + icons
        let ink3: UInt32 // tertiary text + section headers + drained state
        let accent: UInt32 // the single interaction accent (text-sized band)
        let accentDeep: UInt32 // the accent's fill/badge band
        let red: UInt32 // status err
        let orange: UInt32
        let amber: UInt32 // status warn — the HAZARD register
        let green: UInt32 // status ok
        let cyan: UInt32
        let blue: UInt32
        let purple: UInt32
        let magenta: UInt32
        let identity: [UInt32] // 8 project hues (spine + wash duty)
        let ansi: [UInt32] // the full 16-slot terminal palette, engine-mapped
        let isLight: Bool
    }

    /// Build a full ``SlateTheme`` from a ``FoundrySeed`` — structural opacities (borders / hover /
    /// selection) are shared and keyed only on light/dark; the colour roles come from the seed.
    private static func foundry(_ s: FoundrySeed) -> Self {
        // Structure tints (divider / borders / hover / selection) DERIVE from the palette, not a hardcoded
        // black/white: a DARK seed tints them from its INK so every seed's hairline carries its own
        // temperature (warm Ember, mauve Dusk, cool Graphite) instead of a flat `Color.white`. Light seeds
        // keep a near-black structure line.
        let line = Color(slateHex: s.isLight ? 0x000000 : s.ink)
        return Self(
            void: Color(slateHex: s.void),
            // Depth by light, not lines: chrome `ground` (sidebar column) recedes one rung below the PANE
            // surface (`face` / terminal bg). The workspace CONTENT column paints `face`, not `ground`
            // (see ContentColumn).
            ground: Color(slateHex: s.ground),
            face: Color(slateHex: s.face),
            raised: Color(slateHex: s.raised),
            lift: Color(slateHex: s.lift),
            textPrimary: Color(slateHex: s.ink),
            textSecondary: Color(slateHex: s.ink2),
            textTertiary: Color(slateHex: s.ink3),
            icon: Color(slateHex: s.ink2),
            // Dark seeds carry the ink tint one step brighter than the other structure lines —
            // at 0.07 the seam sat barely above the ground tone, more shadow than line
            // (user-flagged, 2026-08-03). 0.10 keeps it a quiet hairline that still reads LIGHT.
            divider: line.opacity(s.isLight ? 0.08 : 0.10),
            cardBorder: line.opacity(s.isLight ? 0.08 : 0.07),
            border: line.opacity(s.isLight ? 0.05 : 0.06),
            borderActive: line.opacity(0.15),
            hover: line.opacity(s.isLight ? 0.045 : 0.05),
            selected: line.opacity(s.isLight ? 0.07 : 0.09),
            header: Color(slateHex: s.ink3),
            accent: Color(slateHex: s.accent),
            accentHex: hex6(s.accent),
            accentMuted: line.opacity(s.isLight ? 0.06 : 0.10),
            panelShadow: Color.black.opacity(s.isLight ? 0.12 : 0.40),
            isLight: s.isLight,
            statusOK: Color(slateHex: s.green),
            statusWarn: Color(slateHex: s.amber),
            statusErr: Color(slateHex: s.red),
            statusInfo: Color(slateHex: s.accent),
            chromaOrange: Color(slateHex: s.orange),
            chromaPurple: Color(slateHex: s.purple),
            chromaBlue: Color(slateHex: s.blue),
            chromaMagenta: Color(slateHex: s.magenta),
            accentDeep: Color(slateHex: s.accentDeep),
            identity: s.identity.map { Color(slateHex: $0) },
            id: "foundry-\(s.name)",
            terminalBackgroundHex: hex6(s.face),
            terminalForegroundHex: hex6(s.ink),
            // The engine-mapped 16-slot palette: dark seeds put `lift` in slot 0 (visible against face) and
            // the ink tiers in 7/8/15; light seeds invert (ink in 0, near-white surfaces in 7/15). Slots
            // 1–6 are the chromatic set with blue leaned toward cyan for on-face readability.
            ansiPalette: s.ansi.map { hex6($0) },
            // Solid lift fill (opaque — libghostty Color is RGB-only). Glyph colours stay via
            // selection-foreground=cell-foreground so this is a highlight, not an invert.
            selectionBackgroundHex: hex6(s.lift),
            cursorHex: hex6(s.ink),
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

    /// Foundry Ember — the DEFAULT theme (dark). Warm graphite (OKLCH hue 55) with a teal accent chosen to
    /// sit maximally far from the hazard amber. face #27221E.
    static let foundryEmber = foundry(FoundrySeed(
        name: "ember",
        void: 0x171310, ground: 0x201B17, face: 0x27221E, raised: 0x322C29, lift: 0x3E3833,
        ink: 0xE6DED6, ink2: 0xADA8A3, ink3: 0x7C7874,
        accent: 0x60CDCD, accentDeep: 0x009898,
        red: 0xFB939C, orange: 0xF2A56F, amber: 0xE5BD66, green: 0x8DCD8E,
        cyan: 0x66CCD1, blue: 0x78BEEF, purple: 0xBCAAF4, magenta: 0xE399D3,
        identity: [0xE7958E, 0xDD9F6B, 0xBDB062, 0x85BF86, 0x55C2BC, 0x6AB8E4, 0x9BA9ED, 0xCA99D6],
        ansi: [
            0x3A3431, 0xFB939C, 0x8DCD8E, 0xE5BD66, 0x56B9DD, 0xBCAAF4, 0x66CCD1, 0xADA8A3,
            0x7C7874, 0xFFBBBF, 0xABE6AC, 0xFCD78A, 0x7CD1F3, 0xD4C8FF, 0x8CE4E9, 0xE6DED6,
        ],
        isLight: false,
    ))

    /// Foundry Ember Light — warm paper, the normal-polarity Ember for the follow-OS light slot.
    /// face #F6F0ED, ink #36312C (Lc ~91 — normal polarity lands naturally firmer).
    static let foundryEmberLight = foundry(FoundrySeed(
        name: "ember-light",
        void: 0xDDD8D4, ground: 0xEBE5E1, face: 0xF6F0ED, raised: 0xFFF9F5, lift: 0xFFFEFE,
        ink: 0x36312C, ink2: 0x756F69, ink3: 0x9A938D,
        accent: 0x007272, accentDeep: 0x004D4D,
        red: 0xB43249, orange: 0xA35303, amber: 0x8E6A00, green: 0x357A3A,
        cyan: 0x00787D, blue: 0x006A9D, purple: 0x6E4FB1, magenta: 0x9A3A8A,
        identity: [0xAB5B56, 0xA2662F, 0x857720, 0x4B864E, 0x008883, 0x277FAB, 0x6470B3, 0x91619C],
        ansi: [
            0x36312C, 0xB43249, 0x357A3A, 0x8E6A00, 0x006E8C, 0x6E4FB1, 0x00787D, 0xFFFEFE,
            0x9A938D, 0xC93450, 0x34893C, 0x9C7500, 0x007A9B, 0x7B57C8, 0x00858A, 0xFFF9F5,
        ],
        isLight: true,
    ))

    /// Foundry Dusk — cool mauve (OKLCH hue 300), the Catppuccin / Rosé Pine temperature family
    /// contrast-corrected to the FOUNDRY targets; iris accent. face #242129.
    static let foundryDusk = foundry(FoundrySeed(
        name: "dusk",
        void: 0x151219, ground: 0x1D1A21, face: 0x242129, raised: 0x2F2C35, lift: 0x3A3741,
        ink: 0xE5DCE9, ink2: 0xADA7AF, ink3: 0x7B777D,
        accent: 0xB3B1FC, accentDeep: 0x7F77D9,
        red: 0xFB939C, orange: 0xF2A56F, amber: 0xE5BD66, green: 0x8DCD8E,
        cyan: 0x66CCD1, blue: 0x78BEEF, purple: 0xBCAAF4, magenta: 0xE399D3,
        identity: [0xE7958E, 0xDD9F6B, 0xBDB062, 0x85BF86, 0x55C2BC, 0x6AB8E4, 0x9BA9ED, 0xCA99D6],
        ansi: [
            0x36343C, 0xFB939C, 0x8DCD8E, 0xE5BD66, 0x56B9DD, 0xBCAAF4, 0x66CCD1, 0xADA7AF,
            0x7B777D, 0xFFBBBF, 0xABE6AC, 0xFCD78A, 0x7CD1F3, 0xD4C8FF, 0x8CE4E9, 0xE5DCE9,
        ],
        isLight: false,
    ))

    /// Foundry Graphite — near-neutral precision (OKLCH hue 270, barely-cool cast); electric cyan accent.
    /// face #222325.
    static let foundryGraphite = foundry(FoundrySeed(
        name: "graphite",
        void: 0x131416, ground: 0x1B1C1E, face: 0x222325, raised: 0x2D2E30, lift: 0x38393C,
        ink: 0xDFDFE3, ink2: 0xA9A9AC, ink3: 0x78787B,
        accent: 0x61C9E7, accentDeep: 0x0094B3,
        red: 0xFB939C, orange: 0xF2A56F, amber: 0xE5BD66, green: 0x8DCD8E,
        cyan: 0x66CCD1, blue: 0x78BEEF, purple: 0xBCAAF4, magenta: 0xE399D3,
        identity: [0xE7958E, 0xDD9F6B, 0xBDB062, 0x85BF86, 0x55C2BC, 0x6AB8E4, 0x9BA9ED, 0xCA99D6],
        ansi: [
            0x343537, 0xFB939C, 0x8DCD8E, 0xE5BD66, 0x56B9DD, 0xBCAAF4, 0x66CCD1, 0xA9A9AC,
            0x78787B, 0xFFBBBF, 0xABE6AC, 0xFCD78A, 0x7CD1F3, 0xD4C8FF, 0x8CE4E9, 0xDFDFE3,
        ],
        isLight: false,
    ))
}

/// Static token namespace. Colours read the active `theme` (default Foundry Ember); metrics/anim are
/// theme-free.
enum Slate {
    /// The active theme. Indirected through ``ThemeStore/shared`` (D3) so runtime theme switching repoints
    /// every token live — `@MainActor` because the store is, and every read site is a SwiftUI `body` /
    /// AppKit lifecycle hook (all MainActor). ``ThemeStore``'s default (`.foundryEmber`) means a
    /// headless / no-store render still resolves a real, deterministic palette.
    @MainActor static var theme: SlateTheme { ThemeStore.shared.active }

    /// The preferred SwiftUI colour scheme for the active theme (drives `.preferredColorScheme`).
    @MainActor static var colorScheme: ColorScheme { theme.isLight ? .light : .dark }

    // The colour namespaces are `@MainActor` because they read the runtime ``ThemeStore`` via
    // ``Slate/theme`` (D3) — every read site is a SwiftUI `body` / AppKit lifecycle hook (all MainActor).
    /// The 5-rung FOUNDRY surface ladder — the ONLY surface vocabulary view code speaks:
    /// `void` (seams + aux backdrops) → `ground` (chrome housing) → `face` (the lit pane) →
    /// `raised` (one step lifted) → `lift` (hover/pressed on raised, selection fills).
    @MainActor
    enum Surface {
        static var void: Color { Slate.theme.void }
        static var ground: Color { Slate.theme.ground }
        static var face: Color { Slate.theme.face }
        static var raised: Color { Slate.theme.raised }
        static var lift: Color { Slate.theme.lift }
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

    /// The seed chromatics outside the status quartet — extra DISTINGUISHABLE hues for chrome that needs
    /// more inks than `ok`/`warn`/`err`/`info` provide, taken from the active seed so a
    /// theme swap repoints them like every other token. Carries no urgency of its own: unlike ``Status``,
    /// the meaning lives entirely at the call site.
    @MainActor
    enum Chroma {
        static var orange: Color { Slate.theme.chromaOrange }
        static var purple: Color { Slate.theme.chromaPurple }
        static var blue: Color { Slate.theme.chromaBlue }
        static var magenta: Color { Slate.theme.chromaMagenta }
    }

    /// The IDENTITY register — a project's own hue, held for life and spent ONLY as a 2px spine plus a
    /// ≤5% wash on its active row (DESIGN.md, the Three-Registers Rule): never per-row plates, never
    /// recoloured text, never identity-tinted icons. The hue is derived from the project's stable key
    /// (FNV-1a over UTF-8, mod 8) so every client resolves the same hue with no synced state.
    @MainActor
    enum Identity {
        /// The 8 engine-generated identity hues of the active theme (one lightness, one chroma).
        static var hues: [Color] { Slate.theme.identity }

        /// The identity hue for a project's stable key (its workspace path / project id).
        static func hue(for key: String) -> Color { hues[index(for: key)] }

        /// Stable key → hue index. FNV-1a 64-bit over UTF-8, folded mod 8 — deterministic across
        /// processes and clients (never `Hasher`, which is seeded per-process).
        nonisolated static func index(for key: String) -> Int {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in key.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return Int(hash % 8)
        }
    }

    @MainActor
    enum Status {
        static var ok: Color { Slate.theme.statusOK }
        static var warn: Color { Slate.theme.statusWarn }
        static var err: Color { Slate.theme.statusErr }
        static var info: Color { Slate.theme.statusInfo }

        /// FIXED security-blue — theme-INDEPENDENT (NOT derived from `Slate.theme`), unlike ``info``. The
        /// secure-input pill must read as the SAME vivid royal-blue on every theme so it can never be confused
        /// with the theme accent: under every FOUNDRY seed `statusInfo` IS the accent (`info == accent`),
        /// which would make a theme-derived security badge indistinguishable
        /// from the accent. Pinned to `secure-input.png`'s royal-blue (#2D6FE8) — a mid royal-blue that keeps
        /// white pill text legible on BOTH light and dark themes. Never re-route this through the theme.
        static let secureInput = Color(slateHex: 0x2D6FE8)

        /// FIXED sync-amber — theme-INDEPENDENT, same rationale as ``secureInput``: the `⚠ SYNC INPUT`
        /// pill flags a MODE where every keystroke fans into multiple shells, so it must read as the
        /// same unmistakable amber on every theme and never collapse into a theme accent (the default
        /// hazard amber `statusWarn` is reserved for the agent-needs-you register). A mid amber keeps white
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
        /// The IDENTITY spine — the 2px project-hue bar standing at the leading edge of a sidebar
        /// project group (the identity register's entire footprint besides the active row's wash).
        static let identitySpineWidth: CGFloat = 2
        /// The active row's identity WASH opacity — the register's ceiling (DESIGN.md caps it at 5%).
        static let identityWashOpacity: CGFloat = 0.05
        /// A DRAINED spine segment's opacity (the Heat-Is-Life Rule: done/disconnected keeps the hue
        /// at 28% — the past desaturates in place rather than vanishing).
        static let identitySpineDrainedOpacity: CGFloat = 0.28
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
