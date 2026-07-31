// KeyboardCheatSheetView — the ⌘/ keyboard cheat sheet, drawn on the shared floating GLASS CARD
// (``SlateOverlayCard``): a column of category runs, each row pairing the binding's title with its chord set
// in a KEYCAP.
//
// It was a grouped `List` of `Section`s before. The keycap is the point of the change: this surface exists
// to teach keys, and a chord printed as loose secondary text is a fact about a key, where a cap is the key.
// The `List`'s section backgrounds went with it — a card does not need boxes drawn inside it to say where a
// run of shortcuts begins; the caps label and the air above it do that.
//
// The rows render the single source-of-truth binding table (``WorkspaceBindingRegistry/groupedForDisplay``),
// with each chord taken from the SAME registry the keyboard dispatcher fires (``WorkspaceBindingRegistry/glyph``)
// so a displayed glyph can never drift from the chord the dispatcher actually fires.
//
// SEAM discipline: the cheat sheet owns NO state — its rows are the pure registry table and its only mutation
// is `closeCheatSheet()` (the Done button / the sheet's native Esc dismissal). ⌘/ is NOT bound here: the
// app-level `WorkspaceKeyDispatcher` owns (and swallows) the toggle chord and drives `cheatSheetVisible`.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

struct KeyboardCheatSheetView: View {
    /// The single overlay reducer — read-only here (the data source is the static registry); the view's only
    /// mutation is `closeCheatSheet()`.
    let coordinator: OverlayCoordinator

    /// One rendered section: a category header + its binding rows. `Identifiable` (by the category) so the
    /// `ForEach` diffs cleanly without a tuple key path.
    private struct CheatSection: Identifiable {
        let category: WorkspaceAction.Category
        let bindings: [WorkspaceBinding]
        var id: String { category.rawValue }
    }

    /// The single source the rows render from — the registry's grouped table (panes, tabs, sessions, focus,
    /// view, agents), with the nine ⌘1…⌘9 select-tab chords already collapsed into one representative row.
    private var sections: [CheatSection] {
        WorkspaceBindingRegistry.groupedForDisplay.map {
            CheatSection(category: $0.category, bindings: $0.bindings)
        }
    }

    /// Which column each section belongs in, balanced by RENDERED HEIGHT (a section costs its rows plus its
    /// own header line) rather than by section count — three short categories beside one long one is the
    /// case that makes a naive halve-the-list split look broken. Greedy: each section joins whichever column
    /// is currently shortest, which keeps the registry's declared order reading down the page.
    ///
    /// Takes plain row counts and returns plain column indices, so it is PURE and unit-pinnable without
    /// standing up a view or the binding registry.
    static func columnAssignment(rowCounts: [Int], columns: Int = 2) -> [Int] {
        let width = max(1, columns)
        var heights = Array(repeating: 0, count: width)
        return rowCounts.map { rows in
            // `min()` on a non-empty array is never nil, and `firstIndex(of:)` of that minimum is never nil
            // — the fallbacks only exist so this function cannot trap on any input.
            let target = heights.min().flatMap { heights.firstIndex(of: $0) } ?? 0
            heights[target] += rows + 1
            return target
        }
    }

    /// The sections dealt into their columns.
    private var columns: [[CheatSection]] {
        let list = sections
        let assignment = Self.columnAssignment(rowCounts: list.map(\.bindings.count))
        var buckets: [[CheatSection]] = [[], []]
        for (section, column) in zip(list, assignment) where buckets.indices.contains(column) {
            buckets[column].append(section)
        }
        return buckets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateCardTitle("Keyboard Shortcuts") {
                Button("Done") { coordinator.closeCheatSheet() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                // TWO COLUMNS, packed as columns rather than as a grid. The table is long enough that one
                // column turns a reference sheet into a scroll, and a reader looking up a chord wants to SEE
                // the set. A `LazyVGrid` was tried first and photographed: it pairs the sections into grid
                // ROWS, so a short category next to a long one is centred against it and floats halfway down
                // the card with dead air above and below. Columns have no such coupling.
                HStack(alignment: .top, spacing: Slate.Metric.space4) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                            ForEach(column) { section in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(section.category.rawValue.uppercased())
                                        .font(Slate.Typeface.instrument(
                                            Slate.Typeface.small, weight: .medium,
                                        ))
                                        .tracking(Slate.Typeface.instrumentTracking)
                                        .foregroundStyle(Slate.Text.tertiary)
                                        .padding(.horizontal, Slate.Metric.space2)
                                        .padding(.bottom, Slate.Metric.space1)
                                    ForEach(section.bindings, id: \.id) { binding in
                                        row(binding)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.top, Slate.Metric.space2)
                .padding(.bottom, Slate.Metric.space4)
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 560)
        #endif
    }

    /// One binding: what it does, and the key that does it. No plate — nothing here is selected, and a
    /// resting row in this card is just its two facts.
    private func row(_ binding: WorkspaceBinding) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(binding.title)
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Slate.Metric.space2)
            if let glyph = chordGlyph(binding) {
                SlateKeycap(label: glyph)
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightRow)
    }

    // MARK: - Glyph derivation

    /// The chord glyph string for a row, or `nil` when the row should render NO glyph. Gated strictly on the
    /// row's OWN `chord`: the collapsed ⌘1…⌘9 representative (and any palette-/menu-only verb like Rename Tab)
    /// has `chord == nil` and bakes its hint into the title, so it gets no glyph. For every chord-bearing row
    /// the glyph is taken from the registry (rendering the full SEQUENCE for a multi-key binding), so the
    /// displayed glyph can never drift from the dispatched chord.
    private func chordGlyph(_ binding: WorkspaceBinding) -> String? {
        guard binding.chord != nil else { return nil }
        return WorkspaceBindingRegistry.glyph(for: binding.action)
    }
}
#endif
