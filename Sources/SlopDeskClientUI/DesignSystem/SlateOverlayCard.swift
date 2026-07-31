// SlateOverlayCard — the shared vocabulary every FLOATING surface speaks: the glass card it is drawn on,
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
//   1. The SURFACE is glass with a rim and a cast shadow, never an opaque box. Glass alone all but vanishes
//      over a dark terminal, so the card adds the two things a real pane of glass has: a specular edge and a
//      shadow under it. Both are theme-directed — a light rim reads as a highlight on a dark theme and as
//      nothing at all on a light one, so on a light theme the edge darkens instead.
//   2. NO chrome inside it. No `Divider` between regions, no grouped-`Form` insets, no `List` section fills.
//      A card that is already a distinct object does not need internal boxes to say where it ends; spacing
//      carries the structure. This is the move that makes the surfaces look related rather than merely tinted.
//   3. A selected row is a PLATE — one surface rung up, hairline-bordered — and its title goes HEAVIER.
//      Never coloured: importance is light and weight, not hue (DECISIONS §git-line-two-registers).
//   4. A key you can press right now is drawn as a KEYCAP in the instrument voice. A bare glyph run does not
//      say "press this"; a cap does.
//
// `Slate` supplies every dimension — raw font/radius/height literals fail `scripts/check-ds-leaks.sh`. No
// AppKit, so this compiles for iOS with the rest of `SlopDeskClientUI`.

#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Letting a sheet get out of its card's way

/// Strip the presenting SHEET WINDOW down to nothing so the glass card inside it is the only surface.
///
/// ⚠️ `.presentationBackground(.clear)` DOES NOT DO THIS ON macOS. It was tried first and photographed: the
/// palette rendered as a card nested inside a second, larger, white rounded panel — because the modifier
/// clears the SwiftUI-drawn background while the sheet's `NSWindow` keeps painting its own opaque ground and
/// casting its own shadow. Nothing reachable from SwiftUI turns those off, so this reaches the window itself.
/// Keep `.presentationBackground(.clear)` alongside it: that one removes the SwiftUI layer, this one the
/// window, and only both together leave the card alone.
///
/// Safe by construction: the representable lives INSIDE the sheet's content, so `view.window` is the sheet's
/// own window and never the workspace's. A nil window (torn down mid-async) is a no-op, not a crash.
#if canImport(AppKit)
private struct ClearSheetWindow: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        // The window is not yet attached while `makeNSView` runs — one runloop hop and it is.
        DispatchQueue.main.async { strip(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async { strip(nsView.window) }
    }

    private func strip(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        // The card casts its own shadow; the window's would sit at the sheet's rectangular bounds, a shadow
        // around nothing.
        window.hasShadow = false
    }
}
#endif

extension View {
    /// Present this content as a FLOATING card rather than a filled sheet panel: the sheet contributes only
    /// its geometry and modality. Pairs with ``SlateGlassCard`` — see ``ClearSheetWindow`` for why one
    /// modifier is not enough.
    func slateClearSheetWindow() -> some View {
        #if canImport(AppKit)
        background(ClearSheetWindow().allowsHitTesting(false))
        #else
        self
        #endif
    }
}

// MARK: - The card surface

/// The floating card's SURFACE: Liquid Glass with a specular rim and a cast shadow, or a plain material when
/// the user asked for less transparency. A modifier rather than a wrapper view because the two branches must
/// land on the SAME geometry — an `if/else` around the whole card would hand SwiftUI two view identities to
/// cross-fade between when the accessibility setting flips.
struct SlateGlassCard: ViewModifier {
    /// Custom glass must self-gate the accessibility setting (the native-chrome research's pitfall list):
    /// with Reduce Transparency on, the card takes a plain opaque material instead.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusPanel, style: .continuous)
    }

    /// The lit edge. Glass is legible at its BOUNDARY — over a dark terminal the blur alone leaves a grey
    /// slab, and the rim is what says "pane of glass". Directed by theme: a light theme gets a darkened
    /// edge, where a white one would disappear.
    private var rim: Color {
        Slate.theme.isLight ? .black.opacity(0.10) : .white.opacity(0.14)
    }

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(.regularMaterial, in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        }
        .overlay { shape.strokeBorder(rim, lineWidth: Slate.Metric.hairline) }
        .shadow(color: Slate.State.shadow, radius: Slate.Metric.panelShadowRadius, y: Slate.Metric.panelShadowY)
    }
}

extension View {
    /// Draw this content as a floating glass card (see ``SlateGlassCard``).
    func slateGlassCard() -> some View { modifier(SlateGlassCard()) }

    /// Sink an editable field into its plate: the pane face, ringed by a hairline, at the small radius.
    ///
    /// A card carries no `Form`, so nothing else says "you may type here" — on glass an unringed field is
    /// indistinguishable from a label. The fill goes DOWN a rung (`face`, not `raised`) on purpose: a
    /// selected row rises out of the card and an input sinks into it, and the two must not read alike.
    func slateFieldPlate() -> some View {
        padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(Slate.Surface.face, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline)
            }
    }

    /// Lift a SELECTED row onto its plate: one surface rung up, hairline-bordered, at the card radius.
    /// Unselected costs nothing — no fill, no border, no reserved inset — so a list at rest is just text.
    func slateSelectionPlate(_ selected: Bool) -> some View {
        background(
            selected ? Slate.Surface.raised : .clear,
            in: .rect(cornerRadius: Slate.Metric.radiusCard),
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(Slate.Line.card, lineWidth: Slate.Metric.cardBorderWidth)
            }
        }
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
struct SlateKeycap: View {
    let label: String
    /// Whether the row this cap sits on is the selected one — the cap brightens WITH its row rather than
    /// staying at one fixed weight, so the eye tracks a single object down the list.
    var lit: Bool = false

    var body: some View {
        Text(label)
            .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .medium))
            .foregroundStyle(lit ? Slate.Text.secondary : Slate.Text.tertiary)
            .frame(height: Slate.Metric.heightControl)
            .padding(.horizontal, Slate.Metric.space2)
            .background(Slate.State.hover, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline)
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
            .fill(Slate.Line.divider)
            .frame(height: Slate.Metric.hairline)
    }
}

// MARK: - The card's own title

/// A floating card's title line: the name of the surface, quietly, with an optional trailing accessory.
///
/// This replaced `SlateSheetHeader`, which spoke the system `.headline` above a `Divider` because it
/// belonged to a native dialog; that file is deleted, along with its `SlateSheetFooter` sibling, now that
/// nothing presents a native-voiced sheet. A glass card is workspace furniture, so its title takes the caps
/// micro-label the rail uses — it names the surface without competing with the row the user is actually
/// reading, and there is no rule under it, because the card has an edge already.
///
/// ⚠️ It is ONE RUNG UP from a section header, and that gap is not decoration. The first cut set both at
/// `small`/`tertiary` and was photographed: on the connect card, `CONNECT TO HOST` and the `HOST` label
/// under it were the same size, ink and voice, stacked four points apart — the card's name read as a third
/// field label. So the title takes `footnote` in `secondary` while section headers stay `small` in
/// `tertiary`, and it carries the air beneath it that separates a name from a list.
struct SlateCardTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(title.uppercased())
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .medium))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.Text.secondary)
            Spacer(minLength: Slate.Metric.space2)
            trailing()
        }
        .padding(.horizontal, Slate.Metric.space4)
        .padding(.top, Slate.Metric.space3)
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
