// PaneSwitcherOverlay — the ⌃⇥ switcher's face: a floating glass card listing the session's panes in
// MOST-RECENTLY-USED order with the provisional highlight marked.
//
// Presented as a plain always-mounted `.overlay` rather than a `.sheet`, unlike every other surface in
// `OverlayHostView`. A sheet is the wrong instrument here: it animates in over ~0.3s and takes key focus,
// but this overlay's whole lifetime is the length of a held ⌃ — often under 200ms — and stealing focus
// mid-gesture would break the `flagsChanged` release that commits it. It renders nothing when the store's
// `paneSwitcher` is nil, so at rest it costs a branch.
//
// It is a READOUT, not a control: the dispatcher owns the gesture (open / step / commit / cancel), and this
// view has no gestures, no buttons, and no state of its own. Clicking through it is impossible because it
// never accepts hits.
//
// A row is ONE roomy line — the pane's identity, a quiet note for what differs, and the ⌘-number set in a
// KEYCAP, because that number is a key the reader can press right now and a bare glyph did not say so.
// Nothing here is coloured: the highlight is a lifted plate and a heavier title, the house rule that a
// readout marks importance with LIGHT and WEIGHT rather than hue (DECISIONS §git-line-two-registers). The
// row is read at a glance for the length of a held modifier, so it rides `heightRowTall` — a 32pt list
// beat is for scanning, not glancing.
//
// The project heads a section ONLY when the list actually spans more than one; with a single project the
// card IS that project, and a header there is a label on a box with one thing in it.
//
// The card must read as GLASS and not as a grey box: `glassEffect` alone all but vanishes over a dark
// terminal, so the surface adds the two things a physical pane of glass has — a specular RIM at the edge
// and a cast SHADOW under it. Both are theme-directed (a light rim on a dark theme is a highlight; on a
// light theme it would be invisible, so the rim darkens instead).
//
// `Slate` supplies GEOMETRY and INK; raw font/radius/height literals fail `scripts/check-ds-leaks.sh`. No
// AppKit, so this compiles for iOS with the rest of `SlopDeskClientUI`, where the switcher never opens.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct PaneSwitcherOverlay: View {
    let store: WorkspaceStore

    /// Custom glass must self-gate the accessibility setting (the native-chrome research's pitfall list):
    /// with Reduce Transparency on, the card takes a plain opaque material instead.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let switcher = store.paneSwitcher {
            // The container's size, not the card's: the card is measured AGAINST the window
            // (``PaneSwitcherMetrics``), so it needs to see it. `GeometryReader` fills the overlay's
            // proposed space, and the card is re-centred inside it.
            GeometryReader { proxy in
                card(PaneSwitcherRowsBuilder.items(for: switcher, store: store), in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A readout never takes hits: the gesture lives entirely on the keyboard, and swallowing a
            // click here would strand a user who reached for the workspace behind it.
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func card(_ items: [PaneSwitcherItem], in container: CGSize) -> some View {
        // A session with more panes than the window is tall must not draw a card taller than its host.
        // The rows scroll instead, and the highlight is kept in view as ⇥ walks past the fold.
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item.content {
                        case let .section(name):
                            SectionHeader(name: name, isFirst: item.id == 0)
                        case let .row(row):
                            RowView(row: row).id(row.id)
                        }
                    }
                }
                .padding(Slate.Metric.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: highlighted(items)) { _, id in
                guard let id else { return }
                withAnimation(Slate.Anim.smallFade) { scroller.scrollTo(id, anchor: .center) }
            }
        }
        .frame(width: PaneSwitcherMetrics.width(container: container.width))
        .frame(maxHeight: PaneSwitcherMetrics.maxHeight(container: container.height))
        // The card is only as tall as its rows until it hits that ceiling — `fixedSize` on the vertical
        // axis stops the ScrollView claiming the whole allowance for four rows.
        .fixedSize(horizontal: false, vertical: true)
        .modifier(SwitcherSurface(reduceTransparency: reduceTransparency))
    }

    private func highlighted(_ items: [PaneSwitcherItem]) -> PaneID? {
        items.lazy.compactMap { item -> PaneSwitcherRow? in
            if case let .row(row) = item.content { row } else { nil }
        }.first(where: \.isHighlighted)?.id
    }
}

/// The card's SURFACE: Liquid Glass with a specular rim and a cast shadow, or a plain material when the
/// user asked for less transparency. Split into a modifier because the two branches must land on the same
/// geometry — an `if/else` around the whole card would give SwiftUI two view identities to cross-fade.
private struct SwitcherSurface: ViewModifier {
    let reduceTransparency: Bool

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
        .shadow(color: Slate.State.shadow, radius: 12, y: 4)
    }
}

/// A project, said once over the run of rows that share it — emitted only when the list spans more than
/// one project (``PaneSwitcherRowsBuilder/items(_:)`` decides). Plain sentence case in the quiet register:
/// this is a divider that happens to carry a name, not a label demanding to be read.
private struct SectionHeader: View {
    let name: String
    /// The first header sits flush against the card's own padding; later ones open a gap above so the
    /// runs read as separate groups rather than one long list.
    let isFirst: Bool

    var body: some View {
        Text(name)
            .font(.system(size: Slate.Typeface.footnote, weight: .medium))
            .foregroundStyle(Slate.Text.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.top, isFirst ? Slate.Metric.space1 : Slate.Metric.space4)
            .padding(.bottom, Slate.Metric.space2)
    }
}

/// One row: identity, the quiet remainder, and the ⌘-key.
private struct RowView: View {
    let row: PaneSwitcherRow

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(row.title)
                .font(.system(
                    size: Slate.Typeface.body, weight: row.isHighlighted ? .medium : .regular,
                ))
                .foregroundStyle(row.isHighlighted ? Slate.Text.primary : Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let note = row.note {
                Text(note)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    // The note is the FIRST thing to go when the line runs out — it is the remainder, and
                    // a squeezed remainder is worth less than an intact identity.
                    .layoutPriority(-1)
            }
            Spacer(minLength: Slate.Metric.space3)
            Keycap(number: row.number, lit: row.isHighlighted)
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRowTall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            row.isHighlighted ? Slate.Surface.raised : .clear,
            in: .rect(cornerRadius: Slate.Metric.radiusCard),
        )
        .overlay {
            if row.isHighlighted {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(Slate.Line.card, lineWidth: Slate.Metric.cardBorderWidth)
            }
        }
    }
}

/// The ⌘-number as a KEY. `fixedSize` is load-bearing, not decoration: in an `HStack` a flexible `Text`
/// will happily eat the width its neighbours needed, and a long title used to truncate the shortcut down
/// to a bare "⌘" — the one glyph on the row that CANNOT survive being shortened, because a shortcut with
/// its number cut off is not a shortcut. Fixed here, the keycap is laid out first and the title takes what
/// is left. Absent past ⌘9, where the chord does not exist (the app binds ⌘1–9 only) — an unpressable key
/// drawn on a row is a lie.
private struct Keycap: View {
    let number: Int
    let lit: Bool

    var body: some View {
        if number <= PaneSwitcherRowsBuilder.highestShortcut {
            Text("⌘\(number)")
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
}
#endif
