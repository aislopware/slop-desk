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
// A row is TWO REGISTERS stacked: the pane's identity, and under it the PLACE that identity lives in —
// its project, then the sub-path it strayed into. Beside them the ⌘-number set in a KEYCAP, because that
// number is a key the reader can press right now and a bare glyph did not say so. Nothing here is
// coloured: the highlight is a lifted plate and a heavier title, the house rule that a readout marks
// importance with LIGHT and WEIGHT rather than hue (DECISIONS §git-line-two-registers).
//
// Why the second line and not a section header: see ``PaneSwitcherRows``. Panes interleave across projects
// in a recency ring, so a header per run degenerates into a caption per row. It also gives the card the
// presence a bare one-line list lacked — the same six panes now read as an object rather than a strip.
// The place line uses WEIGHT to separate its halves as well: the project is set a shade heavier than the
// path under it, so a run of rows from one repo still lines up down the card without a header saying so.
//
// The card's SURFACE, its selection plate and its keycap now live in ``SlateOverlayCard`` — this card is
// where all three were designed, and once it was the surface the user wanted, every other floating overlay
// adopted them. Read that file for why glass needs a rim and a shadow to survive a dark terminal.
//
// `Slate` supplies GEOMETRY and INK; raw font/radius/height literals fail `scripts/check-ds-leaks.sh`. No
// AppKit, so this compiles for iOS with the rest of `SlopDeskClientUI`, where the switcher never opens.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct PaneSwitcherOverlay: View {
    let store: WorkspaceStore

    var body: some View {
        if let switcher = store.paneSwitcher {
            // The container's size, not the card's: the card is measured AGAINST the window
            // (``PaneSwitcherMetrics``), so it needs to see it. `GeometryReader` fills the overlay's
            // proposed space, and the card is re-centred inside it.
            GeometryReader { proxy in
                card(PaneSwitcherRowsBuilder.rows(for: switcher, store: store), in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A readout never takes hits: the gesture lives entirely on the keyboard, and swallowing a
            // click here would strand a user who reached for the workspace behind it.
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func card(_ rows: [PaneSwitcherRow], in container: CGSize) -> some View {
        // A session with more panes than the window is tall must not draw a card taller than its host.
        // The rows scroll instead, and the highlight is kept in view as ⇥ walks past the fold.
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        RowView(row: row).id(row.id)
                    }
                }
                .padding(Slate.Metric.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: rows.first(where: \.isHighlighted)?.id) { _, id in
                guard let id else { return }
                withAnimation(Slate.Anim.smallFade) { scroller.scrollTo(id, anchor: .center) }
            }
        }
        .frame(width: PaneSwitcherMetrics.width(container: container.width))
        .frame(maxHeight: PaneSwitcherMetrics.maxHeight(container: container.height))
        // The card is only as tall as its rows until it hits that ceiling — `fixedSize` on the vertical
        // axis stops the ScrollView claiming the whole allowance for four rows.
        .fixedSize(horizontal: false, vertical: true)
        .slateGlassCard()
    }
}

/// One row: the identity, the place under it, and the ⌘-key.
private struct RowView: View {
    let row: PaneSwitcherRow

    /// The PLACE line, built as one `Text` so its two halves flow and truncate as a single run: the
    /// project set a shade heavier, then the sub-path below it in the plain weight. Weight rather than
    /// ink, because both halves are equally quiet next to the identity — what differs is which of them
    /// the eye should catch when it runs down a column of rows.
    ///
    /// A pane with no project (a video pane, a shell whose cwd has not landed) shows its note alone
    /// rather than an empty lead-in; a pane with neither shows no second line at all.
    private var place: Text? {
        guard let project = row.project else {
            return row.note.map { Text($0).font(.system(size: Slate.Typeface.footnote)) }
        }
        let head = Text(project)
            .font(.system(size: Slate.Typeface.footnote, weight: .medium))
        guard let note = row.note else { return head }
        return Text.spliced([head, Text(" › \(note)").font(.system(size: Slate.Typeface.footnote))])
    }

    var body: some View {
        HStack(spacing: Slate.Metric.space3) {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.system(
                        size: Slate.Typeface.body, weight: row.isHighlighted ? .medium : .regular,
                    ))
                    .foregroundStyle(row.isHighlighted ? SlateOverlayInk.primary : SlateOverlayInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let place {
                    place
                        .foregroundStyle(SlateOverlayInk.tertiary)
                        .lineLimit(1)
                        // Truncate from the HEAD: a deep path's last components are the ones that say
                        // where the pane actually is.
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: Slate.Metric.space3)
            // Absent past ⌘9, where the chord does not exist (the app binds ⌘1–9 only) — an unpressable
            // key drawn on a row is a lie.
            if row.number <= PaneSwitcherRowsBuilder.highestShortcut {
                SlateKeycap(label: "⌘\(row.number)", lit: row.isHighlighted)
            }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRowStacked)
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateSelectionPlate(row.isHighlighted)
    }
}
#endif
