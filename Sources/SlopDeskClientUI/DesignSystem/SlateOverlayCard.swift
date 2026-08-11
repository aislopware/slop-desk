// SlateOverlayCard — the shared vocabulary every FLOATING surface speaks: the paper card it is drawn on,
// the plate a selected row lifts onto, and the keycap a pressable key is set in.
//
// It was written for the ⌃⇥ pane switcher and then, once that card was the one surface the user liked,
// promoted here so the palette / Open Quickly / global search / cheat sheet / connect / peek-reply all read
// as the SAME object. Before this file each of those was a native `.sheet` in the system's own voice —
// a grouped `Form`, a `List` with section backgrounds, an opaque window ground — and the set had no
// common shape at all: six dialogs that happened to share a presentation modifier.
//
// The four moves, which is all "the switcher's style" actually is:
//
//   1. The SURFACE is PAPER: the ground's own cream, opaque, cut at the FAMILY's own corner
//      (``Slate/Metric/radiusPanel`` — not the island's; see ``SlatePaperCard/shape``), edged by a
//      hairline and dropped on a real shadow. It was Liquid Glass until 2026-08-08, and ONE
//      ISLAND took that material's reason away. Glass earns its keep by refracting what varies behind
//      it; behind these cards now lie exactly two flat opaque tones, so the effect degraded to a grey
//      slab that also flipped relationship halfway across itself — light-over-cream at the edges,
//      light-over-glass in the middle. Apple's own rule points the same way (avoid stacking glass;
//      apply the material once, at the top). Rendered side by side at true size, the paper card reads
//      as a sheet laid on the canvas and the glass one all but disappeared into it.
//   2. NO chrome inside it. No `Divider` between regions, no grouped-`Form` insets, no `List` section fills.
//      A card that is already a distinct object does not need internal boxes to say where it ends; spacing
//      carries the structure. This is the move that makes the surfaces look related rather than merely tinted.
//   3. A selected row is a PLATE — one surface rung up, hairline-bordered — and its title goes HEAVIER.
//      Never coloured: importance is light and weight, not hue (DECISIONS §git-line-two-registers).
//   4. A key you can press right now is drawn as a KEYCAP in the instrument voice. A bare glyph run does not
//      say "press this"; a cap does.
//
// ⚠️ THE INK IS NEUTRAL, NOT THE TERMINAL'S. `Slate` supplies every DIMENSION here (raw font/radius/height
// literals fail `scripts/check-ds-leaks.sh`) and the mono FACE, but none of its colour. A floating card is
// not part of the workspace's world: the profile's greys are tinted violet, and a dialog wearing them
// reads as a stained panel rather than as a neutral surface hovering over coloured work. So the family's
// ink comes from the SYSTEM's semantic colours (``SlateOverlayInk``), which are neutral by construction.
// The card stands on the CHROME's polarity — the same light the navigator and the panel stand in — so
// every one of those inks resolves dark on the cream without a single call site changing.
//
// Nor is the MACHINE'S accent part of the family. It was the last colour left — the caret, the fuzzy-match
// run, the ✓ gutter, the default button — and a card that is otherwise monochrome reads as a system dialog
// the moment one blue thing lands on it (and as a PINK one on a machine whose accent is pink, which is not
// a decision this design gets to make). A match run is marked the way every other readout here marks
// importance: heavier, against quieter neighbours. Filled controls, focus rings and selection are handled
// APP-WIDE by the neutral AccentColor asset (see Apps/Shared/Assets.xcassets) — the one supported way to
// reach the focus ring, which no per-subtree `.tint()` can.
//
// Status colour is the exception and stays: a blocked agent's mark and a validation warning MEAN something,
// and neutrality is about the chrome not competing, never about suppressing a signal.
//
// No AppKit, so this compiles for iOS with the rest of `SlopDeskClientUI`.

#if canImport(SwiftUI)
import SwiftUI

// MARK: - The neutral ink

/// The floating family's palette: system-semantic, neutral, theme-INDEPENDENT.
///
/// Every value derives from `Color.primary` (the platform label colour) or the system accent, so it is a
/// true grey on both appearances and repoints itself when the appearance changes — without ever reaching
/// into `Slate.theme`, which is the terminal's filter and belongs to the workspace.
enum SlateOverlayInk {
    /// The thing being read.
    static let primary = Color.primary
    /// A supporting label.
    static let secondary = Color.secondary
    /// A caption, a section header, a resting keycap.
    static let tertiary = Color.primary.opacity(0.45)
    /// The plate a selected row rises onto, and the keycap's face.
    static let plate = Color.primary.opacity(0.08)
    /// A hairline: a plate's edge, the card's one internal rule.
    static let hairline = Color.primary.opacity(0.12)
    /// The ground an editable field sinks into — the opposite direction from ``plate``.
    static let well = Color.primary.opacity(0.04)
}

// MARK: - The card surface

/// The floating card's SURFACE: PAPER — the ground's cream, opaque, at the floating family's own corner,
/// edged by a hairline and dropped on the deepest rung of the shadow ladder.
///
/// Nothing here is appearance-directed any more. The app has ONE polarity (`SlateAppearancePin`), one
/// ground and one glass, so a card that summoned itself over the workspace is either the ground raised or
/// the glass repeated — and the glass repeated is invisible, because a card lands centred, which is where
/// the island already is. The cream reverses that: ~13:1 against the canvas it covers, and against the
/// ground at the card's edges the hairline and the cast shadow carry it, exactly as they carry the island
/// itself. No material, no rim highlight, no Reduce-Transparency branch to keep honest.
struct SlatePaperCard: ViewModifier {
    /// Whether the card carries the click barrier below. The MODAL cards (which float on a full-bleed
    /// dismiss floor) need it; a card that is ITSELF a button — the notification card, whose whole body
    /// is its jump action — must NOT, because a `Button` in the background outranks the wrapping button
    /// for any click the content declines, and the card's own action would silently stop firing.
    var hitBarrier = true

    /// ⚠️ THE FLOATING FAMILY KEEPS ITS OWN CORNER — ``Slate/Metric/radiusPanel``, the radius every one of
    /// these cards wore before the island's went to a window scale. Briefly they were re-pointed at
    /// ``Slate/Metric/islandRadius`` on the reasoning that a summoned card is a window-scale object too;
    /// that reasoning was wrong twice over. The island's 26 is a WINDOW corner earned by a ~880 × 775pt
    /// surface, and a switcher or a palette is a fraction of that, so the same number reads as a soft
    /// blob rather than as a card. And the change had reach nobody asked for: one token moved a corner on
    /// seven surfaces at once. Only the terminal island takes the island corner (user-directed
    /// 2026-08-08). Scale used to branch here — panel vs row — and is gone with it: the family is one
    /// corner again, which is what "the same object" meant in the first place.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusPanel, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(Slate.Surface.field, in: shape)
            // ``Slate/Line/overlayRim``, not the system separator: this card COVERS the workspace,
            // so its edge is the only thing saying where the object ends, and the separator lands at
            // ~1.25 : 1 on the cream — a rule between two visible things, not a boundary. Reported
            // as "no border tint" on the notification card specifically (2026-08-10), which is the
            // member of the family that lands over the terminal's own busy output.
            .overlay { shape.strokeBorder(Slate.Line.overlayRim, lineWidth: Slate.Metric.hairline) }
            // ⚠️ The card is SOLID TO CLICKS, and that is a correctness fix, not polish. The card floats
            // on a full-bleed dismiss floor; a click that lands on the card's own body — a label, the
            // padding between two fields, the gap beside a disclosure row — is not a click on the floor,
            // but nothing in the content is interactive there, so it fell straight through and DISMISSED
            // the card the user was reaching into. The barrier goes BEHIND the content, so every real
            // control on the card still gets its hit first; only what the content declines stops here.
            .background {
                if hitBarrier {
                    Button {} label: { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain)
                }
            }
            // The shadow is what LIFTS an opaque cream card off an opaque cream ground — the hairline
            // alone only draws its outline. The deepest rung on purpose: this surface floats above the
            // island, which is itself already above the ground.
            .slateShadow(.palette, color: Slate.State.overlayShadow)
    }
}

/// The floating family's ONE-LINE member: the transient notice CAPSULE that stands at the island's foot
/// (`COPIED`, `TAB CLOSED`, `JUMPED`, `REPLY SENT`). Same paper, same rim, same neutral ink as
/// ``SlatePaperCard`` — a capsule instead of a card because it carries exactly one line and nothing else.
///
/// ⚠️ IT IS PAPER, AND THAT IS ARITHMETIC RATHER THAN TASTE. These chips used to be drawn ON the glass
/// (``InstrumentChipShell``, the profile's own `raised`/`rim`/`ink2`) and were reported as ugly and sunken
/// (2026-08-11). Measured, the plate stood at **1.63 : 1** against the glass face, its rim at **1.49 : 1**
/// against its own plate, and the LABEL — the word saying what just happened — at **2.19 : 1**, under even
/// the 3.0 floor for non-text. The 2026-08-10 rim fix had only ever touched the border.
///
/// It could not be fixed where it stood. The whole on-glass band, from the face `#22212C` to the comment
/// ink `#7970A9`, is **3.56 : 1 wide in total**, and a chip needs three separable steps inside it (plate,
/// rim, label): lifting the plate to 2.95 drops the ink on it to 5.06 and leaves the rim at 1.22. Every
/// arrangement of that band spends one step to buy another.
///
/// This is the SAME arithmetic ONE ISLAND already resolved once, at the whole-app scale — "any darker frame
/// is arithmetically stuck: `#22212C` against pure black is 1.32 : 1, so the whole dark half of the axis
/// cannot separate at all" (`DESIGN.md`), which is why the ground is Alucard's cream. The notice meets that
/// wall one level down and takes the same way out. On paper every step passes with room to spare: plate
/// **15.32** against the glass, rim **9.57**, label **6.99**, detail **20.25**.
///
/// ⚠️ TAKING THE PAPER MEANS TAKING THE FAMILY'S VOICE — the two are one decision, not two. The floating
/// family's ink is the system's neutral semantics set in sentence case (``SlateOverlayInk``), and its
/// caps-mono eyebrow was rejected wholesale the same week the form cards shed theirs. So `COPIED · 1,204
/// CHARS` became `Copied · 1,204 characters`: the instrument register is the GLASS's voice, and this
/// surface no longer stands on the glass. The one instrument chip that still does — the divider's live
/// ratio readout — keeps ``InstrumentChipShell`` and is untouched.
///
/// The rim is ``Slate/Line/overlayRim`` verbatim, NOT a second light-side rim solved for this shape: it is
/// the same paper over the same terminal, and two washes that mean the same thing drifting apart by a few
/// hundredths is the exact failure the ``Slate/Opacity`` ladder exists to prevent. Where the capsule
/// crosses BRIGHT terminal output the cream itself falls to ~1.03 and the rim (1.32–1.86 there) plus the
/// cast shadow are what carry the boundary — which is why neither is optional on this member.
struct SlatePaperCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Generous sides against a tight top/bottom is what reads as a capsule rather than as a
            // rounded box — the proportion is the shape here, since a capsule has no radius to tune.
            .padding(.horizontal, Slate.Metric.space4)
            .padding(.vertical, Slate.Metric.space2)
            .background(Slate.Surface.field, in: .capsule)
            .overlay { Capsule().strokeBorder(Slate.Line.overlayRim, lineWidth: Slate.Metric.hairline) }
            // ⚠️ THE CLIP IS NOT DECORATION — IT IS WHAT REMOVES THE RIM'S WHISKERS, and the chip's whole
            // family shares the defect, so both members carry this line. `strokeBorder` on a shape whose
            // corner radius reaches (or exceeds) half its height leaves a stray vertical TICK a point or so
            // outside each horizontal extreme, where the two arcs meet. Isolated in the
            // `testRenderIslandChips` probe on 2026-08-11 by rendering the chip four ways at native scale:
            // with the border and without, inside a `Button` and bare — the ticks tracked the BORDER alone,
            // and a plate at a radius small enough to fit inside its own height never had them. Clipping to
            // the same shape is the fix that keeps a true capsule; an inset `.stroke()` was tried and still
            // ticks. Ahead of the shadow, so the shadow still falls OUTSIDE the clip.
            .clipShape(.capsule)
            // ⚠️ THE INK MUST CLIMB BACK OUT OF THE GLASS. This is the one paper surface mounted INSIDE
            // the island subtree, which ``Slate/glassColorScheme`` has forced dark — so `SlateOverlayInk`
            // (semantic, polarity-following) resolved for the dark well and drew WHITE ON CREAM. The
            // scheme follows the PLATE, not the ancestor: the mirror of the selected tab's flip INTO the
            // glass. Applied AFTER the surface so it governs the content, and it is the app's own
            // polarity, not a third appearance — see ``Slate/chromeColorScheme``.
            .environment(\.colorScheme, Slate.chromeColorScheme)
            // The ladder's own rung for a pill floating over the glass. It is nearly invisible against the
            // dark face (a dark cast on a dark ground) and that is fine — it is bought for the case that
            // needs it, where the capsule overlaps bright output and the cream has no contrast of its own.
            .slateShadow(.chip, color: Slate.State.overlayShadow)
    }
}

extension View {
    /// Draw this content as a floating paper card (see ``SlatePaperCard``). `hitBarrier: false` is for a
    /// card whose whole body is already a button (the notification card) — see the modifier's note.
    func slatePaperCard(hitBarrier: Bool = true) -> some View {
        modifier(SlatePaperCard(hitBarrier: hitBarrier))
    }

    /// Draw this content as a floating paper CAPSULE — the transient notice family's shell
    /// (see ``SlatePaperCapsule``).
    func slatePaperCapsule() -> some View {
        modifier(SlatePaperCapsule())
    }

    /// Sink an editable field into its plate: the pane face, ringed by a hairline, at the small radius.
    ///
    /// A card carries no `Form`, so nothing else says "you may type here" — on glass an unringed field is
    /// indistinguishable from a label. The fill goes DOWN a rung (`face`, not `raised`) on purpose: a
    /// selected row rises out of the card and an input sinks into it, and the two must not read alike.
    func slateFieldPlate() -> some View {
        padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(SlateOverlayInk.well, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .strokeBorder(SlateOverlayInk.hairline, lineWidth: Slate.Metric.hairline)
            }
    }

    /// Lift a SELECTED row onto its plate: one surface rung up, hairline-bordered, at the card radius.
    /// Unselected costs nothing — no fill, no border, no reserved inset — so a list at rest is just text.
    func slateSelectionPlate(_ selected: Bool) -> some View {
        background(
            selected ? SlateOverlayInk.plate : .clear,
            in: .rect(cornerRadius: Slate.Metric.radiusCard),
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(SlateOverlayInk.hairline, lineWidth: Slate.Metric.cardBorderWidth)
            }
        }
    }
}

// MARK: - Clicking on a floating card

/// The card's DISMISS FLOOR: an invisible full-bleed button that closes the overlay when the click lands
/// beside the card.
///
/// A `Button` rather than a tap gesture on a `Color`, because this layer floats over an AppKit split
/// (`NSViewControllerRepresentable`) and a real control is the arrangement that is unambiguously hit-tested
/// there. It is also why the card carries its own hit barrier (see ``SlatePaperCard``): a floor that spans
/// the window would otherwise be reachable THROUGH the card's own inert body.
struct SlateClickTarget: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // A clear fill still takes hits once it has a content shape, and it lets the row draw itself.
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Make a finished card row CLICKABLE — as a real button wrapped AROUND the row, never as an invisible
    /// one laid over it.
    ///
    /// ⚠️ The overlay form is what broke hover-select on the palette and Open Quickly. A click target laid
    /// on TOP of a row is topmost for pointer purposes, so it eats the row's `onContinuousHover` along with
    /// its clicks, and the selection stops following the mouse — the one thing a palette must do. Wrapped,
    /// the hover modifier sits outside the button and sees every phase, while the button still owns the
    /// click. The row draws exactly as written either way: `.plain` adds no chrome, and the label keeps the
    /// row's own layout, plate and truncation.
    func slateRowButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { self }
            .buttonStyle(.plain)
    }
}

// MARK: - The keycap

/// A key the reader can press RIGHT NOW, drawn as a cap: the instrument voice on a faint plate with a
/// hairline edge.
///
/// `fixedSize` is load-bearing, not decoration. In an `HStack` a flexible `Text` will happily eat the width
/// its neighbours needed, and a long row title used to truncate the shortcut down to a bare "⌘" — the one
/// glyph on a row that CANNOT survive being shortened, because a shortcut with its key cut off is not a
/// shortcut. Fixed here, the cap is laid out first and the title takes what is left.
///
/// A chord is ONE cap ("⇧⌘L"), not a cap per glyph. The modifiers are not separate keys to find; they are
/// one gesture, and splitting them into a row of little boxes reads as four things to do.
///
/// ⚠️ THE ONE INSTRUMENT-VOICE READOUT SET IN THE SYSTEM FACE, and it is a rendering fact rather than a
/// preference. A chord's modifiers are SYMBOL glyphs (⇧ U+21E7, ⌘ U+2318, ⌥, ⌃), and a monospaced face
/// advances them by its cell rather than by the glyph — SF Mono, which is what `Slate.Typeface.instrument`
/// resolves to wherever the pinned mono is not installed, overlaps ⇧ into ⌘ into W until "⇧⌘W" is one
/// smear. Rendered side by side at 3× the three candidates split two-to-one: both proportional faces set
/// the chord cleanly and the mono one collides. macOS draws the same glyphs in the same face in every menu,
/// so this is also the register a reader already knows a shortcut in.
struct SlateKeycap: View {
    let label: String
    /// Whether the row this cap sits on is the selected one — the cap brightens WITH its row rather than
    /// staying at one fixed weight, so the eye tracks a single object down the list.
    var lit: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: Slate.Typeface.footnote, weight: .medium))
            .foregroundStyle(lit ? SlateOverlayInk.secondary : SlateOverlayInk.tertiary)
            .frame(height: Slate.Metric.heightControl)
            .padding(.horizontal, Slate.Metric.space2)
            .background(SlateOverlayInk.plate, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .strokeBorder(SlateOverlayInk.hairline, lineWidth: Slate.Metric.hairline)
            }
            .fixedSize()
    }
}

// MARK: - The one line a card is allowed to draw inside itself

/// The card's internal hairline — the ONE exception to "no chrome inside".
///
/// A card with a live search field at its top has a real boundary to mark: the results scroll UNDER that
/// field, and without a line the topmost row slides into the query text as it passes. The switcher never
/// faced this (it has no input), which is why the rule reads absolutely there. So: a hairline where content
/// MOVES past content, nowhere else — never to separate two static regions, which is what the system
/// `Divider` was doing in these overlays before and what made them read as stacked boxes.
///
/// Set in the theme's own divider ink rather than `Divider()`, whose system grey ignores the theme and lands
/// far too heavy on glass.
struct SlateCardSeparator: View {
    var body: some View {
        Rectangle()
            .fill(SlateOverlayInk.hairline)
            .frame(height: Slate.Metric.hairline)
    }
}

// MARK: - The card's own title

/// A floating card's title line: a REAL title — the system face at `title`/semibold in the reading ink —
/// with an optional trailing accessory, and no rule under it (the card has an edge already).
///
/// It spoke the instrument caps micro-label first (`CONNECT TO HOST`, mono, tracked wide) and was
/// photographed and rejected as "not modern": three caps-mono runs stacked on one form (title + two field
/// labels) read as engraving on an instrument panel, and no current macOS dialog (HIG Tahoe alerts/panels,
/// Linear, Raycast, Things) titles a form that way — they all set a short sentence-case noun phrase one
/// size up from the body. So the title is the ONE line on a card that outranks the content: `title` (15)
/// at semibold in `primary`, against `base`-in-`secondary` field labels — hierarchy by size and weight,
/// never by voice-switching into caps.
struct SlateCardTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(title)
                .font(.system(size: Slate.Typeface.title, weight: .semibold))
                .foregroundStyle(SlateOverlayInk.primary)
            Spacer(minLength: Slate.Metric.space2)
            trailing()
        }
        .padding(.horizontal, Slate.Metric.space4)
        .padding(.top, Slate.Metric.space4)
        .padding(.bottom, Slate.Metric.space3)
    }
}

extension SlateCardTitle where Trailing == EmptyView {
    /// A plain card title (no trailing accessory).
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
#endif
