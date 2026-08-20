// ViModeOverlay — the vi / copy-mode VIEW layer: the per-pane ``ViModePill`` (the persistent mode badge
// with a live repeat-count + an `×` exit) and the on-demand ``ViKeyHintBar`` (the `⌘/` reference card).
// Both are DRAWINGS over ``ViKeyHintPresentation`` (`SlopDeskClientCore`), which holds the three hint
// tables, the headings, the pill's wording and the reflow ladder.
//
// It rides the EXISTING pure copy-mode engine in ``TerminalViewModel``: both views read the OBSERVABLE
// mirrors (``TerminalViewModel/viVisualMode`` / ``viPendingCount`` / ``showViKeyHints`` /
// ``copyModeBadgeActive``), never the `@ObservationIgnored` `isCopyMode` flag the renderer's keyDown path
// reads, so they re-render reactively without ever touching the keyDown intercept's AttributeGraph hazard.
//
// The vi pill renders inside the terminal pane itself. slopdesk has NO persistent titlebar, so — like the
// status pills — it floats in the pane's TOP-TRAILING overlay region; the key-hint card floats along the
// pane BOTTOM. The leaf gates BOTH through ``PaneStatusPillPresentation``.
//
// THE CARD'S REFLOW IS ARITHMETIC, NOT A `ViewThatFits`. The rung — three columns, MOTION beside a
// stacked SELECT+SEARCH, or one tall column — is ``ViKeyHintPresentation/layout(forWidth:gap:columnWidth:)``,
// and this file supplies only the MEASUREMENT, the way `PhonePanelSheet` supplies `named:` to
// `PanelTabs.labelling`. `ViewThatFits` had to BUILD all three candidates to compare them and has no
// AppKit equivalent at all, so an AppKit card could only have re-derived the ladder from prose.
//
// `Slate.*` tokens ONLY — raw font / radius / colour literals fail `scripts/check-ds-leaks.sh`. No
// libghostty / Metal / VideoToolbox is touched (CLAUDE.md rule #6): plain SwiftUI chips driven by the
// pane model's observables.
//
// HONESTY (the "nothing is a dead key" rule) lives with the tables now: ``ViKeyHintPresentation`` lists
// ONLY the keys ``TerminalViewModel/handleCopyModeKey(_:)`` actually wires, and `ViKeyHintBarTests` pins
// it there.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

/// The vi-mode pill — the persistent badge shown in the pane's top-trailing overlay while
/// the pane is in vi / copy-mode. Faithful to the vi-mode spec's pill description: the current MODE label
/// (`VI` for plain scrollback navigation, `VISUAL` / `VISUAL LINE` / `VISUAL BLOCK` in a visual selection) + the
/// LIVE pending repeat-count digits (shown in the accent tone as the user types `5` before a motion) + an `×`
/// control that exits vi mode.
///
/// Reads the pane model's OBSERVABLE mirrors directly (``TerminalViewModel`` is `@Observable`), so the label
/// swaps and the count appears / clears reactively as ``TerminalViewModel/handleCopyModeKey(_:)`` mutates the
/// pure state and syncs the twins. The `×` calls ``onExit`` — the leaf wires it to the model's
/// ``TerminalViewModel/exitCopyMode()`` (the single exit seam, which also resets the count / visual mode / hint
/// bar), so the pill, the `Esc`/`q` keys, and a programmatic dismiss all converge on one state.
struct ViModePill: View {
    /// The pane's terminal model — the observable source of the mode label + the live repeat-count.
    let model: TerminalViewModel
    /// Called when the user clicks `×` to leave vi mode — the leaf routes it to ``TerminalViewModel/exitCopyMode()``.
    let onExit: () -> Void

    @State private var closeHover = false

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: .characterCursorIbeam)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Text(model.viVisualMode.pillLabelOrDefault)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .tracking(Slate.Typeface.pillTracking)
                .foregroundStyle(Slate.Text.primary)
                .lineLimit(1)
                .fixedSize()
            // The LIVE repeat-count: the accumulated digits the user typed before a motion (e.g. `5` before `j`).
            // Accent-toned + monospaced so the running count reads at a glance; absent when no count is pending.
            if let count = model.viPendingCount {
                Text(String(count))
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Slate.State.accent)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            closeButton
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(Slate.Surface.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .overlay(
            // Plain navigation wears the same subtle hairline as the read-only pill; a visual selection swaps in
            // the accent ring so the "I am selecting" state is unmistakable beside the count.
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .strokeBorder(ring, lineWidth: Slate.Metric.hairline),
        )
        .slateShadow(.chip)
        .animation(Slate.Anim.smallFade, value: model.viPendingCount)
        .animation(Slate.Anim.smallFade, value: model.viVisualMode)
        // Belt-and-suspenders Escape dismiss: the primary exit is the renderer's `keyDown` →
        // `exitCopyMode()` once the terminal is first responder (the routing now nudges focus there on arm).
        // This safety net — if Escape lands in the pill's responder chain instead of the surface — still leaves
        // vi/copy-mode via the SAME `onExit` seam the `×` fires. Which key route that is per platform is
        // ``View/slateCancelKey(perform:)``'s, not this file's.
        .slateCancelKey { onExit() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ViKeyHintPresentation.accessibilityLabel(mode: model.viVisualMode, count: model.viPendingCount),
        )
        .accessibilityHint(ViKeyHintPresentation.exitHelp)
    }

    /// The pill's outline — this renderer's two-line ink ladder over ``TerminalViewModel/VisualMode/isVisual``.
    private var ring: Color {
        // The lit ring is ``Slate/Opacity/accentRing`` (stage F batch P6) — the rung the find bar's
        // ON chip and its AppKit twin also spend, all three having been a raw `0.5` until then.
        model.viVisualMode.isVisual
            ? Slate.State.accent.opacity(Slate.Opacity.accentRing)
            : Slate.Line.subtle
    }

    /// The `×` exit glyph — LIGHTER than the label (the status-pill close-button idiom), with the subtle
    /// hover plate. Leaves vi mode via ``onExit``.
    private var closeButton: some View {
        Button(action: onExit) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.secondary)
                // ``Slate/Metric/glyphPlate`` — the one square every `×` on a pane chip takes.
                .frame(width: Slate.Metric.glyphPlate, height: Slate.Metric.glyphPlate)
                .background(
                    closeHover ? Slate.State.selected : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusSmall),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
        .slateHelp(ViKeyHintPresentation.exitHelp)
    }
}

// MARK: - Key-hint bar

/// The vi key-hint card — the on-demand reference toggled by `⌘/` while in vi mode
/// (off by default; ``TerminalViewModel/showViKeyHints`` drives its visibility, flipped by
/// ``TerminalViewModel/toggleViKeyHints()``). Floats along the pane BOTTOM and lists, in compact columns,
/// the keys slopdesk's copy-mode ACTUALLY wires. Pure presentation: no model reads, no state — every row
/// comes from ``ViKeyHintPresentation``.
struct ViKeyHintBar: View {
    var body: some View {
        // RESPONSIVE: the card re-flows to the pane's width instead of clipping. The RUNG is
        // ``ViKeyHintPresentation/layout(forWidth:gap:columnWidth:)``; ``ViKeyHintReflow`` is the SwiftUI
        // half — it hands that arithmetic the proposal and each column's intrinsic width, then places the
        // columns the rung asked for.
        ViKeyHintReflow(gap: Slate.Metric.space4, stackSpacing: Slate.Metric.space3) {
            ForEach(ViKeyHintColumn.allCases, id: \.self) { column in
                self.column(column)
            }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.vertical, Slate.Metric.space2)
        .background(Slate.Surface.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
        .slateShadow(.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ViKeyHintPresentation.barAccessibilityLabel)
    }

    /// Every key chip the card advertises — the honesty surface, forwarded so the test and the snapshot rig
    /// keep one address for it.
    static var advertisedKeys: [String] { ViKeyHintPresentation.advertisedKeys }

    /// One labelled column of hints (heading + rows).
    private func column(_ column: ViKeyHintColumn) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(column.heading)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .tracking(Slate.Typeface.pillTracking)
                .foregroundStyle(Slate.Text.tertiary)
                .padding(.bottom, Slate.Metric.space1)
            ForEach(column.hints) { hint in
                hintRow(hint)
            }
        }
    }

    /// One hint row — the key chip(s) followed by the description.
    private func hintRow(_ hint: ViKeyHint) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            ForEach(Array(hint.keys.enumerated()), id: \.offset) { _, key in
                keycap(key)
            }
            Text(hint.label)
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// A single key chip — mirrors the keyboard cheat sheet's `keycapChip` so the two reference surfaces read
    /// identically. The RANGE token (``ViKeyHintPresentation/separator``) renders as bare text (no plate) so
    /// `1 … 9` reads as a range rather than as three keys.
    @ViewBuilder
    private func keycap(_ key: String) -> some View {
        if key == ViKeyHintPresentation.separator {
            Text(key)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.tertiary)
        } else {
            Text(key)
                .font(.system(size: Slate.Typeface.small, weight: .medium, design: .monospaced))
                .foregroundStyle(Slate.Text.secondary)
                // ⚠️ 18 is UNNAMED — the keycap's minimum square, one rung under the control plate.
                // Proposed `Slate.Metric.keycap`.
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, Slate.Metric.space1)
                .background(Slate.Surface.face, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                        .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                )
        }
    }
}

/// The SwiftUI half of the card's width ladder: a `Layout` that asks
/// ``ViKeyHintPresentation/layout(forWidth:gap:columnWidth:)`` which rung the proposal affords, then places
/// its three column subviews into the slots ``ViKeyHintPresentation/groups(for:)`` names.
///
/// A `Layout` rather than a `GeometryReader` for one mechanical reason: a `Layout` is HANDED the proposal in
/// `sizeThatFits(proposal:…)`, while a `GeometryReader` reports the size it has already taken by expanding to
/// fill — which would stretch a card whose whole point is to hug its content. It measures each column with
/// `sizeThatFits(.unspecified)`, which is the intrinsic width the `fixedSize()` rows make honest, and that is
/// the `named:` closure's role in `PanelTabs.labelling`: the decision is shared, the measurement is the
/// framework's.
private struct ViKeyHintReflow: Layout {
    /// Between two side-by-side column slots.
    let gap: CGFloat
    /// Between two columns stacked into one slot.
    let stackSpacing: CGFloat

    /// NOT named `Cache`: a nested type with the associated type's own name shadows it, and the
    /// protocol witness then resolves circularly.
    struct ColumnCache {
        var columns: [CGSize]
    }

    func makeCache(subviews: Subviews) -> ColumnCache {
        ColumnCache(columns: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout ColumnCache, subviews: Subviews) {
        cache.columns = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ColumnCache) -> CGSize {
        guard subviews.count == ViKeyHintColumn.allCases.count else { return .zero }
        let slots = slots(for: proposal, cache: cache)
        let width = slots.reduce(CGFloat.zero) { $0 + $1.size.width } + gap * CGFloat(max(slots.count - 1, 0))
        let height = slots.reduce(CGFloat.zero) { Swift.max($0, $1.size.height) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ColumnCache,
    ) {
        guard subviews.count == ViKeyHintColumn.allCases.count else { return }
        var x = bounds.minX
        for slot in slots(for: proposal, cache: cache) {
            var y = bounds.minY
            for column in slot.columns {
                let index = Self.index(of: column)
                let size = cache.columns[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size),
                )
                y += size.height + stackSpacing
            }
            x += slot.size.width + gap
        }
    }

    /// One horizontal slot: the columns stacked into it, and the box they occupy.
    private struct Slot {
        let columns: [ViKeyHintColumn]
        let size: CGSize
    }

    /// The rung the proposal affords, resolved into placed boxes.
    ///
    /// An UNSPECIFIED width (the intrinsic-size query every parent makes before it proposes anything) reads
    /// as infinite, so the card reports its widest arrangement as its ideal — which is what makes a parent
    /// that has room give it room.
    private func slots(for proposal: ProposedViewSize, cache: ColumnCache) -> [Slot] {
        let rung = ViKeyHintPresentation.layout(
            forWidth: Double(proposal.width ?? .infinity), gap: Double(gap),
            columnWidth: { Double(cache.columns[Self.index(of: $0)].width) },
        )
        return ViKeyHintPresentation.groups(for: rung).map { group in
            let sizes = group.map { cache.columns[Self.index(of: $0)] }
            let width = sizes.reduce(CGFloat.zero) { Swift.max($0, $1.width) }
            let height = sizes.reduce(CGFloat.zero) { $0 + $1.height }
                + stackSpacing * CGFloat(max(group.count - 1, 0))
            return Slot(columns: group, size: CGSize(width: width, height: height))
        }
    }

    /// The subview index a column occupies — the `ForEach` builds them in ``ViKeyHintColumn/allCases`` order.
    private static func index(of column: ViKeyHintColumn) -> Int {
        ViKeyHintColumn.allCases.firstIndex(of: column) ?? 0
    }
}
#endif
