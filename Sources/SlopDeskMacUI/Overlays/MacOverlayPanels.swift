// MacOverlayPanels — which summoned cards are currently WINDOWS, and the one place they are opened
// and closed.
//
// The coordinator's flags stay the single truth: this only diffs them into panels, the way
// ``SatelliteWindowsCoordinator`` diffs `detachedPanes` into satellite windows. Every path runs the
// same direction — a chord, a menu item or a palette row flips the flag, the scene's `.onChange`
// lands here, and the panel follows. A dismissal inside the panel (Esc, Done, a click beside it)
// does NOT tear itself down: it flips the flag back and lets the same edge do it, so the flag and
// the window can never disagree about whether the card is up.
//
// docs/56 stage D drains the macOS surfaces out of `SlopDeskClientUI` one at a time, and this file
// is where each overlay lands as it goes. Two so far — the cheat sheet and the notification corner.
//
// The two are shaped differently on purpose. A SUMMONED card is a boolean: it is up or it is not, and
// the flag is the whole state. The notification corner is AMBIENT: it has no flag at all, its content
// IS the state, and the same edge that opens it also reorders it, re-fits it and finally empties it.
// So the cheat sheet takes a `set` and the corner takes a `sync`.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // Slate — the ONE token ladder, for the palette card's first measurement
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // PaneID — a toast's jump target

@MainActor
final class MacOverlayPanels {
    /// The live cheat-sheet card, or `nil` when it is not up.
    private var cheatSheet: MacOverlayPanelController?
    /// The notification corner. Built once per workspace window and kept — it orders itself out when
    /// the stack empties, so there is nothing to tear down between bursts.
    private var toasts: MacToastStackController?
    /// The ⌃⇥ readout. Kept for the same reason as the corner: the gesture is often under 200ms, and
    /// building a window inside it would spend the whole interaction on setup.
    private var switcher: MacPaneSwitcherController?
    /// The ⌘⇧P palette, or `nil` when it is not up. Built per presentation rather than kept: the
    /// query, the selection and the hover arbiter are all per-OPENING state, and a kept card would
    /// have to reset each of them by hand on the way in.
    private var palette: MacOverlayPanelController?
    /// The ⌘⌥J peek card, or `nil` when it is not up. Built per presentation for the palette's
    /// reason and one more: the card holds the reply field's text and the pending-tool disclosure,
    /// and both are per-OPENING state that a kept card would have to clear by hand on the way in.
    private var peekReply: MacOverlayPanelController?

    /// Reconciles the ⌘/ cheat sheet against `visible`.
    ///
    /// `host` is the workspace window captured in the blessed `.introspect(.window)` closure — with
    /// no window there is nothing to hang a card on, so the call is a silent no-op rather than a
    /// card that opens somewhere the user cannot see.
    func setCheatSheet(
        _ visible: Bool, host: NSWindow?, store: WorkspaceStore, coordinator: OverlayCoordinator,
    ) {
        guard visible else {
            cheatSheet?.dismiss()
            cheatSheet = nil
            // ⚠️ The keyboard has to go back to the PANE. Ordering the panel out restores the
            // workspace window's own first responder, but where the workspace's focus sits is store
            // state rather than responder state — the pane's reclaim paths all gate on a focus
            // TRANSITION or a click, and nothing here changed either. Same call the find bar makes
            // when it closes.
            store.reclaimKeyboardFocusInActivePane()
            return
        }
        guard cheatSheet == nil, let host else { return }
        let controller = MacOverlayPanelController(
            host: host,
            content: MacCheatSheetView(onDone: { [coordinator] in coordinator.closeCheatSheet() }),
            size: MacCheatSheetView.cardSize,
            // Esc and click-away flip the FLAG; the edge that follows closes the panel.
            onDismiss: { [coordinator] in coordinator.closeCheatSheet() },
        )
        cheatSheet = controller
        controller.present()
    }

    /// Reconciles the ⌘⇧P command palette against `visible`.
    ///
    /// `toggledState` is the chrome's answer to "does this row show its ✓ right now", built by the
    /// window root from the LIVE chrome — the coordinator never learns what a sidebar is, and the
    /// card asks the question again on every render, so a verb run with ⌘↩ flips its own gutter.
    ///
    /// The card is measured by its RESULTS, so the controller is handed a first size and then told
    /// each new one as the query narrows the list.
    func setPalette(
        _ visible: Bool, host: NSWindow?, store: WorkspaceStore, coordinator: OverlayCoordinator,
        toggledState: @escaping @MainActor (PaletteItem) -> Bool,
    ) {
        guard visible else {
            palette?.dismiss()
            palette = nil
            // The keyboard goes back to the PANE — same call, same reason, as the cheat sheet's.
            store.reclaimKeyboardFocusInActivePane()
            return
        }
        guard palette == nil, let host else { return }
        let card = MacPaletteView(
            coordinator: coordinator, store: store, toggledState: toggledState,
        )
        let controller = MacOverlayPanelController(
            host: host,
            content: card,
            size: NSSize(
                width: PaletteMetrics.panelWidth,
                height: Slate.Metric.heightInput + PaletteMetrics.resultsMaxHeight,
            ),
            onDismiss: { [coordinator] in coordinator.closePalette() },
        )
        card.onResize = { [weak controller] size in controller?.resize(to: size) }
        palette = controller
        controller.present()
        // After `present()`, and it has to be: a field cannot take first responder in a window that
        // is not yet key, so a card that focused itself at build time would come up unfocused.
        card.begin()
    }

    /// Reconciles the ⌘⌥J Peek & Reply card against `visible`.
    ///
    /// The card is measured by its CONTENT — a pane with no pending call and no recent output makes
    /// a genuinely shorter one — so the controller is handed a first size and told each new one as
    /// the queue advances.
    func setPeekReply(
        _ visible: Bool, host: NSWindow?, store: WorkspaceStore, coordinator: OverlayCoordinator,
    ) {
        guard visible else {
            peekReply?.dismiss()
            peekReply = nil
            // The keyboard goes back to the PANE — same call, same reason, as the cheat sheet's.
            store.reclaimKeyboardFocusInActivePane()
            return
        }
        guard peekReply == nil, let host else { return }
        let card = MacPeekReplyView(store: store, coordinator: coordinator)
        let controller = MacOverlayPanelController(
            host: host,
            content: card,
            // A first guess only, and immediately corrected: the card reports its real height on its
            // first draw, before the panel is ever seen at this one.
            size: NSSize(
                width: Slate.Metric.cardFormWidth, height: Slate.Metric.cardFormWidth,
            ),
            onDismiss: { [coordinator] in coordinator.closePeekReply() },
        )
        card.onResize = { [weak controller] size in controller?.resize(to: size) }
        peekReply = controller
        controller.present()
        // After `present()`: a field cannot take first responder in a window that is not yet key.
        card.begin()
    }

    /// Reconciles the notification corner against the coordinator's live stack.
    ///
    /// A card is a DOOR: clicking it jumps to the pane it names, which is what keeps a notification
    /// about somewhere else from being a dead end. The jump is routed through `jumpToPaneTree` (not
    /// `focusPaneTree`) because an undirected landing that CROSSES a tab swaps the whole viewport, and
    /// that seam is what fires the "JUMPED · session ▸ tab" orientation breadcrumb.
    func syncToasts(
        _ stack: [Toast], host: NSWindow?, store: WorkspaceStore, coordinator: OverlayCoordinator,
    ) {
        guard let host else { return }
        let controller = toasts ?? MacToastStackController(host: host)
        toasts = controller
        controller.sync(
            stack,
            onDismiss: { [coordinator] id in coordinator.dismissToast(id) },
            onJump: { [store] key in store.jumpToPaneNamedByNotification(key) },
        )
    }

    /// Reconciles the ⌃⇥ readout against the store's live gesture.
    ///
    /// `nil` is every one of the gesture's three endings at once — commit, cancel, or a window that
    /// went away — so there is nothing here that has to tell them apart. The rows are rebuilt on each
    /// step because the store's own recency ring is the source; the ring itself is frozen for the
    /// gesture, so a step moves the plate rather than reordering anything.
    func syncPaneSwitcher(_ gesture: PaneSwitcher?, host: NSWindow?, store: WorkspaceStore) {
        guard let gesture, let host else {
            switcher?.dismiss()
            return
        }
        let controller = switcher ?? MacPaneSwitcherController(host: host)
        switcher = controller
        controller.show(PaneSwitcherRowsBuilder.rows(for: gesture, store: store))
    }
}
