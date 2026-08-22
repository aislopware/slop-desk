// KeybindingsEditorReading — what the Key Bindings editor READS out of the registry.
//
// Five helpers stood in both editors, and four of them were byte-identical including their doc
// comments — `cmp` clean, only the declaration order differed. Nothing in them names a view: they are
// pure over `(KeybindingPreferences, String query)` and answer with rows, a chord and a glyph. Under
// docs/56 §3 that is the shared logic target's, not a UI target's, and it is here now.
//
// ONE thing changed on the way down, and it closes a latent disagreement rather than being a tidy-up.
// `effectiveGlyph` re-walked the override map itself (`chord(for:)` → `asRegistryChord` → else the
// registry default) while `effectiveChord` — which is what the SEARCH FILTER matches against — asked
// ``WorkspaceBindingRegistry/resolvedChord(for:overrides:)``. The two walks agree for every binding
// whose action names it back, and nothing guarantees that of a binding that shares an action with
// another: the chip could print one chord while the filter matched a different one. There is one walk
// now, and the glyph is the spelling of the chord the filter used.

import SlopDeskVideoProtocol // KeybindingPreferences — the persisted override map
import SlopDeskWorkspaceCore

/// Every word the Key Bindings editor puts on screen, spelled once.
///
/// Seven of these stood character for character in both editors — more duplicated user-facing copy than
/// any other surface in the split, including the confirmation alert's title, its body and both of its
/// buttons. That is a translation bug already in the tree: reword one half and the two platforms ship
/// different sentences for the same destructive action, with nothing to notice.
package enum KeybindingsEditorCopy {
    /// The section heading and the sentence under it.
    package static let title = "Keyboard Shortcuts"
    package static let subtitle =
        "Click a shortcut to record a replacement; Backspace clears it, Esc cancels."

    /// The search field's prompt.
    package static let searchPrompt = "Search key bindings"

    /// The reset affordance: the button, its explanation, and the confirmation it raises. There is NO
    /// per-row revert on either half — one button clears every override — so the confirmation's body
    /// has to say "every", and it says it once.
    package static let resetAction = "Reset to Default"
    package static let resetHelp = "Reset every customized shortcut to its default"
    package static let resetConfirmTitle = "Reset all key bindings?"
    package static let resetConfirmBody = "This clears every customized shortcut and restores the defaults."

    /// The conflict banner's heading, and the mark on a row that shares its chord.
    package static let conflictsTitle = "Shortcut conflicts"
    package static let conflictHelp = "This shortcut conflicts with another command"
}

/// The Key Bindings editor's reads: which rows survive the search, which rows a category holds, and
/// what a row's chip says.
package enum KeybindingsEditorReading {
    /// What the chip shows when a binding resolves to no chord at all.
    package static let unboundGlyph = "—"

    /// Which rows of `WorkspaceBindingRegistry.allBindings` the search query keeps, in that order —
    /// asked once per keystroke and read by every category.
    package static func surviving(
        overrides: KeybindingPreferences, query: String,
    ) -> [Bool] {
        KeybindingsEditorModel.surviving(
            WorkspaceBindingRegistry.allBindings,
            effectiveChord: { effectiveChord(for: $0, overrides: overrides) },
            query: query,
        )
    }

    /// The bindings in `category` that survive the search, minus the synthetic ⌘1…⌘9 representative —
    /// it has no single chord to rebind, and the real per-digit chords are an implementation detail.
    /// `surviving` is positional against `allBindings`, so this walks the same array it was built from.
    package static func bindings(
        in category: WorkspaceAction.Category, surviving: [Bool],
    ) -> [WorkspaceBinding] {
        zip(WorkspaceBindingRegistry.allBindings, surviving).filter { binding, kept in
            kept
                && binding.category == category
                && binding.id != WorkspaceBindingRegistry.selectPaneRepresentative.id
        }.map(\.0)
    }

    /// The binding a row id names.
    package static func binding(forID id: String) -> WorkspaceBinding? {
        WorkspaceBindingRegistry.allBindings.first { $0.id == id }
    }

    /// The conflict banner's lines: one per chord bound twice, naming the actions fighting over it.
    /// Sorted twice on purpose — the actions inside a line, then the lines — so the banner is stable
    /// across the dictionary's iteration order and does not reshuffle on an unrelated rebind.
    ///
    /// A sixth helper spelled in both editors and not counted among the five: the phone built the same
    /// strings inline inside its banner body, which is why a `cmp` of the two files never saw it.
    package static func conflictLines(_ conflicts: [String: [String]]) -> [String] {
        conflicts.map { chord, ids in
            let titles = ids.compactMap { binding(forID: $0)?.title }.sorted()
            return "\(chord): \(titles.joined(separator: ", "))"
        }.sorted()
    }

    /// The binding's EFFECTIVE chord: the user override if it maps, else the registry default. The
    /// same source ``effectiveGlyph(for:overrides:)`` renders, surfaced as a `KeyChord` so the search
    /// filter can match its glyph and its canonical spelling.
    package static func effectiveChord(
        for binding: WorkspaceBinding, overrides: KeybindingPreferences,
    ) -> KeyChord? {
        WorkspaceBindingRegistry.resolvedChord(for: binding.action, overrides: overrides)
    }

    /// What the chip shows: the effective chord's glyph, or ``unboundGlyph`` for a binding with none.
    /// Through the spelling memo, so a default chord — which is every chord until the user rebinds one
    /// — is a dictionary read rather than the two doors and four allocations rendering it costs.
    package static func effectiveGlyph(
        for binding: WorkspaceBinding, overrides: KeybindingPreferences,
    ) -> String {
        guard let chord = effectiveChord(for: binding, overrides: overrides) else { return unboundGlyph }
        return KeybindingsEditorModel.spelling(of: chord).glyph
    }
}
