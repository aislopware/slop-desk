import Foundation
import SlopDeskWorkspaceModel

// MARK: - The ⌃⇥ pane switcher (press-and-hold, MRU-ordered)

/// Drives ``PaneSwitcher`` against the live tree. The model is pure; this is the part that knows where
/// the candidate order comes from and what a commit costs.
public extension WorkspaceStore {
    /// Opens the switcher, or steps it when already open.
    ///
    /// Repeat presses must STEP rather than re-open: re-opening would re-freeze the ring and pin the
    /// highlight at index 1, so a held ⌃ with three ⇥ taps could never reach the third pane.
    ///
    /// `armedByModifier` records that a HELD modifier opened this, so ``commitPaneSwitcherOnModifierRelease()``
    /// knows whether a modifier release is the commit gesture or an unrelated key-up.
    func openOrStepPaneSwitcher(forward: Bool, armedByModifier: Bool) {
        if paneSwitcher != nil {
            paneSwitcher?.step(forward: forward)
            previewHighlightedPane()
            return
        }
        let ordered = flatOrderedPaneIDs()
        let candidates = PaneSwitcher.candidates(
            active: tree.activeSession?.activeTab?.activePane,
            mru: paneSwitcherMRU,
            ordered: ordered,
        )
        // No switcher for a lone pane: the dispatcher reads `paneSwitcher == nil` to decide whether it
        // swallowed ⌃⇥, so refusing here is what lets the chord fall through to the pane.
        paneSwitcher = PaneSwitcher(candidates: candidates, forward: forward, armedByModifier: armedByModifier)
        previewHighlightedPane()
    }

    /// Commits the highlighted pane and closes the switcher — the ONLY point in the gesture that stages
    /// a focus intent.
    ///
    /// A pane closed mid-gesture is dropped rather than committed: the frozen ring can outlive its
    /// panes, and staging `.focusPane` for one the host no longer has is a silently-refused intent.
    ///
    /// Lands through ``WorkspaceStore/revealPaneTree(_:)`` — the one "take me to this pane" call the
    /// rail rows and the drag-move commit already share — so a pane in another tab brings its tab with
    /// it and the arrival clears that tab's badges, exactly as arriving by any other route does.
    func commitPaneSwitcher() {
        guard let switcher = paneSwitcher else { return }
        paneSwitcher = nil
        // The preview is UNWOUND before the commit, not folded into it: `revealPaneTree` publishes focus
        // the way this device is configured to (an intent when following, its own overlay when not), and
        // it can only get that right starting from the focus the gesture began with.
        endPaneSwitcherPreview()
        guard tree.contains(switcher.highlighted) else { return }
        revealPaneTree(switcher.highlighted)
    }

    /// Commits ONLY when a held modifier armed this switcher. A switcher opened from the palette (nothing
    /// held) must survive an unrelated modifier release — otherwise tapping ⇧ while it is open would
    /// silently pick whatever happened to be highlighted.
    func commitPaneSwitcherOnModifierRelease() {
        guard paneSwitcher?.armedByModifier == true else { return }
        commitPaneSwitcher()
    }

    /// Abandons the walk (Esc, or the workspace window losing key) leaving the active pane untouched —
    /// including any pane the preview walked through on the way.
    func cancelPaneSwitcher() {
        paneSwitcher = nil
        endPaneSwitcherPreview()
    }

    /// The ring the switcher freezes, most-recently-visited first.
    ///
    /// TWO sources, each where it is authoritative. ``WorkspaceStore/paneVisitMRU`` is this device's own
    /// navigation history — per-client by design (docs/45 §7.3 lists a client's "last pane" beside the
    /// latched video modes, distinct from the SHARED `session/focusMRU` the close path reads), because
    /// two desks alternating between two different pairs of panes have no common answer to "the pane I
    /// was just in". But that ring starts EMPTY on a fresh client, where the host's tab ring is the only
    /// recency anyone has — so each remembered tab contributes its own active pane BEHIND the local
    /// entries. ``PaneSwitcher/candidates(active:mru:ordered:)`` dedupes, so the overlap costs nothing.
    var paneSwitcherMRU: [PaneID] {
        guard let session = tree.activeSession else { return paneVisitMRU }
        var activePaneOfTab: [TabID: PaneID] = [:]
        for tab in session.tabs { activePaneOfTab[tab.id] = tab.activePane }
        return paneVisitMRU + tabFocusMRU.compactMap { activePaneOfTab[$0] }
    }
}

// MARK: - Follow-along preview

/// Showing each highlighted pane as the walk passes over it, so ⌃⇥ is a look rather than a guess.
///
/// ⚠️ This does NOT relax the switcher's founding rule that the highlight is LOCAL. A pane focus is a
/// host-owned intent, and staging one per step would broadcast every intermediate pane of a cycle to
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
    /// Shows the currently-highlighted pane locally, remembering what to put back the first time.
    func previewHighlightedPane() {
        guard SettingsKey.paneSwitcherPreviewEnabled, let switcher = paneSwitcher else { return }
        // Nothing to preview onto a pane this client's mirror does not have — the frozen ring can
        // outlive its panes, exactly as the commit path guards. The TAB is resolved FROM the pane,
        // because that is what a pane focus carries.
        guard let (_, tab) = tree.tab(containing: switcher.highlighted) else { return }
        if !paneSwitcherPreviewing {
            paneSwitcherPreviewing = true
            paneSwitcherFocusBeforePreview = deviceFocus
        }
        setDeviceFocus(DeviceFocus(tab: tab, pane: switcher.highlighted))
    }

    /// Puts the pre-gesture view back. Idempotent, and a no-op when no preview ran — so the plain
    /// (preview-off) switcher and every non-switcher caller of ``cancelPaneSwitcher()`` are untouched.
    func endPaneSwitcherPreview() {
        guard paneSwitcherPreviewing else { return }
        paneSwitcherPreviewing = false
        let restored = paneSwitcherFocusBeforePreview
        paneSwitcherFocusBeforePreview = nil
        setDeviceFocus(restored)
    }
}
