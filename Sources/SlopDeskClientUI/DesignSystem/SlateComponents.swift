// SlateComponents — the reusable chrome component kit on the token layer.
//
// Small, composable pieces factored out of the chrome so every surface stays consistent and new views are
// quick to assemble: the terminal-dialect `StatusGlyph` instrument, a key/value row, a
// pill/badge, and an `.slateCard()` surface modifier.
// All built on `Slate.*` tokens + `SlateTheme`. See also SlateControls (`SlatePlateButton`), SlateRow
// (`SlateListRow` / `SlateSectionHeader`) and SlateMonogram (the host-identity plate).

#if canImport(SwiftUI)
import SwiftUI

/// The AGENT status instrument, spoken as TEXT in the terminal's own dialect: each reading is a
/// single character in the instrument (mono) face, centred in a fixed 16pt box — the chrome's status
/// voice IS the pane's voice, exactly the glyphs a CLI would print:
///   • `resting`  → `·` muted (an idle prompt — no colour spent);
///   • `awaiting` → `?` bold in the act-now amber (answer me);
///   • `done`     → `●` (the quiet unread-finish dot, as the character a CLI would print).
/// Mounted where ONE pane's agent state gets a compact readout (the iOS toolbar, the Peek & Reply
/// header). The sidebar rows speak the same states through the trailing mark's hue instead
/// (``StatusPresentation/statusDot(working:badge:)``) — so no glyph column rides the rail.
///
/// ⚠️ `working` is the ONE reading that is not typed: it mounts the rail's own ``AgentSpinner``, the
/// drawn braille cell. It used to be a typed pulse (`· ✢ ✳ ✶ ✻ ✽` breathing out and back) and the two
/// surfaces then said the same thing two different ways — one pane could be spinning in the sidebar
/// and blooming in the header at the same instant. There is exactly one working mark in this app now,
/// and every mount of it turns in unison off the same wall clock.
/// Pure SwiftUI — no video/capture (hang-safety #6).
struct StatusGlyph: View {
    enum Reading: Equatable {
        case resting
        case working
        case awaiting
        case done
    }

    let reading: Reading
    let tint: Color

    /// The fixed glyph box — star / dot advance widths differ, so the frame pins layout while
    /// frames (or states) swap.
    static let box: CGFloat = 16

    var body: some View {
        content
            .frame(width: Self.box, height: Self.box)
    }

    @ViewBuilder private var content: some View {
        switch reading {
        case .resting: glyph("·", weight: .regular)
        // The rail's own cell, at the rail's own size: a 16pt text box carries a 14pt mark the same
        // way the rail column does, and using the identical view is what keeps the two surfaces from
        // ever drifting apart on the state a user watches longest.
        case .working: AgentSpinner(ink: tint)
        case .awaiting: glyph("?", weight: .bold)
        case .done: glyph("●", weight: .regular)
        }
    }

    private func glyph(_ text: String, weight: Font.Weight) -> some View {
        Text(text)
            .font(Slate.Typeface.instrument(Slate.Typeface.body, weight: weight))
            .foregroundStyle(tint)
            .fixedSize()
    }
}

/// The quiet ZERO-STATE line for a list surface — one tertiary-ink body line, centred, with
/// breathing room. Every "no results / no matches / nothing yet" in a palette, search or popover
/// list is this one object (round 13 — four surfaces had hand-rolled the identical block), so the
/// app's empty voice stays text-only and uniform: no illustration, no glyph, no card.
/// The full-pane empty state with its display glyph is a different intent — ``SlateEmptyState``.
struct SlateNoResultsLine: View {
    let message: String
    /// Overlay cards pass their own neutral world's ink (`SlateOverlayInk.tertiary`).
    var ink: Color = Slate.Text.tertiary
    /// The vertical breathing room — the roomy default for a results pane; a dense popover
    /// passes a tighter rung.
    var inset: CGFloat = Slate.Metric.space4

    var body: some View {
        Text(message)
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, inset)
    }
}

/// A "card" surface: element background, hairline border, rounded corners. The floating-card idiom
/// for inset content (command output, detail boxes). Use `.slateCard()` on any view.
private struct SlateCardModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Slate.Line.subtle, lineWidth: 1),
            )
    }
}

extension View {
    /// The CHROME panel's text-input plate: the hover fill every panel search field already stood
    /// on, plus the boundary it never had. The overlay family's ``slateFieldPlate()`` is this one's
    /// twin — it has ringed its fields all along, on the reasoning that an unringed field is
    /// indistinguishable from a label, and the panels are what never got the same treatment.
    ///
    /// The fill alone is `quinarySystemFill` — 1.02:1 against the cream ground, which is to say the
    /// field had no perceivable edge at all and read as a gap in the panel rather than a place to
    /// type. The border is what makes it a field. It is deliberately kept LIGHT (1.99:1, user-chosen
    /// 2026-08-08 over a heavier edge that clears the 3.0 non-text floor): the control is still
    /// identified by its own magnifier and placeholder, both well above the reading floor, so the
    /// edge reinforces a boundary rather than carrying it alone.
    ///
    /// Four call sites shared this plate by hand before it was one modifier; the button plates
    /// (``SlatePlateGroup``) deliberately do NOT take it — a button group is not somewhere to type.
    func slateChromeFieldPlate() -> some View {
        let shape = RoundedRectangle(cornerRadius: Slate.Metric.radiusControl, style: .continuous)
        return background(Slate.State.hover, in: shape)
            .overlay { shape.strokeBorder(Slate.Line.field, lineWidth: Slate.Metric.hairline) }
    }

    /// Wraps the view in a card surface (element fill + hairline border + rounded corners).
    func slateCard(
        radius: CGFloat = Slate.Metric.radiusControl,
        fill: Color = Slate.Surface.raised,
    ) -> some View {
        modifier(SlateCardModifier(radius: radius, fill: fill))
    }
}
#endif
