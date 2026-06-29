// KeyboardCheatSheetView — the ⌘/ keyboard cheat sheet overlay (E2 / WI-3). Renders the single
// source-of-truth binding table (``WorkspaceBindingRegistry/groupedForDisplay``) as one ALL-CAPS section
// per category (Panes / Tabs / Sessions / Focus / View / Agents), each row pairing the binding's title
// (left) with its chord rendered as per-symbol keycap chips (right) — so a displayed glyph can never drift
// from the chord the keyboard dispatcher actually fires (both read the SAME registry).
//
// Shares the PaletteView panel shell (`Otty.Surface.card` body, `Otty.Metric.radiusCard` corners,
// `Otty.Line.card` hairline stroke, `Otty.State.shadow` drop shadow) so the floating overlays read as one
// family; the scrim + centering + fade are added by the `OverlayHostView` (WI-5) that mounts this — the
// view IS the panel. `Otty.*` tokens ONLY (raw font/radius literals fail `scripts/check-ds-leaks.sh`).
//
// SEAM discipline: the cheat sheet owns NO state — its rows are the pure registry table and its only
// mutation is `closeCheatSheet()` on Esc / scrim-tap. ⌘/ is NOT bound here: the app-level
// `WorkspaceKeyDispatcher` owns (and swallows) the toggle chord and drives `cheatSheetVisible` through the
// coordinator closure (single chord owner — see the E2 plan §Non-obvious constraints).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct KeyboardCheatSheetView: View {
    /// The single overlay reducer — read-only here (the data source is the static registry); the view's only
    /// mutation is `closeCheatSheet()`.
    let coordinator: OverlayCoordinator

    /// Focus the panel on appear so Esc reaches `.onExitCommand` (the cheat sheet has no text field to take
    /// first-responder the way the palette's search field does — without focus, Esc would never fire).
    @FocusState private var panelFocused: Bool

    // The fixed panel width (the palette is ~720; the cheat sheet's title+chip rows are tighter) + the list
    // viewport cap (the full table is long — Panes / View have ~20 rows each — so it scrolls past the cap).
    private let panelWidth: CGFloat = 640
    private let listMaxHeight: CGFloat = 520

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

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle()
                .fill(Otty.Line.divider)
                .frame(height: Otty.Metric.hairline)
            sectionList
        }
        .frame(width: panelWidth)
        .background(Otty.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard)
                .stroke(Otty.Line.card, lineWidth: Otty.Metric.hairline),
        )
        .shadow(color: Otty.State.shadow, radius: 30, x: 0, y: 12)
        // Make the panel itself focusable (no text field here) so Esc lands; suppress the focus ring so the
        // read-only panel doesn't draw a highlight outline. The deferred focus mirrors the palette idiom (a
        // `@FocusState` set in the same tick the view appears is dropped before its responder exists).
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onAppear { DispatchQueue.main.async { panelFocused = true } }
        #if os(macOS)
            .onExitCommand { coordinator.closeCheatSheet() }
        #else
            .onKeyPress(.escape, phases: .down) { _ in
                coordinator.closeCheatSheet()
                return .handled
            }
        #endif
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemSymbol: .keyboard)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
            Text("Keyboard Shortcuts")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Spacer(minLength: Otty.Metric.space2)
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 48)
    }

    // MARK: - Section list

    private var sectionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sections) { section in
                    sectionHeader(section.category)
                    ForEach(section.bindings, id: \.id) { binding in
                        bindingRow(binding)
                    }
                }
            }
            .padding(.vertical, Otty.Metric.space1)
        }
        .frame(maxHeight: listMaxHeight)
    }

    private func sectionHeader(_ category: WorkspaceAction.Category) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            Text(category.rawValue.uppercased())
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Otty.State.header)
            Spacer(minLength: Otty.Metric.space2)
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.top, Otty.Metric.space3)
        .padding(.bottom, Otty.Metric.space1)
    }

    // MARK: - Binding row

    private func bindingRow(_ binding: WorkspaceBinding) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            Text(binding.title)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
            Spacer(minLength: Otty.Metric.space2)
            if let glyph = chordGlyph(binding) {
                HStack(spacing: Otty.Metric.space1) {
                    ForEach(Array(keycaps(glyph).enumerated()), id: \.offset) { _, key in
                        keycapChip(key)
                    }
                }
            }
        }
        .padding(.horizontal, Otty.Metric.space3)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Otty.Metric.space2)
    }

    private func keycapChip(_ key: String) -> some View {
        Text(key)
            .font(.system(size: Otty.Typeface.small, weight: .medium))
            .foregroundStyle(Otty.Text.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, Otty.Metric.space1)
            .background(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                    .fill(Otty.Surface.element),
            )
    }

    // MARK: - Glyph derivation

    /// The chord glyph string for a row, or `nil` when the row should render NO chip. Gated strictly on the
    /// row's OWN `chord`: the collapsed ⌘1…⌘9 representative (and any palette-/menu-only verb like Rename Tab)
    /// has `chord == nil` and bakes its hint into the title, so it gets no chip — `glyph(for:)` of the
    /// representative's stand-in `.selectTab(1)` action would otherwise resolve the real ⌘1 binding. For every
    /// chord-bearing row the glyph is taken from the registry (`glyph(for:)` renders the full SEQUENCE for a
    /// multi-key binding), so the displayed chips can never drift from the dispatched chord.
    private func chordGlyph(_ binding: WorkspaceBinding) -> String? {
        guard binding.chord != nil else { return nil }
        return WorkspaceBindingRegistry.glyph(for: binding.action)
    }

    /// Split a chord glyph string ("⇧⌘L", or a space-separated multi-chord sequence "⌃A D") into one chip per
    /// key symbol (the spec renders each key as its own rounded badge). Whitespace separators are dropped.
    private func keycaps(_ glyph: String) -> [String] {
        glyph.split(separator: " ").flatMap { chord in chord.map(String.init) }
    }
}
#endif
