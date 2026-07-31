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
            previewHighlightedTab()
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
        previewHighlightedTab()
    }

    /// Commits the highlighted tab and closes the switcher — the ONLY point in the gesture that stages a
    /// focus intent.
    ///
    /// A tab closed mid-gesture is dropped rather than committed: the frozen ring can outlive its tabs,
    /// and staging `.focusTab` for a tab the host no longer has is a silently-refused intent.
    func commitTabSwitcher() {
        guard let switcher = tabSwitcher else { return }
        tabSwitcher = nil
        // The preview is UNWOUND before the commit, not folded into it: `selectTab` publishes focus the
        // way this device is configured to (an intent when following, its own overlay when not), and it
        // can only get that right starting from the focus the gesture began with.
        endTabSwitcherPreview()
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

    /// Abandons the walk (Esc, or the workspace window losing key) leaving the active tab untouched —
    /// including any tab the preview walked through on the way.
    func cancelTabSwitcher() {
        tabSwitcher = nil
        endTabSwitcherPreview()
    }
}

// MARK: - Follow-along preview

/// Showing each highlighted tab as the walk passes over it, so ⌃⇥ is a look rather than a guess.
///
/// ⚠️ This does NOT relax the switcher's founding rule that the highlight is LOCAL. A tab focus is a
/// host-owned intent, and staging one per step would broadcast every intermediate tab of a cycle to
/// every other client on the workspace. The preview rides ``WorkspaceStore/DeviceFocus`` instead — the
/// same device-local overlay an unfollowing device lives on (docs/45 §8.2). It writes no intent,
/// publishes no presence (that rides `reconcileTree`, which this never calls), and is unwound on both
/// exits. The commit still stages exactly once.
///
/// Cheap by construction: `SplitContainer` renders EVERY tab of the active session and merely hides the
/// inactive ones, so stepping the preview is a visibility flip, not a mount. The one real cost is a
/// VIDEO pane, whose UDP/VT/Metal pipeline is gated on that same visibility and so starts and stops as
/// the walk passes — which is the honest reason this is a setting and not a law.
extension WorkspaceStore {
    /// Shows the currently-highlighted tab locally, remembering what to put back the first time.
    func previewHighlightedTab() {
        guard SettingsKey.tabSwitcherPreviewEnabled, let switcher = tabSwitcher else { return }
        // Nothing to preview onto a tab this client's mirror does not have — the frozen ring can outlive
        // its tabs, exactly as the commit path guards.
        guard tree.sessions.contains(where: { $0.tabs.contains { $0.id == switcher.highlighted } })
        else { return }
        if !tabSwitcherPreviewing {
            tabSwitcherPreviewing = true
            tabSwitcherFocusBeforePreview = deviceFocus
        }
        setDeviceFocus(DeviceFocus(tab: switcher.highlighted, pane: nil))
    }

    /// Puts the pre-gesture view back. Idempotent, and a no-op when no preview ran — so the plain
    /// (preview-off) switcher and every non-switcher caller of ``cancelTabSwitcher()`` are untouched.
    func endTabSwitcherPreview() {
        guard tabSwitcherPreviewing else { return }
        tabSwitcherPreviewing = false
        let restored = tabSwitcherFocusBeforePreview
        tabSwitcherFocusBeforePreview = nil
        setDeviceFocus(restored)
    }
}
