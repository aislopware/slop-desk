import Foundation
import SlopDeskWorkspaceModel

// MARK: - WorkspaceStore × device-local focus (docs/45 §8.2)

/// Whether local navigation moves the SHARED layout or only this device's view of it.
///
/// `Session.activeTabID` and `Tab.activePaneID` are host truth: they decide the close successor,
/// notification targeting and what a fresh client opens into. That is right for a desk, and wrong for
/// a phone — an iPhone glancing at a build log must not drag a Studio's screen with it. So the rule is
/// per-device, and it is ``DevicePreferences/followSessionFocus`` (ON macOS, OFF iOS):
///
/// | following | this device renders | local navigation writes |
/// |---|---|---|
/// | ON | `session/activeTabID` + `tab/activePaneID` | a `focusTab` / `focusPane` INTENT — every following client moves |
/// | OFF | its own ``WorkspaceStore/deviceFocus`` | nothing — the layout is untouched |
///
/// Presence goes out either way (``WorkspaceStore/publishWorkspacePresence()`` reports the projection,
/// which already carries the overlay), so the other clients always know where this one is looking.
extension WorkspaceStore {
    /// The focus a device chose for itself: a tab, and optionally a pane inside it.
    ///
    /// One value rather than a per-tab map, because that is exactly what the two intents it stands in
    /// for carry — `focusTab` names a tab and leaves each tab's own `activePane` alone, `focusPane`
    /// names a pane and takes its tab with it.
    struct DeviceFocus: Equatable {
        /// The tab this device is looking at.
        var tab: TabID
        /// The pane inside it, when the navigation named one. `nil` for a plain tab switch, which
        /// leaves the tab's host-owned `activePane` showing.
        var pane: PaneID?
    }

    /// `tree`'s device-focus overlay: `focus` applied to the host's projection.
    ///
    /// Applies the SAME pure ops ``WorkspaceIntentApplier`` would have — so an unfollowing device sees
    /// precisely what it would have seen had it been following, including `focusPane`'s zoom-exit rule
    /// (focus must never land on a pane the zoom collapse hides).
    ///
    /// Resolution is checked against the projection every time, never cached: a tab or pane another
    /// client closed simply stops applying, and host truth shows through. That is what keeps this
    /// device off a blank view when the thing it was watching goes away.
    static func applying(_ focus: DeviceFocus, to tree: TreeWorkspace) -> TreeWorkspace {
        if let pane = focus.pane, tree.contains(pane) {
            return WorkspaceTreeOps.focusPane(pane, in: tree)
        }
        guard let sIdx = tree.sessions.firstIndex(where: { $0.tabs.contains { $0.id == focus.tab } }),
              let tIdx = tree.sessions[sIdx].tabs.firstIndex(where: { $0.id == focus.tab })
        else { return tree }
        var out = tree
        out.activeSessionID = out.sessions[sIdx].id
        out.sessions[sIdx].activeTabIndex = tIdx
        return out
    }

    /// Records this device's own focus and repaints. Always `true` — there is nothing to refuse: the
    /// overlay resolves against the projection at read time, so recording a focus on a tab that has
    /// since gone is inert rather than wrong.
    ///
    /// Bumps ``workspaceMirrorRevision`` for the same reason ``setLiveDividerWeight(_:)`` does: that
    /// counter is both the projection cache's key and the Observation shadow every `tree` reader binds
    /// to, so a change that skipped it would neither repaint nor invalidate.
    @discardableResult
    func setDeviceFocus(_ next: DeviceFocus?) -> Bool {
        deviceFocus = next
        workspaceMirrorRevision &+= 1
        return true
    }

    /// What this device is looking at RIGHT NOW, as an overlay — the value it takes hold of the instant
    /// it stops following.
    ///
    /// Without it, stopping is not an event: `deviceFocus` would stay `nil`, ``WorkspaceStore/tree``
    /// would go on projecting host truth verbatim, and the device would keep being dragged until it
    /// happened to navigate locally. The moment somebody reaches for that switch is the moment
    /// something else is dragging them, so "detach at the next tap" is precisely the wrong time.
    ///
    /// The pane rides along only when carrying it changes nothing on screen: ``applying(_:to:)`` runs
    /// `focusPane`, which exits a zoom that is showing some OTHER pane. Detaching must be invisible.
    ///
    /// `nil` with no active tab — there is nothing to hold, and host truth showing through IS the
    /// right answer for a device that is looking at an empty workspace.
    func currentViewAsDeviceFocus() -> DeviceFocus? {
        guard let tab = tree.activeSession?.activeTab else { return nil }
        let zoomHoldsAnotherPane = tab.zoomedPane != nil && tab.zoomedPane != tab.activePane
        return DeviceFocus(tab: tab.id, pane: zoomHoldsAnotherPane ? nil : tab.activePane)
    }

    /// Publishes a TAB focus the way this device is configured to: an intent when following, a local
    /// overlay when not. `true` when the focus landed somewhere.
    ///
    /// Both overloads ABANDON an open ⌃⇥ switcher first. These two functions are the choke point every
    /// local navigation passes through (a tab-bar click, a pane click, a rail row, a palette jump), and a
    /// switcher opened without a held modifier has no key-up coming to end it — left up, its next Return
    /// would commit a highlight chosen for a workspace the user has already left. Ordering matters: the
    /// switcher's own commit clears itself BEFORE calling `selectTab`, so this never eats its selection.
    ///
    /// Being that choke point is also why the ⌃⇥ ring is recorded here (``WorkspaceStore/notePaneVisit(_:)``):
    /// every deliberate navigation lands in it exactly once, whatever surface asked for it. A tab focus
    /// records the tab's OWN active pane, because that is the pane the user ends up looking at.
    @discardableResult
    func stageFocus(tab: TabID) -> Bool {
        cancelPaneSwitcher()
        if let landing = tree.sessions.lazy
            .compactMap({ $0.tabs.first { $0.id == tab } }).first?.activePane
        {
            notePaneVisit(landing)
        }
        // The kind is recorded HERE, at the choke point, because only here is it known — see
        // ``WorkspaceStore/FocusIntent``. A refused stage records nothing.
        guard devicePreferences.followSessionFocus else {
            let staged = setDeviceFocus(DeviceFocus(tab: tab, pane: nil))
            if staged { noteFocusIntent(.tab) }
            return staged
        }
        let staged = stage(.focusTab, WorkspaceIntentArgs.encode(tab: tab))
        if staged { noteFocusIntent(.tab) }
        return staged
    }

    /// Publishes a PANE focus the way this device is configured to. The unfollowing path resolves the
    /// owning tab first, because a pane focus carries its tab: focusing a pane in another tab has to
    /// switch this device to that tab as well, exactly as the applier does.
    @discardableResult
    func stageFocus(pane: PaneID) -> Bool {
        cancelPaneSwitcher()
        notePaneVisit(pane)
        guard devicePreferences.followSessionFocus else {
            guard let (_, tab) = tree.tab(containing: pane) else { return false }
            let staged = setDeviceFocus(DeviceFocus(tab: tab, pane: pane))
            if staged { noteFocusIntent(.pane) }
            return staged
        }
        let staged = stage(.focusPane, WorkspaceIntentArgs.encode(pane: pane))
        if staged { noteFocusIntent(.pane) }
        return staged
    }
}
