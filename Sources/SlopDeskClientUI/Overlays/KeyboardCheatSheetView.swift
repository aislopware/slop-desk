// KeyboardCheatSheetView — the ⌘/ keyboard cheat sheet, NATIVE SwiftUI (E2 / WI-3). Everything outside the
// workspace + panes is native chrome, so this is a native `.sheet` body — a grouped `List` of `Section`s (one
// per binding category: Panes / Tabs / Sessions / Focus / View / Agents), each row a native `LabeledContent`
// pairing the binding's title (leading) with its chord glyph (trailing) — the System-Settings shortcut idiom.
// NOT the old bespoke `Slate.Surface.face` panel. Presented as a real sheet by ``OverlayHostView``.
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

    var body: some View {
        VStack(spacing: 0) {
            SlateSheetHeader("Keyboard Shortcuts", systemImage: "keyboard") {
                Button("Done") { coordinator.closeCheatSheet() }
                    .keyboardShortcut(.cancelAction)
            }

            List {
                ForEach(sections) { section in
                    Section(section.category.rawValue) {
                        ForEach(section.bindings, id: \.id) { binding in
                            LabeledContent(binding.title) {
                                if let glyph = chordGlyph(binding) {
                                    Text(glyph).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 560)
        #endif
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
