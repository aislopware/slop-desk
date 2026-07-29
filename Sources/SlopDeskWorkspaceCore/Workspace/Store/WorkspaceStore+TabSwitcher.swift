import Foundation
import SlopDeskWorkspaceModel

// MARK: - The ⌃⇥ tab switcher (press-and-hold, MRU-ordered)

/// Drives ``TabSwitcher`` against the live tree. The model is pure; this is the part that knows where
/// the candidate order comes from and what a commit costs.
///
/// The ring is the HOST's (``WorkspaceStore/tabFocusMRU`` → `WorkspaceTopology.focusMRU`), the same one
/// the close path reads for its successor — so "the tab ⌃⇥ goes back to" and "the tab closing this one
/// returns to" can never disagree.
public extension WorkspaceStore {
    /// Opens the switcher, or steps it when already open.
    ///
    /// Repeat presses must STEP rather than re-open: re-opening would re-freeze the ring and pin the
    /// highlight at index 1, so a held ⌃ with three ⇥ taps could never reach the third tab.
    ///
    /// `armedByModifier` records that a HELD modifier opened this, so ``commitTabSwitcherOnModifierRelease()``
    /// knows whether a modifier release is the commit gesture or an unrelated key-up.
    func openOrStepTabSwitcher(forward: Bool, armedByModifier: Bool) {
        if tabSwitcher != nil {
            tabSwitcher?.step(forward: forward)
            return
        }
        let ordered = flatOrderedTabIDs()
        let candidates = TabSwitcher.candidates(
            active: tree.activeSession?.activeTab?.id,
            mru: tabFocusMRU,
            ordered: ordered,
        )
        // No switcher for a lone tab: the dispatcher reads `tabSwitcher == nil` to decide whether it
        // swallowed ⌃⇥, so refusing here is what lets the chord fall through to the pane.
        tabSwitcher = TabSwitcher(candidates: candidates, forward: forward, armedByModifier: armedByModifier)
    }

    /// Commits the highlighted tab and closes the switcher — the ONLY point in the gesture that stages a
    /// focus intent.
    ///
    /// A tab closed mid-gesture is dropped rather than committed: the frozen ring can outlive its tabs,
    /// and staging `.focusTab` for a tab the host no longer has is a silently-refused intent.
    func commitTabSwitcher() {
        guard let switcher = tabSwitcher else { return }
        tabSwitcher = nil
        guard let session = tree.activeSession,
              let index = session.tabs.firstIndex(where: { $0.id == switcher.highlighted })
        else { return }
        selectTab(index)
    }

    /// Commits ONLY when a held modifier armed this switcher. A switcher opened from the palette (nothing
    /// held) must survive an unrelated modifier release — otherwise tapping ⇧ while it is open would
    /// silently pick whatever happened to be highlighted.
    func commitTabSwitcherOnModifierRelease() {
        guard tabSwitcher?.armedByModifier == true else { return }
        commitTabSwitcher()
    }

    /// Abandons the walk (Esc, or the workspace window losing key) leaving the active tab untouched.
    func cancelTabSwitcher() {
        tabSwitcher = nil
    }
}
