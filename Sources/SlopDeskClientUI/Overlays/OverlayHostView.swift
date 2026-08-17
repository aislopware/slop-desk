// OverlayHostView — the single mount point that presents EVERY floating overlay above the workspace as
// NATIVE SwiftUI chrome (the "everything outside the workspace + panes is native" directive). It owns no
// state. The summoned PICKERS are IN-WINDOW paper cards (``SlateOverlayCard``) driven by the injected
// ``OverlayCoordinator`` flags; the two surfaces that are DECISIONS rather than pickers use the platform's
// own modals — Connect-to-Host is a native `.sheet` (user-directed 2026-08-08) and the pane/tab close
// confirmation a native `.alert` off the store's `pendingClose*` parks. The always-mounted
// ``ToastStackView`` (which renders nothing when empty) is the
// host's only other in-tree content — transient notifications float over the workspace without a modal.
//
// One host so every overlay shares one presentation point: because the coordinator only ever drives one
// overlay flag at a time (its `run()` closes-then-opens; the open* methods are the only writers), a single
// computed ``ActiveSheet`` is robust — it can never race two chained presentations, and a dismissal (Esc /
// click-away) routes through `closeActiveSheet()` to the matching `close*()`.
//
// MOUNTING: each shell's root view attaches this as a top `.overlay` — `MacWorkspaceRootView` on the
// `WorkspaceSplitRepresentable` and on the iOS `NavigationSplitView` — a `.sheet`/`.alert` presented from an
// overlay composes over the window on both platforms.
//
// SEAM discipline: the host owns NO state — every read/close goes through the coordinator (the single
// `@Observable` reducer) or the store (the close-confirmation parks). The `toggledState` predicate is built
// by the root from the live `WorkspaceChromeState` (macOS) or a no-op (iOS) and handed to the palette, so the
// pure coordinator never learns about chrome. NATIVE styling only (system fonts / controls) — the overlays
// carry their own content; the host adds only the shared card surface.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // PaneID — the notification jump target
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
    /// (see ``OverlayHostView/toggledState(for:store:)``) so the pure coordinator stays chrome-agnostic.
    /// Defaults to "nothing toggled" (iOS / previews).
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
        // ⚠️ TWO LAYERS, deliberately not one chain. The ambient layer (toasts, chips, the ⌃⇥ readout)
        // is TRANSPARENT TO HITS unless a toast is up, so the workspace beneath stays clickable — and
        // `allowsHitTesting(false)` on it suppresses hits for everything composed into that chain,
        // INCLUDING overlays attached further down it. A modal card hung off the same chain therefore
        // took no clicks at all: neither its rows nor its dismiss-backdrop responded (measured — a
        // palette row click ran nothing). So the modal is a SIBLING in a ZStack, owning its own hit
        // testing.
        ZStack {
            ToastStackView(coordinator: coordinator, onJump: jumpToNotifiedPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!coordinator.toasts.isEmpty)
                // The transient chip stack (copy receipt · notice · connection indicator) is NOT here: it
                // stands at the foot of the ISLAND (``IslandChipStack``, mounted by ``ContentColumn``).
                // Centred on the window it drifted off the canvas it described, and its window-measured
                // inset parked it on the island's bottom edge over the prompt line (user-directed
                // 2026-08-09).
                //
                // The ⌃⇥ switcher readout, centred like the macOS app switcher it echoes. Deliberately NOT a
                // `.sheet` (see `PaneSwitcherOverlay`): a sheet would take key focus and break the `flagsChanged`
                // ⌃-release that commits the gesture, and its present animation outlasts the whole interaction.
                .overlay(alignment: .center) { PaneSwitcherOverlay(store: store) }
                .animation(Slate.Anim.smallFade, value: activeSheet)

            // ⚠️ The card is presented IN THIS WINDOW, not in a sheet, and that is the only way it can look
            // like the ⌃⇥ switcher — which is the whole point of the family.
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
            // (Until 2026-08-08 this note argued refraction: the card was Liquid Glass and a sheet had
            // nothing behind it to refract. ONE ISLAND retired the material — see ``SlatePaperCard`` — but
            // every other reason to stay in-window survived it intact.)
            //
            // The keyboard needs nothing from the sheet: it already yields on the COORDINATOR's flags
            // (`capturesKeyboardWhileVisible` → the app's `isOverlayCapturingKeys` → the dispatcher's
            // NSEvent monitor hands the event back to the responder chain), which is how a focused card
            // here receives typing and its own ⌘-chords. Esc and click-away are the backdrop's job below.
            modalOverlay
        }
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
        .alert(
            closeAlertTitle,
            isPresented: closeAlertBinding,
            actions: {
                // "Close" is the destructive action (it stops a running command / discards the pane/tab);
                // Cancel is the safe default. Native roles give the macOS alert its standard button
                // placement + tinting.
                Button("Close", role: .destructive) { store.confirmPendingClose() }
                Button("Cancel", role: .cancel) { store.cancelPendingClose() }
            },
            message: { Text(closeAlertMessage) },
        )
        // No tint override anywhere on this layer: the app's ONE neutral accent (the AccentColor
        // asset) already makes stock controls, focus rings and selection read graphite — here and in
        // the workspace beneath alike (see ``SlateOverlayInk``).
    }

    /// Lands on the pane a notification came from. This is what makes a toast a DOOR rather than a dead
    /// end: every push site is gated on the source pane NOT being focused, so the card always names
    /// somewhere else. Routed through `jumpToPaneTree` (not `focusPaneTree`) for the same reason
    /// ``ConnectionAlertChip`` is — an undirected landing that CROSSES a tab swaps the whole viewport, and
    /// that seam fires the "JUMPED · session ▸ tab" orientation breadcrumb. An unparseable key (a toast
    /// whose pane is long gone) is a silent no-op, never a crash on attacker/host-shaped text.
    private func jumpToNotifiedPane(_ paneKey: String) {
        guard let raw = UUID(uuidString: paneKey) else { return }
        store.jumpToPaneTree(PaneID(raw: raw))
    }

    // MARK: - Active overlay (single presentation seam)

    /// Which overlay (if any) should be presented, resolved from the coordinator flags in a fixed priority
    /// order. The coordinator drives one flag at a time, so this is unambiguous: exactly one card is
    /// mounted, and one overlay replacing another (palette → connect) is a single swap.
    private enum ActiveSheet: Identifiable {
        case palette
        case cheatSheet
        case openQuickly
        case peekReply
        case globalSearch
        var id: Self { self }
    }

    private var activeSheet: ActiveSheet? {
        if coordinator.paletteVisible { return .palette }
        if coordinator.cheatSheetVisible { return .cheatSheet }
        if coordinator.openQuicklyVisible { return .openQuickly }
        if coordinator.peekReplyVisible { return .peekReply }
        if coordinator.globalSearchVisible { return .globalSearch }
        return nil
    }

    /// The presented card, centred over the workspace on a hit-catching backdrop.
    ///
    /// The backdrop does NOT dim. These are surfaces you summon over your work and dismiss in a second, and
    /// the workspace behind is the context you summoned them about — the switcher makes the same call, and
    /// a macOS sheet did not dim either, so nothing regresses. It is not `Color.clear` either: a truly
    /// clear rectangle takes no hits, and catching the click that dismisses the card is its whole job.
    ///
    /// It is a SIBLING in the ZStack rather than an `.overlay` on the ambient chain, because that chain
    /// carries `allowsHitTesting(false)` whenever no toast is up.
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
                // The controls are real AppKit controls and read as themselves, in the app's ONE
                // neutral accent. No `.tint()` here: the earlier per-card grey tint made the platform
                // draw a prominent button as a near-white plate under a white label in dark mode. The
                // AccentColor asset carries a per-appearance graphite instead, so the platform keeps
                // its own label-contrast logic.
            }
            .transition(.opacity)
            // ⚠️ Closing the card must hand the KEYBOARD BACK. The card's field is the window's first
            // responder while it is up, and tearing it down leaves the window itself holding the
            // responder — so the pane the user was working in went deaf and had to be clicked before it
            // would take a keystroke again. Nothing else fires here: the pane's own reclaim paths all gate
            // on a focus TRANSITION or a click, and the workspace focus never changed. A sheet did not
            // need this (AppKit restored the parent window's responder on dismissal); an in-window card
            // does. Same call the find bar makes when it closes.
            .onDisappear { store.reclaimKeyboardFocusInActivePane() }
            // Esc reaches the focused card's own handler in every case but one — the cheat sheet has no
            // field to focus — so the backdrop carries the same escape as a floor. macOS spells it
            // `onExitCommand` (unavailable on iOS, where the cards are reached by tap anyway).
            #if os(macOS)
                .onExitCommand { closeActiveSheet() }
            #endif
        }
    }

    private func closeActiveSheet() {
        if coordinator.paletteVisible { coordinator.closePalette() }
        else if coordinator.cheatSheetVisible { coordinator.closeCheatSheet() }
        else if coordinator.openQuicklyVisible { coordinator.closeOpenQuickly() }
        else if coordinator.peekReplyVisible { coordinator.closePeekReply() }
        else if coordinator.globalSearchVisible { coordinator.closeGlobalSearch() }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .palette:
            PaletteView(coordinator: coordinator, store: store, toggledState: toggledState)
        case .cheatSheet:
            KeyboardCheatSheetView(coordinator: coordinator)
        case .openQuickly:
            OpenQuicklyView(store: store, coordinator: coordinator, folders: coordinator.folders)
        case .peekReply:
            PeekReplyOverlay(store: store, coordinator: coordinator)
        case .globalSearch:
            GlobalSearchView(store: store, coordinator: coordinator)
        }
    }

    // MARK: - Connect-to-Host (native .sheet)

    /// Presentation binding for the Connect sheet. `set(false)` — Esc, the Cancel role, or any system
    /// dismissal — routes to `closeConnect()` so the coordinator stays the single owner of the flag;
    /// `set(true)` never happens (a sheet does not present itself) and is deliberately not modelled.
    private var connectSheetBinding: Binding<Bool> {
        Binding(
            get: { coordinator.connectVisible },
            set: { if !$0 { coordinator.closeConnect() } },
        )
    }

    // MARK: - Close confirmation (native .alert)

    /// Whether the pane/tab close confirmation is up — driven by EITHER store park (they are mutually
    /// exclusive). `set(false)` (Esc / a system dismissal) cancels the park, matching the Cancel button.
    private var closeAlertBinding: Binding<Bool> {
        Binding(
            get: { store.pendingCloseSpec != nil || store.pendingTabCloseID != nil },
            set: { if !$0 { store.cancelPendingClose() } },
        )
    }

    /// The alert headline: the pane's title when a pane close is parked ("Close “<pane>”?"), else the tab copy.
    private var closeAlertTitle: String {
        if let spec = store.pendingCloseSpec {
            return spec.title.isEmpty ? "Close this pane?" : "Close “\(spec.title)”?"
        }
        return "Close this tab?"
    }

    /// The policy-aware alert body: the policy line only when a configured policy ACTUALLY gated the park
    /// (`pendingClosePolicyGated` — a park raised purely for the project-loss warning must not claim "a
    /// process is still running" over an idle shell), plus the project-loss line when the close takes a
    /// project's last pane/tab with it. Both can apply (a busy shell that is also its project's last
    /// pane). Reuses the pure ``CloseConfirmationPanel`` copy the tests pin, so the wording can't drift
    /// from the pinned strings; the policy fallback keeps a park that matches neither gate (both resolved
    /// live, so either can decay while the dialog is up) from rendering an empty body.
    private var closeAlertMessage: String {
        let scope: CloseScope = store.pendingCloseSpec != nil ? .pane : .tab
        var lines: [String] = []
        if store.pendingClosePolicyGated {
            lines.append(CloseConfirmationPanel.reason(for: store.pendingCloseReasonPolicy ?? .process, scope: scope))
        }
        if let project = store.pendingCloseProjectName {
            lines.append(CloseConfirmationPanel.projectCloseReason(project: project, scope: scope))
        }
        if lines.isEmpty {
            lines.append(CloseConfirmationPanel.reason(for: store.pendingCloseReasonPolicy ?? .process, scope: scope))
        }
        return lines.joined(separator: "\n\n")
    }

    /// The toggled-state predicate the root hands to ``PaletteView`` — built from the live chrome so the
    /// palette's ✓ gutter reflects the real sidebar visibility (a visible panel ⇒ ✓ on its toggle
    /// row). Pure + `static` so it is unit-pinnable without instantiating the view. `@MainActor`
    /// because it reads the `@MainActor` ``WorkspaceChromeState``. Resolves the checkable View toggles — Toggle
    /// Tabs Panel, Pin Window — PLUS the two Shell toggles whose live state lives on
    /// the active pane (Read Only / Secure Keyboard Entry), read off the `store` so the ✓ tracks the real pane
    /// input gate / secure-entry state rather than staying perpetually dark.
    @MainActor
    package static func toggledState(
        for chrome: WorkspaceChromeState, store: WorkspaceStore,
    ) -> @MainActor (PaletteItem) -> Bool {
        { item in
            switch item.id {
            case "action.toggleSidebar": !chrome.sidebarCollapsed
            case "action.toggleCodeSidebar": !chrome.codeSidebarCollapsed
            // Pin Window is a CHECKABLE toggle — light the ✓ gutter while the window is pinned, so the
            // palette (and the View menu) tell the user the current pinned state. Mirrors the sidebar
            // treatment, reading the SAME live `chrome.pinned` the menu Button + the `NSWindow.level` glue flip.
            case "action.pinWindow": chrome.pinned
            // Read Only / Secure Keyboard Entry are CHECKABLE toggles whose live state lives on
            // the ACTIVE pane (the convergent `paneReadOnly` set / the model's `secureInputActive` mirror), NOT
            // on `chrome` — so the ✓ tracks the real input gate / secure-entry state instead of never lighting.
            case "action.toggleReadOnly": store.isActivePaneReadOnly()
            case "action.secureKeyboardEntry": store.isActivePaneSecureInputActive()
            default: false
            }
        }
    }
}

// MARK: - CloseConfirmationPanel (close-confirmation COPY — the pure wording the native `.alert` renders)

/// The pure close-confirmation copy — a caseless namespace for the wording ONLY; the confirmation itself is a
/// native `.alert` (``OverlayHostView``). Kept as a static
/// helper so ``CloseConfirmationPanelTests`` still pins the policy→copy mapping without instantiating a view.
enum CloseConfirmationPanel {
    /// The close-confirmation subtitle for a given resolved policy + close scope. PURE — unit-pinnable. The
    /// wording stays soft: a running process names the consequence; `always` asks plainly (scoped to "pane" vs
    /// "tab"); `multiple_tabs` warns that the window holds several tabs.
    static func reason(for policy: CloseConfirmationPolicy, scope: CloseScope = .tab) -> String {
        switch policy {
        case .process:
            "A process is still running. Closing it will stop the command."
        case .always:
            switch scope {
            case .pane: "Are you sure you want to close this pane?"
            case .tab,
                 .window: "Are you sure you want to close this tab?"
            }
        case .multipleTabs:
            "This window has multiple tabs."
        }
    }

    /// The project-loss warning line: the parked close takes `project`'s LAST pane / tab with it, so the
    /// whole By-Project section disappears. Appended to (or standing in for) the policy reason above.
    static func projectCloseReason(project: String, scope: CloseScope) -> String {
        switch scope {
        case .pane:
            "This is the last pane of “\(project)”. Closing it will close the project."
        case .tab,
             .window:
            "This is the last tab of “\(project)”. Closing it will close the project."
        }
    }
}
#endif
