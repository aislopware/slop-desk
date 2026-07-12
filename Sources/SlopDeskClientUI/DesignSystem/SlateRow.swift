// SlateRow — THE list-row shell (MERIDIAN C2) + the sidebar section header.
//
// `SlateListRow` is the ONE row anatomy every sidebar/list row shares (the Raycast model): an optional
// leading accessory, a title slot, an optional instrument-voice subtitle, and ordered trailing accessories.
// One shell = one set of constants, so a row can never drift off the system:
//   height    → the ladder: `heightRow` single-line, `heightRowTall` with a subtitle
//   padding   → horizontal `space3`
//   idle      → transparent;  hover → `Slate.State.hover` flat plate
//   active    → a RAISED card: `Slate.Surface.raised` fill + 1px `Slate.Line.card` hairline.
//               NO shadow — at-rest depth is the surface ladder, never a cast shadow (MERIDIAN L5).
// The subtitle always speaks the INSTRUMENT voice (MERIDIAN L2: it is data — cwd / git line / host app —
// not prose), so no caller can restyle it.
// `SlateTabRow` and future host/window rows build on this shell.

#if canImport(SwiftUI)
import SwiftUI

/// One list row: `leading` accessory + `title` slot (+ optional instrument `subtitle`) + PER-LINE trailing
/// accessories. `titleTrailing` sits on line 1 (right of the title); `subtitleTrailing` sits on the compact
/// line-2 subtitle (right of the cwd/git line) and renders ONLY when a subtitle exists. Both builders receive
/// the live hover flag so a caller can swap clusters under hover (e.g. status meta ↔ close button) without
/// owning its own hover state. The trailing clusters are split per line (rather than ONE full-height centered
/// column) so a two-line row can keep the running-process label pinned to line 1 and the status badge alone on
/// the compact line 2 — a single accessory would otherwise float vertically between the two lines.
struct SlateListRow<
    Leading: View, Title: View, TitleTrailing: View, SubtitleTrailing: View, TrailingOverlay: View,
>: View {
    /// Active/selected treatment — the raised card. Default resting row.
    var active = false
    /// The muted truncating-middle second line (cwd / git line / host app). `nil`/empty ⇒ single-line row.
    var subtitle: String?
    /// An optional COLOURED rendering of the same second line — used by the git line to tint its status
    /// tokens (`↑ahead` / `↓behind` / `· N changed`) while the branch inherits the row's muted secondary
    /// (MERIDIAN "colour = state, not ornament"). When present it renders in place of ``subtitle`` but keeps
    /// the SAME instrument font + secondary default, so a caller can only supply per-run COLOUR, never restyle
    /// the voice. Its plain text MUST equal ``subtitle`` (the height/search/truncation still key on that).
    var subtitleColored: AttributedString?
    /// Tap action for the whole row. `nil` ⇒ no-op (a presentation-only row).
    var onTap: (() -> Void)?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let title: () -> Title
    /// Line-1 trailing cluster (right of the title) — receives the hover flag.
    @ViewBuilder let titleTrailing: (_ hovering: Bool) -> TitleTrailing
    /// Line-2 trailing cluster (right of the subtitle) — rendered ONLY when a subtitle exists; receives hover.
    @ViewBuilder let subtitleTrailing: (_ hovering: Bool) -> SubtitleTrailing
    /// A FULL-HEIGHT trailing overlay, vertically CENTERED over the whole row (both lines) at the same trailing
    /// inset as the content — the home for a hover-revealed close `×`, which must sit centered on the row
    /// rather than pinned to either line's baseline. Receives the hover flag; draw nothing (EmptyView) for a
    /// row with no such affordance.
    @ViewBuilder let trailingOverlay: (_ hovering: Bool) -> TrailingOverlay

    /// EXTERNAL hover, for a row whose events are owned by an AppKit overlay (the host-windows rail's
    /// drag source swallows the events SwiftUI `.onHover` needs — the overlay senses hover with its own
    /// tracking area and drives the row through this instead). `nil` (every other caller) keeps the
    /// shell's own `.onHover`.
    var hoverOverride: Bool?

    @State private var hovering = false

    private var isHovering: Bool { hoverOverride ?? hovering }

    private var hasSubtitle: Bool { !(subtitle ?? "").isEmpty }

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Slate.Metric.space2) {
                    title()
                    Spacer(minLength: Slate.Metric.space2)
                    titleTrailing(isHovering)
                }
                if hasSubtitle {
                    HStack(spacing: Slate.Metric.space2) {
                        // The COLOURED git line (when supplied) renders in place of the plain string — same
                        // instrument font, same secondary default, only per-run status colour differs.
                        (subtitleColored.map(Text.init) ?? Text(subtitle ?? ""))
                            .font(Slate.Typeface.instrument(Slate.Typeface.small))
                            .foregroundStyle(Slate.Text.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Slate.Metric.space2)
                        subtitleTrailing(isHovering)
                    }
                }
            }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: hasSubtitle ? Slate.Metric.heightRowTall : Slate.Metric.heightRow)
        // The close `×` (and any future full-height affordance) rides a CENTERED trailing overlay — pinned to
        // the same trailing inset as the content, vertically centered over BOTH lines so it never floats off a
        // single line's baseline (the per-line clusters above fade out under hover to clear the way for it).
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
    /// A row with no leading accessory (the sidebar tab rows — name-first, no icon), with per-line trailing
    /// clusters: `titleTrailing` on line 1 (running-process label / hover close) and `subtitleTrailing` on the
    /// compact line 2 (the status badge).
    init(
        active: Bool = false,
        subtitle: String? = nil,
        subtitleColored: AttributedString? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder titleTrailing: @escaping (_ hovering: Bool) -> TitleTrailing,
        @ViewBuilder subtitleTrailing: @escaping (_ hovering: Bool) -> SubtitleTrailing,
        @ViewBuilder trailingOverlay: @escaping (_ hovering: Bool) -> TrailingOverlay,
    ) {
        self.init(
            active: active, subtitle: subtitle, subtitleColored: subtitleColored, onTap: onTap,
            leading: { EmptyView() }, title: title, titleTrailing: titleTrailing,
            subtitleTrailing: subtitleTrailing, trailingOverlay: trailingOverlay,
        )
    }
}

/// A sidebar section header: uppercase, tertiary, small — with an optional trailing accessory (e.g. "+").
struct SlateSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
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
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.top, Slate.Metric.space2)
        .padding(.bottom, Slate.Metric.space1)
    }
}

extension SlateSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
#endif
