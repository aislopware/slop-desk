// SlateDesign — the minimalist design-token layer.
//
// A THIN, headless token layer: no separate SPM target (`SlopDeskDesignSystem` stays deleted) — just
// `Color`/`CGFloat`/`Animation` constants compiled into `SlopDeskClientUI`.
//
// Design DNA — NATIVE CHROME, TERMINAL GLASS (user-directed 2026-08-07, replacing the painted
// FOUNDRY chrome after three hex-world rounds all read as generic):
//   - CHROME IS THE OPERATING SYSTEM'S. Every chrome surface, text tier, hairline and fill resolves to
//     a SEMANTIC system colour (`labelColor` tiers, `separatorColor`, the system fill ladder,
//     `windowBackgroundColor`/`underPageBackgroundColor`). Semantic colours resolve per-appearance at
//     draw time, so the chrome follows the OS light/dark switch, window activation and vibrancy the
//     way a native app does — behaviours a static hex palette can never fake. No invented chrome hex.
//   - THE TERMINAL IS THE CONTENT EXCEPTION (the Pages pattern): the pane area keeps a deliberate
//     fixed palette — the ``SlateTheme`` TERMINAL PROFILE — the way a printed page stays white in a
//     dark window. The whole split tree renders as ONE floating island (JetBrains Islands): a single
//     rounded glass card on the system chrome, panes divided INSIDE it by subtle lines on the glass.
//   - ONE brand accent: the fixed Ember teal (light `#007272`, lifted for dark appearances). It is the
//     only chrome colour that is ours; everything else is the system's.
//   - The metric / type ladders are unchanged: 8pt grid, closed height ladder, JetBrains Mono
//     instrument voice (`check-ds-leaks.sh` still enforces the closed scales).
//
// MULTI-THEME is now TERMINAL-PROFILE-ONLY: a theme switch swaps the glass palette (cells, ANSI,
// selection, cursor, the island's own ink) and touches NO chrome. `Slate.theme` still indirects
// through ``ThemeStore/shared`` (D3) so a runtime profile switch repoints the glass tokens live;
// chrome tokens no longer read the store at all — they are semantic and follow the window appearance.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A TERMINAL PROFILE — the fixed palette of the terminal glass (the one deliberate-colour surface in
/// an otherwise system-semantic app). Owns everything drawn ON the glass: the cell colours libghostty
/// paints, the ANSI set, and the ink/edge/accent the SwiftUI chrome floating inside the island uses
/// (status line, chips, focus corner) — ON-GLASS text must read against the profile, not against the
/// OS appearance, because the glass does not follow the OS appearance.
struct SlateTheme: Equatable {
    /// Stable identity for change-detection + persistence (`ThemeChoice.builtinID`).
    let id: String
    /// Whether the GLASS is light — the profile's own polarity, independent of the OS appearance
    /// (a dark glass in a light window is the product default).
    let isLight: Bool

    // The glass surfaces
    /// The terminal cell surface — the island's ground.
    let terminal: Color
    /// The divider / seam line ON the glass (the profile's selection tone: one step off the face).
    let terminalEdge: Color
    /// A lifted plate ON the glass (chips, handles) — the selection fill.
    let terminalRaised: Color

    // The on-glass ink
    /// Primary on-glass ink — the profile foreground.
    let terminalInk: Color
    /// Secondary on-glass ink (status line, captions on the glass).
    let terminalInk2: Color
    /// The on-glass ACCENT (focus corner, divider drag line, drop washes) — profile-tuned because the
    /// window accent is appearance-tuned and the glass ignores the appearance.
    let terminalAccent: Color

    // The libghostty config values (6-hex, no `#`) — applied via ``TerminalConfigBuilder``.
    let terminalBackgroundHex: String
    let terminalForegroundHex: String
    /// The 16 ANSI terminal colours (indices 0–15). Reaches the cells via `palette = N=<hex>`.
    let ansiPalette: [String]
    /// Selection highlight background, opaque RGB; paired with `selection-foreground =
    /// cell-foreground` so glyph colours stay under the fill (not an invert). `nil` ⇒ no line.
    let selectionBackgroundHex: String?
    /// Cursor block colour; `nil` ⇒ follow the foreground.
    let cursorHex: String?
    /// Glyph-under-cursor colour; `nil` ⇒ follow the background.
    let cursorTextHex: String?

    /// Build a profile from 24-bit RGB values (single source for both the `Color` and hex forms).
    private static func profile(
        id: String, isLight: Bool,
        face: UInt32, ink: UInt32, ink2: UInt32, edge: UInt32, accent: UInt32,
        ansi: [UInt32],
    ) -> Self {
        Self(
            id: id,
            isLight: isLight,
            terminal: Color(slateHex: face),
            terminalEdge: Color(slateHex: edge),
            terminalRaised: Color(slateHex: edge),
            terminalInk: Color(slateHex: ink),
            terminalInk2: Color(slateHex: ink2),
            terminalAccent: Color(slateHex: accent),
            terminalBackgroundHex: hex6(face),
            terminalForegroundHex: hex6(ink),
            ansiPalette: ansi.map { hex6($0) },
            // Solid edge-tone fill (opaque — libghostty Color is RGB-only). Glyph colours stay via
            // selection-foreground=cell-foreground, so this is a highlight, not an invert.
            selectionBackgroundHex: hex6(edge),
            cursorHex: hex6(ink),
            cursorTextHex: nil,
        )
    }

    /// 6-hex uppercase string (no `#`) for a 24-bit RGB literal — the libghostty config value format.
    /// Manual (no `String(format:)`) to stay allocation-cheap and trap-free.
    private static func hex6(_ v: UInt32) -> String {
        func pair(_ x: UInt32) -> String {
            let s = String(x & 0xFF, radix: 16, uppercase: true)
            return (x & 0xFF) < 0x10 ? "0" + s : s
        }
        return pair(v >> 16) + pair(v >> 8) + pair(v)
    }

    // MARK: - Built-in profiles

    /// Ember — the DEFAULT: the warm dark glass the product has worn since FOUNDRY (#27221E cells,
    /// the palette the user picked and kept through every chrome round). Ids keep their historic
    /// `foundry-` prefix so persisted theme choices resolve unchanged.
    static let foundryEmber = profile(
        id: "foundry-ember", isLight: false,
        face: 0x27221E, ink: 0xE6DED6, ink2: 0xADA8A3, edge: 0x3E3833, accent: 0x66CCD1,
        ansi: [
            0x3A3431, 0xFB939C, 0x8DCD8E, 0xE5BD66, 0x56B9DD, 0xBCAAF4, 0x66CCD1, 0xADA8A3,
            0x7C7874, 0xFFBBBF, 0xABE6AC, 0xFCD78A, 0x7CD1F3, 0xD4C8FF, 0x8CE4E9, 0xE6DED6,
        ],
    )

    /// Ember Light — warm paper glass, the light-polarity Ember.
    static let foundryEmberLight = profile(
        id: "foundry-ember-light", isLight: true,
        face: 0xF6F0ED, ink: 0x36312C, ink2: 0x756F69, edge: 0xE3DCD7, accent: 0x007272,
        ansi: [
            0x36312C, 0xB43249, 0x357A3A, 0x8E6A00, 0x006E8C, 0x6E4FB1, 0x00787D, 0xFFFEFE,
            0x9A938D, 0xC93450, 0x34893C, 0x9C7500, 0x007A9B, 0x7B57C8, 0x00858A, 0xFFF9F5,
        ],
    )

    /// Dusk — cool mauve glass (the Catppuccin / Rosé Pine temperature family); iris accent.
    static let foundryDusk = profile(
        id: "foundry-dusk", isLight: false,
        face: 0x242129, ink: 0xE5DCE9, ink2: 0xADA7AF, edge: 0x36343C, accent: 0xB3B1FC,
        ansi: [
            0x36343C, 0xFB939C, 0x8DCD8E, 0xE5BD66, 0x56B9DD, 0xBCAAF4, 0x66CCD1, 0xADA7AF,
            0x7B777D, 0xFFBBBF, 0xABE6AC, 0xFCD78A, 0x7CD1F3, 0xD4C8FF, 0x8CE4E9, 0xE5DCE9,
        ],
    )

    /// Graphite — near-neutral precision glass; electric cyan accent.
    static let foundryGraphite = profile(
        id: "foundry-graphite", isLight: false,
        face: 0x222325, ink: 0xDFDFE3, ink2: 0xA9A9AC, edge: 0x343537, accent: 0x61C9E7,
        ansi: [
            0x343537, 0xFB939C, 0x8DCD8E, 0xE5BD66, 0x56B9DD, 0xBCAAF4, 0x66CCD1, 0xA9A9AC,
            0x78787B, 0xFFBBBF, 0xABE6AC, 0xFCD78A, 0x7CD1F3, 0xD4C8FF, 0x8CE4E9, 0xDFDFE3,
        ],
    )
}

/// Static token namespace. CHROME tokens are semantic system colours (appearance-following, fixed at
/// compile time); GLASS tokens read the active terminal profile through ``ThemeStore`` (D3).
enum Slate {
    /// The active TERMINAL PROFILE. Indirected through ``ThemeStore/shared`` (D3) so a runtime
    /// profile switch repoints the glass tokens live — `@MainActor` because the store is.
    /// ``ThemeStore``'s default (`.foundryEmber`) means a headless render resolves a real palette.
    @MainActor static var theme: SlateTheme { ThemeStore.shared.active }

    /// The colour scheme of the GLASS (the terminal profile's own polarity) — forced onto the island
    /// subtree (`ContentColumn` / the satellite roots) so every semantic colour drawn ON the glass
    /// (status line, chips, overlays) resolves against the profile's polarity instead of the OS
    /// appearance: the glass does not follow the OS, so its ink must not either. This is the native
    /// dark-content-well idiom (a video player's letterbox, a dark artboard) applied to the terminal.
    @MainActor static var glassColorScheme: ColorScheme { theme.isLight ? .light : .dark }

    /// The FIXED brand accent (Ember teal) as an appearance-dynamic pair: the picked `#007272` on
    /// light appearances, lifted to stay legible on dark chrome. The ONLY chrome colour that is not
    /// the system's — user-directed 2026-08-07 (fixed teal over the user-configurable system accent).
    private static let accentTeal = Color(slateDynamicLight: 0x007272, dark: 0x3DB8B8)
    /// The accent's fill/badge band (filled pills, progress fills — white text sits on it).
    private static let accentTealDeep = Color(slateDynamicLight: 0x005555, dark: 0x0E6B6B)

    /// The chrome surface ladder — SEMANTIC system surfaces plus the one glass exception:
    /// `void` (aux-window backdrops) → `ground` (sidebar housing; on macOS the real sidebar material
    /// sits BEHIND the column and this is its fallback) → `face` (the window content ground) →
    /// `raised`/`lift` (the system fill ladder) → `terminal` (the island glass — profile-driven).
    @MainActor
    enum Surface {
        #if canImport(AppKit)
        static let void = Color(nsColor: .underPageBackgroundColor)
        static let ground = Color(nsColor: .underPageBackgroundColor)
        static let face = Color(nsColor: .windowBackgroundColor)
        static let raised = Color(nsColor: .quaternarySystemFill)
        static let lift = Color(nsColor: .tertiarySystemFill)
        /// The SOLID mini-island fill — the active sidebar row's chip (Canario's white active tab).
        /// Against ``field`` it carries the JetBrains Islands island↔field relationship in both
        /// appearances: WHITE on the grey light field (island lighter than field), and a step
        /// DARKER than the dark field (island darker than field) — the same deliberate ~1.2:1
        /// whisper their theme ships, from a semantic colour instead of invented hex.
        static let chip = Color(nsColor: .controlBackgroundColor)
        /// THE FLOOR — the one colour every window column and divider gap paints (user-directed
        /// 2026-08-07, islands round). NOT the raw `windowBackgroundColor`: on current macOS that
        /// resolves to PURE WHITE in light and to a tone DARKER than the Ember glass in dark
        /// (#1E1E1E vs #27221E — measured), which flattens the white active chip into the floor
        /// and inverts the reference's dark-mode relationship. JetBrains Islands runs the field a
        /// deliberate step OFF the island tones in each mode — darker than the islands in light,
        /// lighter in dark, ~1.2:1. This dynamic colour derives that step from semantics at draw
        /// time: the window background blended a few points toward its opposite pole. Exposed as
        /// an `NSColor` too because the AppKit split view (divider gap + layer) paints the same
        /// floor.
        static let fieldNSColor = NSColor(
            name: nil,
            dynamicProvider: { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let base = NSColor.windowBackgroundColor
                return base.blended(withFraction: dark ? 0.09 : 0.08, of: dark ? .white : .black)
                    ?? base
            },
        )
        static let field = Color(nsColor: fieldNSColor)
        #else
        static let void = Color(uiColor: .secondarySystemBackground)
        static let ground = Color(uiColor: .secondarySystemBackground)
        static let face = Color(uiColor: .systemBackground)
        static let raised = Color(uiColor: .quaternarySystemFill)
        static let lift = Color(uiColor: .tertiarySystemFill)
        /// See the AppKit notes — the solid active-row chip and the window floor; the grouped
        /// pair is iOS's own "cell on a field" idiom, so no blend is needed here.
        static let chip = Color(uiColor: .secondarySystemGroupedBackground)
        static let field = Color(uiColor: .systemGroupedBackground)
        #endif
        /// The terminal glass — the island's fixed profile surface (NOT appearance-following).
        static var terminal: Color { Slate.theme.terminal }
    }

    /// ON-GLASS vocabulary — everything drawn INSIDE the terminal island reads these, never the
    /// semantic `Text`/`State` tiers: the glass keeps its profile palette under either OS
    /// appearance, so appearance-tuned ink would invert against it (dark label on dark glass).
    @MainActor
    enum Terminal {
        static var ink: Color { Slate.theme.terminalInk }
        static var ink2: Color { Slate.theme.terminalInk2 }
        static var edge: Color { Slate.theme.terminalEdge }
        static var raised: Color { Slate.theme.terminalRaised }
        static var accent: Color { Slate.theme.terminalAccent }
    }

    /// The semantic text tiers — resolve per-appearance AND per-vibrancy (a custom RGB here would
    /// silently opt the label out of vibrancy on the sidebar material).
    @MainActor
    enum Text {
        #if canImport(AppKit)
        static let primary = Color(nsColor: .labelColor)
        static let secondary = Color(nsColor: .secondaryLabelColor)
        static let tertiary = Color(nsColor: .tertiaryLabelColor)
        static let icon = Color(nsColor: .secondaryLabelColor)
        #else
        static let primary = Color(uiColor: .label)
        static let secondary = Color(uiColor: .secondaryLabel)
        static let tertiary = Color(uiColor: .tertiaryLabel)
        static let icon = Color(uiColor: .secondaryLabel)
        #endif
    }

    @MainActor
    enum Line {
        #if canImport(AppKit)
        static let divider = Color(nsColor: .separatorColor)
        static let card = Color(nsColor: .separatorColor)
        static let subtle = Color(nsColor: .separatorColor).opacity(0.6)
        static let active = Color(nsColor: .tertiaryLabelColor)
        #else
        static let divider = Color(uiColor: .separator)
        static let card = Color(uiColor: .separator)
        static let subtle = Color(uiColor: .separator).opacity(0.6)
        static let active = Color(uiColor: .tertiaryLabel)
        #endif
    }

    @MainActor
    enum State {
        #if canImport(AppKit)
        /// Row hover — the system's faintest fill (the same plate `List` hover uses).
        static let hover = Color(nsColor: .quinarySystemFill)
        #else
        static let hover = Color(uiColor: .quaternarySystemFill)
        #endif
        /// Selected row — the brand accent at a wash, so selection carries the one non-system colour.
        static let selected = Slate.accentTeal.opacity(0.15)
        static let accent = Slate.accentTeal
        static let accentMuted = Slate.accentTeal.opacity(0.12)
        static let header = Text.secondary
        /// Floating-panel drop shadow — soft black, heavier on dark appearances.
        static let shadow = Color(slateDynamicLight: 0x000000, dark: 0x000000, lightAlpha: 0.15, darkAlpha: 0.45)
        /// The ACTIVE tab card's cast shadow — light appearances only; on dark, at-rest depth is the
        /// fill ladder, and a dark-on-dark shadow reads as a smudged edge, not lift.
        static let cardShadow = Color(slateDynamicLight: 0x000000, dark: 0x000000, lightAlpha: 0.04, darkAlpha: 0)
    }

    /// Extra DISTINGUISHABLE hues for chrome that needs more inks than the status set — the SYSTEM
    /// palette (appearance-tuned by the OS), consistent with every other chrome colour.
    @MainActor
    enum Chroma {
        #if canImport(AppKit)
        static let orange = Color(nsColor: .systemOrange)
        static let purple = Color(nsColor: .systemPurple)
        static let blue = Color(nsColor: .systemBlue)
        static let magenta = Color(nsColor: .systemPink)
        #else
        static let orange = Color(uiColor: .systemOrange)
        static let purple = Color(uiColor: .systemPurple)
        static let blue = Color(uiColor: .systemBlue)
        static let magenta = Color(uiColor: .systemPink)
        #endif
    }

    /// The IDENTITY register — a project's own hue, held for life and spent ONLY as a spine/wash on
    /// its rows (never per-row plates, never recoloured text). The hues are the SYSTEM palette — the
    /// same eight-family dialect Finder tags speak, appearance-tuned by the OS.
    @MainActor
    enum Identity {
        #if canImport(AppKit)
        static let hues: [Color] = [
            Color(nsColor: .systemRed), Color(nsColor: .systemOrange),
            Color(nsColor: .systemYellow), Color(nsColor: .systemGreen),
            Color(nsColor: .systemTeal), Color(nsColor: .systemBlue),
            Color(nsColor: .systemIndigo), Color(nsColor: .systemPurple),
        ]
        #else
        static let hues: [Color] = [
            Color(uiColor: .systemRed), Color(uiColor: .systemOrange),
            Color(uiColor: .systemYellow), Color(uiColor: .systemGreen),
            Color(uiColor: .systemTeal), Color(uiColor: .systemBlue),
            Color(uiColor: .systemIndigo), Color(uiColor: .systemPurple),
        ]
        #endif

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
        #if canImport(AppKit)
        static let ok = Color(nsColor: .systemGreen)
        static let warn = Color(nsColor: .systemOrange)
        static let err = Color(nsColor: .systemRed)
        #else
        static let ok = Color(uiColor: .systemGreen)
        static let warn = Color(uiColor: .systemOrange)
        static let err = Color(uiColor: .systemRed)
        #endif
        /// Info rides the brand accent (the one non-system chrome colour).
        static let info = Slate.accentTeal

        /// FIXED security-blue — appearance-INDEPENDENT: the secure-input pill must read as the SAME
        /// vivid royal-blue everywhere so it can never be confused with the accent. Pinned to
        /// `secure-input.png`'s royal-blue; white pill text stays legible on light and dark alike.
        /// Never re-route this through a theme or the system palette.
        static let secureInput = Color(slateHex: 0x2D6FE8)

        /// FIXED sync-amber — same rationale as ``secureInput``: the `⚠ SYNC INPUT` pill flags a MODE
        /// where every keystroke fans into multiple shells, so it must read as the same unmistakable
        /// amber everywhere. Never re-route this through a theme or the system palette.
        static let syncInput = Color(slateHex: 0xD97A1F)
    }

    /// The accent's deep band — the fill/badge variant for surfaces where the text-sized accent would
    /// be a pastel wash (filled pills, progress fills).
    @MainActor
    enum Accent {
        static let deep = Slate.accentTealDeep
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

        /// The terminal ISLAND's corner — the one rounded glass card the whole split tree renders as
        /// (JetBrains Islands, user-directed 2026-08-07). Rides the floating-panel rung: the island
        /// IS a floating panel, just a permanent one.
        static let radiusIsland: CGFloat = radiusPanel
        /// The desk margin around the island — the system chrome visible around the glass.
        static let islandMargin: CGFloat = space2

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

    /// An APPEARANCE-DYNAMIC colour pair — resolves `light`/`dark` per the effective appearance at
    /// draw time (the mechanism every semantic system colour uses), so the brand accent follows the
    /// window appearance the way `labelColor` does instead of being pinned to one mode.
    init(
        slateDynamicLight light: UInt32, dark: UInt32,
        lightAlpha: Double = 1, darkAlpha: Double = 1,
    ) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(slateHex: dark, alpha: darkAlpha)
                : NSColor(slateHex: light, alpha: lightAlpha)
        })
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(slateHex: dark, alpha: darkAlpha)
                : UIColor(slateHex: light, alpha: lightAlpha)
        })
        #endif
    }
}

#if canImport(AppKit)
extension NSColor {
    /// 24-bit sRGB hex + alpha (the dynamic-pair helper's leaf).
    convenience init(slateHex hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha,
        )
    }
}
#elseif canImport(UIKit)
extension UIColor {
    /// 24-bit sRGB hex + alpha (the dynamic-pair helper's leaf).
    convenience init(slateHex hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha,
        )
    }
}
#endif
#endif
