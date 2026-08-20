// SlateRow — THE list-row shell (MERIDIAN C2) + the sidebar section header.
//
// `SlateListRow` is the ONE row anatomy every sidebar/list row shares (the Raycast model): an optional
// leading accessory, a title slot, and a trailing accessory cluster — on a SINGLE fixed-height line.
// One shell = one set of constants, so a row can never drift off the system:
//   height    → `heightRow` — every row, always; a row never grows a second line, so the list's
//               rhythm is a constant beat and state changes swap TEXT, not geometry
//   padding   → horizontal `space3`
//   idle      → transparent;  hover → `Slate.State.hover` flat plate
//   active    → a RAISED card: `Slate.Surface.raised` fill + 1px `Slate.Line.card` hairline.
//               NO shadow — at-rest depth is the surface ladder, never a cast shadow (MERIDIAN L5).
// Generic list surfaces (keybindings editor, popover rows) build on this shell. The sidebar TAB row
// (`SlateTabRow`) does NOT — it is the standalone otty `TabsPanelRowView` port with its own measured
// height/inset/shadow.

#if os(iOS)
import SlopDeskSlate
import SwiftUI

/// One list row: `leading` accessory + `title` slot + trailing accessories, on one fixed-height line.
/// The `titleTrailing` builder receives the live hover flag so a caller can swap clusters under hover
/// (e.g. status meta ↔ close button) without owning its own hover state.
struct SlateListRow<Leading: View, Title: View, TitleTrailing: View, TrailingOverlay: View>: View {
    /// Active/selected treatment — the raised card. Default resting row.
    var active = false
    /// Tap action for the whole row. `nil` ⇒ no-op (a presentation-only row).
    var onTap: (() -> Void)?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let title: () -> Title
    /// Trailing cluster (right of the title) — receives the hover flag.
    @ViewBuilder let titleTrailing: (_ hovering: Bool) -> TitleTrailing
    /// A trailing overlay at the same trailing inset as the content — the home for a hover-revealed
    /// close `×` (the trailing cluster fades out under hover to clear the way for it). Receives the
    /// hover flag; draw nothing (EmptyView) for a row with no such affordance.
    @ViewBuilder let trailingOverlay: (_ hovering: Bool) -> TrailingOverlay

    /// EXTERNAL hover, for a row whose events are owned by an AppKit overlay (the host-windows rail's
    /// drag source swallows the events SwiftUI `.onHover` needs — the overlay senses hover with its own
    /// tracking area and drives the row through this instead). `nil` (every other caller) keeps the
    /// shell's own `.onHover`.
    var hoverOverride: Bool?

    @State private var hovering = false

    private var isHovering: Bool { hoverOverride ?? hovering }

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            leading()
            title()
            Spacer(minLength: Slate.Metric.space2)
            titleTrailing(isHovering)
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRow)
        .overlay(alignment: .trailing) {
            trailingOverlay(isHovering)
                .padding(.trailing, Slate.Metric.space3)
        }
        .background(rowBackground, in: .rect(cornerRadius: Slate.Metric.radiusTab))
        .overlay { if active { RoundedRectangle(cornerRadius: Slate.Metric.radiusTab).strokeBorder(
            Slate.Line.card,
            lineWidth: Slate.Metric.cardBorderWidth,
        ) } }
        .contentShape(.rect)
        .onTapGesture { onTap?() }
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: isHovering)
        .animation(Slate.Anim.smallFade, value: active)
    }

    private var rowBackground: Color {
        if active { Slate.Surface.raised }
        else if isHovering { Slate.State.hover }
        else { .clear }
    }
}

extension SlateListRow where Leading == EmptyView {
    /// A row with no leading accessory (the sidebar tab rows — name-first, no icon).
    init(
        active: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder titleTrailing: @escaping (_ hovering: Bool) -> TitleTrailing,
        @ViewBuilder trailingOverlay: @escaping (_ hovering: Bool) -> TrailingOverlay,
    ) {
        self.init(
            active: active, onTap: onTap,
            leading: { EmptyView() }, title: title, titleTrailing: titleTrailing,
            trailingOverlay: trailingOverlay,
        )
    }
}

/// A sidebar section header: uppercase, tertiary, small — with an optional trailing accessory (e.g. "+").
struct SlateSectionHeader<Accessory: View>: View {
    let title: String
    /// A qualifier that belongs to the TITLE — drawn immediately after it, one ink quieter, in the
    /// same engraved register. Distinct from ``accessory``, which is pinned to the far trailing edge
    /// where a CONTROL belongs: a qualifier sent there stops reading as part of the heading the wider
    /// the surface gets, until at panel width it is a lone readout marooned across an empty rule.
    var caption: String?
    let accessory: Accessory

    init(_ title: String, caption: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.caption = caption
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 0) {
            // MERIDIAN L2: caps micro-labels speak the INSTRUMENT voice — mono + wide tracking, the
            // "engraved on the tool" register that marks taxonomy against the prose rows below.
            Text(title.uppercased())
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.State.header)
            if let caption {
                Text(caption)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .regular))
                    .foregroundStyle(Slate.Text.tertiary)
                    .lineLimit(1)
                    .padding(.leading, Slate.Metric.space2)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.top, Slate.Metric.space2)
        .padding(.bottom, Slate.Metric.space1)
    }
}

extension SlateSectionHeader where Accessory == EmptyView {
    init(_ title: String, caption: String? = nil) {
        self.init(title, caption: caption) { EmptyView() }
    }
}
#endif
