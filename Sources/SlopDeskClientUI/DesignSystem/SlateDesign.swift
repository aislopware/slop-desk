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
//   4. THE GROUND IS ALUCARD'S CREAM `#FFFBEB` — the light theme's own published face, used as the
//      frame under the dark glass. That is the CANARIO read: a light frame carrying a dark island,
//      ~13:1 apart, the only way to get real drama out of a dark terminal (a dark-on-dark frame caps
//      at 1.32:1 against #22212C even at pure black — arithmetic, not taste). It reverses the
//      earlier "no inverted frame" verdict on the user's explicit instruction.
//
// ONE APPEARANCE (user-directed 2026-08-08): the theme PICKER is gone and so is its machinery —
// there is no light/dark slot, no follow-OS resolution, no per-theme font map, no runtime store. The
// app is a cream ground carrying a dark terminal, always, and law 4 is the reason a second profile
// had nothing left to vary: the ground was already the same cream under both, so an "Alucard" pick
// only flattened the one contrast the design is built on. `Slate.theme` is therefore a CONSTANT.
//
//   - Text tiers, hairlines and state fills stay SEMANTIC system colours — they resolve against the
//     app-level appearance pin, which is ALWAYS LIGHT, because law 4 makes the ground light. That is
//     a CONSEQUENCE of the ground, not a second decision: semantic ink pinned dark would draw
//     white-on-cream in the navigator. The glass keeps its own polarity via
//     ``Slate/glassColorScheme``, so the dark island still carries light ink.
//   - ONE brand accent: the fixed Dracula purple (light `#644AC9`, the Pro `#9580FF` on dark).
//     Identity hues stay OFF chrome glyphs; the status dot set is the only other colour the sidebar
//     speaks.
//   - The metric / type ladders are unchanged: 8pt grid, closed height ladder, JetBrains Mono
//     instrument voice (`check-ds-leaks.sh` still enforces the closed scales).

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
struct SlateTheme: Equatable, Sendable {
    // The glass surfaces
    /// The terminal cell surface — the island's ground.
    let terminal: Color
    /// The divider / seam line ON the glass (the profile's selection tone: one step off the face).
    let terminalEdge: Color
    /// A lifted plate ON the glass (chips, handles) — the selection fill.
    let terminalRaised: Color

    /// THE GROUND — everything that is not the one island (law 1): the navigator, the code panel,
    /// the top band and the moat around the terminal. Alucard's published cream `#FFFBEB`, never
    /// invented (inventing a chrome hex is what sank the five dead worlds). FIXED,
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
    /// The on-glass OK ink — the profile's OWN green (its ANSI slot 2), not the system status green.
    /// A status mark drawn ON the glass has to answer to the glass: the system palette is tuned for
    /// the OS appearance and lands a saturated signal green beside a set of lightness-normalized
    /// pastels, which is exactly how the command ladder came to wear a colour the terminal under it
    /// never speaks (user-reported 2026-08-09).
    let terminalOk: Color
    /// The on-glass ERROR ink — the profile's own red (ANSI slot 1). Same rationale as ``terminalOk``.
    let terminalErr: Color

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

    /// The AUTHORED chrome ladder (ONE ISLAND, user-directed 2026-08-08): `ground` (everything that
    /// is not the island), `line` (rules), `lift` (plates). The island itself is not a rung: it IS
    /// the glass face.
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

    /// Build the profile from 24-bit RGB values (single source for both the `Color` and hex forms).
    /// The ISLAND tone is not a parameter: it IS `glass.face` (law 1), so the profile cannot
    /// accidentally ship an island in a tone its terminal does not wear.
    private static func profile(
        glass: GlassSet,
        ansi: [UInt32],
        chrome: ChromeLadder,
    ) -> Self {
        Self(
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
            // The status inks are READ OUT of the profile's own ANSI set rather than named a second
            // time, so a profile cannot ship a green for its cells and a different green for the
            // chrome standing on them. Index-guarded (never a trap on a short palette): a profile
            // that shipped no ANSI at all falls back to its ink, which is legible if colourless.
            terminalOk: Color(slateHex: ansi.indices.contains(ansiGreen) ? ansi[ansiGreen] : glass.ink),
            terminalErr: Color(slateHex: ansi.indices.contains(ansiRed) ? ansi[ansiRed] : glass.ink),
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

    /// The ANSI slots the on-glass status inks are read from — the terminal convention (1 = red,
    /// 2 = green), so "failed" and "clean" are drawn in the same two colours the cells below them use.
    private static let ansiRed = 1
    private static let ansiGreen = 2

    /// 6-hex uppercase string (no `#`) for a 24-bit RGB literal — the libghostty config value format.
    /// Manual (no `String(format:)`) to stay allocation-cheap and trap-free.
    private static func hex6(_ v: UInt32) -> String {
        func pair(_ x: UInt32) -> String {
            let s = String(x & 0xFF, radix: 16, uppercase: true)
            return (x & 0xFF) < 0x10 ? "0" + s : s
        }
        return pair(v >> 16) + pair(v >> 8) + pair(v)
    }

    // MARK: - THE profile (user-directed 2026-08-08: exactly ONE)

    //
    // The app wears DRACULA PRO verbatim — the published Pro glass (#22212C face, #F8F8F2 ink,
    // #454158 selection, #7970A9 comment) and the normalized accent seven (S100/L75 in HSL, hue
    // rotated: the Pro method). The CHROME ladder is the published Dracula chrome TRANSPOSED into
    // the glass's band (flat round, user-directed 2026-08-08): the official VS Code Dracula chrome
    // steps its surfaces inside one hue (statusbar #191A21 → sidebar #21222C → editor #282A36 →
    // rail #343746), and each rung here applies that ladder's per-channel offsets to the Pro face
    // instead of the classic one. No frame, no second hue: depth is the only chrome voice.

    /// THE appearance — Dracula Pro glass standing on Alucard's cream.
    /// ANSI note: the Pro seven has no blue — the blue slot carries the purple, per Dracula's own
    /// terminal convention. Brights repeat the bases: the Pro accents are already
    /// lightness-normalized at the top of the band, so a +L derivation only washes them out.
    static let app = profile(
        glass: GlassSet(face: 0x22212C, ink: 0xF8F8F2, ink2: 0x7970A9, edge: 0x454158, accent: 0x9580FF),
        ansi: [
            0x454158, 0xFF9580, 0x8AFF80, 0xFFFF80, 0x9580FF, 0xFF80BF, 0x80FFEA, 0xF8F8F2,
            0x7970A9, 0xFF9580, 0x8AFF80, 0xFFFF80, 0x9580FF, 0xFF80BF, 0x80FFEA, 0xFFFFFF,
        ],
        // The GROUND is Alucard's cream #FFFBEB — a LIGHT frame carrying the dark island, the
        // Canario read (~13:1 apart). Any darker frame is arithmetically stuck: #22212C against
        // pure black is 1.32:1, so the whole dark half of the axis cannot separate at all. Lift is
        // the published rail rung (+0C/+0D/+10 on the face → #2E2E3C); the LINE stays the 10%-ink
        // tint, the pane seam inside the island.
        chrome: ChromeLadder(ground: 0xFFFBEB, line: 0x312F37, lift: 0x2E2E3C),
    )
}

/// Static token namespace. CHROME tokens are semantic system colours (appearance-following, fixed at
/// compile time); GLASS tokens read the one terminal profile.
enum Slate {
    /// THE terminal profile. A constant since the theme picker was retired (user-directed
    /// 2026-08-08) — the runtime store that used to indirect this is gone with it. Kept `@MainActor`
    /// (and a computed property) so no call site of the token layer had to move.
    @MainActor static var theme: SlateTheme { .app }

    /// The colour scheme of the GLASS — forced onto the island subtree (`ContentColumn` / the
    /// satellite roots) so every semantic colour drawn ON the glass (status line, chips, overlays)
    /// resolves DARK, against the terminal, instead of following the app's light chrome pin. This is
    /// the native dark-content-well idiom (a video player's letterbox, a dark artboard) applied to
    /// the terminal, and it is the ONE place in the app that opts out of the light pin.
    @MainActor static var glassColorScheme: ColorScheme { .dark }

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
        /// The status pair ON the glass — the profile's own green / red (``SlateTheme/terminalOk``,
        /// ``SlateTheme/terminalErr``). Anything drawn inside the island that has to say "clean" or
        /// "failed" reads THESE, never ``Slate/Status`` — that set is the system's, tuned for the OS
        /// appearance and out of family beside the glass.
        static var ok: Color { Slate.theme.terminalOk }
        static var err: Color { Slate.theme.terminalErr }
    }

    /// The text tiers — a ladder MEASURED against this app's own ground rather than inherited whole
    /// from the system's.
    ///
    /// Apple's label alphas are tuned for a sidebar drawn on a VIBRANT material, which lends its
    /// labels contrast the flat ground here cannot: this chrome paints one opaque cream (there is no
    /// `NSVisualEffectView` anywhere under the columns), so the tiers landed on the ground at
    /// 14.5 : 3.9 : 1.9 — the second rung under the 4.5 reading floor, the third under even the 3.0
    /// floor for non-text, while carrying real data (the process label, the branch name, a command's
    /// duration, and the host line exactly when it says DISCONNECTED). Legibility, user-reported
    /// 2026-08-08. Measured on white as a control: 3.95 : 1.88, so the cream was never the cause.
    ///
    /// The two weak rungs are re-solved against `#FFFBEB`, and they are the ground's own colour at
    /// that depth rather than a foreign neutral, so the ladder keeps the cream's warmth. `primary`
    /// stays the system semantic — it already measures 14.5 and costs nothing.
    ///
    /// The quiet rung is solved one step deeper than the plain cream needs (5.17 there, where 4.51
    /// would have done), because the sidebar's ground is no longer only the cream: a project island
    /// lays its identity hue under the rows (``Slate/ProjectTint``), and a tinted bed is a DIFFERENT
    /// ground. `#76746D` held 4.51 on the cream but slid to 4.21 under the bed; this rung is solved
    /// so it holds exactly 4.50 on the DEEPEST bed in the register, and the cream simply gets a
    /// darker quiet tier for free. It is therefore pinned to ``Slate/Opacity/bed`` — re-solve it if
    /// that alpha ever moves.
    ///
    /// ⚠️ PINNED ON THE LIGHT SIDE ONLY. Two subtrees flip `colorScheme` to glass (the selected row's
    /// ``SlateCompactIsland``, the pane chrome inside the terminal island); a flat hex draws
    /// dark-on-dark there, which is exactly what the first true-size render of this ladder showed.
    /// The dark side therefore keeps the system tiers untouched.
    @MainActor
    enum Text {
        #if canImport(AppKit)
        static let primary = Color(nsColor: .labelColor)
        static let secondary = Color(slatePinnedLight: 0x585751, darkSystem: .secondaryLabelColor)
        static let tertiary = Color(slatePinnedLight: 0x6C6B64, darkSystem: .tertiaryLabelColor)
        static let icon = secondary
        #else
        static let primary = Color(uiColor: .label)
        static let secondary = Color(slatePinnedLight: 0x585751, darkSystem: .secondaryLabel)
        static let tertiary = Color(slatePinnedLight: 0x6C6B64, darkSystem: .tertiaryLabel)
        static let icon = secondary
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

        /// The INPUT plate's boundary — see ``slateFieldPlate()``. Its own token, and NOT
        /// ``divider``: measured on the cream ground the separator lands at 1.25:1, which is a rule
        /// between two visible things, not an edge that can say where a field starts.
        static let field = Color(
            slateDynamicLight: 0x000000, dark: 0xFFFFFF,
            lightAlpha: Opacity.edge, darkAlpha: Opacity.edge,
        )
    }

    /// The ALPHA ladder — a closed scale for translucency, the one dimension the closed colour
    /// tokens did not govern (round 13): every `.opacity(N)` in chrome code picks a rung here, so
    /// two washes that mean the same thing can never drift apart by a few hundredths again.
    enum Opacity {
        /// A GROUND that has to stay a ground (``ProjectTint/wash(for:)``). Below ``faint``, because
        /// a bed that reads as a FILL stops being a ground: measured across the identity register
        /// the island lands 1.13–1.15× off the cream, which is separation the eye resolves without
        /// the group turning into a coloured panel. The first pass shipped 0.05 (1.06×) and read as
        /// barely there in the running app (user-reported 2026-08-09).
        ///
        /// The tint is not free and the price is paid in ``Slate/Text/tertiary``: a tinted bed is a
        /// different ground, and every step here deepens the rung that has to stay legible on the
        /// worst bed in the register. Raising this without re-solving that rung is how the quiet
        /// tier silently drops under the 4.5 reading floor.
        static let bed = 0.10
        /// The faint accent wash (``State/accentMuted``'s dose).
        static let faint = 0.12
        /// The selection/latch wash (``State/selected``'s dose).
        static let wash = 0.15
        /// An INPUT's boundary (``Line/field``). Its own rung because a field's edge answers to a
        /// different question than a hairline's: a rule separates two things that are both already
        /// visible, while this is the only mark saying where the typing area begins.
        static let edge = 0.28
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
        /// The SUMMONED card's cast shadow — twice ``shadow``, and its own rung because it does twice the
        /// work. A panel that floats over the dark island is separated by tone alone; a paper card is the
        /// ground's own cream lifted off the ground, so nothing but the cast tells the two apart at the
        /// card's edges. Compared side by side at true size, `shadow` read as a halo and this reads as lift.
        static let overlayShadow = Color(slateDynamicLight: 0x000000, dark: 0x000000, lightAlpha: 0.30, darkAlpha: 0.55)
        // NO `cardShadow` rung (user-directed 2026-08-09). The 4% whisper the selected tab chip
        // used to cast existed for a cream plate on a cream ground; the single profile made that
        // chip the island's dark glass, and a fill that far from the ground needs no cast to be
        // seen. Only things that genuinely FLOAT still carry one — see ``Slate/Elevation``.
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

    /// The per-project IDENTITY hue — a launch-stable colour per project, spent as the GROUND its
    /// group stands on and nowhere else (``ProjectTint/wash(for:)``, ``SlateProjectIsland``).
    ///
    /// The earlier reading of this idea — the hue on the folder GLYPH — was rejected as ornament,
    /// and that verdict still holds: the folder in the group header stays monochrome. What was
    /// approved instead (user-directed 2026-08-08) is the island reading: one low-alpha bed under
    /// the whole project, header and rows together, so the colour names the GROUP rather than
    /// decorating a symbol inside it.
    ///
    /// The register is the half of the wheel the STATUS vocabulary does not speak. Red, amber and
    /// green are deliberately absent: a project whose bed was amber would be saying, in the app's
    /// own dialect, that something in it needs attention. Measured as the direction each bed is
    /// displaced from the cream in `a*b*`, the register occupies the arc 195°–340° — teal, blue,
    /// indigo, magenta, rose — and nothing else.
    ///
    /// ⚠️ The map is FNV-1a over the seed's UTF-8, never `hashValue`: Swift's is per-process seeded,
    /// so a `hashValue` register would deal every project a new colour on every launch — the one
    /// thing an identity mark may not do.
    ///
    /// ## Why these five hexes look garish and are not
    ///
    /// The register's entries are BED SOURCES, not inks: they exist only to be composited at
    /// ``Slate/Opacity/bed`` and are never drawn at strength anywhere. That matters because the
    /// cream ground is itself strongly chromatic (L\* 98.5, C\* 8.3 at h 99.5°), so at 10 % a bed
    /// keeps 90 % of the cream and the reachable colours form a tiny cube anchored at the cream's
    /// own corner — each channel can only be pulled DOWN, and by at most 25/255. Inside that cube a
    /// "nice" mid-tone source barely moves the bed at all, which is why the previous register's
    /// nominal five hues collapsed on screen: its worst pair (brown against the neutral bucket)
    /// measured ΔE2000 **2.28**, below the threshold at which two large flat fields read as
    /// different colours at all, and blue-vs-teal only reached 5.01. Solving instead for maximum
    /// minimum separation over that cube — same alpha, same lightness band, same hue arc — lifts the
    /// worst pair to **7.00** and flattens the whole set into the 7.00–7.25 band, so there is no
    /// longer one weak link. Saturated sources are simply where that optimum lives.
    ///
    /// Never spend an entry of this register as an ink, a stroke or a mark. Use ``Slate/Chroma``.
    enum ProjectTint {
        /// The five identity BED SOURCES — teal, blue, indigo, magenta, rose. Read the type note
        /// before touching a hex: these are solved values, not picked ones, and each is meaningful
        /// only after compositing at ``Slate/Opacity/bed`` over the cream ground.
        ///
        /// Solved under four simultaneous constraints: every bed lands in L\* 92.80–94.40 (a
        /// NARROWER spread than the register it replaces, so no project's bed reads as heavier than
        /// another's), every bed's displacement from the cream stays inside the 195°–340° arc (the
        /// status vocabulary keeps red / amber / green), every source stays a real colour (no
        /// channel above 248), and the minimum pairwise ΔE2000 across all six beds — the five here
        /// plus ``neutralSource`` — is maximised.
        @MainActor
        static let register: [Color] = [
            Color(slateHex: 0x00A68F), Color(slateHex: 0x0075F7), Color(slateHex: 0x514AF8),
            Color(slateHex: 0xF414F7), Color(slateHex: 0xF854A4),
        ]

        /// The keyless "Other" bucket's bed source. It is ``Slate/Text/secondary``'s light pin
        /// rather than a sixth identity, because the bucket has no identity to spend — but it IS
        /// part of the separation solve above (it measures ΔE2000 7.21 from its nearest neighbour),
        /// since on screen it is just another bed the eye has to tell from the ones around it.
        static let neutralSource = 0x585751

        /// The SEED a project key is dealt from: the key's last path component, case-folded and
        /// NFC-normalised.
        ///
        /// The key itself is an absolute path (a git worktree toplevel, else the pane's cwd), and
        /// hashing it whole made the colour a property of WHERE a project sits rather than of the
        /// project — the same checkout on the other machine, or moved one directory up, was dealt a
        /// different identity. The basename is the part that travels.
        ///
        /// Case folding is not cosmetic: on a case-insensitive volume `~/Work/App` and `~/work/app`
        /// name the same directory, and the host pushes whichever spelling the shell happened to
        /// use. NFC likewise — an accented basename reaches us decomposed from one filesystem and
        /// composed from another, and unnormalised those are different bytes and so different
        /// colours for one project.
        static func seed(for key: String) -> String {
            var path = Substring(key)
            while path.hasSuffix("/") { path = path.dropLast() }
            let base = path.split(separator: "/").last.map(String.init) ?? String(path)
            return base.lowercased().precomposedStringWithCanonicalMapping
        }

        /// FNV-1a-64 over UTF-8. Wrapping multiply is the algorithm, not an overflow.
        static func hash(_ text: String) -> UInt64 {
            var value: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value = value &* 0x100_0000_01B3
            }
            return value
        }

        /// FNV-1a-64 over a key's ``seed(for:)``, reduced mod the register size.
        static func index(of key: String, count: Int) -> Int {
            Int(hash(seed(for: key)) % UInt64(count))
        }

        /// The identity indices for ONE ordered run of islands — the answer to "which bed does each
        /// group in this column stand on", resolved for the run as a whole rather than per group.
        ///
        /// A pure hash cannot satisfy both things a project bed has to do. Dealt independently, two
        /// projects that happen to hash alike land side by side wearing one colour, and the bed
        /// stops saying where one group ends — with five entries that is a 1-in-5 coin flip on every
        /// adjacent pair, so in a column of six projects it is likelier to happen than not. So the
        /// hash proposes and the RUN disposes: a group whose preferred index matches the island
        /// directly above it re-probes once, at a stride also taken from its own hash. The register
        /// count is prime and the stride lands in 1…4, so the probe can never return where it
        /// started and one probe always suffices — there is only ever one index to avoid.
        ///
        /// What this trades away, honestly: a project's colour is no longer a function of its name
        /// ALONE but of its name and what sits above it, so inserting a project can re-deal the one
        /// below it (and, rarely, cascade one further). That is not a defect of the repair, it is
        /// the tension in the requirement — "always the same colour" and "never the same colour as
        /// your neighbour" cannot both hold unconditionally — and it is spent in the direction that
        /// keeps the column readable. The common case is untouched: with no collision, every group
        /// keeps exactly the colour its own basename hashes to.
        struct Deal {
            /// Per-island register index in the run's order; `nil` is the keyless bucket.
            let indices: [Int?]

            /// Deal `keys` in render order. A `nil` key takes the neutral bed and constrains
            /// nothing after it — the neutral is ΔE2000 ≥ 7.21 from every register entry, so a
            /// keyed group below the "Other" bucket can never be mistaken for it.
            init(keys: [String?]) {
                let count = Slate.ProjectTint.registerCount
                var dealt: [Int?] = []
                dealt.reserveCapacity(keys.count)
                var previous: Int?
                for key in keys {
                    guard let key else {
                        dealt.append(nil)
                        previous = nil
                        continue
                    }
                    let hash = Slate.ProjectTint.hash(Slate.ProjectTint.seed(for: key))
                    var index = Int(hash % UInt64(count))
                    if index == previous {
                        // A second, INDEPENDENT digit of the same hash picks the stride, so the
                        // re-deal stays a pure function of (this key, the index above it) and two
                        // colliding projects do not both walk to the same replacement.
                        let stride = 1 + Int((hash / UInt64(count)) % UInt64(count - 1))
                        index = (index + stride) % count
                    }
                    dealt.append(index)
                    previous = index
                }
                indices = dealt
            }

            /// The BED for the island at `position` — its dealt hue at ``Slate/Opacity/bed``, or the
            /// neutral bed for the keyless bucket. Out of range yields the neutral bed rather than
            /// trapping: a bed is decoration, and a view that has out-run its deal must still draw.
            @MainActor
            subscript(position: Int) -> Color {
                guard indices.indices.contains(position), let index = indices[position] else {
                    return Slate.ProjectTint.neutralBed
                }
                return Slate.ProjectTint.register[index].opacity(Opacity.bed)
            }
        }

        /// The keyless bucket's bed — ``neutralSource`` at ``Slate/Opacity/bed``.
        @MainActor
        static var neutralBed: Color { Color(slateHex: UInt32(neutralSource)).opacity(Opacity.bed) }

        /// The register size, readable without `@MainActor` (``Deal`` runs the arithmetic off the
        /// colour values). Pinned by `SlateProjectTintTests` to match ``register``'s own count.
        static let registerCount = 5
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
        ///
        /// BACK DOWN to the grid's inset step (user-directed 2026-08-09: the moat read too wide on
        /// the left and right). It was raised to 12 on 2026-08-08 on the reasoning that 8 reads as
        /// padding rather than clearance — true against a bare edge, and wrong against the two
        /// columns the island actually stands between: the navigator's list and the panel's strip
        /// each hold their own content off their edges by 8, so a 12pt moat put 20pt of ground
        /// between a tab card and the glass while the bottom edge — which meets the window frame with
        /// nothing in between — got 12. Eight is what makes the four gaps read alike.
        ///
        /// It is the OUTER margin only — nothing inside the island moves, so the panes keep their own
        /// spacing.
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
        /// titlebar stand on, beside the island. The height ladder's chrome-strip rung
        /// (``heightStrip`` / ``titlebarHeight``); the band is not a new measurement.
        static let bandHeight: CGFloat = heightStrip
        /// THE ISLAND'S TOP LINE — ``islandInset`` and nothing else, because the island keeps one
        /// moat on all four sides (user-directed 2026-08-09).
        ///
        /// Now that the moat is 8 this is also ``bandControlInset``, and that coincidence is the
        /// whole point of the second alignment pass (user-directed 2026-08-09): the island's top edge
        /// and the top edge of every plate standing in the band are ONE line. At 12 it was a line
        /// that agreed with nothing — 4pt under the plates' tops, 20 above their bottoms — which is
        /// what read as "hơi lệch" across the top of the window.
        static let bandInset: CGFloat = islandInset
        /// Where a CONTROL in the band hangs from. Not the island's line: a control is 24 and a
        /// traffic light is 16, so hanging both from one line leaves the discs riding 4pt high
        /// against every plate beside them (user-reported 2026-08-09). This inset is the one that
        /// puts a plate's CENTRE on the lights' centre — measured at 20 on the running app, with the
        /// titlebar height declared (`SlopDeskClientApp.lowerTrafficLightsToTheTopLine`) — so the
        /// band reads as one row of centres and the island's edge runs just under the lights' own.
        static let bandControlInset: CGFloat = space2

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

        // The COMMAND LADDER (`CommandLadderOverlay`) — the per-command tick rail on a terminal
        // pane's trailing edge.

        /// The ladder's RAIL — its full width, hit area included. It is the pane's own inner gutter
        /// (`space2`, the breathing room `TerminalLeafView` already holds the terminal surface off
        /// its edges) and not one point more, which is the whole rule: the ladder stands in ground
        /// the pane had already cleared, so it can neither draw over a cell nor swallow a click meant
        /// for one. Its first pass was a `plate`-wide column INSIDE the surface and did both
        /// (user-reported 2026-08-09).
        static let ladderRail: CGFloat = space2
        /// One tick's length at rest — half the rail, centred, so the mark reads as a rung on an edge
        /// rather than as something poking out of the text.
        static let ladderTick: CGFloat = 4
        /// A tick's length under the pointer. Still inside the rail with a point to spare on each
        /// side: the growth is symmetric about the rail's centre line, so hovering can never push the
        /// mark back over the terminal — the earlier trailing-anchored 6 → 12 growth did.
        static let ladderTickActive: CGFloat = 6
        /// A tick's thickness — two points, the smallest mark that still reads as a deliberate rung
        /// at the pitch the ladder runs.
        static let ladderTickWeight: CGFloat = 2
        /// How far the ladder holds off the pane's top and bottom. Sized to clear the ISLAND'S OWN
        /// CORNER: at `ladderRail` in from the glass edge the `islandRadius` curve cuts about 7pt up
        /// from the bottom, so a shorter inset would let the last tick slide under the rounded corner.
        static let ladderInset: CGFloat = space4
        /// The hover PEEK card's width — the excerpt of a block's output the ladder shows while the
        /// pointer dwells on a tick. Wide enough for a build log's ordinary line, narrow enough that
        /// it covers a strip of the pane rather than the pane.
        static let ladderPeekWidth: CGFloat = 320
        /// One excerpt line's row height in the peek card — the ``Typeface/footnote`` mono face's
        /// line box, declared rather than inferred so the card's height is COMPUTABLE and its
        /// placement beside a tick can be solved (and unit-pinned) before it is drawn.
        static let ladderPeekLine: CGFloat = 14
        /// The gap between the rail and the peek card's trailing edge — the card hangs off the rail,
        /// it does not touch it.
        static let ladderPeekGap: CGFloat = space2

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
        /// `heightRow`.
        static let heightRowTall: CGFloat = 44
        /// The TWO-REGISTER row: an identity with its place set under it (the ⌃⇥ switcher). Two type
        /// sizes stacked (13 over 11) come to ~29pt of ink, so this rung is that plus a breath either
        /// side — one step above `heightRowTall`, which is the same row with only one thing to say.
        static let heightRowStacked: CGFloat = 48
        /// The sidebar TAB row — the standard single-line row rung (`heightRow`), so the tab list
        /// keeps the ladder's beat: denser than a lounge list, taller than a menu row.
        static let heightTabRow: CGFloat = heightRow
        /// The chrome rail OUTSIDE the project islands — the connection footer's content inset and
        /// the empty-list label's. `space3`, one step wider than the rail inside an island, because
        /// nothing out here has an island edge to stand off from.
        static let tabRowInset: CGFloat = space3
        /// How far a project island holds its content off its OWN edge — the selected row's dark
        /// chip must float inside the bed rather than butt against it. A grid step (`space2`), and
        /// chosen at true size against 6 and 10 (user-directed 2026-08-08).
        static let projectIslandInset: CGFloat = space2
        /// The text rail INSIDE a project island — header name, git line and every row title stand
        /// here. `projectIslandInset + islandRail` is held at 18 so the runs keep the rail the
        /// sidebar had before the islands arrived, minus nothing: what the island spends on its own
        /// breathing room, the rail gives back.
        static let islandRail: CGFloat = 10
        /// The sidebar project-group header row (gutter chevron + name). 24pt + the list's 2pt row
        /// spacing on both sides = the 28pt inter-group band; the air IS the separator.
        static let heightSectionHeader: CGFloat = 24
        /// Chrome strips: the titlebar / traffic-light band. NOT a free number — one control
        /// (``heightControl``) with ``bandControlInset`` above and a matching grid step below, so the
        /// row sits centred on the traffic lights' own centre. Every column's SECOND row starts
        /// here: the navigator's search field, the panel's surfaces, and — only while the navigator
        /// is hidden, when the band runs over the content column — the island's top edge
        /// (``slateIsland(clearingBand:)``).
        ///
        /// The island's FIRST row does not: it starts at ``bandInset``, inside the band
        /// (user-directed 2026-08-09). A band the island merely hung below — tried at both 40 and 32
        /// — read as the middle column starting one row lower than the two beside it.
        static let heightStrip: CGFloat = bandControlInset + heightControl + space2
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
        /// Where chrome may start on the traffic-light row: clear of the three system window
        /// controls. MEASURED on the running app with the titlebar declared at toolbar height
        /// (`SlopDeskClientApp.growTitlebarToBandHeight`) — three discs from a 12pt leading inset on
        /// a 23pt pitch, so the cluster's trailing edge lands at 71 — plus air.
        /// ``WindowSidebarToggle`` is the one thing mounted here, and the titlebar's own strip
        /// starts a plate further right so the two never contend for the slot.
        /// ⚠️ This is AppKit's placement, not ours. Do not reintroduce a manual inset constant —
        /// positioning the buttons by frame is what made them flicker on every window re-title.
        static let windowControlsLead: CGFloat = 80
        static let sidebarWidth: CGFloat = 220
        /// The MINIMIZED sidebar — the rail (user-directed 2026-08-07, rail round): collapsing the
        /// tabs panel narrows it to this instead of removing it, so the window controls keep a
        /// column under them and the projects stay one glance away. Wide enough that the system
        /// traffic lights (which end ~74pt in) sit inside it with air to spare.
        static let railWidth: CGFloat = 80
        /// One rail project chip — the roomy-row rung, a square the folder mark centres in.
        static let railChip: CGFloat = heightRowTall
        /// The RIGHT PANEL'S RAIL — what the panel leaves behind instead of vanishing (user-directed
        /// 2026-08-09). One control plate with the grid's inset either side, which puts the rail's
        /// toggle at exactly the x the panel's own hide toggle stands at, so the one control the
        /// user aims at never moves between the two states. Everything below it — the surface tabs,
        /// turned on their side — is that same plate width.
        static let panelRailWidth: CGFloat = plate + 2 * space2
        /// A rail tab's LONG side, the one that runs down the rail. Every tab takes the same length
        /// (the widest name plus its mark and the plate's own padding), because a rail of tabs each
        /// as long as its own word reads as a ragged list rather than as a strip of tabs.
        static let panelRailTabLength: CGFloat = 104
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
    /// floats, ``State/overlayShadow`` for a summoned card) via ``SwiftUICore/View/slateShadow(_:color:)``.
    ///
    /// Every rung here belongs to something that genuinely LEAVES its surface. The old `card` rung
    /// — a 2/1 whisper for a plate resting IN a surface — is gone with the selection chip's shadow
    /// (user-directed 2026-08-09): at-rest depth is the fill ladder's job, and a cast under a
    /// stationary plate is the flourish a flat vocabulary reads as dated.
    enum Elevation {
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
            case .chip: 4
            case .ghost: 8
            case .panel: 12
            case .palette: 30
            }
        }

        var y: CGFloat {
            switch self {
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
        /// How fast THE acknowledgement plays (`View.slateGlyphAck`) — a symbol bounce runs long by
        /// default and a click has to feel answered, not performed. Lives here rather than at the one
        /// call site because the effect is the app's, not any one button's.
        static let ackSpeed: Double = 1.4
        /// Divider / plate hover — EaseInEaseOut 0.16s.
        static let dividerHover = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.16)
        /// MERIDIAN L4 "needle" — the mechanical settle used for the ONE orchestrated moment (the connect
        /// handshake's colour-in). Fast attack, long decel, no overshoot (no springs anywhere).
        static let needle = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.24)
        /// The EMPHASIZED curve — a fast, decisive attack with a long settle, for the moves big
        /// enough that the eye tracks the object rather than just noticing the result. Named once
        /// here because two very different actuators spend it: SwiftUI (`stackReflow`, `columnSlide`)
        /// and AppKit (`NSSplitViewItem.animator()`, which cannot take a SwiftUI `Animation` and so
        /// needs the raw control points).
        static let emphasizedControlPoints: (x1: Float, y1: Float, x2: Float, y2: Float)
            = (0.4, 0, 0.2, 1)
        /// A whole COLUMN reflowing (toast spine expand/collapse shifts every sibling card, not just the
        /// hovered one) — a shade longer than `standard`, gentle symmetric ease so the reverse (mouse-out)
        /// reads as calm as the forward. EaseInEaseOut 0.28s.
        static let stackReflow = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.28)
        /// The SELECTION PLATE travelling between two chips (`SlateCompactIsland`'s morph). Longer
        /// than `standard` and on the emphasized curve on purpose: `standard` is sized for a state
        /// that CHANGES IN PLACE, and spent on a plate crossing the whole panel it read as a skip
        /// rather than a move (measured: the plate cleared 128pt in ~120ms). This is still well
        /// under the column slide — the plate is the smaller object and must not feel heavier.
        static let selectionMorph = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)
        /// A SPLIT COLUMN opening or closing — the sidebar and the code panel (user-directed
        /// 2026-08-09). The longest move in the app: an entire column's width travels, so it takes
        /// the emphasized curve and a beat more than `stackReflow` to keep the terminal's re-wrap
        /// from reading as a snap. Anything that has to LAND with the column (the titlebar strip
        /// arriving as the sidebar leaves) delays by this much.
        static let columnSlideDuration: Double = 0.32
        static let columnSlide = Animation.timingCurve(0.4, 0, 0.2, 1, duration: columnSlideDuration)
        /// The ONE repeating shape in the vocabulary — a slow symmetric breathe for a preview that
        /// demonstrates blinking (the cursor preview). EaseInEaseOut 0.55s, autoreversing forever;
        /// never used on live chrome (the at-rest-motion purge stands).
        static let pulse = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.55)
            .repeatForever(autoreverses: true)
    }
}

extension View {
    /// Cast the shadow of a named ``Slate/Elevation`` rung. The colour defaults to the floating
    /// object's soft black (``Slate/State/shadow``); a summoned card passes the heavier
    /// ``Slate/State/overlayShadow``. Radius/y never appear at a call site — the rung is the API.
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

    /// A LIGHT-PINNED ink: an exact colour on the one light ground this app owns, and the SYSTEM
    /// semantic anywhere the appearance resolves dark. The asymmetry is the point — the light ground
    /// is a fixed cream this design measured its ladder against, while the dark side is whatever
    /// surface the glass subtrees happen to be, which only the system tiers can track. See
    /// ``Slate/Text`` for why the light rungs left the system ladder in the first place.
    #if canImport(AppKit)
    init(slatePinnedLight light: UInt32, darkSystem: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? darkSystem
                : NSColor(slateHex: light)
        })
    }
    #elseif canImport(UIKit)
    init(slatePinnedLight light: UInt32, darkSystem: UIColor) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkSystem : UIColor(slateHex: light)
        })
    }
    #endif
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
