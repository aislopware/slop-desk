// SlateDesign — the minimalist design-token layer.
//
// A THIN, headless token layer: no separate SPM target (`SlopDeskDesignSystem` stays deleted) — just
// `Color`/`CGFloat`/`Animation` constants compiled into `SlopDeskClientUI`.
//
// Design DNA — ONE ISLAND (user-directed 2026-08-08, twice: first "re-implement the floating-island
// chrome, the Rio-Canario / JetBrains-Islands read", then — on seeing a window where every column and
// every pane was its own island — "too busy; make it a MODERN island: only ONE big island in the
// middle, the terminal, splits parted by a divider; the two side panels SINK into the background, the
// VS Code background matches that background; and make the background the Alucard (light) theme's
// own bg". FOUR LAWS, in force everywhere:
//
//   1. ONE ISLAND. The window holds exactly TWO tones, and only ONE thing is lifted: the terminal
//      canvas. It wears the theme's glass, rounds at the concentric radius and floats in a uniform
//      moat. EVERYTHING else — the navigator, the code panel, the top band, the moat — is the GROUND
//      (``Surface/ground``) and is FLUSH: no rounding, no inset, no second working tone. A panel that
//      sinks does not compete with the one thing that is meant to read as lifted, which is exactly
//      what the many-islands pass got wrong.
//   2. INSIDE THE ISLAND, SEPARATION IS A LINE. Panes tile the island edge-to-edge and are parted by
//      the ``PaneDivider`` hairline. A channel of ground between panes would restate at pane level
//      the distinction the island already draws at window level — one lift, one vocabulary.
//   3. CONCENTRIC GEOMETRY. Window 16 (the macOS Tahoe titlebar-only window radius), moat 8, island
//      8: Apple's own concentricity rule (inner radius = outer radius − inset). The same 8 falls out
//      of JetBrains' published `Island.arc.compact = 16` (an arc WIDTH ⇒ radius 8) and out of
//      measuring Canario (≈7.5), so three independent sources agree on the number.
//   4. THE GROUND IS ALUCARD'S CREAM `#FFFBEB` IN BOTH PROFILES — the light theme's own published
//      face, used as the frame under either glass. On Dracula that is the CANARIO read: a light
//      frame carrying a dark island, ~13:1 apart, the only way to get real drama out of a dark theme
//      (a dark-on-dark frame caps at 1.32:1 against #22212C even at pure black — arithmetic, not
//      taste). On Alucard the ground and the glass are the SAME cream, so the window reads as one
//      calm light surface and structure falls to the dividers and the island's corner alone. This
//      reverses the earlier "no inverted frame" verdict on the user's explicit instruction.
//
//   - Text tiers, hairlines and state fills stay SEMANTIC system colours — they resolve against the
//     app-level appearance pin, which is now ALWAYS LIGHT (`chromeIsLight == true`), because law 4
//     makes the ground light in both profiles. That is a CONSEQUENCE of the ground, not a second
//     decision: semantic ink pinned dark would draw white-on-cream in the navigator. The glass keeps
//     its own polarity via ``Slate/glassColorScheme``, so a dark island still carries light ink.
//   - ONE brand accent: the fixed Dracula purple (light `#644AC9`, the Pro `#9580FF` on dark).
//     Identity hues stay OFF chrome glyphs; the status dot set is the only other colour the sidebar
//     speaks.
//   - The metric / type ladders are unchanged: 8pt grid, closed height ladder, JetBrains Mono
//     instrument voice (`check-ds-leaks.sh` still enforces the closed scales).
//
// MULTI-THEME is TERMINAL-PROFILE-ONLY: a theme switch swaps the glass palette (cells, ANSI,
// selection, cursor, on-island ink); the GROUND does not move. `Slate.theme` indirects through
// ``ThemeStore/shared`` (D3) so a runtime profile switch repoints the glass tokens live.

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
    /// Whether the GLASS is light — the profile's own polarity. Drives the forced on-glass colour
    /// scheme (``Slate/glassColorScheme``): text drawn ON the glass resolves against the glass, not
    /// against the OS or the chrome.
    let isLight: Bool
    /// Whether the CHROME is light. ALWAYS `true` under ONE ISLAND (user-directed 2026-08-08): law 4
    /// puts the same cream ground under both profiles, so the semantic ink standing on it must
    /// resolve light-appearance in both, or the navigator draws white-on-cream. The app-level pin
    /// (`ThemeStore.pinAppAppearance`) reads THIS, not ``isLight`` — one appearance voice for every
    /// chrome surface including the auxiliary windows, so nothing is half-and-half; the dark island
    /// is not an exception to it but a surface outside it, wearing the profile palette directly.
    let chromeIsLight: Bool

    // The glass surfaces
    /// The terminal cell surface — the island's ground.
    let terminal: Color
    /// The divider / seam line ON the glass (the profile's selection tone: one step off the face).
    let terminalEdge: Color
    /// A lifted plate ON the glass (chips, handles) — the selection fill.
    let terminalRaised: Color

    /// THE GROUND — everything that is not the one island (law 1): the navigator, the code panel,
    /// the top band and the moat around the terminal. Alucard's published cream `#FFFBEB` under both
    /// profiles, never invented (inventing a chrome hex is what sank the five dead worlds). FIXED,
    /// never appearance-resolved (the CGColor-snapshot trap family stays dead). Raw hex because the
    /// AppKit split shell resolves it as an `NSColor`.
    let groundHexValue: UInt32
    /// The ISLAND tone — the terminal canvas, the ONE lifted surface. EQUAL to the glass face by
    /// construction, so a profile cannot ship an island in a tone its terminal does not wear. Raw
    /// hex for the AppKit side.
    let chromeHexValue: UInt32
    /// A hairline rule — the pane seam inside the island, a section rule on the ground.
    let chromeLineHexValue: UInt32
    /// The LIFTED rung standing on the ground (hover plates, inset fills) — the activity-bar rung of
    /// the published Dracula ladder (#343746), transposed.
    let chromeLiftHexValue: UInt32
    /// ``groundHexValue`` as the SwiftUI colour the band, the side panels and the moat read.
    var ground: Color { Color(slateHex: groundHexValue) }
    /// ``chromeHexValue`` as the SwiftUI colour the island reads.
    var chrome: Color { Color(slateHex: chromeHexValue) }
    /// ``chromeLineHexValue`` as the SwiftUI colour rules read.
    var chromeLine: Color { Color(slateHex: chromeLineHexValue) }
    /// ``chromeLiftHexValue`` as the SwiftUI colour lifted plates read.
    var chromeLift: Color { Color(slateHex: chromeLiftHexValue) }

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

    /// The AUTHORED chrome ladder a profile ships (ONE ISLAND, user-directed 2026-08-08): `ground`
    /// (everything that is not the island — the SAME cream in both profiles), `line` (rules), `lift`
    /// (plates). The island itself is not a rung: it IS the glass face.
    struct ChromeLadder {
        let ground: UInt32
        let line: UInt32
        let lift: UInt32
    }

    /// The published GLASS palette a profile ships — the terminal's own five (face/ink/comment/
    /// selection-edge/accent), verbatim from the theme's spec.
    struct GlassSet {
        let face: UInt32
        let ink: UInt32
        let ink2: UInt32
        let edge: UInt32
        let accent: UInt32
    }

    /// Build a profile from 24-bit RGB values (single source for both the `Color` and hex forms).
    /// The chrome polarity is LIGHT for every profile — see ``chromeIsLight``; the ground is cream
    /// in both. The ISLAND tone is not a parameter: it IS `glass.face` (law 1), so a profile cannot
    /// accidentally ship an island in a tone its terminal does not wear.
    private static func profile(
        id: String, isLight: Bool,
        glass: GlassSet,
        ansi: [UInt32],
        chrome: ChromeLadder,
    ) -> Self {
        Self(
            id: id,
            isLight: isLight,
            chromeIsLight: true,
            terminal: Color(slateHex: glass.face),
            terminalEdge: Color(slateHex: glass.edge),
            terminalRaised: Color(slateHex: glass.edge),
            groundHexValue: chrome.ground,
            chromeHexValue: glass.face,
            chromeLineHexValue: chrome.line,
            chromeLiftHexValue: chrome.lift,
            terminalInk: Color(slateHex: glass.ink),
            terminalInk2: Color(slateHex: glass.ink2),
            terminalAccent: Color(slateHex: glass.accent),
            terminalBackgroundHex: hex6(glass.face),
            terminalForegroundHex: hex6(glass.ink),
            ansiPalette: ansi.map { hex6($0) },
            // Solid edge-tone fill (opaque — libghostty Color is RGB-only). Glyph colours stay via
            // selection-foreground=cell-foreground, so this is a highlight, not an invert.
            selectionBackgroundHex: hex6(glass.edge),
            cursorHex: hex6(glass.ink),
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

    // MARK: - Built-in profiles (user-directed 2026-08-07, round 8 verdict: exactly TWO)

    //
    // The app wears DRACULA PRO verbatim — the published Pro glass (#22212C face, #F8F8F2 ink,
    // #454158 selection, #7970A9 comment) and the normalized accent seven (S100/L75 in HSL, hue
    // rotated: the Pro method), plus its official light counterpart ALUCARD from the public spec.
    // The CHROME ladder is the published Dracula chrome TRANSPOSED into each glass's band (flat
    // round, user-directed 2026-08-08): the official VS Code Dracula chrome steps its surfaces
    // inside one hue (statusbar #191A21 → sidebar #21222C → editor #282A36 → rail #343746), and
    // each rung here applies that ladder's per-channel offsets to the Pro face instead of the
    // classic one. No frame, no second hue: depth is the only chrome voice.

    /// Dracula — the DEFAULT: Dracula Pro glass over a chrome ladder one band darker.
    /// ANSI note: the Pro seven has no blue — the blue slot carries the purple, per Dracula's own
    /// terminal convention. Brights repeat the bases: the Pro accents are already
    /// lightness-normalized at the top of the band, so a +L derivation only washes them out.
    static let dracula = profile(
        id: "dracula", isLight: false,
        glass: GlassSet(face: 0x22212C, ink: 0xF8F8F2, ink2: 0x7970A9, edge: 0x454158, accent: 0x9580FF),
        ansi: [
            0x454158, 0xFF9580, 0x8AFF80, 0xFFFF80, 0x9580FF, 0xFF80BF, 0x80FFEA, 0xF8F8F2,
            0x7970A9, 0xFF9580, 0x8AFF80, 0xFFFF80, 0x9580FF, 0xFF80BF, 0x80FFEA, 0xFFFFFF,
        ],
        // The GROUND is Alucard's cream #FFFBEB — a LIGHT frame carrying the dark island, the
        // Canario read (~13:1 apart). Any darker frame is arithmetically stuck: #22212C against
        // pure black is 1.32:1, so the whole dark half of the axis cannot separate at all. Lift is
        // the published rail rung (+0C/+0D/+10 on the face → #2E2E3C); the LINE stays the 10%-ink
        // tint, the pane seam inside the island (it pairs with Alucard's 14.2% at OKLab ΔL ≈ 0.09).
        chrome: ChromeLadder(ground: 0xFFFBEB, line: 0x312F37, lift: 0x2E2E3C),
    )

    /// Alucard — Dracula Pro's official light theme (public spec hexes verbatim): cream glass over
    /// a cream chrome ladder one band deeper. Its accents are darkness-normalized for the light
    /// ground, so brights repeat the bases here too.
    static let alucard = profile(
        id: "alucard", isLight: true,
        glass: GlassSet(face: 0xFFFBEB, ink: 0x1F1F1F, ink2: 0x6C664B, edge: 0xCFCFDE, accent: 0x644AC9),
        ansi: [
            0x1F1F1F, 0xCB3A2A, 0x14710A, 0x846E15, 0x644AC9, 0xA3144D, 0x036A96, 0xCFCFDE,
            0x6C664B, 0xCB3A2A, 0x14710A, 0x846E15, 0x644AC9, 0xA3144D, 0x036A96, 0xFFFBEB,
        ],
        // The GROUND is this profile's OWN face — so on Alucard the ground and the island are the
        // same cream and the window reads as one calm light surface, structure carried by the
        // dividers and the island's corner alone. (It is also the tone the dark profile borrows.)
        // Lift steps toward white; the LINE is the 14.2% ink tint (see Dracula).
        chrome: ChromeLadder(ground: 0xFFFBEB, line: 0xD8D3C3, lift: 0xFFFDF4),
    )
}

/// Static token namespace. CHROME tokens are semantic system colours (appearance-following, fixed at
/// compile time); GLASS tokens read the active terminal profile through ``ThemeStore`` (D3).
enum Slate {
    /// The active TERMINAL PROFILE. Indirected through ``ThemeStore/shared`` (D3) so a runtime
    /// profile switch repoints the glass tokens live — `@MainActor` because the store is.
    /// ``ThemeStore``'s default (`.dracula`) means a headless render resolves a real palette.
    @MainActor static var theme: SlateTheme { ThemeStore.shared.active }

    /// The colour scheme of the GLASS (the terminal profile's own polarity) — forced onto the island
    /// subtree (`ContentColumn` / the satellite roots) so every semantic colour drawn ON the glass
    /// (status line, chips, overlays) resolves against the profile's polarity instead of the OS
    /// appearance: the glass does not follow the OS, so its ink must not either. This is the native
    /// dark-content-well idiom (a video player's letterbox, a dark artboard) applied to the terminal.
    @MainActor static var glassColorScheme: ColorScheme { theme.isLight ? .light : .dark }

    /// The FIXED brand accent (Dracula purple) as an appearance-dynamic pair: Alucard's `#644AC9`
    /// on light appearances, the Pro `#9580FF` on dark. The ONLY chrome colour that is not the
    /// system's — user-directed 2026-08-07 (fixed brand accent over the user-configurable system
    /// accent; purple replaced the Ember teal in the round-8 Dracula verdict).
    private static let accentPurple = Color(slateDynamicLight: 0x644AC9, dark: 0x9580FF)
    /// The accent's fill/badge band (filled pills, progress fills — white text sits on it).
    private static let accentPurpleDeep = Color(slateDynamicLight: 0x4B29A7, dark: 0x6B4BD6)

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
        /// THE GROUND — the one sunken tone every column paints: the navigator, the code panel, the
        /// top band and the island's moat (law 1: they SINK, they are not islands). Kept under its
        /// old name because the eight column call sites mean exactly this; ``island`` is its
        /// counterpart, the one lifted surface. `ground` above is a different thing — the semantic
        /// aux-window backdrop.
        static var field: Color { Slate.theme.ground }
        #else
        static let void = Color(uiColor: .secondarySystemBackground)
        static let ground = Color(uiColor: .secondarySystemBackground)
        static let face = Color(uiColor: .systemBackground)
        static let raised = Color(uiColor: .quaternarySystemFill)
        static let lift = Color(uiColor: .tertiarySystemFill)
        /// See the AppKit notes — the solid active-row chip; the chrome ground is the profile's
        /// own rung on iOS too, so both platforms stand on the same flat chrome.
        static let chip = Color(uiColor: .secondarySystemGroupedBackground)
        static var field: Color { Slate.theme.ground }
        #endif
        /// The terminal glass — the island's fixed profile surface (NOT appearance-following).
        static var terminal: Color { Slate.theme.terminal }
        /// THE ISLAND — the terminal canvas, the one lifted surface (law 1). Equal to ``terminal`` by
        /// construction; spelled separately so the island's own geometry reads by intent.
        static var island: Color { Slate.theme.chrome }
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

        /// Ink ON a saturated fill band — the fixed pills (secure blue / sync amber) and the
        /// accent's deep band. Appearance-INDEPENDENT white on purpose: those fills are pinned,
        /// so their ink must be too (a semantic label would flip against an unmoving plate).
        static let onAccent = Color.white
        /// Ink ON the warn/hazard plate (hint badges) — black stays legible on amber in both
        /// appearances, the same pinned-fill rationale as ``onAccent``.
        static let onWarn = Color.black
    }

    @MainActor
    enum Line {
        #if canImport(AppKit)
        static let divider = Color(nsColor: .separatorColor)
        static let card = Color(nsColor: .separatorColor)
        static let subtle = Color(nsColor: .separatorColor).opacity(Opacity.muted)
        static let active = Color(nsColor: .tertiaryLabelColor)
        #else
        static let divider = Color(uiColor: .separator)
        static let card = Color(uiColor: .separator)
        static let subtle = Color(uiColor: .separator).opacity(Opacity.muted)
        static let active = Color(uiColor: .tertiaryLabel)
        #endif
    }

    /// The ALPHA ladder — a closed scale for translucency, the one dimension the closed colour
    /// tokens did not govern (round 13): every `.opacity(N)` in chrome code picks a rung here, so
    /// two washes that mean the same thing can never drift apart by a few hundredths again.
    enum Opacity {
        /// The faint accent wash (``State/accentMuted``'s dose).
        static let faint = 0.12
        /// The selection/latch wash (``State/selected``'s dose).
        static let wash = 0.15
        /// De-emphasised ink ON a plate — a ruled-out hint letter, the dock badge's track.
        static let dim = 0.35
        /// Muted presence: soft hairlines (``Line/subtle``), secondary badge ink on a plate.
        static let muted = 0.6
        /// The near-opaque backdrop a readout stands on over live content (video HUD chips).
        static let scrim = 0.88
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
        static let selected = Slate.accentPurple.opacity(Opacity.wash)
        static let accent = Slate.accentPurple
        static let accentMuted = Slate.accentPurple.opacity(Opacity.faint)
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

    // The per-project IDENTITY hue register (tinted folders, FNV-1a → 8 system hues) is RETIRED
    // (flat round restraint, user-directed 2026-08-08): a hue per project on chrome glyphs read as
    // ornament. Projects are told apart by name, position and tooltip; do not reintroduce a
    // per-project colour mark without a fresh verdict.

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
        static let info = Slate.accentPurple

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
        static let deep = Slate.accentPurpleDeep
    }

    /// Geometry — theme-independent. Radii + the 8pt grid + chrome dimensions.
    enum Metric {
        // MARK: The ONE-ISLAND geometry (law 3)

        /// The WINDOW's own corner radius — macOS 26 Tahoe gives a window the corner its titlebar
        /// asks for, and this app runs `.hiddenTitleBar`. MEASURED on Tahoe 26.5 by rendering one
        /// `NSWindow` per configuration and reading the alpha profile of its corner: no toolbar 16,
        /// `.unifiedCompact` toolbar 21, `.unified` toolbar 26 (Finder and System Settings both
        /// measure 26). Kept because it is a real dimension of the frame — NOT because the island is
        /// derived from it; see ``islandRadius``.
        static let windowRadius: CGFloat = 16
        /// The MOAT — the uniform strip of ground between the island and everything around it. The
        /// island's only margin, equal on all four sides so the lift reads as a lift and not as a
        /// misaligned panel.
        static let islandInset: CGFloat = 8
        /// The island's corner — a WINDOW-SCALE corner, because the island is a window-scale surface
        /// (~880 × 775pt). 26 is what macOS 26 Tahoe puts on a full-chrome window, measured on this
        /// OS; the island wearing it reads as a window floating inside the window, which is the
        /// metaphor.
        ///
        /// The earlier 8, then 14, came from a concentricity rule — inner = outer − inset — that does
        /// NOT apply here: the island lives in the CENTRE column, ~230pt clear of the window's own
        /// corners, so its corners are never seen beside the frame's and nothing constrains them to
        /// stay under 16. Its neighbours are flat dividers and bare ground. (JetBrains' `Island.arc`
        /// and Rio Canario's ≈7.5 are small because their islands tile a window edge to edge; ours is
        /// one card in the middle of a field.) User-directed 2026-08-08, twice.
        static let islandRadius: CGFloat = 26
        /// The COMPACT island — the SELECTED tab's chip, at ``heightRow``/``plate`` scale. Not the
        /// big number scaled down (a corner is read against the surface it cuts, not as a ratio):
        /// this is one rung above the 8 macOS Tahoe puts on its own selected sidebar row (measured in
        /// System Settings), so a selected tab reads as a rounded island rather than the squarish
        /// card it was, while staying clear of the pill a 32pt row reaches at 16.
        static let islandRadiusCompact: CGFloat = 10
        /// The GROUND BAND across the window's top — the strip the traffic lights and the hover
        /// titlebar stand on, above the island. The height ladder's chrome-strip rung
        /// (``heightStrip`` / ``titlebarHeight``); the band is not a new measurement.
        static let bandHeight: CGFloat = heightStrip

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

        /// The footer ARC GAUGE (``PulseGauge``): a ring the size of a footnote glyph box, so it
        /// stands where the metric's SF-symbol mark used to and the pulse line's rhythm holds.
        static let gaugeDiameter: CGFloat = 11
        /// The gauge's ring weight — two hairlines: one reads as a slot, two read as a filling band.
        static let gaugeStroke: CGFloat = 2

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
        static let cardMargin = EdgeInsets(
            top: space1, leading: space4, bottom: space4, trailing: space4,
        )

        /// A FORM card's fixed width (connect, peek-reply) — one width for every dialog-shaped overlay,
        /// so two cards summoned in a row read as the same object at the same distance. List overlays
        /// (palette / open-quickly / global search) size to their own content instead.
        static let cardFormWidth: CGFloat = 460
        /// A PORT number's field on a form card — five digits wide, never the card's width: a field's
        /// width is part of what it says about its answer.
        static let portFieldWidth: CGFloat = 96

        // Chrome dimensions (semantic aliases INTO the height ladder — never a sixth literal)
        static let paneHeaderHeight: CGFloat = heightBar
        /// The hover-reveal titlebar strip height — the content area reserves this at its top so the
        /// terminal starts BELOW the titlebar (the resting silhouette), not under the centred title.
        static let titlebarHeight: CGFloat = heightStrip
        static let sidebarWidth: CGFloat = 220
        /// The MINIMIZED sidebar — the rail (user-directed 2026-08-07, rail round): collapsing the
        /// tabs panel narrows it to this instead of removing it, so the window controls keep a
        /// column under them and the projects stay one glance away. Wide enough that the system
        /// traffic lights (which end ~74pt in) sit inside it with air to spare.
        static let railWidth: CGFloat = 80
        /// One rail project chip — the roomy-row rung, a square the folder mark centres in.
        static let railChip: CGFloat = heightRowTall
        /// The collapsed right panel's EDGE HANDLE (the drawer pull on the window's trailing edge):
        /// its long side. Two control rungs, so the pull reads as a handle, not a button.
        static let edgeHandleLength: CGFloat = heightControl * 2
        /// The edge handle's short side — slim enough to hug the edge, wide enough to hit.
        static let edgeHandleThickness: CGFloat = 20
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
        /// Tracking (pt) for caps micro-labels on a PILL/BADGE plate (the secure-input pill, the
        /// mode badges) — measured off the system secure-input pill's own small-caps spacing, one
        /// shade tighter than the sidebar's ``capsTracking``; its own rung because it is a
        /// measurement, not a preference.
        static let pillTracking: CGFloat = 0.5
    }

    /// The SHADOW ladder (round 13) — one named rung per depth a floating object can sit at, so a
    /// chip in one file can never cast a slightly different shadow than the same chip in another.
    /// Each rung bundles radius + y; the colour stays the caller's (``State/shadow`` for true
    /// floats, ``State/cardShadow`` for the active card's whisper) via ``SwiftUICore/View/slateShadow(_:color:)``.
    enum Elevation {
        /// The active card's whisper — the overlay card sitting IN a surface, barely off it.
        case card
        /// A pill/chip floating over the glass: status pills, mode badges, instrument chips.
        case chip
        /// A pane ghost mid-drag — clearly lifted, still near.
        case ghost
        /// A floating panel: the find bar, the overlay cards.
        case panel
        /// The command palette — the deepest float in the app.
        case palette

        var radius: CGFloat {
            switch self {
            case .card: 2
            case .chip: 4
            case .ghost: 8
            case .panel: 12
            case .palette: 30
            }
        }

        var y: CGFloat {
            switch self {
            case .card: 1
            case .chip: 1
            case .ghost: 2
            case .panel: 4
            case .palette: 12
            }
        }
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
        /// The ONE repeating shape in the vocabulary — a slow symmetric breathe for a preview that
        /// demonstrates blinking (the cursor preview). EaseInEaseOut 0.55s, autoreversing forever;
        /// never used on live chrome (the at-rest-motion purge stands).
        static let pulse = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.55)
            .repeatForever(autoreverses: true)
    }
}

extension View {
    /// Cast the shadow of a named ``Slate/Elevation`` rung. The colour defaults to the floating
    /// object's soft black (``Slate/State/shadow``); the active card passes its own whisper
    /// (``Slate/State/cardShadow``). Radius/y never appear at a call site — the rung is the API.
    @MainActor
    func slateShadow(_ elevation: Slate.Elevation, color: Color? = nil) -> some View {
        shadow(color: color ?? Slate.State.shadow, radius: elevation.radius, y: elevation.y)
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
