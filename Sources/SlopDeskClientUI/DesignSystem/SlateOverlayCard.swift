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
//   1. The SURFACE is PAPER: the ground's own cream, opaque, cut at the island's corner, edged by the
//      island's hairline and dropped on a real shadow. It was Liquid Glass until 2026-08-08, and ONE
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

/// The floating card's SURFACE: PAPER — the ground's cream, opaque, at the island's own corner, edged by
/// the island's hairline and dropped on the deepest rung of the shadow ladder.
///
/// Nothing here is appearance-directed any more. The app has ONE polarity (`SlateAppearancePin`), one
/// ground and one glass, so a card that summoned itself over the workspace is either the ground raised or
/// the glass repeated — and the glass repeated is invisible, because a card lands centred, which is where
/// the island already is. The cream reverses that: ~13:1 against the canvas it covers, and against the
/// ground at the card's edges the hairline and the cast shadow carry it, exactly as they carry the island
/// itself. No material, no rim highlight, no Reduce-Transparency branch to keep honest.
struct SlatePaperCard: ViewModifier {
    /// Panel-scale (a summoned card) or row-scale (a notification). A corner is read against the surface
    /// it cuts, so the two do not share a number: the palette is a window-scale object and takes the
    /// island's own 26; a 320 × 46 notification takes the compact island's 10, one rung above the corner
    /// Tahoe puts on a selected row.
    enum Scale {
        case panel
        case row

        var radius: CGFloat {
            switch self {
            case .panel: Slate.Metric.islandRadius
            case .row: Slate.Metric.islandRadiusCompact
            }
        }
    }

    var scale: Scale = .panel

    /// Whether the card carries the click barrier below. The MODAL cards (which float on a full-bleed
    /// dismiss floor) need it; a card that is ITSELF a button — the notification card, whose whole body
    /// is its jump action — must NOT, because a `Button` in the background outranks the wrapping button
    /// for any click the content declines, and the card's own action would silently stop firing.
    var hitBarrier = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: scale.radius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(Slate.Surface.field, in: shape)
            .overlay { shape.strokeBorder(Slate.Line.divider, lineWidth: Slate.Metric.hairline) }
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

extension View {
    /// Draw this content as a floating paper card (see ``SlatePaperCard``). `hitBarrier: false` is for a
    /// card whose whole body is already a button (the notification card) — see the modifier's note.
    func slatePaperCard(scale: SlatePaperCard.Scale = .panel, hitBarrier: Bool = true) -> some View {
        modifier(SlatePaperCard(scale: scale, hitBarrier: hitBarrier))
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
