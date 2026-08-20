// SlateDesign — the minimalist design-token layer, and the floor of `SlopDeskSlate`.
//
// A THIN, headless token layer — `SlateNativeColor`/`Color`/`CGFloat`/`Animation` constants and
// nothing that draws. It compiled into `SlopDeskClientUI` for as long as there was ONE UI target to
// compile it into; it is its own target since docs/56 increment 28, because there are two now and the
// AppKit half reads ~200 of these. `check-supervisor.sh` fails the build if a `some View` lands here:
// a token is a value both frameworks read, and every mark with two renderers keeps them one floor up.
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
import QuartzCore // CAMediaTimingFunction — ``SlateCurve``'s CoreAnimation rung, on BOTH platforms
import SlopDeskClientCore // AgentInk — the status vocabulary this ladder resolves for both platforms
import SwiftUI
#if canImport(AppKit)
import AppKit

/// The platform's own colour type — what a token IS before a view framework looks at it.
///
/// Every colour in this file was already built out of one of these (a semantic system colour, a
/// dynamic light/dark pair, or a hex): SwiftUI's `Color` has never been the value, only a wrapper
/// around it. Naming the wrapped type lets the AppKit half of the client (docs/56 stage D — an
/// `NSView` cannot fill with a `Color`) read the SAME constant the SwiftUI half derives from,
/// instead of a second palette that drifts.
package typealias SlateNativeColor = NSColor
/// The platform's own font type — see ``SlateNativeColor`` for why the token layer names it.
package typealias SlateNativeFont = NSFont
#elseif canImport(UIKit)
import UIKit

/// See the AppKit branch — `UIColor` is the same thing on the phone.
package typealias SlateNativeColor = UIColor
/// See the AppKit branch.
package typealias SlateNativeFont = UIFont
#endif

/// A TERMINAL PROFILE — the fixed palette of the terminal glass (the one deliberate-colour surface in
/// an otherwise system-semantic app). Owns everything drawn ON the glass: the cell colours libghostty
/// paints, the ANSI set, and the ink/edge/accent the SwiftUI chrome floating inside the island uses
/// (status line, chips, focus corner) — ON-GLASS text must read against the profile, not against the
/// OS appearance, because the glass does not follow the OS appearance.
package struct SlateTheme: Equatable, Sendable {
    /// THE PROFILE, as the five hexes it publishes. Every glass colour below is COMPUTED from this
    /// (and the two derivations beside it), because a profile has to reach two frameworks: SwiftUI
    /// draws with `Color`, the AppKit surfaces draw with ``SlateNativeColor``, and a stored pair
    /// would be the same tone spelled twice — see ``Slate/Native``.
    package let glass: GlassSet

    // The glass surfaces
    /// The terminal cell surface — the island's ground.
    package var terminal: Color { Color(slateHex: glass.face) }
    /// The divider / seam line ON the glass (the profile's selection tone: one step off the face).
    package var terminalEdge: Color { Color(slateHex: glass.edge) }
    /// A lifted plate ON the glass (chips, handles) — the selection fill.
    package var terminalRaised: Color { Color(slateHex: glass.edge) }
    /// The RIM around a lifted plate ON the glass — one step BRIGHTER than the plate, never equal to
    /// it. Its own token because ``terminalEdge`` is a SEAM (a line drawn between two things that
    /// already differ — the pane divider, the island's own edge) and a rim is the only mark saying
    /// where a floating chip ENDS. The two shared a value until 2026-08-10, which made every chip's
    /// border literally invisible: `edge` and `raised` are both the profile's selection tone, so the
    /// copy receipt and every `NoticeChip` drew a `#454158` hairline on a `#454158` plate and read as
    /// a text run floating unbounded over the terminal (user-reported). A rim on a DARK plate has to
    /// be LIGHTER than it — the inverse of the light side's rule (``Slate/Line/overlayRim``), which is
    /// darker than its cream — so this is derived by lifting the plate toward the profile's own
    /// comment ink rather than by inventing a hex.
    package var terminalRim: Color { Color(slateHex: terminalRimHex) }
    /// ``terminalRim``'s value: the plate lifted HALFWAY to the profile's comment ink.
    package var terminalRimHex: UInt32 { Self.mix(glass.edge, glass.ink2) }

    /// THE GROUND — everything that is not the one island (law 1): the navigator, the code panel,
    /// the top band and the moat around the terminal. Alucard's published cream `#FFFBEB`, never
    /// invented (inventing a chrome hex is what sank the five dead worlds). FIXED,
    /// never appearance-resolved (the CGColor-snapshot trap family stays dead). Raw hex because the
    /// AppKit split shell resolves it as an `NSColor`.
    package let groundHexValue: UInt32
    /// The ISLAND tone — the terminal canvas, the ONE lifted surface. EQUAL to the glass face by
    /// construction, so a profile cannot ship an island in a tone its terminal does not wear. Raw
    /// hex for the AppKit side.
    package var chromeHexValue: UInt32 { glass.face }
    /// ``groundHexValue`` as the SwiftUI colour the band, the side panels and the moat read.
    package var ground: Color { Color(slateHex: groundHexValue) }
    /// ``chromeHexValue`` as the SwiftUI colour the island reads.
    package var chrome: Color { Color(slateHex: chromeHexValue) }

    // The on-glass ink
    /// Primary on-glass ink — the profile foreground.
    package var terminalInk: Color { Color(slateHex: glass.ink) }
    /// Secondary on-glass ink (status line, captions on the glass).
    package var terminalInk2: Color { Color(slateHex: glass.ink2) }
    /// The on-glass ACCENT (focus corner, divider drag line, drop washes) — profile-tuned because the
    /// window accent is appearance-tuned and the glass ignores the appearance.
    package var terminalAccent: Color { Color(slateHex: glass.accent) }
    /// The on-glass OK ink — the profile's OWN green (its ANSI slot 2), not the system status green.
    /// A status mark drawn ON the glass has to answer to the glass: the system palette is tuned for
    /// the OS appearance and lands a saturated signal green beside a set of lightness-normalized
    /// pastels, which is exactly how the command ladder came to wear a colour the terminal under it
    /// never speaks (user-reported 2026-08-09).
    package var terminalOk: Color { Color(slateHex: terminalOkHex) }
    /// The on-glass ERROR ink — the profile's own red (ANSI slot 1). Same rationale as ``terminalOk``.
    package var terminalErr: Color { Color(slateHex: terminalErrHex) }

    /// The status inks are READ OUT of the profile's own ANSI set rather than named a second time,
    /// so a profile cannot ship a green for its cells and a different green for the chrome standing
    /// on them. Index-guarded (never a trap on a short palette): a profile that shipped no ANSI at
    /// all falls back to its ink, which is legible if colourless.
    package var terminalOkHex: UInt32 { ansi.indices.contains(Self.ansiGreen) ? ansi[Self.ansiGreen] : glass.ink }
    /// See ``terminalOkHex`` — the red slot.
    package var terminalErrHex: UInt32 { ansi.indices.contains(Self.ansiRed) ? ansi[Self.ansiRed] : glass.ink }

    /// The 16 ANSI colours as the profile publishes them (24-bit RGB); ``ansiPalette`` is the same
    /// set in libghostty's 6-hex config form.
    package let ansi: [UInt32]

    // The libghostty config values (6-hex, no `#`) — applied via ``TerminalConfigBuilder``.
    package let terminalBackgroundHex: String
    package let terminalForegroundHex: String
    /// The 16 ANSI terminal colours (indices 0–15). Reaches the cells via `palette = N=<hex>`.
    package let ansiPalette: [String]
    /// Selection highlight background, opaque RGB; paired with `selection-foreground =
    /// cell-foreground` so glyph colours stay under the fill (not an invert). `nil` ⇒ no line.
    package let selectionBackgroundHex: String?
    /// Cursor block colour; `nil` ⇒ follow the foreground.
    package let cursorHex: String?
    /// Glyph-under-cursor colour; `nil` ⇒ follow the background.
    package let cursorTextHex: String?

    /// The published GLASS palette a profile ships — the terminal's own five (face/ink/comment/
    /// selection-edge/accent), verbatim from the theme's spec.
    package struct GlassSet: Equatable, Sendable {
        package let face: UInt32
        package let ink: UInt32
        package let ink2: UInt32
        package let edge: UInt32
        package let accent: UInt32
    }

    /// Build the profile from 24-bit RGB values (single source for both the `Color` and hex forms).
    /// The ISLAND tone is not a parameter: it IS `glass.face` (law 1), so the profile cannot
    /// accidentally ship an island in a tone its terminal does not wear.
    private static func profile(
        glass: GlassSet,
        ansi: [UInt32],
        ground: UInt32,
    ) -> Self {
        Self(
            glass: glass,
            groundHexValue: ground,
            ansi: ansi,
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

    /// The per-channel MIDPOINT of two 24-bit RGB literals — integer arithmetic, so the derived
    /// tone is exact and reproducible (no float rounding to argue about). The one derivation the
    /// profile does: ``terminalRim`` is the plate lifted halfway toward the on-glass comment ink.
    package static func mix(_ a: UInt32, _ b: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            (((a >> shift) & 0xFF) + ((b >> shift) & 0xFF)) / 2
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
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
    package static let app = profile(
        glass: GlassSet(face: 0x22212C, ink: 0xF8F8F2, ink2: 0x7970A9, edge: 0x454158, accent: 0x9580FF),
        ansi: [
            0x454158, 0xFF9580, 0x8AFF80, 0xFFFF80, 0x9580FF, 0xFF80BF, 0x80FFEA, 0xF8F8F2,
            0x7970A9, 0xFF9580, 0x8AFF80, 0xFFFF80, 0x9580FF, 0xFF80BF, 0x80FFEA, 0xFFFFFF,
        ],
        // The GROUND is Alucard's cream #FFFBEB — a LIGHT frame carrying the dark island, the
        // Canario read (~13:1 apart). Any darker frame is arithmetically stuck: #22212C against
        // pure black is 1.32:1, so the whole dark half of the axis cannot separate at all. It is the
        // ONE authored chrome tone: the island is not a second one, it IS the glass face (law 1).
        ground: 0xFFFBEB,
    )
}

/// Static token namespace. CHROME tokens are semantic system colours (appearance-following, fixed at
/// compile time); GLASS tokens read the one terminal profile.
package enum Slate {
    /// THE terminal profile. A constant since the theme picker was retired (user-directed
    /// 2026-08-08) — the runtime store that used to indirect this is gone with it. Kept `@MainActor`
    /// (and a computed property) so no call site of the token layer had to move.
    @MainActor package static var theme: SlateTheme { .app }

    /// The colour scheme of the GLASS — forced onto the island subtree (`ContentColumn` / the
    /// satellite roots) so every semantic colour drawn ON the glass (status line, chips, overlays)
    /// resolves DARK, against the terminal, instead of following the app's light chrome pin. This is
    /// the native dark-content-well idiom (a video player's letterbox, a dark artboard) applied to
    /// the terminal, and it is the ONE place in the app that opts out of the light pin.
    @MainActor package static var glassColorScheme: ColorScheme { .dark }

    /// The colour scheme of the CHROME — the app's one polarity, and the ONE place it is decided.
    /// ``SlateAppearancePin`` derives each platform's spelling of it from this rung (`NSApp.appearance`
    /// on the Mac, the window scene's `traitOverrides` on the phone), and it is named here so a subtree
    /// that has to climb BACK out of the glass can say so in tokens rather than in a bare `.light`.
    ///
    /// There is exactly one such subtree: ``SlatePaperCapsule``, the transient notice. It is cream —
    /// ``Surface/field``, a FIXED tone that does not follow any appearance — but it is mounted on the pane
    /// canvas, INSIDE the island subtree that ``glassColorScheme`` has forced dark. Its ink comes from
    /// ``SlateOverlayInk``, which derives from `Color.primary`/`.secondary`, so without this it resolved
    /// for the dark well and drew WHITE ON CREAM: a capsule with the right surface and no readable text
    /// (caught in the `testRenderIslandChips` snapshot, 2026-08-11, before it ever shipped).
    ///
    /// This is the same move the SELECTED TAB already makes in the other direction — a compact island on
    /// the cream ground flips its row to the glass polarity "so every ink on it resolves against the plate
    /// it stands on" (`DESIGN.md`). One rule, both directions: the scheme follows the PLATE, not the
    /// ancestor. It is not a new appearance (the app still has exactly two polarities and one `NSApp`
    /// pin) — it is the pin, restored for an object that stepped out of the glass.
    @MainActor package static var chromeColorScheme: ColorScheme { .light }

    /// The FIXED brand accent (Dracula purple) as an appearance-dynamic pair: Alucard's `#644AC9`
    /// on light appearances, the Pro `#9580FF` on dark. The ONLY chrome colour that is not the
    /// system's — user-directed 2026-08-07 (fixed brand accent over the user-configurable system
    /// accent; purple replaced the Ember teal in the round-8 Dracula verdict).
    @MainActor private static let accentPurple = Color(slateNative: Native.accent)
    /// The accent's fill/badge band (filled pills, progress fills — white text sits on it).

    /// THE TOKEN VALUES, in the platform's own colour type.
    ///
    /// Every colour rung below — ``Surface``, ``Text``, ``Line``, ``State``, ``Status``,
    /// ``StatusInk``, ``Terminal`` — is `Color(slateNative:)` over a constant declared HERE, so a
    /// token is one value with two views of it and never two spellings that can drift apart. The
    /// AppKit half of the client (docs/56 stage D) reads these directly: an `NSView` fills with an
    /// `NSColor`, and re-deriving the ladder in AppKit terms is exactly the duplicate implementation
    /// `CLAUDE.md` forbids.
    ///
    /// Two rungs are deliberately absent because they are not colours the platform has an opinion
    /// about: `Text/onAccent` and `Text/onWarn` are pinned white and black (``SlateNativeColor/white``
    /// / `.black` reach them without a token), and ``ProjectTint``'s register is a list of bed
    /// SOURCES that only ever composites through ``ProjectTint/wash(for:)``.
    @MainActor
    package enum Native {
        /// The brand accent — see ``Slate/accentPurple``. The two hexes are spelled ONCE, here.
        package static let accent = SlateNativeColor.slateDynamic(light: 0x644AC9, dark: 0x9580FF)

        /// The chrome surface ladder — see ``Slate/Surface`` for what each rung means and for the
        /// ⚠️ about `ground` not being the app's ground.
        @MainActor
        package enum Surface {
            #if canImport(AppKit)
            package static let void = SlateNativeColor.underPageBackgroundColor
            package static let ground = SlateNativeColor.underPageBackgroundColor
            package static let face = SlateNativeColor.windowBackgroundColor
            package static let raised = SlateNativeColor.quaternarySystemFill
            package static let lift = SlateNativeColor.tertiarySystemFill
            package static let chip = SlateNativeColor.controlBackgroundColor
            #else
            package static let void = SlateNativeColor.secondarySystemBackground
            package static let ground = SlateNativeColor.secondarySystemBackground
            package static let face = SlateNativeColor.systemBackground
            package static let raised = SlateNativeColor.quaternarySystemFill
            package static let lift = SlateNativeColor.tertiarySystemFill
            package static let chip = SlateNativeColor.secondarySystemGroupedBackground
            #endif
            /// THE GROUND — the profile's own cream, the one authored chrome tone.
            package static var field: SlateNativeColor { SlateNativeColor(slateHex: Slate.theme.groundHexValue) }
            package static var terminal: SlateNativeColor { Terminal.face }
            package static var island: SlateNativeColor { SlateNativeColor(slateHex: Slate.theme.chromeHexValue) }
        }

        /// The ON-GLASS vocabulary, straight off the one terminal profile — see ``Slate/Terminal``.
        @MainActor
        package enum Terminal {
            package static var face: SlateNativeColor { color(Slate.theme.glass.face) }
            package static var ink: SlateNativeColor { color(Slate.theme.glass.ink) }
            package static var ink2: SlateNativeColor { color(Slate.theme.glass.ink2) }
            package static var edge: SlateNativeColor { color(Slate.theme.glass.edge) }
            package static var raised: SlateNativeColor { edge }
            package static var rim: SlateNativeColor { color(Slate.theme.terminalRimHex) }
            package static var accent: SlateNativeColor { color(Slate.theme.glass.accent) }
            package static var ok: SlateNativeColor { color(Slate.theme.terminalOkHex) }
            package static var err: SlateNativeColor { color(Slate.theme.terminalErrHex) }

            private static func color(_ hex: UInt32) -> SlateNativeColor { SlateNativeColor(slateHex: hex) }
        }

        /// The text ladder — see ``Slate/Text`` for why the two weak rungs left the system's.
        @MainActor
        package enum Text {
            #if canImport(AppKit)
            package static let primary = SlateNativeColor.labelColor
            package static let secondary = SlateNativeColor.slatePinnedLight(
                0x585751, darkSystem: .secondaryLabelColor,
            )
            #else
            package static let primary = SlateNativeColor.label
            package static let secondary = SlateNativeColor.slatePinnedLight(
                0x585751, darkSystem: .secondaryLabel,
            )
            #endif
            package static let tertiary = SlateNativeColor.slateDynamic(light: 0x6C6B64, dark: 0x89888B)
            package static let icon = secondary
        }

        /// The rules and edges — see ``Slate/Line``.
        @MainActor
        package enum Line {
            #if canImport(AppKit)
            package static let divider = SlateNativeColor.separatorColor
            package static let active = SlateNativeColor.tertiaryLabelColor
            #else
            package static let divider = SlateNativeColor.separator
            package static let active = SlateNativeColor.tertiaryLabel
            #endif
            package static let card = divider
            package static let subtle = divider.slateScalingAlpha(Opacity.muted)
            package static let field = SlateNativeColor.slateDynamic(
                light: 0x000000, dark: 0xFFFFFF, lightAlpha: Opacity.edge, darkAlpha: Opacity.edge,
            )
            package static let overlayRim = SlateNativeColor.slateDynamic(
                light: 0x000000, dark: 0xFFFFFF, lightAlpha: Opacity.rim, darkAlpha: Opacity.rim,
            )
        }

        /// The FLOATING FAMILY's ink — see ``SlateOverlayInk`` for why a summoned card wears the
        /// system's neutral semantics rather than the terminal's tinted greys.
        ///
        /// Its four derived rungs are alphas over the platform LABEL colour, so they resolve against
        /// whichever polarity the card stands in without a call site changing. They live here, in
        /// the native layer, for the reason the whole ``Native`` block exists: the Mac's cheat sheet
        /// is an `NSView` (docs/56 stage D) and the phone's is a `View`, and the ladder they read
        /// has to be ONE value with two views of it.
        @MainActor
        package enum Overlay {
            /// The thing being read.
            package static var primary: SlateNativeColor { Text.primary }
            /// A supporting label. The SYSTEM's secondary, not ``Text/secondary`` — that rung is
            /// pinned to an authored hex for the chrome's cream, and this family is neutral.
            #if canImport(AppKit)
            package static let secondary = SlateNativeColor.secondaryLabelColor
            #else
            package static let secondary = SlateNativeColor.secondaryLabel
            #endif
            /// A caption, a section header, a resting keycap.
            package static var tertiary: SlateNativeColor { Text.primary.withAlphaComponent(0.45) }
            /// The plate a selected row rises onto, and the keycap's face.
            package static var plate: SlateNativeColor { Text.primary.withAlphaComponent(0.08) }
            /// A hairline: a plate's edge, the card's one internal rule.
            package static var hairline: SlateNativeColor { Text.primary.withAlphaComponent(0.12) }
            /// The ground an editable field sinks into — the opposite direction from ``plate``.
            package static var well: SlateNativeColor { Text.primary.withAlphaComponent(0.04) }
        }

        /// The interaction fills and casts — see ``Slate/State``.
        @MainActor
        package enum State {
            #if canImport(AppKit)
            package static let hover = SlateNativeColor.quinarySystemFill
            #else
            package static let hover = SlateNativeColor.quaternarySystemFill
            #endif
            package static let selected = accent.slateScalingAlpha(Opacity.wash)
            package static let accentMuted = accent.slateScalingAlpha(Opacity.faint)
            package static let header = Text.secondary
            package static let shadow = SlateNativeColor.slateDynamic(
                light: 0x000000, dark: 0x000000, lightAlpha: 0.15, darkAlpha: 0.45,
            )
            package static let overlayShadow = SlateNativeColor.slateDynamic(
                light: 0x000000, dark: 0x000000, lightAlpha: 0.30, darkAlpha: 0.55,
            )
        }

        /// The status FILLS — see ``Slate/Status`` (marks and words take ``StatusInk`` instead).
        @MainActor
        package enum Status {
            #if canImport(AppKit)
            package static let ok = SlateNativeColor.systemGreen
            package static let warn = SlateNativeColor.systemOrange
            package static let err = SlateNativeColor.systemRed
            #else
            package static let ok = SlateNativeColor.systemGreen
            package static let warn = SlateNativeColor.systemOrange
            package static let err = SlateNativeColor.systemRed
            #endif
            package static let info = accent
            package static let secureInput = SlateNativeColor(slateHex: 0x2D6FE8)
            package static let syncInput = SlateNativeColor(slateHex: 0xD97A1F)
        }

        /// The six SOLVED status angles — see ``Slate/StatusInk`` before touching a hex.
        @MainActor
        package enum StatusInk {
            package static let ok = SlateNativeColor.slateDynamic(light: 0x006817, dark: 0x00B12D)
            package static let warn = SlateNativeColor.slateDynamic(light: 0x705500, dark: 0xBE9200)
            package static let notice = SlateNativeColor.slateDynamic(light: 0x9F3600, dark: 0xFF6920)
            package static let err = SlateNativeColor.slateDynamic(light: 0xB40034, dark: 0xFF6471)
            package static let info = SlateNativeColor.slateDynamic(light: 0x005D91, dark: 0x00A0F4)
            package static let aside = SlateNativeColor.slateDynamic(light: 0x9400BD, dark: 0xDB65FF)
        }

        /// One run of the project header's GIT LINE, as ink.
        ///
        /// ⚠️ NO LONGER MAC-ONLY. This said "the line is drawn by the Mac's navigator header and
        /// nowhere else — the phone's grouped list has no room for it", which stopped being true at
        /// docs/56 increment 85: the phone's section header draws the same line, shedding runs with
        /// `ViewThatFits` where AppKit measures the ladder by hand. It reaches this rung through
        /// `Color(slateNative:)` — ONE call site, the same value — rather than a `Slate.gitInk(_:)`
        /// twin beside `attentionInk`/`agentInk`. A second entry point is worth minting when a second
        /// caller needs it; until then the bridge that already exists is the smaller thing to keep
        /// true, and a twin would be one more pair that can drift.
        ///
        /// The four WORKTREE states are a RAMP, not a set of labels: `+staged` → `!modified` →
        /// `?untracked` → `~conflicted` is "how far this work is from being committed" (in the index
        /// → in the worktree → git has never seen it → it is broken), and the chromatics sweep that
        /// distance exactly: green → yellow → orange → red, monotone, in the SAME left-to-right order
        /// the sigils already appear. The ramp is the reason `?` is orange rather than one more grey
        /// — it is the rung between "you changed it" and "it is broken".
        ///
        /// Off the ramp: `↑↓` divergence is where the branch sits against its upstream and `$` stash
        /// is work parked to one side. Neither is a worktree state, so both take a cool hue and stay
        /// out of the warm sweep. The BRANCH keeps the supporting ink — it is the line's identity,
        /// not a count.
        ///
        /// ⚠️ ``StatusInk``, never the system `Status` palette this first came back in: as ink on the
        /// cream the system hues measured 2.05 (green) and 2.12 (orange) — the loudest words in the
        /// rail drawn two and a half times fainter than the grey whose job is to be ignored
        /// (user-reported 2026-08-10). Two roles were also literally the same colour, so the
        /// four-rung ramp rendered in three. These are solved iso-lightness on the deepest bed, which
        /// is what lets the ramp read AS a ramp: four hues at ONE contrast, so the order comes from
        /// chromatics and never from one run happening to shout. The hues also cannot collide with
        /// the bed they stand on — a project island's is solved to the 195°–340° arc precisely so
        /// red / amber / green stay the status vocabulary's alone (``Slate/ProjectTint``).
        package static func gitInk(_ role: GitInk) -> SlateNativeColor {
            switch role {
            case .branch: Text.secondary
            case .divergence: StatusInk.info
            case .staged: StatusInk.ok
            case .modified: StatusInk.warn
            case .untracked: StatusInk.notice
            case .conflicted: StatusInk.err
            case .stash: StatusInk.aside
            }
        }

        /// One ATTENTION role, as ink — the native view of ``Slate/attentionInk(_:)``.
        package static func attentionInk(_ role: AttentionRole) -> SlateNativeColor {
            switch role {
            case .awaiting: StatusInk.warn
            case .failed: StatusInk.err
            case .finished: StatusInk.ok
            }
        }

        /// One AGENT's state, as ink — the native view of ``Slate/agentInk(_:)``, and the reason
        /// ``AgentInk`` exists as a value at all.
        package static func agentInk(_ ink: AgentInk) -> SlateNativeColor {
            switch ink {
            case .muted: Text.secondary
            case .awaiting,
                 .thinking: StatusInk.warn
            case .done: StatusInk.ok
            }
        }

        /// The connection alarm's ink — the native view of ``Slate/connectionAlarmInk(_:)``. One step
        /// up the text ladder per rung, tertiary → secondary → primary. NO hue: a row of metric digits
        /// has nothing to hang a palette on, and an instrument that lights a different colour per fault
        /// asks the eye to learn one before it can read a number.
        package static func connectionAlarmInk(_ alarm: ConnectionAlarm) -> SlateNativeColor {
            switch alarm {
            case .quiet: Text.tertiary
            case .raised: Text.secondary
            case .loud: Text.primary
            }
        }

        /// The connection alarm's weight — the native view of ``Slate/connectionAlarmWeight(_:)``, the
        /// second channel carrying the same rungs. A brightness step alone is easy to lose beside a
        /// hostname; the weight step is what makes a raised reading findable without looking for it.
        ///
        /// A separate switch from the SwiftUI spelling rather than one shared body — ``Font/Weight``
        /// and ``SlateNativeFont/Weight`` are different types on the two frameworks, the same split
        /// ``Slate/PaneStatusPillArt`` leaves a pill's glyph weight in (one name below, one line per
        /// framework), so there is nothing here for a shared body to be written ON.
        package static func connectionAlarmWeight(_ alarm: ConnectionAlarm) -> SlateNativeFont.Weight {
            switch alarm {
            case .quiet: .regular
            case .raised: .semibold
            case .loud: .bold
            }
        }

        /// The pane status pill's fill — the native view of ``Slate/paneStatusPillFill(_:)``. The
        /// vivid tones are theme-INDEPENDENT on purpose (the shipped themes have `info == accent`, so a
        /// palette-derived security badge would be invisible against the accent — `secure-input.png` is
        /// the green-accent Paper theme yet the pill is the same royal blue), and only a NAME can say
        /// that — ``PaneStatusPillInk`` is that name, one floor down and colour-free.
        package static func paneStatusPillFill(_ ink: PaneStatusPillInk) -> SlateNativeColor {
            switch ink {
            case .security: Status.secureInput
            case .sync: Status.syncInput
            }
        }

        /// One TOAST rung, as ink — the native view of ``Slate/toastMarkInk(for:)``. `.warn` is AMBER,
        /// not the theme accent (see ``ToastMarkRung/warn``): the rail already fixed "amber = a
        /// question waiting", and every FOUNDRY seed sets `info == accent`, so the accent would have
        /// drawn needs-input in the same cyan as a routine notice. `.neutral` stays the family's own
        /// reading ink — status hues keep their meaning, and a routine notice stays NEUTRAL.
        package static func toastMarkInk(for rung: ToastMarkRung) -> SlateNativeColor {
            switch rung {
            case .ok: Status.ok
            case .warn: Status.warn
            case .err: Status.err
            case .neutral: Overlay.secondary
            }
        }

        /// The project BEDS, natively — the same five sources at the same alpha the SwiftUI side
        /// composites, reached by the index a ``Slate/ProjectTint/Deal`` dealt.
        ///
        /// The DEAL itself is not duplicated here: it is index arithmetic over a whole ordered run
        /// (a group whose hash collides with the island above it re-probes), and the Mac's navigator
        /// runs the same `Deal` the phone does and only asks this for the colour at a position.
        @MainActor
        package enum ProjectTint {
            /// The bed for a dealt index, or the NEUTRAL bed for the keyless bucket (`nil`) and for
            /// an index that has out-run the register — a bed is decoration, and a view past the end
            /// of its deal must still draw.
            package static func bed(at index: Int?) -> SlateNativeColor {
                guard let index, Slate.ProjectTint.registerHexes.indices.contains(index) else {
                    return neutralBed
                }
                return SlateNativeColor(slateHex: Slate.ProjectTint.registerHexes[index])
                    .slateScalingAlpha(Opacity.bed)
            }

            /// The keyless bucket's bed — the host island wears it too (`SlopDeskMacUI`'s
            /// `MacConnectionIsland`):
            /// a machine is not a project, so it must not wear a project's identity hue.
            package static var neutralBed: SlateNativeColor {
                SlateNativeColor(slateHex: UInt32(Slate.ProjectTint.neutralSource))
                    .slateScalingAlpha(Opacity.bed)
            }
        }
    }

    /// The chrome surface ladder — SEMANTIC system surfaces plus the one glass exception:
    /// `void` (aux-window backdrops) → `ground` (sidebar housing; on macOS the real sidebar material
    /// sits BEHIND the column and this is its fallback) → `face` (the window content ground) →
    /// `raised`/`lift` (the system fill ladder) → `terminal` (the island glass — profile-driven).
    ///
    /// ⚠️⚠️ **THE APP'S GROUND IS ``field``, NOT ``ground``.** The name is a leftover: on macOS
    /// `ground` and `void` are the SAME system backdrop (`underPageBackgroundColor`, a mid grey
    /// measured `#A1A09F`), and ONE ISLAND law 4 paints every column, moat and band with the
    /// authored cream `#FFFBEB` = ``field``. Nothing in the shipping chrome stands on `ground`. The
    /// mistake is silent — it compiles, it renders, and it simply shows the wrong colour: it cost
    /// the device panels a whole "third grey" round (`docs/DECISIONS.md`, TWO TONES) and, until
    /// 2026-08-11, every snapshot render in `SlateSnapshotRender`. Reach for `field` unless you
    /// specifically want the OS's aux-window backdrop.
    @MainActor
    package enum Surface {
        static let void = Color(slateNative: Native.Surface.void)
        /// ⚠️ NOT the app's ground — see the ladder's note above; you almost certainly want ``field``.
        package static let ground = Color(slateNative: Native.Surface.ground)
        package static let face = Color(slateNative: Native.Surface.face)
        package static let raised = Color(slateNative: Native.Surface.raised)
        static let lift = Color(slateNative: Native.Surface.lift)
        /// The SOLID mini-island fill — the active sidebar row's chip (Canario's white active tab).
        /// Against ``field`` it carries the JetBrains Islands island↔field relationship in both
        /// appearances: WHITE on the grey light field (island lighter than field), and a step
        /// DARKER than the dark field (island darker than field) — the same deliberate ~1.2:1
        /// whisper their theme ships, from a semantic colour instead of invented hex. On iOS the
        /// nearest grouped rung stands in.
        package static let chip = Color(slateNative: Native.Surface.chip)
        /// THE GROUND — the one sunken tone every column paints: the navigator, the code panel, the
        /// top band and the island's moat (law 1: they SINK, they are not islands). Kept under its
        /// old name because the eight column call sites mean exactly this; ``island`` is its
        /// counterpart, the one lifted surface. `ground` above is a different thing — the semantic
        /// aux-window backdrop.
        package static var field: Color { Slate.theme.ground }
        /// The terminal glass — the island's fixed profile surface (NOT appearance-following).
        package static var terminal: Color { Slate.theme.terminal }
        /// THE ISLAND — the terminal canvas, the one lifted surface (law 1). Equal to ``terminal`` by
        /// construction; spelled separately so the island's own geometry reads by intent.
        package static var island: Color { Slate.theme.chrome }
    }

    /// ON-GLASS vocabulary — everything drawn INSIDE the terminal island reads these, never the
    /// semantic `Text`/`State` tiers: the glass keeps its profile palette under either OS
    /// appearance, so appearance-tuned ink would invert against it (dark label on dark glass).
    @MainActor
    package enum Terminal {
        package static var ink: Color { Slate.theme.terminalInk }
        package static var ink2: Color { Slate.theme.terminalInk2 }
        package static var edge: Color { Slate.theme.terminalEdge }
        package static var raised: Color { Slate.theme.terminalRaised }
        /// The RIM of a floating plate ON the glass (``InstrumentChipShell``, the connection chip) —
        /// LIGHTER than the plate, unlike ``edge``, which is the same tone as it. See
        /// ``SlateTheme/terminalRim``: a border that matches its own fill is not a border.
        package static var rim: Color { Slate.theme.terminalRim }
        package static var accent: Color { Slate.theme.terminalAccent }
        /// The status pair ON the glass — the profile's own green / red (``SlateTheme/terminalOk``,
        /// ``SlateTheme/terminalErr``). Anything drawn inside the island that has to say "clean" or
        /// "failed" reads THESE, never ``Slate/Status`` — that set is the system's, tuned for the OS
        /// appearance and out of family beside the glass.
        package static var ok: Color { Slate.theme.terminalOk }
        package static var err: Color { Slate.theme.terminalErr }
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
    /// ground. `#76746D` held 4.51 on the cream but slid to 4.21 under the bed; this rung was solved
    /// to hold exactly 4.50 on the DEEPEST bed in the register, and the cream simply gets a darker
    /// quiet tier for free. It is therefore pinned to ``Slate/Opacity/bed`` — re-solve it if that
    /// alpha ever RISES. It fell instead (0.10 → 0.08 on 2026-08-10), which only lightens every bed
    /// and hands this rung margin: 4.60 on the deepest one now. The hex is kept as solved rather
    /// than walked back up, because it is the cream's own colour at depth and the ladder reads by
    /// its steps, not by its floor.
    ///
    /// ⚠️ The LIGHT rungs are flat hexes; the dark side is NOT a free system fallback. Two subtrees
    /// flip `colorScheme` to glass (the selected row's plate in ``MacSidebarRowView``, the pane chrome inside
    /// the terminal island), and a light-pinned hex would draw dark-on-dark there — which is why
    /// `secondary` still defers to the system tier on that side (`secondaryLabel` composites to
    /// 5.76 on the glass face and needs no help).
    ///
    /// The QUIET rung does not get that luck, and the same complaint arrived from the other side
    /// (user-reported 2026-08-10, the selected tab's `zsh` label): the glass subtrees are not
    /// "whatever surface happens to be there" — they are ONE surface, the profile face `#22212C`,
    /// and `tertiaryLabel`'s 25% white composites to **2.28 : 1** on it, far under even the 3.0
    /// non-text floor while carrying the same data the light rung was re-solved for. So this rung is
    /// pinned on BOTH sides, each against its own ground: the cream's own colour at depth
    /// (`#6C6B64`), and the GLASS's own face lifted 48% toward the profile ink (`#89888B`, 4.51 on
    /// the face) — in-family on each side rather than one foreign neutral spanning both. Re-solve
    /// the dark rung if the profile's face or ink ever moves.
    @MainActor
    package enum Text {
        package static let primary = Color(slateNative: Native.Text.primary)
        package static let secondary = Color(slateNative: Native.Text.secondary)
        package static let tertiary = Color(slateNative: Native.Text.tertiary)
        package static let icon = secondary

        /// Ink ON a saturated fill band — the fixed pills (secure blue / sync amber) and the
        /// accent's deep band. Appearance-INDEPENDENT white on purpose: those fills are pinned,
        /// so their ink must be too (a semantic label would flip against an unmoving plate).
        package static let onAccent = Color.white
        /// Ink ON the warn/hazard plate (hint badges) — black stays legible on amber in both
        /// appearances, the same pinned-fill rationale as ``onAccent``.
        package static let onWarn = Color.black
    }

    @MainActor
    package enum Line {
        package static let divider = Color(slateNative: Native.Line.divider)
        package static let card = Color(slateNative: Native.Line.card)
        package static let subtle = Color(slateNative: Native.Line.subtle)
        static let active = Color(slateNative: Native.Line.active)

        /// The INPUT plate's boundary — see ``slateFieldPlate()``. Its own token, and NOT
        /// ``divider``: measured on the cream ground the separator lands at 1.25:1, which is a rule
        /// between two visible things, not an edge that can say where a field starts.
        package static let field = Color(slateNative: Native.Line.field)

        /// A FLOATING SURFACE's rim — the toast card, every summoned paper card, the sheet. Its own
        /// token, and NOT ``divider``: the system separator measures ~1.25 : 1 on this cream, which
        /// is a rule between two visible things, not the edge of an object that has to read as
        /// LIFTED off the ground it covers. A notification card is exactly that object, and it was
        /// reported as having no visible border at all (2026-08-10).
        ///
        /// Polarity-INVERTING, which is the whole rule: a rim is drawn in the OPPOSITE polarity to
        /// the surface it bounds — black on the light card here, and on the glass the mirror image
        /// (``Slate/Terminal/rim`` lifts the dark plate toward its ink). One idea, spelled once per
        /// ground, because each ground is the only thing its own rim can be solved against.
        package static let overlayRim = Color(slateNative: Native.Line.overlayRim)
    }

    /// The ALPHA ladder — a closed scale for translucency, the one dimension the closed colour
    /// tokens did not govern (round 13): every `.opacity(N)` in chrome code picks a rung here, so
    /// two washes that mean the same thing can never drift apart by a few hundredths again.
    package enum Opacity {
        /// A GROUND that has to stay a ground (``ProjectTint/wash(for:)``, and the connection
        /// island's neutral bed). Below ``faint``, because a bed that reads as a FILL stops being a
        /// ground: measured across the identity register the island lands 1.089–1.121× off the
        /// cream, which is separation the eye resolves without the group turning into a coloured
        /// panel.
        ///
        /// The band is narrow at both ends. The first pass shipped 0.05 (1.05–1.08×) and read as
        /// barely there in the running app (user-reported 2026-08-09); it then sat at 0.10 until the
        /// beds were found to be spending more colour than the STATUS runs standing on them
        /// (user-directed 2026-08-10) — the sidebar's saturated ink is supposed to be the git line
        /// and the marks, and a bed is the one thing here that is coloured everywhere at once.
        /// Dropping to 0.08 takes ~21 % of the bed's a\*b\* displacement off the cream (magenta,
        /// the loudest, 14.51 → 11.39) while staying two full steps above the rejected pass.
        ///
        /// The tint is not free and the price is paid twice. In ``Slate/Text/tertiary``: a tinted
        /// bed is a different ground, and every step here deepens the rung that has to stay legible
        /// on the worst bed in the register — raising this without re-solving that rung is how the
        /// quiet tier silently drops under the 4.5 reading floor (lowering it, as here, only hands
        /// that rung margin back: 4.46 → 4.60). And in ``Slate/ProjectTint/register``, whose hexes
        /// were solved for maximum separation AT an alpha: every step down scales the whole set
        /// toward the cream together.
        package static let bed = 0.08
        /// The faint accent wash (``State/accentMuted``'s dose).
        package static let faint = 0.12
        /// The selection/latch wash (``State/selected``'s dose).
        package static let wash = 0.15
        /// An INPUT's boundary (``Line/field``). Its own rung because a field's edge answers to a
        /// different question than a hairline's: a rule separates two things that are both already
        /// visible, while this is the only mark saying where the typing area begins.
        package static let edge = 0.28
        /// A FLOATING SURFACE's rim (``Line/overlayRim``). Between ``wash`` and ``edge`` on purpose:
        /// a card's border has to be found at a glance over busy content, but it bounds a whole
        /// surface rather than the one small typing area ``edge`` was solved for — at 0.28 the card
        /// reads as outlined instead of lifted.
        package static let rim = 0.20
        /// De-emphasised ink ON a plate — a ruled-out hint letter, the dock badge's track.
        package static let dim = 0.35
        /// The accent spent as an OUTLINE rather than as a fill — a LIT chip's ring.
        ///
        /// Its own rung because a ring answers a question no fill does. The plate under it is already
        /// the accent at ``faint`` (``State/accentMuted``), so a full-strength border reads as a
        /// second, louder object drawn on top of that wash; anything at ``dim`` or below stops
        /// separating the lit chip from the idle one beside it, which is the only thing the ring is
        /// for. Half is where the outline still reads as the SAME accent the wash is.
        ///
        /// Three surfaces spend it and they say one thing — "this mode is on": the find bar's lit
        /// mode chip, the global-search bar's (the AppKit half of the same chip, whose header pins
        /// *"the find bar and the global-search query bar render the pills identically"*), and the vi
        /// pill in a visual selection. All three were a raw `0.5` until docs/56 stage F batch P6, one
        /// of them across the framework boundary — which is 56c's finding one dimension over: a
        /// number two renderers both need is a pair the day it is written.
        package static let accentRing = 0.5
        /// WITHHELD: the control is here, and it cannot be spent right now.
        ///
        /// Always the second half of a pair — `.disabled` plus this, never either alone. Refusing
        /// without dimming reads as a broken button; dimming without refusing invites the click anyway.
        /// The pairing is what says "there is a reason, and it is elsewhere on screen": a locked
        /// viewport dims its own zoom cluster so the eye is sent to the lock, which stays lit.
        ///
        /// The SAME NUMBER as ``accentRing`` and deliberately not the same rung. That one is a stroke
        /// alpha on an accent outline; this is a whole control's presence. They agree today by
        /// coincidence, and folding them would mean a future adjustment to a ring's weight silently
        /// re-dimming every disabled control in the app.
        ///
        /// Three surfaces spent it as a raw literal before this existed — `FontSettingsView`'s locked
        /// face-pickers, `MacFontFamilySurface`'s private `lockedAlpha` (the AppKit half of that same
        /// row, so the pair had already drifted into two spellings), and the remote-window control
        /// bar's viewport cluster. P6's rule is why it lands here rather than as a fourth: the value
        /// carries no colour, so it descends to the floor instead of being pinned as a pair.
        package static let withheld = 0.5
        /// Muted presence: soft hairlines (``Line/subtle``), secondary badge ink on a plate.
        package static let muted = 0.6
        /// A veil that RECEDES a pane while another one is the subject — the ⌃⇥ walk's dimming of
        /// everything you are not about to land on.
        ///
        /// Its own rung between ``muted`` and ``scrim`` because it answers a question neither does.
        /// ``scrim`` is a backdrop a readout stands ON and may hide what is under it; ``muted`` is a
        /// presence an *ink* is spent at. This one has to subtract exactly enough that the eye finds
        /// the one undimmed pane across a 1280pt window in the length of a modifier tap, and no more
        /// — a dimmed pane must stay READABLE or the walk is a jump between blanks rather than a look.
        ///
        /// MEASURED, not picked. 0.55 was the first pass and was photographed: on a light theme the
        /// black text only reached mid-grey, so the difference was there and not findable at a glance,
        /// which is the one thing this rung has to be. It is deliberately NOT a resting treatment —
        /// permanently dimming unfocused panes was tried and removed, because a pane you are watching
        /// a build in must not be half-erased for having the cursor elsewhere.
        ///
        /// Minted before its second speller existed (docs/56 wave R, batch R1), which is the only
        /// difference between this comment and a post-mortem: an alpha has no framework in it, so it
        /// descends to the floor and BOTH renderers read the one rung — where a `Color` could only be
        /// pinned as a pair and reported the drift after it shipped (P6's finding, increment 57d).
        package static let recede = 0.72
        /// The near-opaque backdrop a readout stands on over live content (video HUD chips).
        package static let scrim = 0.88
    }

    @MainActor
    package enum State {
        /// Row hover — the system's faintest fill (the same plate `List` hover uses).
        package static let hover = Color(slateNative: Native.State.hover)
        /// Selected row — the brand accent at a wash, so selection carries the one non-system colour.
        package static let selected = Color(slateNative: Native.State.selected)
        package static let accent = Slate.accentPurple
        package static let accentMuted = Color(slateNative: Native.State.accentMuted)
        package static let header = Text.secondary
        /// Floating-panel drop shadow — soft black, heavier on dark appearances.
        package static let shadow = Color(slateNative: Native.State.shadow)
        /// The SUMMONED card's cast shadow — twice ``shadow``, and its own rung because it does twice the
        /// work. A panel that floats over the dark island is separated by tone alone; a paper card is the
        /// ground's own cream lifted off the ground, so nothing but the cast tells the two apart at the
        /// card's edges. Compared side by side at true size, `shadow` read as a halo and this reads as lift.
        package static let overlayShadow = Color(slateNative: Native.State.overlayShadow)
        // NO `cardShadow` rung (user-directed 2026-08-09). The 4% whisper the selected tab chip
        // used to cast existed for a cream plate on a cream ground; the single profile made that
        // chip the island's dark glass, and a fill that far from the ground needs no cast to be
        // seen. Only things that genuinely FLOAT still carry one — see ``Slate/Elevation``.
    }

    // NO `Chroma` tier. It held four extra system hues (`orange` / `purple` / `blue` / `magenta`) for
    // "chrome that needs more inks than the status set", and only the git line ever drew from it —
    // where `Chroma.orange` turned out to BE `Status.warn` (both `systemOrange`), rendering two rungs
    // of that line's ramp in one identical colour, and `Chroma.purple` sat 12.6° in Lab hue from the
    // accent the neighbouring run used. A second unstructured palette beside the status vocabulary
    // only ever offered a way to collide with it by accident. ``StatusInk`` is now six SOLVED angles,
    // which is the whole set that was wanted; anything genuinely outside the status vocabulary should
    // earn its own named token rather than pick a system hue out of a drawer (2026-08-10).

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
    /// cream ground is itself strongly chromatic (L\* 98.5, C\* 8.3 at h 99.5°), so at 8 % a bed
    /// keeps 92 % of the cream and the reachable colours form a tiny cube anchored at the cream's
    /// own corner — each channel can only be pulled DOWN, and by at most 20/255. Inside that cube a
    /// "nice" mid-tone source barely moves the bed at all, which is why the previous register's
    /// nominal five hues collapsed on screen: its worst pair (brown against the neutral bucket)
    /// measured ΔE2000 **2.28**, below the threshold at which two large flat fields read as
    /// different colours at all, and blue-vs-teal only reached 5.01. Solving instead for maximum
    /// minimum separation over that cube — same lightness band, same hue arc — lifted the worst pair
    /// to **7.00** and flattened the whole set into the 7.00–7.25 band, so there is no longer one
    /// weak link. Saturated sources are simply where that optimum lives.
    ///
    /// ⚠️ That solve ran at ``Slate/Opacity/bed`` = 0.10. The alpha came DOWN to 0.08 on 2026-08-10
    /// (user-directed: the beds were out-colouring the status runs standing on them), and every
    /// pairwise distance scales toward the cream with it — the worst pair now measures ≈5.5 by the
    /// same yardstick. That is still comfortably above the ~2.3 at which two large flat fields stop
    /// reading as different colours, and the hexes are deliberately NOT re-solved for the new alpha:
    /// re-optimising would buy back separation the round just decided to spend, and the ``Deal``
    /// already guarantees the case the eye actually meets (two ADJACENT islands never share a hue).
    ///
    /// Never spend an entry of this register as an ink, a stroke or a mark. Use ``Slate/StatusInk``.
    package enum ProjectTint {
        /// The five identity BED SOURCES — teal, blue, indigo, magenta, rose. Read the type note
        /// before touching a hex: these are solved values, not picked ones, and each is meaningful
        /// only after compositing at ``Slate/Opacity/bed`` over the cream ground.
        ///
        /// Solved under four simultaneous constraints: every bed lands in a NARROW lightness band
        /// (L\* 92.80–94.40 at the alpha it was solved at, 94.02–95.15 at today's 0.08 — narrower
        /// than the register it replaces either way, so no project's bed reads as heavier than
        /// another's), every bed's displacement from the cream stays inside the 195°–340° arc (the
        /// status vocabulary keeps red / amber / green), every source stays a real colour (no
        /// channel above 248), and the minimum pairwise ΔE2000 across all six beds — the five here
        /// plus ``neutralSource`` — is maximised.
        /// The five sources as HEXES — spelled ONCE, because two frameworks read them: the phone's
        /// beds resolve through ``register`` and the Mac's through ``Slate/Native/ProjectTint/bed(at:)``,
        /// and a bed dealt to one project may not be a different colour on the two devices.
        package static let registerHexes: [UInt32] = [0x00A68F, 0x0075F7, 0x514AF8, 0xF414F7, 0xF854A4]

        @MainActor
        package static let register: [Color] = registerHexes.map { Color(slateHex: $0) }

        /// The keyless "Other" bucket's bed source. It is ``Slate/Text/secondary``'s light pin
        /// rather than a sixth identity, because the bucket has no identity to spend — but it IS
        /// part of the separation solve above (it measures ΔE2000 7.21 from its nearest neighbour),
        /// since on screen it is just another bed the eye has to tell from the ones around it.
        package static let neutralSource = 0x585751

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
        package static func seed(for key: String) -> String {
            var path = Substring(key)
            while path.hasSuffix("/") { path = path.dropLast() }
            let base = path.split(separator: "/").last.map(String.init) ?? String(path)
            return base.lowercased().precomposedStringWithCanonicalMapping
        }

        /// FNV-1a-64 over UTF-8. Wrapping multiply is the algorithm, not an overflow.
        package static func hash(_ text: String) -> UInt64 {
            var value: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value = value &* 0x100_0000_01B3
            }
            return value
        }

        /// FNV-1a-64 over a key's ``seed(for:)``, reduced mod the register size.
        package static func index(of key: String, count: Int) -> Int {
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
        package struct Deal {
            /// Per-island register index in the run's order; `nil` is the keyless bucket.
            package let indices: [Int?]

            /// Deal `keys` in render order. A `nil` key takes the neutral bed and constrains
            /// nothing after it — the neutral is ΔE2000 ≥ 7.21 from every register entry, so a
            /// keyed group below the "Other" bucket can never be mistaken for it.
            package init(keys: [String?]) {
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
            package subscript(position: Int) -> Color {
                guard indices.indices.contains(position), let index = indices[position] else {
                    return Slate.ProjectTint.neutralBed
                }
                return Slate.ProjectTint.register[index].opacity(Opacity.bed)
            }
        }

        /// The keyless bucket's bed — ``neutralSource`` at ``Slate/Opacity/bed``.
        @MainActor
        package static var neutralBed: Color { Color(slateHex: UInt32(neutralSource)).opacity(Opacity.bed) }

        /// The register size, readable without `@MainActor` (``Deal`` runs the arithmetic off the
        /// colour values). Pinned by `SlateProjectTintTests` to match ``register``'s own count.
        package static let registerCount = 5
    }

    @MainActor
    package enum Status {
        package static let ok = Color(slateNative: Native.Status.ok)
        package static let warn = Color(slateNative: Native.Status.warn)
        package static let err = Color(slateNative: Native.Status.err)
        /// Info rides the brand accent (the one non-system chrome colour).
        package static let info = Slate.accentPurple

        /// FIXED security-blue — appearance-INDEPENDENT: the secure-input pill must read as the SAME
        /// vivid royal-blue everywhere so it can never be confused with the accent. Pinned to
        /// `secure-input.png`'s royal-blue; white pill text stays legible on light and dark alike.
        /// Never re-route this through a theme or the system palette.
        package static let secureInput = Color(slateNative: Native.Status.secureInput)

        /// FIXED sync-amber — same rationale as ``secureInput``: the `⚠ SYNC INPUT` pill flags a MODE
        /// where every keystroke fans into multiple shells, so it must read as the same unmistakable
        /// amber everywhere. Never re-route this through a theme or the system palette.
        package static let syncInput = Color(slateNative: Native.Status.syncInput)
    }

    /// The status vocabulary as INK, because a colour tuned for a FILL is the wrong colour for a
    /// mark or a word.
    ///
    /// ## Why ``Status`` could not keep doing this job
    ///
    /// `Status.ok`/`warn`/`err` are the system palette, and the system palette is tuned for dark UI
    /// and for filled controls. Measured as ink on this chrome's cream (`#FFFBEB`) they land at
    /// **2.05** (systemGreen) and **2.12** (systemOrange) — under even the 3.0 non-text floor, while
    /// ``Text/tertiary``, the rung whose whole job is to be ignorable, measures **5.16**. The rail
    /// was spending its loudest vocabulary on its faintest ink: a `+3` staged count was two and a
    /// half times quieter than the `zsh` label beside it (user-reported 2026-08-10).
    ///
    /// Two more faults died with it. `Status.warn` and the retired `Chroma.orange` were BOTH `systemOrange`, so
    /// the git line's documented green→yellow→orange→red ramp rendered `!modified` and `?untracked`
    /// in one identical colour — a four-rung ramp with three rungs. And `info` (the accent) sat
    /// 12.6° from `Chroma.purple` in Lab hue, so `↑↓` and `$` were near-indistinguishable too.
    ///
    /// ## How this set is built
    ///
    /// Six hue angles, solved ISO-LIGHTNESS on each side — one L\*, maximum in-gamut chroma at that
    /// L\* for every angle. Iso-lightness is the whole point: equal contrast BY CONSTRUCTION, so no
    /// run can shout over another by accident and hue is left to do the only job it is good at,
    /// which is naming WHICH state this is.
    ///
    /// - **Light** — solved on the DEEPEST project bed, not the bare cream, because that is the
    ///   worst ground a git line ever stands on: L\* 37.75, every entry ≥ 6.02 there (≈6.77 on the
    ///   plain cream). That is ``Text/secondary``'s own level (6.24 / 6.99), so a count is never
    ///   quieter than the branch name beside it — and its hue and weight put it above.
    /// - **Dark** — solved on the glass face `#22212C`, the ONE dark surface in this app (the
    ///   selected row's compact island, the island chips): L\* 63.0, every entry ≥ 5.52, a clear
    ///   step above the dark quiet rung's 4.51.
    ///
    /// Closest pair 32 ΔE76 on the light side, 41 on the dark — no two runs can be confused.
    ///
    /// ⚠️ This tier is for TEXT AND MARKS. Fills keep ``Status``: a filled amber plate wants the
    /// vivid system orange behind black ink, and darkening it would only muddy the plate — a colour
    /// tuned for a fill is the wrong colour for a mark, and the reverse.
    ///
    /// ⚠️ NOT for anything inside the terminal island — `ok`/`err` there are the profile's own ANSI
    /// pair (``Terminal/ok``, ``Terminal/err``), because a surface that ships its own palette must
    /// answer in it.
    ///
    /// Re-solve BOTH sides if the cream, the deepest bed (so: ``Opacity/bed``) or the glass face
    /// moves — each side is pinned to its own ground, and neither is a free system fallback.
    @MainActor
    package enum StatusInk {
        /// Clean / done / `+staged` — the ramp's far end (h 140°).
        package static let ok = Color(slateNative: Native.StatusInk.ok)
        /// Wants a human / awaiting input / `!modified` (h 85°).
        package static let warn = Color(slateNative: Native.StatusInk.warn)
        /// `?untracked` — the rung between "you changed it" and "it is broken" (h 50°). Its own
        /// entry, not a second spelling of ``warn``: that collision is what flattened the ramp.
        package static let notice = Color(slateNative: Native.StatusInk.notice)
        /// Broken — error / `~conflicted` (h 22°).
        package static let err = Color(slateNative: Native.StatusInk.err)
        /// Bookkeeping against elsewhere — `↑↓` divergence (h 265°). BLUE now, not the accent: the
        /// accent means selection, and a run that borrowed it read as one.
        package static let info = Color(slateNative: Native.StatusInk.info)
        /// Parked on purpose — `$stash` (h 320°). Cool, off the warm ramp, and far enough from
        /// ``info`` to be told apart at a glance.
        package static let aside = Color(slateNative: Native.StatusInk.aside)
    }

    /// One ATTENTION role, as ink — the three states that WAIT ON YOU, on the hue budget's own rungs.
    ///
    /// The role is ``TabBadgeReading``'s (which badge means what, and which of them outranks which);
    /// the hue is this ladder's, and ``Slate/Native/attentionInk(_:)`` is the same lookup in
    /// `NSColor`. Two spellings, one decision — the split the whole ``Native`` block exists for,
    /// because the Mac's navigator rows are `NSView`s (docs/56 stage D) and the phone's are `View`s.
    ///
    /// ⚠️ A ring 10 pt across is the thinnest thing in the rail that carries state, so it is exactly
    /// where a hue tuned for filled controls fails worst (systemGreen measures 2.05 on this cream) —
    /// hence ``StatusInk``'s solved angles rather than ``Status``'s system fills. The system palette
    /// was tried for the MARK COLUMN ALONE on 2026-08-11 (user-directed) and REVERTED the same day
    /// on hardware; see `docs/DECISIONS.md`. Do not re-propose it without a different ground.
    @MainActor
    package static func attentionInk(_ role: AttentionRole) -> Color {
        Color(slateNative: Native.attentionInk(role))
    }

    /// One AGENT's state, as ink.
    ///
    /// The mapping from a `ClaudeStatus` to a MEANING is ``AgentReadout/ink(_:)``, one floor down and
    /// framework-free; this is the rung that meaning lands on, and ``Slate/Native/agentInk(_:)`` is
    /// the same lookup in `NSColor`. Two spellings, one decision — the split the whole ``Native``
    /// block exists for, because the Mac's peek card is an `NSView` and the phone's is a `View`.
    ///
    /// ⚠️ `thinking` and `awaiting` land on the SAME warm rung deliberately (see
    /// ``StatusPresentation/thinkingMark`` for the measurement that put them there). What separates
    /// them is the silhouette and the motion — a still hand against a block of dots with a hole
    /// running round it — never the hue.
    @MainActor
    package static func agentInk(_ ink: AgentInk) -> Color {
        Color(slateNative: Native.agentInk(ink))
    }

    /// The connection alarm's ink: one step up the text ladder per rung, tertiary → secondary →
    /// primary — the SwiftUI view of ``Slate/Native/connectionAlarmInk(_:)``. NO hue: a row of digits
    /// has nothing to hang a palette on, and an instrument that lights a different colour per fault
    /// asks the eye to learn one before it can read a number.
    @MainActor
    package static func connectionAlarmInk(_ alarm: ConnectionAlarm) -> Color {
        Color(slateNative: Native.connectionAlarmInk(alarm))
    }

    /// The connection alarm's weight — the second channel, carrying the same rungs. At small type
    /// sizes a brightness step alone is easy to lose beside surrounding text; the weight step is what
    /// makes a raised reading findable without looking for it.
    ///
    /// A separate switch from the native spelling — see ``Slate/Native/connectionAlarmWeight(_:)`` for
    /// why the two cannot share one body.
    package static func connectionAlarmWeight(_ alarm: ConnectionAlarm) -> Font.Weight {
        switch alarm {
        case .quiet: .regular
        case .raised: .semibold
        case .loud: .bold
        }
    }

    /// The pane status pill's fill — the SwiftUI view of ``Slate/Native/paneStatusPillFill(_:)``. THE
    /// two vivid tones are theme-INDEPENDENT on purpose (the shipped themes have `info == accent`, so
    /// a palette-derived security badge would be invisible against the accent — `secure-input.png` is
    /// the green-accent Paper theme yet the pill is the same royal blue), and only a NAME can say
    /// that — ``PaneStatusPillInk`` is that name, one floor down and colour-free.
    @MainActor
    package static func paneStatusPillFill(_ ink: PaneStatusPillInk) -> Color {
        Color(slateNative: Native.paneStatusPillFill(ink))
    }

    /// One TOAST rung, as ink — the SwiftUI view of ``Slate/Native/toastMarkInk(for:)``. `.warn` is
    /// AMBER, not the theme accent (see ``ToastMarkRung/warn``): the rail already fixed "amber = a
    /// question waiting", and every FOUNDRY seed sets `info == accent`, so the accent would have drawn
    /// needs-input in the same cyan as a routine notice. `.neutral` stays the floating family's own
    /// reading ink — status hues keep their meaning, and a routine notice stays NEUTRAL.
    @MainActor
    package static func toastMarkInk(for rung: ToastMarkRung) -> Color {
        Color(slateNative: Native.toastMarkInk(for: rung))
    }

    /// Geometry — theme-independent. Radii + the 8pt grid + chrome dimensions.
    package enum Metric {
        // MARK: The ONE-ISLAND geometry (law 3)

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
        package static let islandInset: CGFloat = 8
        /// The island's corner — THE FRAME'S OWN, so the glass and the window that holds it speak one
        /// corner. Equal to the WINDOW's own by intent, not by coincidence: this app runs
        /// `.hiddenTitleBar`, and 16 is what macOS 26 Tahoe measures on a titlebar-only window —
        /// MEASURED on 26.5 by rendering one `NSWindow` per configuration and reading the alpha
        /// profile of its corner (no toolbar 16, `.unifiedCompact` 21, `.unified` 26, which is what
        /// Finder and System Settings both measure).
        ///
        /// DOWN FROM 26 (user-directed 2026-08-10), settled on a true-size board rather than on the
        /// argument: 26 / 21 / 16 rendered at the reference 1280 × 800 from this token layer, with the
        /// real ground, glass and rim, and read at 1:1. At 26 the arc starts before the eye reaches
        /// the edge and the canvas reads soft.
        ///
        /// 26 was picked on 2026-08-08 because it is what Tahoe puts on a FULL-CHROME window — but
        /// that number belongs to a window carrying a `.unified` toolbar, and the island carries no
        /// chrome at all; it is a bare canvas. Borrowing a toolbar window's corner for it spent the
        /// top of the system's scale on the one surface with the least reason to ask for it. The
        /// island stays a window-scale surface (~880 × 775pt) — it just wears THIS window's corner
        /// instead of a bigger window's.
        ///
        /// Apple's own rule for macOS 26 is a RELATION, never a table: fixed, capsule, or concentric
        /// (`inner = outer − padding`), with `ConcentricRectangle` / `.rect(corner: .containerConcentric)`
        /// as the API. Strict concentricity would say 16 − 8 = 8 here, which is the number two earlier
        /// rounds already rejected as boxy; 16 is the nearest rung that stops the island from being
        /// ROUNDER than the frame containing it, which is the direction concentricity actually forbids.
        /// The 2026-08-08 note that the two corners are never seen together (the island sits in the
        /// CENTRE column, ~230pt clear of the frame's) still holds and is why 8 is not owed — it just
        /// never licensed going past the frame. (JetBrains' `Island.arc` and Rio Canario's ≈7.5 are
        /// small because their islands tile a window edge to edge; ours is one card in a field.)
        ///
        /// History: 8 → 14 → 26 → 16.
        package static let islandRadius: CGFloat = 16
        /// The COMPACT island — the SELECTED tab's chip, at ``heightRow``/``plate`` scale. Not the
        /// big number scaled down (a corner is read against the surface it cuts, not as a ratio):
        /// this is one rung above the 8 macOS Tahoe puts on its own selected sidebar row (measured in
        /// System Settings), so a selected tab reads as a rounded island rather than the squarish
        /// card it was, while staying clear of the pill a 32pt row reaches at 16.
        package static let islandRadiusCompact: CGFloat = 10
        /// The GROUND BAND across the window's top — the strip the traffic lights and the hover
        /// titlebar stand on, beside the island. The height ladder's chrome-strip rung
        /// (``heightStrip`` / ``titlebarHeight``); the band is not a new measurement.
        package static let bandHeight: CGFloat = heightStrip
        /// THE ISLAND'S TOP LINE — ``islandInset`` and nothing else, because the island keeps one
        /// moat on all four sides (user-directed 2026-08-09).
        ///
        /// Now that the moat is 8 this is also ``bandControlInset``, and that coincidence is the
        /// whole point of the second alignment pass (user-directed 2026-08-09): the island's top edge
        /// and the top edge of every plate standing in the band are ONE line. At 12 it was a line
        /// that agreed with nothing — 4pt under the plates' tops, 20 above their bottoms — which is
        /// what read as "hơi lệch" across the top of the window.
        package static let bandInset: CGFloat = islandInset
        /// Where a CONTROL in the band hangs from. Not the island's line: a control is 24 and a
        /// traffic light is 16, so hanging both from one line leaves the discs riding 4pt high
        /// against every plate beside them (user-reported 2026-08-09). This inset is the one that
        /// puts a plate's CENTRE on the lights' centre — measured at 20 on the running app, with the
        /// titlebar height declared (`SlopDeskClientApp.lowerTrafficLightsToTheTopLine`) — so the
        /// band reads as one row of centres and the island's edge runs just under the lights' own.
        package static let bandControlInset: CGFloat = space2

        // Radii (from design-tokens.css)
        package static let radiusCard: CGFloat = 8
        /// A FLOATING panel's corner — the notification card, and any future free-standing panel. One rung
        /// softer than ``radiusCard``, which is tuned for content INSET into a surface: at the notification's
        /// 320pt × ~46pt an 8pt corner reads boxy, and 16 starts sliding toward a pill. 12 was picked
        /// by rendering 8 / 10 / 12 / 16 at true size side by side.
        package static let radiusPanel: CGFloat = 12
        package static let radiusTab: CGFloat = 6 // tab / sidebar-row card — rides the control-radius family
        package static let radiusControl: CGFloat = 6
        package static let radiusItem: CGFloat = 6
        package static let radiusSmall: CGFloat = 4 // small inner plate (e.g. tab close-button hover)

        // 8pt spacing grid
        package static let space1: CGFloat = 4
        package static let space2: CGFloat = 8
        package static let space3: CGFloat = 12
        package static let space4: CGFloat = 16

        /// The STATE DOT: a filled circle that qualifies the text beside it (unsaved changes, a
        /// live indicator) rather than standing on its own. Sized to sit under a footnote's
        /// x-height so it reads as punctuation, not as a badge.
        package static let dot: CGFloat = 6

        /// How far the island's transient chip stack (``IslandChipStack`` — copy receipt, notice,
        /// connection indicator) stands off the island's FOOT. Two rungs of the scale, not one,
        /// because a chip is a floating cue over live text: at the window's old 16pt inset it sat on
        /// the island's bottom edge and covered the prompt line the user was typing on
        /// (user-reported 2026-08-09). At 24 there is a clear channel of glass under it, so the
        /// prompt stays readable while the chip is up.
        package static let islandChipInset: CGFloat = space4 + space2

        // The HEIGHT LADDER (MERIDIAN C1) — the closed vertical rhythm, every step a multiple of 4.
        // View code picks a rung, never a raw `frame(height: N)` literal (`check-ds-leaks.sh` enforces it).
        /// Popover/menu rows, chips, the titlebar clusters, plate buttons.
        package static let heightControl: CGFloat = 24
        /// Bars: the pane header, title-menu rows.
        package static let heightBar: CGFloat = 28
        /// The standard single-line list row (palette results, footers).
        package static let heightRow: CGFloat = 32
        /// The ROOMY single-line row — a list read at a GLANCE rather than scanned. One rung above
        /// `heightRow`.
        package static let heightRowTall: CGFloat = 44
        /// The TWO-REGISTER row: an identity with its place set under it (the ⌃⇥ switcher). Two type
        /// sizes stacked (13 over 11) come to ~29pt of ink, so this rung is that plus a breath either
        /// side — one step above `heightRowTall`, which is the same row with only one thing to say.
        package static let heightRowStacked: CGFloat = 48
        /// The sidebar TAB row — the standard single-line row rung (`heightRow`), so the tab list
        /// keeps the ladder's beat: denser than a lounge list, taller than a menu row.
        package static let heightTabRow: CGFloat = heightRow
        /// The chrome rail OUTSIDE the project islands — the connection footer's content inset and
        /// the empty-list label's. `space3`, one step wider than the rail inside an island, because
        /// nothing out here has an island edge to stand off from.
        package static let tabRowInset: CGFloat = space3
        /// How far a project island holds its content off its OWN edge — the selected row's dark
        /// chip must float inside the bed rather than butt against it. A grid step (`space2`), and
        /// chosen at true size against 6 and 10 (user-directed 2026-08-08).
        package static let projectIslandInset: CGFloat = space2
        /// The text rail INSIDE a project island — header name, git line and every row title stand
        /// here. `projectIslandInset + islandRail` is held at 18 so the runs keep the rail the
        /// sidebar had before the islands arrived, minus nothing: what the island spends on its own
        /// breathing room, the rail gives back.
        package static let islandRail: CGFloat = 10
        /// The sidebar project-group header row (gutter chevron + name). 24pt + the list's 2pt row
        /// spacing on both sides = the 28pt inter-group band; the air IS the separator.
        package static let heightSectionHeader: CGFloat = 24
        /// Chrome strips: the titlebar / traffic-light band. NOT a free number — one control
        /// (``heightControl``) with ``bandControlInset`` above and a matching grid step below, so the
        /// row sits centred on the traffic lights' own centre. Every column's SECOND row starts
        /// here: the navigator's search field, the panel's surfaces, and — only while the navigator
        /// is hidden, when the band runs over the content column — the island's top edge
        /// (``SlopDeskMacUI/MacContentColumn``, which is where the moat is measured).
        ///
        /// The island's FIRST row does not: it starts at ``bandInset``, inside the band
        /// (user-directed 2026-08-09). A band the island merely hung below — tried at both 40 and 32
        /// — read as the middle column starting one row lower than the two beside it.
        package static let heightStrip: CGFloat = bandControlInset + heightControl + space2
        /// The overlay search-input strip (palette / navigator / global search / open-quickly).
        package static let heightInput: CGFloat = 48
        /// A drawer that shares a column with the thing it is about (the simulator console under the
        /// device). Fixed rather than proportional: the drawer is a reading surface and a share-of-the
        /// -column would make its row count depend on the window height, so the same log would show
        /// four lines on a laptop and twenty on a display. Six rows plus the drawer's own strip.
        package static let heightDrawer: CGFloat = 180

        /// A FORM card's fixed width (connect, peek-reply) — one width for every dialog-shaped overlay,
        /// so two cards summoned in a row read as the same object at the same distance. List overlays
        /// (palette / open-quickly / global search) size to their own content instead.
        package static let cardFormWidth: CGFloat = 460
        /// A PORT number's field on a form card — five digits wide, never the card's width: a field's
        /// width is part of what it says about its answer.
        package static let portFieldWidth: CGFloat = 96

        // Chrome dimensions (semantic aliases INTO the height ladder — never a sixth literal)
        package static let paneHeaderHeight: CGFloat = heightBar
        /// The hover-reveal titlebar strip height — the content area reserves this at its top so the
        /// terminal starts BELOW the titlebar (the resting silhouette), not under the centred title.
        package static let titlebarHeight: CGFloat = heightStrip
        /// Where chrome may start on the traffic-light row: clear of the three system window
        /// controls. MEASURED on the running app with the titlebar declared at toolbar height
        /// (`SlopDeskClientApp.growTitlebarToBandHeight`) — three discs from a 12pt leading inset on
        /// a 23pt pitch, so the cluster's trailing edge lands at 71 — plus air.
        /// ``MacWindowSidebarToggle`` is the one thing mounted here, and the titlebar's own strip
        /// starts a plate further right so the two never contend for the slot.
        /// ⚠️ This is AppKit's placement, not ours. Do not reintroduce a manual inset constant —
        /// positioning the buttons by frame is what made them flicker on every window re-title.
        package static let windowControlsLead: CGFloat = 80
        package static let sidebarWidth: CGFloat = 220
        /// The RIGHT PANEL'S RAIL — what the panel leaves behind instead of vanishing (user-directed
        /// 2026-08-09). One control plate with the grid's inset either side, which puts the rail's
        /// toggle at exactly the x the panel's own hide toggle stands at, so the one control the
        /// user aims at never moves between the two states. Everything below it — the surface tabs,
        /// turned on their side — is that same plate width.
        package static let panelRailWidth: CGFloat = plate + 2 * space2
        /// A rail tab's LONG side, the one that runs down the rail. Every tab takes the same length
        /// (the widest name plus its mark and the plate's own padding), because a rail of tabs each
        /// as long as its own word reads as a ragged list rather than as a strip of tabs.
        package static let panelRailTabLength: CGFloat = 104
        /// The Settings window's left navigator column (a two-column Settings layout — wider than the
        /// workspace sidebar so the icon+label section rows + the search pill sit comfortably).
        package static let settingsSidebarWidth: CGFloat = 260
        package static let hairline: CGFloat = 1
        package static let cardBorderWidth: CGFloat = 1
        package static let dividerHoverWidth: CGFloat = 2
        /// Active-pane focus marker: leg length (points) of the small FILLED accent triangle in the focused
        /// pane's TOP-LEFT corner (Warp-style), not a box/bracket/underline/dot/top-bar outline and not
        /// dimming the unfocused panes — a small corner mark signals focus without adding a border to the
        /// FLAT pane or making idle panes look disabled.
        package static let focusCornerSize: CGFloat = 12

        // Control plate (PlateIconButton) — rides the ladder's control rung.
        package static let plate: CGFloat = heightControl
        package static let iconSize: CGFloat = 13
        /// A GLYPH's own plate: the square a bare mark takes when it stands INSIDE another control
        /// rather than as one. Every `×` on a pane chip is this size — the status pills', the vi
        /// pill's, the hint badge's — and it is the hit area as much as the drawing.
        ///
        /// NOT ``plate``, and the gap between them is what the rung is for: a control plate is the
        /// smallest thing a pointer aims at on its own, while this one lives inside a chip that is
        /// itself only ``heightControl`` tall, so taking the control rung would leave the chip no
        /// room for the word beside the mark. It equals ``space4`` by arithmetic and NOT by
        /// derivation — this is a target, and it must not move the day the spacing grid does.
        package static let glyphPlate: CGFloat = 16
        // Settings option CARDS (`SettingsOptionCards`) — the illustrated radio group used where the choice
        // has a SHAPE (cursor caret, tab position, key layout, window geometry, theme). ONE size for all of
        // them: a card that is bigger in one group than another reads as a different control.
        /// The illustration band inside one option card: the drawing area above the label. Two control
        /// rungs (2 × `heightControl`) — enough for a legible mini-diagram (including the theme swatch's
        /// title bar + three code lines), still a card and not a panel.
        package static let settingsCardArt: CGFloat = heightControl * 2
        /// One option card's width — FIXED, not a minimum. The grid wraps at this width rather than
        /// stretching its columns, so every card in Settings is the same size (a theme swatch is exactly as
        /// wide as a caret card). 116 fits the longest card label ("Classic Light") without truncating.
        package static let settingsCardWidth: CGFloat = 116

        // Simulator DEVICE cards + the device list's columns (`SimulatorDeviceList`). A right panel is
        // ~700pt wide and a device name is ~180 of it, so both of these exist to stop a list of names
        // from being drawn one-per-line across a surface four times wider than anything on it.
        /// The screen box inside a running device's card — the live thumbnail's height. This is the one
        /// place the panel SHOWS a device rather than naming it, so it is sized to be read, and matched
        /// to what the server actually sends: its scale-6 capture is 202 × 438 (measured 2026-08-04),
        /// which at 2× is exactly a 200pt-tall box. Bigger would be upscaling; smaller would be paying
        /// for pixels and then throwing them away.
        package static let deviceCardArt: CGFloat = 200
        /// A device card's width — FIXED, like the Settings option card and for the same reason: an
        /// adaptive column stretches, so a single running device would be one 700pt-wide card with a
        /// 92pt phone floating in the middle of it. A portrait phone at ``deviceCardArt`` is the narrow
        /// case (92) and an iPad the wide one (150); both centre in this, so the two shapes read true
        /// against each other, and the caption under them still fits a name and its verb.
        package static let deviceCardWidth: CGFloat = 180
        /// ``AndroidMarkPath``'s box in a tab plate — the ONE mark in the app that is a drawn path
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
        package static let androidMark: CGFloat = 17
        /// The device-family mark's column (`SimulatorFamilyMark`). One control rung wide because the
        /// five silhouettes are NOT one width: measured at 13pt type the phone is 13 across, the
        /// landscape pad 20 and the vision headset 23. Sized to the narrowest, the wide ones spill into
        /// the gap and touch the name; sized to the widest, every name in the list starts on one rail
        /// no matter which family the row belongs to.
        package static let deviceMarkWidth: CGFloat = heightControl
        /// A device ROW's minimum column width in the list's grid. Fits the longest device name this
        /// server serves ("iPad Pro 13-inch (M5)") plus its verb without truncating, and wraps to two
        /// columns at panel width instead of stranding a triangle 500pt from the name it belongs to.
        package static let deviceRowWidth: CGFloat = 240

        /// A popover's content width. FIXED for the same reason the notification card is: a popover that
        /// hugs its content is a popover whose width is decided by whichever row happens to hold the
        /// longest string, so the same control opens at a different size on different data. 260 is the
        /// sidebar's own working width — a popover anchored in the sidebar reads as belonging to it
        /// rather than as a window that happened to land there.
        package static let popoverWidth: CGFloat = 260

        // Notification stack (`ToastStackView`) — a notification is a pane speaking from off-screen, so it
        // is a small card in the corner, never a sheet.
        /// One notification card's width — UNIFORM across the stack, and deliberately so. Cards that hug
        /// their own content were tried first (a short notice as a small chip, a long one as a wide card)
        /// and rendered as a ragged staircase: right-aligned in the corner, every left edge landing
        /// somewhere different, and the width tracking TITLE LENGTH rather than importance — the widest
        /// card in a burst was whichever happened to have the longest name. A single column edge is what
        /// lets a stack read as one stack. 320 (down from the old 340) with the ✕ no longer holding a
        /// permanent slot, so a short title no longer stares across a gutter at a button.
        package static let toastWidth: CGFloat = 320
    }

    /// Typography scale — one named role per size; UI = system, instrument/rail = JetBrains Mono (SF Mono
    /// when absent). A closed scale (no raw `.font(.system(size:))` literals in view code —
    /// `scripts/check-ds-leaks.sh` enforces it).
    package enum Typeface {
        /// Large empty-state / placeholder glyph (build-status / empty pane).
        package static let display: CGFloat = 40
        /// A floating card's TITLE — one rung above ``body``, the only size in the overlay family that
        /// outranks the content it names.
        package static let title: CGFloat = 15
        /// Primary content + the command input field — the slightly-larger reading size.
        package static let body: CGFloat = 13
        /// Default UI label size — the sidebar's ROW TITLES included.
        package static let base: CGFloat = 12
        /// Secondary labels, chips, pills, the sidebar's project headers.
        package static let footnote: CGFloat = 11
        /// Captions, kbd hints, tab subtext.
        package static let small: CGFloat = 10
        /// The instrument face: the same family libghostty embeds as the terminal's default, so the
        /// chrome's mono voice IS the pane's voice.
        package static let mono = "JetBrains Mono"

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
        package static func instrument(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            monoInstalled
                ? .custom(mono, size: size).weight(weight)
                : .system(size: size, weight: weight, design: .monospaced)
        }

        /// The SAME voice for an AppKit label (docs/56 stage D) — the same family, the same
        /// installed check, the same SF Mono fallback, because the value here is the FACE and the
        /// size ladder, not the font object either framework builds out of them.
        ///
        /// Not derived from ``instrument(_:weight:)`` by conversion, and deliberately not the other
        /// way round either: `Font.custom(_:size:)` scales with Dynamic Type and `Font(_: NSFont)`
        /// does not, so deriving the SwiftUI rung from this one would silently pin the phone's text
        /// at a fixed size.
        package static func instrumentNative(
            _ size: CGFloat, weight: SlateNativeFont.Weight = .regular,
        ) -> SlateNativeFont {
            guard monoInstalled else { return .monospacedSystemFont(ofSize: size, weight: weight) }
            let descriptor = SlateNativeFont.systemFont(ofSize: size, weight: weight)
                .fontDescriptor.withFamily(mono)
            #if canImport(AppKit)
            return NSFont(descriptor: descriptor, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: weight)
            #else
            return UIFont(descriptor: descriptor, size: size)
            #endif
        }

        /// Tracking (pt) for caps micro-labels set in the instrument voice — wide enough to read as
        /// engraving, applied ONLY to all-caps labels.
        package static let instrumentTracking: CGFloat = 1.2
        /// Tracking (pt) for the SIDEBAR's caps labels ("TABS", project headers) — the otty
        /// measurement (`.tracking(0.6)` on the system face), narrower than the instrument engraving.
        package static let capsTracking: CGFloat = 0.6
        /// Tracking (pt) for caps micro-labels on a PILL/BADGE plate (the secure-input pill, the
        /// mode badges) — measured off the system secure-input pill's own small-caps spacing, one
        /// shade tighter than the sidebar's ``capsTracking``; its own rung because it is a
        /// measurement, not a preference.
        package static let pillTracking: CGFloat = 0.5
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
    package enum Elevation {
        /// A pill/chip floating over the glass: status pills, mode badges, instrument chips.
        case chip
        /// A pane ghost mid-drag — clearly lifted, still near.
        case ghost
        /// A floating panel: the find bar, the overlay cards.
        case panel
        /// The command palette — the deepest float in the app.
        case palette

        package var radius: CGFloat {
            switch self {
            case .chip: 4
            case .ghost: 8
            case .panel: 12
            case .palette: 30
            }
        }

        package var y: CGFloat {
            switch self {
            case .chip: 1
            case .ghost: 2
            case .panel: 4
            case .palette: 12
            }
        }
    }

    /// Animation timing — extracted verbatim from `ReplicaKit.Anim` (cubic-bezier, NO springs anywhere).
    /// THE MOTION VALUES — a curve and a duration, before a framework animates with them.
    ///
    /// Same reason as ``Slate/Native``: `withAnimation` is SwiftUI's, and the AppKit surfaces stage D
    /// is porting animate through `CAAnimation` / `NSAnimationContext`, which take control points and
    /// a duration. One value, two views of it — ``Anim`` below is the SwiftUI view of this namespace,
    /// and ``SlateCurve/timingFunction`` is the CoreAnimation one. The split shell has needed the raw
    /// points since long before the port (`NSSplitViewItem.animator()` cannot take an `Animation`),
    /// and it used to reach for a lone `emphasizedControlPoints` constant that named the curve a
    /// second time.
    package enum Motion {
        /// Relayout / panel / tab-select / indicator slide — EaseInEaseOut 0.20s.
        package static let standard = SlateCurve(0.42, 0, 0.58, 1, duration: 0.20)
        /// animateIn / row reflow / toggle thumb — EaseOut 0.18s.
        package static let fadeSlideIn = SlateCurve(0, 0, 0.58, 1, duration: 0.18)
        /// Hover reveal / panel-toggle show — EaseOut 0.15s.
        package static let reveal = SlateCurve(0, 0, 0.58, 1, duration: 0.15)
        /// animateOut — EaseIn 0.14s.
        package static let fadeOut = SlateCurve(0.42, 0, 1, 1, duration: 0.14)
        /// Scroll fade / link pill / hover plate — EaseOut 0.12s.
        package static let smallFade = SlateCurve(0, 0, 0.58, 1, duration: 0.12)
        /// Divider / plate hover — EaseInEaseOut 0.16s.
        package static let dividerHover = SlateCurve(0.42, 0, 0.58, 1, duration: 0.16)
        /// The MERIDIAN L4 "needle" — see ``Anim/needle``.
        package static let needle = SlateCurve(0.2, 0, 0, 1, duration: 0.24)
        /// The prompt-jump landing FLASH's decay — see ``Anim/promptFlash``.
        ///
        /// An ALIAS of ``needle`` rather than a second `SlateCurve` carrying the same four numbers,
        /// which is deliberate in both directions. The flash IS a needle — a hard cut on, a long
        /// decel off, nothing travelling — so re-typing the control points would be one motion with
        /// two spellings, the failure this whole namespace exists to prevent; and naming the ROLE is
        /// what lets ``Anim/promptFlashHold`` be derived from it, so the beat that unmounts the
        /// flash follows the fade automatically instead of silently stopping being longer than it.
        package static let promptFlash = needle
        /// A whole COLUMN reflowing — see ``Anim/stackReflow``.
        package static let stackReflow = SlateCurve(0.4, 0, 0.2, 1, duration: 0.28)
        /// The selection plate travelling — see ``Anim/selectionMorph``.
        package static let selectionMorph = SlateCurve(0.4, 0, 0.2, 1, duration: 0.26)
        /// A split COLUMN opening or closing — the longest move in the app; see ``Anim/columnSlide``.
        package static let columnSlide = SlateCurve(0.4, 0, 0.2, 1, duration: 0.32)
        /// The one repeating shape — see ``Anim/pulse`` (the repeat itself is SwiftUI's).
        package static let pulse = SlateCurve(0.42, 0, 0.58, 1, duration: 0.55)
    }

    package enum Anim {
        /// Relayout / panel / tab-select / indicator slide — EaseInEaseOut 0.20s.
        package static let standard = Motion.standard.animation
        /// animateIn / row reflow / toggle thumb — EaseOut 0.18s.
        package static let fadeSlideIn = Motion.fadeSlideIn.animation
        /// Hover reveal / panel-toggle show — EaseOut 0.15s.
        package static let reveal = Motion.reveal.animation
        /// animateOut — EaseIn 0.14s.
        package static let fadeOut = Motion.fadeOut.animation
        /// Scroll fade / link pill / hover plate — EaseOut 0.12s.
        package static let smallFade = Motion.smallFade.animation
        /// How fast THE acknowledgement plays (`View.slateGlyphAck`) — a symbol bounce runs long by
        /// default and a click has to feel answered, not performed. Lives here rather than at the one
        /// call site because the effect is the app's, not any one button's.
        package static let ackSpeed: Double = 1.4
        /// Divider / plate hover — EaseInEaseOut 0.16s.
        package static let dividerHover = Motion.dividerHover.animation
        /// MERIDIAN L4 "needle" — the mechanical settle used for the connect handshake's colour-in.
        /// Fast attack, long decel, no overshoot (no springs anywhere). ``promptFlash`` is the same
        /// curve under its own name.
        package static let needle = Motion.needle.animation
        /// The PROMPT-JUMP LANDING FLASH's decay — the ⌘PageUp/⌘PageDown flash that anchors the eye
        /// where a jump went. The same mechanical settle as ``needle`` and named separately because
        /// the two rungs below are keyed to this role, not to the handshake's.
        ///
        /// The AppKit half animates `Slate.Motion.promptFlash.timingFunction` on a layer's opacity
        /// and holds for ``promptFlashHold``; the SwiftUI half spends this `Animation` and sleeps
        /// for the same. One rung, two views of it — ``SlateCurve``'s whole reason.
        package static let promptFlash = Motion.promptFlash.animation
        /// The opacity the flash CUTS ON at, before it decays to zero. Loud enough to catch a
        /// saccade, quiet enough to read as light rather than as a selection band.
        ///
        /// On ``Anim`` rather than on ``Opacity``, for ``plateIgniteScale``'s reason: it is an
        /// amplitude the motion SPENDS and never rests at — no chrome is ever drawn at this alpha —
        /// while every rung on the alpha ladder is a resting value some surface holds.
        package static let promptFlashPeak: Double = 0.28
        /// How long the flash's rects stay MOUNTED — the fade, PLUS the beat that unmounts it.
        ///
        /// The extra beat is not part of the motion and must never be spent animating: it is slack
        /// between the last frame of the decay and tearing the rects out of the view tree, so the
        /// unmount can never race the fade and clip it. It exists because the two are driven by
        /// different clocks — an animation's and a `Task.sleep`'s — which will not agree to the
        /// frame.
        ///
        /// Derived from ``Motion/promptFlash`` on purpose. It was a bare `300` at the one call site
        /// whose only job was "longer than the fade", so it stopped being that the moment anyone
        /// retuned the curve, and nothing anywhere would have gone red.
        package static let promptFlashHold: Double = Motion.promptFlash.duration + 0.06
        /// A whole COLUMN reflowing (toast spine expand/collapse shifts every sibling card, not just the
        /// hovered one) — a shade longer than `standard`, gentle symmetric ease so the reverse (mouse-out)
        /// reads as calm as the forward. EaseInEaseOut 0.28s.
        package static let stackReflow = Motion.stackReflow.animation
        /// The SELECTION PLATE travelling between two chips (``MacPanelTabGroup``'s morph). Longer
        /// than `standard` and on the emphasized curve on purpose: `standard` is sized for a state
        /// that CHANGES IN PLACE, and spent on a plate crossing the whole panel it read as a skip
        /// rather than a move (measured: the plate cleared 128pt in ~120ms). This is still well
        /// under the column slide — the plate is the smaller object and must not feel heavier.
        package static let selectionMorph = Motion.selectionMorph.animation
        /// How far the selection plate is CLOSED at the start of an ignite — the height it opens
        /// FROM when it arrives in an island the previous selection was not in (user-directed
        /// 2026-08-10). Not a `Metric`: it is a ratio the motion spends, not a dimension the layout
        /// reserves, and the plate it scales is whatever rung its surface uses (a sidebar row here,
        /// a band chip there).
        ///
        /// 0.80, not the 0.88 first tried, and the reason is the CURVE rather than the depth. On the
        /// emphasized curve most of a scale is spent in the first fifth of its duration: measured in
        /// the running app, an 0.88 plate was back to full height 53ms in — while it was still almost
        /// transparent — so the opening finished before there was anything to watch and the change
        /// read as the plain cross-fade it was supposed to replace. Opening from 0.80 at full ink
        /// (the ignite ``MacPanelTabGroup`` runs) puts the motion where the eye already is.
        package static let plateIgniteScale: CGFloat = 0.80
        /// A SPLIT COLUMN opening or closing — the sidebar and the code panel (user-directed
        /// 2026-08-09). The longest move in the app: an entire column's width travels, so it takes
        /// the emphasized curve and a beat more than `stackReflow` to keep the terminal's re-wrap
        /// from reading as a snap. Anything that has to LAND with the column (the titlebar strip
        /// arriving as the sidebar leaves) delays by this much.
        package static let columnSlideDuration = Motion.columnSlide.duration
        package static let columnSlide = Motion.columnSlide.animation
        /// The ONE repeating shape in the vocabulary — a slow symmetric breathe for a preview that
        /// demonstrates blinking (the cursor preview). EaseInEaseOut 0.55s, autoreversing forever;
        /// never used on live chrome (the at-rest-motion purge stands).
        package static let pulse = Motion.pulse.animation.repeatForever(autoreverses: true)
    }
}

// MARK: - The floating family's neutral ink

/// The floating (overlay) family's palette: system-semantic, neutral, theme-INDEPENDENT — the switcher,
/// the palette, Open Quickly, global search, the cheat sheet, Connect, peek-reply and the toast stack.
///
/// Every value derives from the platform label colour or the system accent, so it is a true grey on both
/// appearances and repoints itself when the appearance changes — without ever reaching into `Slate.theme`,
/// which is the terminal's filter and belongs to the workspace.
///
/// Relocated here from `SlopDeskClientUI` (docs/56 batch 3): the rungs themselves have always lived in
/// ``Slate/Native/Overlay``, one floor below both renderers, and this SwiftUI view of them was the one
/// piece of that pair still sitting above the design floor — reachable by the phone's cards, unreachable
/// by the Mac's `NSView`-built cheat sheet and toast panel, which read ``Slate/Native/Overlay`` directly.
/// A pure `Color`-wrapper table with no `View` conformance belongs beside the token it wraps, not above it.
@MainActor
package enum SlateOverlayInk {
    /// The thing being read.
    package static let primary = Color(slateNative: Slate.Native.Overlay.primary)
    /// A supporting label.
    package static let secondary = Color(slateNative: Slate.Native.Overlay.secondary)
    /// A caption, a section header, a resting keycap.
    package static let tertiary = Color(slateNative: Slate.Native.Overlay.tertiary)
    /// The plate a selected row rises onto, and the keycap's face.
    package static let plate = Color(slateNative: Slate.Native.Overlay.plate)
    /// A hairline: a plate's edge, the card's one internal rule.
    package static let hairline = Color(slateNative: Slate.Native.Overlay.hairline)
    /// The ground an editable field sinks into — the opposite direction from ``plate``.
    package static let well = Color(slateNative: Slate.Native.Overlay.well)
}

package extension Color {
    /// The SwiftUI view of a token — the one bridge between the value (a ``SlateNativeColor``) and
    /// the framework that draws it. Every rung in ``Slate`` comes through here.
    init(slateNative color: SlateNativeColor) {
        #if canImport(AppKit)
        self.init(nsColor: color)
        #elseif canImport(UIKit)
        self.init(uiColor: color)
        #endif
    }

    /// 24-bit RGB hex literal initializer, e.g. `Color(slateHex: 0xFC_FB_F9)`.
    init(slateHex hex: UInt32) {
        self.init(slateNative: SlateNativeColor(slateHex: hex))
    }

    /// An APPEARANCE-DYNAMIC colour pair — resolves `light`/`dark` per the effective appearance at
    /// draw time (the mechanism every semantic system colour uses), so the brand accent follows the
    /// window appearance the way `labelColor` does instead of being pinned to one mode.
    init(
        slateDynamicLight light: UInt32, dark: UInt32,
        lightAlpha: Double = 1, darkAlpha: Double = 1,
    ) {
        self.init(slateNative: .slateDynamic(
            light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha,
        ))
    }

    /// A LIGHT-PINNED ink: an exact colour on the one light ground this app owns, and the SYSTEM
    /// semantic anywhere the appearance resolves dark. The asymmetry is the point — the light ground
    /// is a fixed cream this design measured its ladder against, while the dark side is whatever
    /// surface the glass subtrees happen to be, which only the system tiers can track. See
    /// ``Slate/Text`` for why the light rungs left the system ladder in the first place.
    init(slatePinnedLight light: UInt32, darkSystem: SlateNativeColor) {
        self.init(slateNative: .slatePinnedLight(light, darkSystem: darkSystem))
    }
}

#if canImport(AppKit)
package extension NSColor {
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
package extension UIColor {
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

/// A NAMED MOTION — a cubic Bézier and a duration, which is what both animation frameworks in this
/// client actually take: SwiftUI wants an `Animation`, CoreAnimation wants control points plus a
/// `duration` on the context. Spelling the rung once as the value and deriving both views of it is
/// the same move ``Slate/Native`` makes for colour, and for the same reason — the AppKit surfaces
/// (docs/56 stage D) must animate on the app's curve without re-typing its numbers.
package struct SlateCurve: Equatable, Sendable {
    package let x1: Double
    package let y1: Double
    package let x2: Double
    package let y2: Double
    /// Seconds. The one number a delay off this rung (`.delay(columnSlideDuration * 0.55)`) reads.
    package let duration: Double

    package init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, duration: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.duration = duration
    }

    /// The SwiftUI view of the rung.
    package var animation: Animation { .timingCurve(x1, y1, x2, y2, duration: duration) }

    /// The CoreAnimation view of the rung — for a `CAAnimation`'s `timingFunction` or an
    /// `NSAnimationContext`'s (`NSSplitViewItem.animator()` has needed exactly this since before the
    /// AppKit port began).
    ///
    /// UNGATED, though every caller today is AppKit. `CAMediaTimingFunction` is QuartzCore, which
    /// both platforms have, and a `#if canImport(AppKit)` around it said "macOS" while meaning
    /// "CoreAnimation" — so the first phone view that drives a `CALayer` directly would have found
    /// the app's own curve missing and re-typed the four control points, which is the second copy
    /// this whole struct exists to prevent. The phone already hosts `CALayer`-backed `UIView`s (the
    /// device panels' screen views, the terminal), so this is not hypothetical. A rung with no
    /// caller on one platform costs a few bytes; a rung UNREACHABLE on one platform costs a
    /// divergent curve nobody notices until the two halves animate differently.
    package var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }
}

// MARK: - The value side of both bridges

package extension SlateNativeColor {
    /// An APPEARANCE-DYNAMIC pair — the mechanism every semantic system colour uses, spelled once
    /// here so the AppKit rung and the SwiftUI rung are the same object rather than two builds of
    /// the same two hexes.
    static func slateDynamic(
        light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1,
    ) -> SlateNativeColor {
        #if canImport(AppKit)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(slateHex: dark, alpha: darkAlpha)
                : NSColor(slateHex: light, alpha: lightAlpha)
        }
        #elseif canImport(UIKit)
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(slateHex: dark, alpha: darkAlpha)
                : UIColor(slateHex: light, alpha: lightAlpha)
        }
        #endif
    }

    /// A hex on the light side, a SYSTEM semantic on the dark one — see ``Color/init(slatePinnedLight:darkSystem:)``.
    static func slatePinnedLight(
        _ light: UInt32, darkSystem: SlateNativeColor,
    ) -> SlateNativeColor {
        #if canImport(AppKit)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? darkSystem
                : NSColor(slateHex: light)
        }
        #elseif canImport(UIKit)
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkSystem : UIColor(slateHex: light)
        }
        #endif
    }

    /// The same colour at a FRACTION of its own alpha — what SwiftUI's `.opacity(_:)` does to a
    /// `Color`, and NOT what `withAlphaComponent(_:)` does (that one REPLACES the alpha, which turns
    /// the system separator — already a low-alpha black — into a solid rule). Stays dynamic: the
    /// scale is applied to whatever the appearance resolves, not to one snapshot of it.
    func slateScalingAlpha(_ factor: Double) -> SlateNativeColor {
        #if canImport(AppKit)
        return NSColor(name: nil) { [self] appearance in
            var resolved = self
            appearance.performAsCurrentDrawingAppearance {
                resolved = self.usingColorSpace(.sRGB) ?? self
            }
            return resolved.withAlphaComponent(resolved.alphaComponent * factor)
        }
        #elseif canImport(UIKit)
        return UIColor { [self] traits in
            let resolved = resolvedColor(with: traits)
            return resolved.withAlphaComponent(resolved.cgColor.alpha * factor)
        }
        #endif
    }
}
#endif
