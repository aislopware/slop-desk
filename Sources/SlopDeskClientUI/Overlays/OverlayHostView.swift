// OverlayHostView — THE PHONE's single mount point for everything that floats over the workspace.
//
// ⚠️ EVERY SURFACE HAS LEFT THE MAC, and each of them left the same way (docs/56 stage D): a surface
// leaves this floor by being REWRITTEN in each platform's own framework, never by being gated inside
// one view. What the halves share they share BELOW the view layer, so neither spells the rule out.
// The Mac's are ``SlopDeskMacUI/MacCheatSheetView``, ``SlopDeskMacUI/MacToastStack``,
// ``SlopDeskMacUI/MacPaneSwitcher``, ``SlopDeskMacUI/MacPaletteView``,
// ``SlopDeskMacUI/MacPeekReplyView``, ``SlopDeskMacUI/MacGlobalSearchView``,
// ``SlopDeskMacUI/MacOpenQuicklyView``, ``SlopDeskMacUI/MacConnectSheet`` and
// ``SlopDeskMacUI/MacCloseConfirmation``; they meet the phone's here at ``CheatSheetContent``,
// ``ToastPresentation``, ``PaneSwitcherRowsBuilder``, ``PalettePresentation``,
// ``PeekReplyPresentation``, ``GlobalSearchPresentation``, ``OpenQuicklyPresentation``,
// ``ConnectPresentation`` and ``CloseConfirmationCopy``.
//
// The two that went LAST are the two that were never cards, and they went differently. A picker you
// summon, skim and dismiss became a borderless `NSPanel` over there; a FORM you fill in and commit and
// an ALERT are what the platform's own modal exists for, so on the Mac they are real sheets and here
// they are SwiftUI's `.sheet` and `.alert` — the same decision on both platforms, drawn by each
// platform's own framework. Neither was ever owed a card, which is why they outlasted every card.
//
// ⚠️ THE TOASTS LEAVING IS WHAT MADE THIS LAYER HONEST. The ambient layer used to carry
// `.allowsHitTesting(!coordinator.toasts.isEmpty)`, because an always-mounted full-bleed host over
// the AppKit split claims every hit inside its bounds — that flag was the only thing keeping the
// terminal clickable. With the cards in a window sized to the column, the layer beneath is a readout
// that takes no hits at all, and there is no flag left to keep honest.
//
// One host so every overlay shares one presentation point: because the coordinator only ever drives one
// overlay flag at a time (its `run()` closes-then-opens; the open* methods are the only writers), a single
// computed ``ActiveSheet`` is robust — it can never race two chained presentations, and a dismissal (Esc /
// click-away) routes through `closeActiveSheet()` to the matching `close*()`.
//
// MOUNTING: the phone's root (`WorkspaceRootView`) attaches this as a top `.overlay` on its
// `NavigationSplitView` — a `.sheet`/`.alert` presented from an overlay composes over the window.
//
// SEAM discipline: the host owns NO state — every read/close goes through the coordinator (the single
// `@Observable` reducer) or the store (the close-confirmation parks). NATIVE styling only (system fonts /
// controls) — the overlays carry their own content; the host adds only the shared card surface.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SwiftUI

package struct OverlayHostView: View {
    /// The live store — passed to the palette / pickers (working-directory badge, sources) and read for the
    /// pane/tab close-confirmation parks (`pendingCloseSpec` / `pendingTabCloseID`).
    package let store: WorkspaceStore
    /// The app-global connection — bound by ``ConnectHostView`` (the host/port form is a thin view over it).
    package let connection: AppConnection
    /// The single overlay reducer — every overlay's visibility + close routes through it.
    @Bindable package var coordinator: OverlayCoordinator
    /// Whether a palette row currently shows its ✓ (toggled-on) gutter. Built by the root from the live chrome
    /// (see ``PalettePresentation/toggledState(chrome:store:)``) so the pure coordinator stays chrome-agnostic.
    /// Defaults to "nothing toggled" (previews).
    package var toggledState: @MainActor (PaletteItem) -> Bool = { _ in false }
    package init(
        store: WorkspaceStore,
        connection: AppConnection,
        coordinator: OverlayCoordinator,
        toggledState: @escaping @MainActor (PaletteItem) -> Bool = { _ in false },
    ) {
        self.store = store
        self.connection = connection
        self.coordinator = coordinator
        self.toggledState = toggledState
    }

    package var body: some View {
        // ⚠️ ONE LAYER, and that is the stage-D dividend. This used to be a ZStack of two: an AMBIENT
        // chain (toasts, the ⌃⇥ readout) that had to carry `allowsHitTesting(false)` — which
        // suppresses hits for everything composed into it, INCLUDING overlays attached further down,
        // so a modal hung off the same chain took no clicks at all (measured: a palette row click ran
        // nothing) — and the modal as its SIBLING. Both ambient tenants are their own surfaces now, so
        // the host presents modals and nothing else, and the hit-testing hazard is gone with them.
        //
        // The transient chip stack (copy receipt · notice · connection indicator) was never here: it
        // stands at the foot of the ISLAND (``IslandChipStack``, mounted by ``ContentColumn``).
        //
        // ⚠️ The card is presented IN THIS WINDOW, not in a sheet, and that is the only way it can look
        // like the rest of the family.
        //
        // A sheet is a separate WINDOW, and a window brings its own surface and its own mask. Two
        // symptoms, one root: the sheet paints its ground across its whole frame, which flashed as a
        // pale panel on open (and, once the card was inset to make room for its shadow, showed as a
        // halo ringing it); and the sheet window's mask clipped the corner to the SYSTEM's radius
        // instead of the island's 26, which is the one number the whole family is cut at.
        //
        // The card is also SHADOWED, and a shadow needs something to fall on. In-window it falls on the
        // island and the ground — the same two tones the island's own cast lands on — so the card reads
        // as one more thing lifted off this canvas. Presented in its own window it falls on nothing the
        // user can see, and the depth cue the paper surface depends on is simply gone.
        //
        // The keyboard needs nothing from the sheet: it already yields on the COORDINATOR's flags
        // (`capturesKeyboardWhileVisible`), which is how a focused card here receives typing and its own
        // chords. Dismissal is the backdrop's job below.
        modalOverlay
            // The card's `.transition(.opacity)` needs a transaction to ride, and the flags are
            // mutated outside a `withAnimation` — so the value-keyed animation is what drives the diff.
            .animation(Slate.Anim.smallFade, value: activeSheet)
            // CONNECT-TO-HOST is the ONE overlay presented as a real system sheet (user-directed
            // 2026-08-08). It is the only surface in the set that is a FORM the user fills in and
            // commits — every other card is a picker you summon, skim and dismiss in a second — and a
            // form is exactly what the platform's own modal is for: it owns the window, it can't be
            // dismissed by a stray click into the workspace mid-edit, and Esc/Return land on Cancel and
            // Connect through the buttons' native roles rather than through a hand-rolled floor.
            //
            // The reasons the OTHER cards stay in-window (above) all still hold and none of them applied
            // here: this card carries no glass, its corner is the family's own rather than the island's,
            // and the depth cue a summoned picker gets from casting a shadow on the island is not what
            // makes a modal form legible.
            //
            // `connectVisible` is `private(set)`, so the binding is one-way by construction: reads come
            // from the coordinator, and any system dismissal routes back through `closeConnect()` — which
            // also bumps `connectGeneration`, invalidating an in-flight connect Task exactly as Cancel does.
            .sheet(isPresented: connectSheetBinding) {
                ConnectHostView(connection: connection, coordinator: coordinator)
            }
            // The pane/tab CLOSE CONFIRMATION — the platform's own alert, off the store's two
            // mutually-exclusive parks. The WORDING is ``CloseConfirmationCopy``, shared with the Mac's
            // `NSAlert`: which line a park deserves is three branches and a join, and that is exactly
            // the amount of logic that drifts when two halves each carry it.
            .alert(
                closeRequest.map(CloseConfirmationCopy.title) ?? "",
                isPresented: closeAlertBinding,
                actions: {
                    // "Close" is the destructive action (it stops a running command / discards the pane/tab);
                    // Cancel is the safe default. Native roles give the alert its standard button
                    // placement + tinting.
                    Button("Close", role: .destructive) { store.confirmPendingClose() }
                    Button("Cancel", role: .cancel) { store.cancelPendingClose() }
                },
                message: { Text(closeRequest.map(CloseConfirmationCopy.message) ?? "") },
            )
        // No tint override anywhere on this layer: the app's ONE neutral accent (the AccentColor
        // asset) already makes stock controls, focus rings and selection read graphite — here and in
        // the workspace beneath alike (see ``SlateOverlayInk``).
    }

    // MARK: - Active overlay (single presentation seam)

    /// Which overlay (if any) should be presented, resolved from the coordinator flags in a fixed priority
    /// order. The coordinator drives one flag at a time, so this is unambiguous: exactly one card is
    /// mounted, and one overlay replacing another (palette → connect) is a single swap.
    package enum ActiveSheet: Identifiable, CaseIterable {
        case palette
        case openQuickly
        case peekReply
        case globalSearch
        package var id: Self { self }
    }

    private var activeSheet: ActiveSheet? {
        if coordinator.paletteVisible { return .palette }
        if coordinator.openQuicklyVisible { return .openQuickly }
        if coordinator.peekReplyVisible { return .peekReply }
        if coordinator.globalSearchVisible { return .globalSearch }
        return nil
    }

    /// The presented card, centred over the workspace on a hit-catching backdrop.
    ///
    /// The backdrop does NOT dim. These are surfaces you summon over your work and dismiss in a second, and
    /// the workspace behind is the context you summoned them about — the switcher makes the same call, and
    /// a system sheet did not dim either, so nothing regresses. It is not `Color.clear` either: a truly
    /// clear rectangle takes no hits, and catching the tap that dismisses the card is its whole job.
    @ViewBuilder
    private var modalOverlay: some View {
        if let sheet = activeSheet {
            ZStack {
                // A BUTTON, not a tap gesture — see ``SlateClickTarget`` for why nothing on this layer
                // may rely on SwiftUI gesture recognition.
                SlateClickTarget { closeActiveSheet() }
                sheetContent(sheet)
                    .slatePaperCard()
                    // The card must never run out of a small window; this is the margin it keeps.
                    .padding(Slate.Metric.space4)
            }
            .transition(.opacity)
            // ⚠️ Closing the card must hand the KEYBOARD BACK. The card's field is the window's first
            // responder while it is up, and tearing it down leaves the window itself holding the
            // responder — so the pane the user was working in went deaf and had to be tapped before it
            // would take a keystroke again. Nothing else fires here: the pane's own reclaim paths all gate
            // on a focus TRANSITION or a tap, and the workspace focus never changed. Same call the find
            // bar makes when it closes.
            .onDisappear { store.reclaimKeyboardFocusInActivePane() }
        }
    }

    private func closeActiveSheet() {
        if coordinator.paletteVisible { coordinator.closePalette() }
        else if coordinator.openQuicklyVisible { coordinator.closeOpenQuickly() }
        else if coordinator.peekReplyVisible { coordinator.closePeekReply() }
        else if coordinator.globalSearchVisible { coordinator.closeGlobalSearch() }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .palette:
            PaletteView(coordinator: coordinator, store: store, toggledState: toggledState)
        case .openQuickly:
            OpenQuicklyView(store: store, coordinator: coordinator, folders: coordinator.folders)
        case .peekReply:
            PeekReplyOverlay(store: store, coordinator: coordinator)
        case .globalSearch:
            GlobalSearchView(store: store, coordinator: coordinator)
        }
    }

    // MARK: - Connect-to-Host (native .sheet)

    /// Presentation binding for the Connect sheet. `set(false)` — the Cancel role or any system
    /// dismissal — routes to `closeConnect()` so the coordinator stays the single owner of the flag;
    /// `set(true)` never happens (a sheet does not present itself) and is deliberately not modelled.
    private var connectSheetBinding: Binding<Bool> {
        Binding(
            get: { coordinator.connectVisible },
            set: { if !$0 { coordinator.closeConnect() } },
        )
    }

    // MARK: - Close confirmation (native .alert)

    /// The live parked close, or `nil` when nothing is parked. Resolved on every render rather than
    /// captured, which is the store's own choice: a pane opened or closed while the dialog is up keeps
    /// the project-loss line honest.
    private var closeRequest: CloseConfirmationCopy.Request? {
        CloseConfirmationCopy.request(store: store)
    }

    /// Whether the confirmation is up — driven by EITHER store park (they are mutually exclusive).
    /// `set(false)` (a system dismissal) cancels the park, matching the Cancel button.
    private var closeAlertBinding: Binding<Bool> {
        Binding(
            get: { closeRequest != nil },
            set: { if !$0 { store.cancelPendingClose() } },
        )
    }
}
#endif
