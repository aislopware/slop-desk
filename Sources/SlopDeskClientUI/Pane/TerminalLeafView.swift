// TerminalLeafView — the terminal pane leaf's content, minimal by design: the terminal surface
// seam (TerminalRendererFactory.make, else BuildStatusPlaceholderView).
// No persistent cwd chrome (the cwd chip only appears in menus/overlays), no bottom cwd pill, no mounted
// bottom command-input row; text delivery (incl. Peek & Reply) routes through `InputBarModel` headlessly.
//
// SEAM: the Xcode app target injects the production `GhosttyTerminalView`; a headless `swift build`
// registers no factory, so we mount `BuildStatusPlaceholderView` — this library NEVER imports libghostty/Metal.
//
// Lazy connect: `live.connection?.connect()` runs in a `.task` on appear (don't slam N sockets restoring N
// panes). The leaf is keyed `.id(PaneID)` by PaneContainer so the surface / connection is never reused
// across panes (identity hazard). SYSTEM colours only.
//
// NO command-block decoration on the surface: the per-command tick rail that stood in the trailing
// gutter (round 14) was REMOVED WHOLE at the user's direction 2026-08-10. Block navigation keeps its
// keyboard and Command Navigator paths; the pane's edges carry nothing.

#if canImport(SwiftUI)
import Defaults // observe the Auto-Secure-Input / indicator defaults so the toggle is LIVE.
import Foundation
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskTerminal // TerminalViewportSnapshotting — the iOS letterbox reads the live cell advance.
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // PaneID — the autotype seam's task key.
import SwiftUI

struct TerminalLeafView: View {
    /// The live session backing this pane (terminal model + input bar). When `nil` (no live handle yet, or
    /// a non-terminal kind) the leaf shows the placeholder only.
    let live: LivePaneSession?
    /// Workspace focus → drives the production renderer's first responder (only the focused pane types).
    let isFocused: Bool

    /// The host-reported working directory (`pane/cwd`, live-set from OSC 7)
    /// for the bottom status bar's left field. Resolved by ``PaneContainer`` from the store's spec so it stays
    /// reactive; `nil` until the host first reports a cwd.
    let cwd: String?
    /// The app-global connection host (`ConnectionTarget.host`) for the status bar's
    /// right field. Empty when not yet connected / unknown (the strip then omits the host).
    let host: String

    /// The live workspace store, needed by the per-pane Command Navigator (⌃⌘O). Its row jump
    /// routes through ``WorkspaceStore/jumpToNavigatorBlockInActivePane(index:)`` (the shared ``BlockJump``
    /// re-anchor engine, which resolves the ACTIVE pane = the pane the navigator is over). Passed from ``PaneContainer``.
    let store: WorkspaceStore

    /// The in-pane ⌘F find bar's view-model (pure ``TerminalSearchController`` + the libghostty
    /// `search:` passthrough). Wired to the pane's `onRequestFind*` callbacks in `.task`; per-pane `@State`
    /// (the leaf is `.id(PaneID)`-keyed), so no cross-pane bleed.
    @State private var findBar = TerminalFindBarModel()

    /// The per-pane macOS Secure Keyboard Entry actuator. Driven (in `wirePaneCallbacks`)
    /// from the model's `onHostEchoChanged` (auto, on a host no-echo password prompt) + the manual
    /// `onManualSecureInputChanged` toggle, it engages / disengages process-global `EnableSecureEventInput`
    /// with a strict single-reference balance. It also observes the app-frontmost edge
    /// (``SecureKeyboardEntryController/observeAppActivity()``), so the lock releases whenever slopdesk is
    /// backgrounded / window-resigned and re-acquires on return — never leaked to other apps' keyboards.
    /// Torn down on disappear so the lock can't leak past a pane close either. Inert off macOS (no-op controller).
    @State private var secureInput = SecureKeyboardEntryController()

    /// The LIVE "Auto Secure Input" setting, OBSERVED (not just read at wire time) so a
    /// Settings toggle reconciles every open pane at once. Reading it as `@Default` registers observation, so the
    /// body re-renders on the change edge and ``onChange(of:)`` pushes the new value into this pane's
    /// ``SecureKeyboardEntryController`` (releasing an engaged process-global lock when turned OFF) AND the model's
    /// pill mirror — the "live" contract the Settings footer claims (watch for the carryover footgun).
    @Default(.autoSecureInput) private var autoSecureInput
    /// The LIVE "Show Secure Input Indicator" setting. OBSERVED so flipping it re-renders the
    /// leaf and ``PaneStatusPillPresentation`` re-evaluates the secure-input pill at once — turning it
    /// off mid-prompt without waiting for a pane swap or the next echo edge.
    @Default(.secureInputIndicator) private var secureInputIndicator

    /// The per-leaf Command Navigator (⌃⌘O) chrome the model's `onRequestBlockNavigator` callback
    /// TOGGLES. A reference type so the `@MainActor` closure can flip it (the find-bar idiom); per-pane
    /// (`.id(PaneID)`-keyed), so no cross-pane bleed, and the modal only opens over the pane the store fired — the
    /// active pane.
    @State private var navigatorChrome = CommandNavigatorChrome()

    /// The single overlay coordinator, used ONLY to surface a transient error
    /// toast when a host open/reveal RPC fails — so the action is never a SILENT no-op. `nil` outside the app
    /// scene root (tests/previews) ⇒ the failure is swallowed there, never a crash.
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    /// The shared chrome model (injected by ``ContentColumn``), used ONLY to reveal the RIGHT code
    /// panel when an open-in-code-panel action lands in the workbench. `nil` in previews/tests ⇒
    /// the file still opens (host-side), the panel just isn't auto-revealed.
    @Environment(WorkspaceChromeState.self) private var workspaceChrome: WorkspaceChromeState?

    var body: some View {
        VStack(spacing: 0) {
            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Inner breathing room so terminal content isn't flush against the pane edges / split divider
                // (issue: the user asked for padding around the panes). `Slate.Surface.terminal` on the VStack fills
                // the inset gutter (flat, no card). NB the inset shrinks the libghostty surface, so the host PTY
                // grid loses ~1 col/row each side — it reflows through the existing PaneContainer.size →
                // resize-scrim → host TIOCSWINSZ path, no new signal needed.
                // EVEN on all four sides. The sides were briefly wider than the ends to give the
                // command ladder a rail worth aiming at; with the ladder gone the gutter carries
                // nothing, so it goes back to the grid and the pane gets its columns back.
                .padding(Slate.Metric.space2)
            // NO per-pane status strip on a TERMINAL pane (issue: the user judged the terminal pane footer
            // low-value and asked to drop it). The cwd / exit / progress cues are low-value; host + connection status now
            // live ONCE in the connection island (the sidebar's foot, or the titlebar band while the
            // column is collapsed), not per pane. The
            // GUI/window pane keeps a bottom bar, but as a CONTROL bar (resize / lock / zoom), not a status strip.
        }
        .background(Slate.Surface.terminal)
        // Keyed on the pane AND on the launch dial hold, so a leaf that mounts while this client's
        // restored layout is still unanswered runs the task, does nothing, and RE-runs on the release
        // (the key moves off `nil` — the `autotypeTaskKey` shape).
        .task(id: dialTaskKey) { await connectIfNeeded() }
        // The `SLOPDESK_AUTOTYPE` OUT-path proof (docs/22 §7) rides its OWN task, keyed on the pane
        // being connected rather than on this leaf appearing — see `autotypeTargetIfConnected`.
        .task(id: autotypeTargetIfConnected) { await runAutotypeIfRequested() }
        // Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks on appear AND on every live-session swap (`initial: true`
        // fires once up-front, then on each `live?.id` change). Synchronous `@MainActor` closure — no actor
        // hop, unlike the `@Sendable async` `.task` above.
        .onChange(of: live?.id, initial: true) { wirePaneCallbacks() }
        // Keep Secure Input LIVE to a Settings toggle. `wireSecureInputCallbacks()` only
        // re-syncs on a pane swap, so without this an engaged process-global lock + the pill would linger past
        // the user turning "Auto Secure Input" OFF — the carryover footgun. Pushing the new value into BOTH the
        // controller (releases the lock on the OFF edge) AND the model's pill mirror reconciles them at once.
        // The indicator change needs no push — `secureInputIndicator` as `@Default` already re-renders
        // the pill gate; the reconcile keeps the model mirror authoritative if a future read moves off it.
        .onChange(of: autoSecureInput) { reconcileSecureInputSetting() }
        // Mirror the host cwd onto the model so the AppKit renderer's ⌘-hover hit-test can
        // resolve a RELATIVE detected path to its absolute form. The cwd arrives reactively from `PaneContainer`
        // (OSC 7) and changes independently of the live-session id, so it gets its own `onChange`; `initial: true`
        // seeds it once on mount. No-op when no model yet.
        .onChange(of: cwd, initial: true) {
            live?.terminalModel?.linkCwd = cwd
        }
        // Clear the callbacks when the leaf is torn down so a dead `@State` holder can't be driven by a
        // surviving model (the model is owned by the live session, which can outlive this `.id(PaneID)` leaf).
        .onDisappear { clearPaneCallbacks() }
    }

    /// The terminal pixels (the seam) — production renderer if the app registered one, else the headless
    /// placeholder. This library NEVER imports libghostty/Metal: it only calls the factory seam. The vi-mode
    /// pill, `🔒 READ ONLY ×` pill and ⌘F find bar float top-trailing OVER the surface (none reflow the buffer),
    /// stacked in one overlay so they never collide; the vi key-hint bar floats along the bottom.
    private var terminalSurface: some View {
        ZStack(alignment: .topLeading) {
            if let model = live?.terminalModel {
                // The phone's KEY responder, under the pixels and behind every overlay. On macOS
                // the renderer is the first responder and this does not exist; on iOS the renderer
                // is a Metal layer that answers no key event, so without this mount the pane cannot
                // receive a keystroke at all. Zero-sized and touch-transparent — it holds first
                // responder, the accessory row and the press handlers, nothing visual.
                #if os(iOS)
                if let live {
                    TerminalInputHost(live: live, focusCoordinator: store.focusCoordinator)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                #endif
                letterboxed(model: model) {
                    if TerminalRendererFactory.shared != nil {
                        TerminalRendererFactory.make(model: model, isFocused: isFocused)
                    } else {
                        BuildStatusPlaceholderView(model: model)
                    }
                }
                // The ⌘-hold link underline, a DECORATION overlay over the surface (never a
                // content branch — libghostty-freeze guardrail). Coincident with the surface (both fill this
                // top-leading ZStack), so the cell metrics (origin 0,0 = surface top-left) map straight to
                // the Canvas. Inert unless the renderer set `linkHighlightActive` (macOS ⌘); a placeholder
                // surface doesn't conform to the viewport seam, so it draws nothing.
                LinkHighlightOverlay(model: model, cwd: cwd)
                // The prompt-jump landed flash — one ~240ms accent fade over the row libghostty pinned
                // the jumped-to prompt at, anchoring the eye after the viewport hard-cuts. Also a
                // DECORATION overlay coincident with the surface; inert until a jump settles.
                PromptJumpFlashOverlay(model: model)
                // The copy-mode block cursor — one accent-outlined cell at the vi cursor (the
                // selection itself renders natively via the fork's set_selection ABI). Also a DECORATION
                // overlay coincident with the surface; inert outside copy-mode / when the cursor is
                // scrolled off-viewport / over a placeholder surface.
                ViCursorOverlay(model: model)
                // The Vimium Hint Mode overlay — dims the surface + draws yellow 2-letter
                // labels when armed (⌘⇧J open / ⌘⇧Y copy / reveal). Also a DECORATION overlay coincident with the
                // surface (origin 0,0). Inert unless the renderer armed `hintMode` (or an iOS tap-on-label); a
                // placeholder surface draws nothing.
                HintModeOverlay(model: model)
                // The Command Navigator (⌃⌘O) — a scrimmed, centered card listing the pane's
                // recent OSC-133 command blocks (search + All/Failed/Bookmarked filter), jumping the scrollback
                // on ↩. Toggled by `onRequestBlockNavigator` (wired in `wireNavigatorCallbacks`); the store fires
                // that only on the ACTIVE pane, so this card only mounts over the focused pane.
                if navigatorChrome.isVisible {
                    CommandNavigatorView(
                        model: model,
                        store: store,
                        onClose: { navigatorChrome.isVisible = false },
                    )
                    .transition(.opacity)
                }
            } else {
                Color.clear
            }
        }
        // ONE top-trailing overlay holds the vi-mode pill, the status chips and the find bar, stacked
        // top→down so an open find bar reflows BELOW the persistent pills instead of overlapping them.
        // slopdesk has no persistent titlebar, so the pane hosts these directly.
        //
        // WHICH chips are up, and in WHAT ORDER, is not this view's to say: it is one ordered list in
        // ``PaneStatusPillPresentation/visible(_:)``, so an AppKit canvas asks the same question rather
        // than re-deriving "read-only hides under vi, secure input hides under read-only, sync input
        // hides under nothing" from the same prose and being right by luck.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: Slate.Metric.space2) {
                if PaneStatusPillPresentation.showsViModePill(pillConditions),
                   let model = live?.terminalModel
                {
                    ViModePill(model: model, onExit: { model.exitCopyMode() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ForEach(visiblePills, id: \.self) { pill in
                    PaneStatusPillView(pill: pill, onDismiss: { dismiss(pill) })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if findBar.visible, live?.terminalModel != nil {
                    TerminalFindBar(model: findBar)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(Slate.Metric.space2)
        }
        // The vi key-hint bar floats along the pane BOTTOM when `⌘/` has toggled it on during a vi
        // session — the gate is `copyModeBadgeActive`-first, so it tears down the instant vi mode exits
        // (which also resets `showViKeyHints`).
        .overlay(alignment: .bottom) {
            if showViHintBar {
                ViKeyHintBar()
                    .padding(Slate.Metric.space2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // ⚠️ NO copy-receipt chip here any more (user-directed 2026-08-11). The `COPIED · N` confirmation
        // used to mount bottom-TRAILING in this view for pane-scoped copies while pane-less ones (palette
        // "Copy Path") drew at the island's foot — one event with two homes, so the user had to learn both
        // to know where to look. The pane still OWNS the receipt (`TerminalViewModel.copyReceipt`, which is
        // its state); only the mount moved, to `IslandChipStack`, which now reads it through
        // `WorkspaceStore.activePaneCopyReceipt()`.
        .animation(Slate.Anim.reveal, value: findBar.visible)
        .animation(Slate.Anim.reveal, value: visiblePills)
        .animation(Slate.Anim.reveal, value: PaneStatusPillPresentation.showsViModePill(pillConditions))
        .animation(Slate.Anim.reveal, value: showViHintBar)
        .animation(Slate.Anim.reveal, value: navigatorChrome.isVisible)
    }

    /// Places the terminal pixels.
    ///
    /// On iOS the pane holds a grid it did NOT choose — a phone is size-passive host-side (docs/45
    /// §8.3), so the resolved grid belongs to whichever Mac clamped the fold — and the surface is
    /// centred with letterbox bars plus the `120×40 · sized by MacBook Pro` readout. On macOS the
    /// window IS a contributor, so the surface fills the pane exactly as it always has and a bar
    /// would frame a pane that is already right.
    @ViewBuilder
    private func letterboxed(
        model: TerminalViewModel,
        @ViewBuilder _ content: @escaping () -> some View,
    ) -> some View {
        #if os(iOS)
        TerminalLetterboxContainer(
            // `flatMap`, not `map`: both reads are themselves optional, and a nested optional here
            // would make "no pane" and "no resolved grid" different values that mean the same thing.
            grid: live.flatMap { store.paneResolvedGrid(for: $0.id) },
            // The renderer's own natural cell advance. Absent for a placeholder / pre-layout surface,
            // which is exactly when the container degrades to full-bleed.
            cellSize: (model.surface as? TerminalViewportSnapshotting)?.cellMetrics()
                .map { CGSize(width: $0.cellWidth, height: $0.cellHeight) },
            readout: live.flatMap { store.paneGridReadout(for: $0.id) },
            content: content,
        )
        #else
        content()
        #endif
    }

    /// Everything the pill gates read, taken once per body pass.
    ///
    /// Every field is an OBSERVABLE mirror (never the `@ObservationIgnored` `isReadOnly`/`isCopyMode`
    /// the renderer's keyDown path reads), so reading them HERE is what makes the chips light and clear
    /// reactively. `secureInputIndicator` is the OBSERVED `@Default`, not the bare `SettingsKey`
    /// accessor: that is the live-toggle contract — flipping "Show Secure Input Indicator" hides the
    /// chip at once instead of waiting for a pane swap. `store.syncInputArmed(for:)` reads the
    /// observable `syncInputTabs`, so arming or disarming anywhere re-renders this leaf.
    ///
    /// A not-yet-live pane reads as all-false, which shows no chip — the same answer the five separate
    /// `guard let model else { return false }` gates gave.
    private var pillConditions: PaneStatusConditions {
        guard let model = live?.terminalModel else { return PaneStatusConditions() }
        return PaneStatusConditions(
            readOnly: model.readOnlyBadgeActive,
            copyMode: model.copyModeBadgeActive,
            hintMode: model.hintMode != nil,
            secureInput: model.secureInputActive,
            secureInputIndicator: secureInputIndicator,
            syncInput: live.map { store.syncInputArmed(for: $0.id) } ?? false,
        )
    }

    /// The chips that are up, TOP-DOWN, from the one ordered list below the UI.
    private var visiblePills: [PaneStatusPill] {
        PaneStatusPillPresentation.visible(pillConditions)
    }

    /// Whether the vi key-hint bar is shown: in vi mode AND the per-session `⌘/` toggle is on.
    private var showViHintBar: Bool {
        guard let model = live?.terminalModel else { return false }
        return PaneStatusPillPresentation.showsViKeyHintBar(
            pillConditions, hintsToggled: model.showViKeyHints,
        )
    }

    /// The `×` on a dismissible chip. Read-only releases through the model, whose `onReadOnlyChanged`
    /// hook converges the store's `paneReadOnly` set; sync input disarms the WHOLE tab, because the mode
    /// is the tab's and clearing it on one pane only would leave the siblings still fanning input.
    /// Secure input carries no `×` (``PaneStatusPill/dismissHelp``), so it never reaches here.
    private func dismiss(_ pill: PaneStatusPill) {
        switch pill {
        case .readOnly:
            live?.terminalModel?.exitReadOnly()
        case .syncInput:
            if let paneID = live?.id { store.disarmSyncInput(for: paneID) }
        case .secureInput:
            break
        }
    }

    /// Wire all per-pane view callbacks (find + secure input + hint mode + host path actions) on
    /// appear / live-session swap.
    private func wirePaneCallbacks() {
        wireFindCallbacks()
        wireSecureInputCallbacks()
        wireHintCallbacks()
        wireNavigatorCallbacks()
        wirePathActionCallbacks()
    }

    /// Clear all per-pane view callbacks on teardown so a surviving model can't drive a dead leaf's `@State`.
    private func clearPaneCallbacks() {
        clearFindCallbacks()
        clearSecureInputCallbacks()
        clearHintCallbacks()
        clearNavigatorCallbacks()
        clearPathActionCallbacks()
    }

    /// Wire the pane's host OPEN / REVEAL path callbacks to the live
    /// ``MetadataClient`` — so ⌘click "Open", ⌘⇧click "Reveal in Finder", the right-click Open / Reveal items,
    /// Jump-To open/reveal, and Hint-to-open/reveal on a detected PATH all route to the HOST Mac's Finder/app (a
    /// path lives on the host, not the client). The client provider captures `live` WEAKLY (so the model-stored
    /// closure never retains the live session into a cycle) and reads the CURRENT façade each fire (replaced on
    /// every reconnect — `activeMetadataClient` is `nil` while disconnected). A `.notFound`/`.error`/timeout
    /// raises a transient error toast rather than being swallowed. No-op for a non-terminal / not-yet-live pane.
    private func wirePathActionCallbacks() {
        guard let model = live?.terminalModel else { return }
        let overlay = overlayCoordinator
        let chrome = workspaceChrome
        HostPathActions.wire(
            model: model,
            client: { [weak live] in live?.connection?.activeMetadataClient },
            revealCodePanel: { [weak live] in
                // Open-in-editor is the second doorway through the code panel's open gate: the host
                // has already routed the file into the workbench, so the panel must mount it — a
                // reveal that landed on the gate's button would ask permission for a thing already
                // done. The pane's host-pushed key is the root the panel will render for.
                if let pane = live?.id, let root = store.hostPushedProjectKey(pane) {
                    chrome?.openCodeProject(root)
                }
                chrome?.revealCodeSidebar()
            },
            onResult: { action, path, ok in
                guard !ok else { return }
                overlay?.pushToast(Toast(
                    id: "host-path-action",
                    flavor: .error,
                    // The subject is the ACTION that failed, not a sentence about failing: the `FAILED`
                    // eyebrow already carries that, and lower-case keeps the instrument register the rest
                    // of the card is set in.
                    title: TerminalLeafPolicy.pathActionFailureTitle(action),
                    body: path,
                    // No `paneKey`: this reports a FAILED host action the user just took in the pane they
                    // are looking at — there is nowhere else to go, so the card stays a plain notice.
                ))
            },
        )
    }

    /// Nil the host path callbacks so the durable terminal model stops referencing this torn-down leaf.
    private func clearPathActionCallbacks() {
        guard let model = live?.terminalModel else { return }
        HostPathActions.clear(model: model)
    }

    /// Wire the pane's Command Navigator toggle: ⌃⌘O routes through the store
    /// (`requestBlockNavigatorInActivePane` → `activeTerminalModel.onRequestBlockNavigator`), so this closure
    /// fires only when THIS pane is active. It TOGGLES the per-leaf ``CommandNavigatorChrome``. No `[weak chrome]`
    /// needed: the chrome is the leaf's own `@State`, not the model, so there is no model→leaf retain cycle
    /// (`clearNavigatorCallbacks` nils the model's reference on teardown). No-op for a non-terminal / not-yet-live pane.
    private func wireNavigatorCallbacks() {
        guard let model = live?.terminalModel else { return }
        let chrome = navigatorChrome
        model.onRequestBlockNavigator = { chrome.isVisible.toggle() }
    }

    /// Nil the navigator callback so the durable terminal model stops referencing this torn-down leaf's
    /// `@State` chrome (the leaf is `.id(PaneID)`-keyed and can be rebuilt while the live session survives).
    private func clearNavigatorCallbacks() {
        live?.terminalModel?.onRequestBlockNavigator = nil
    }

    /// Wire the pane's Hint Mode actuation: the model resolves a label (macOS key-resolve
    /// or iOS tap-on-label) and fires ``TerminalViewModel/onHintConfirmed`` with the target + intent; the view is
    /// the thin platform actuator (open path → host RPC, open URL → client, copy → client pasteboard, reveal →
    /// host RPC — the SAME `LinkActionPolicy` the ⌘click / Jump-To paths use). `[weak model]` so the closure never
    /// retains the model into a cycle (also nilled on teardown). No-op off-terminal.
    private func wireHintCallbacks() {
        guard let model = live?.terminalModel else { return }
        model.onHintConfirmed = { [weak model] target, intent in
            guard let model else { return }
            TerminalHintActuator.perform(target, intent: intent, model: model)
        }
    }

    /// Nil the hint callback so the durable terminal model stops referencing this torn-down leaf.
    private func clearHintCallbacks() {
        live?.terminalModel?.onHintConfirmed = nil
    }

    /// Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks to the find-bar holder (the seam the store fires via
    /// `requestFind*InActivePane()`). No-op for a non-terminal / not-yet-live pane (`terminalModel == nil`);
    /// `terminalModel` is non-nil from session creation for a terminal pane, so this lands on first `.task`.
    private func wireFindCallbacks() {
        guard let model = live?.terminalModel else { return }
        let bar = findBar
        bar.attach(model)
        model.onRequestFind = { bar.open() }
        // Copy-mode `?` opens the SAME bar biased BACKWARD so its `n`/`N` step against the
        // forward sense (vim parity). Without this the `?` handler falls back to `onRequestFind` (forward) and
        // the backward bias never lands.
        model.onRequestFindBackward = { bar.open(backward: true) }
        model.onRequestFindNext = { bar.next() }
        model.onRequestFindPrev = { bar.previous() }
        // "Search all tabs" (find.png's `rectangle.stack` button): escalate the in-pane find to cross-tab
        // Global Search (⇧⌘F), seeded with the live query. The coordinator is captured by value (a long-lived
        // scene object); `nil` outside the app scene (tests/previews) ⇒ the button just dismisses the bar.
        bar.onSearchAllTabs = { [overlayCoordinator] seed in
            overlayCoordinator?.openGlobalSearch(seed: seed)
        }
    }

    /// Detach the holder + nil the callbacks so the model stops referencing a torn-down leaf's `@State`.
    private func clearFindCallbacks() {
        findBar.attach(nil)
        findBar.onSearchAllTabs = nil
        guard let model = live?.terminalModel else { return }
        model.onRequestFind = nil
        model.onRequestFindBackward = nil
        model.onRequestFindNext = nil
        model.onRequestFindPrev = nil
    }

    /// Wire the pane's SECURE-INPUT actuator: sync the controller to the model's current
    /// secure-input inputs + the live Auto-Secure-Input setting, then drive it on each change so macOS
    /// process-global Secure Keyboard Entry engages on a host no-echo password prompt (auto) or the manual toggle
    /// and disengages on the inverse edge. Also starts the controller observing the app-frontmost edge
    /// (idempotent) so an engaged lock is RELEASED whenever slopdesk is backgrounded and re-acquired on return —
    /// never leaked process-wide to other apps' keyboards. No-op for a non-terminal / not-yet-live pane; inert
    /// off macOS (stub controller).
    private func wireSecureInputCallbacks() {
        guard let model = live?.terminalModel else { return }
        let controller = secureInput
        controller.setAutoSecureInput(SettingsKey.autoSecureInputEnabled)
        controller.setHostNoEcho(model.hostNoEcho)
        controller.setManualOn(model.manualSecureInput)
        controller.observeAppActivity()
        model.onHostEchoChanged = { controller.setHostNoEcho($0) }
        model.onManualSecureInputChanged = { controller.setManualOn($0) }
    }

    /// Reconcile this pane's Secure Input to a LIVE "Auto Secure Input" settings change.
    /// Driven by `.onChange(of: autoSecureInput)`, it pushes the new value into BOTH the actuator and the pill
    /// mirror so an engaged process-global `EnableSecureEventInput` lock is RELEASED (and the pill hidden) the
    /// instant the setting turns OFF — never lingering until the next pane swap / echo edge. No-op for a
    /// not-yet-live pane; inert off macOS (stub controller, model mirror stays `false`).
    private func reconcileSecureInputSetting() {
        guard let model = live?.terminalModel else { return }
        secureInput.setAutoSecureInput(autoSecureInput)
        model.reconcileSecureInputSetting()
    }

    /// Force-disengage secure input + nil the callbacks on teardown so the process-global `EnableSecureEventInput`
    /// reference is always released on a pane close (never leaked) and a surviving model can't drive a dead
    /// leaf's controller.
    private func clearSecureInputCallbacks() {
        secureInput.teardown()
        guard let model = live?.terminalModel else { return }
        model.onHostEchoChanged = nil
        model.onManualSecureInputChanged = nil
    }

    /// What the connect-on-appear task waits for: this pane, once its id is one the host answers for.
    ///
    /// `nil` while this launch's `adoptWorkspace` is outstanding. The layout on screen is then the one
    /// read off `workspace.json`, staged optimistically — a PREDICTION — and a host that already has
    /// a workspace is about to replace every pane in it. Dialling inside that window spawns a shell
    /// per stale id on the host and abandons it a round trip later (``WorkspaceStore/panesMayDial``).
    private var dialTaskKey: PaneID? {
        TerminalLeafPolicy.dialTaskKey(pane: live?.id, mayDial: store.panesMayDial)
    }

    private func connectIfNeeded() async {
        // The key above already encodes the hold, and SwiftUI runs the task for the `nil` key too —
        // so the gate is re-asserted here rather than relied upon as a scheduling accident.
        guard store.panesMayDial else { return }
        // IDEMPOTENT: SwiftUI re-fires this `.task` on every remount — including a pane REMOUNT on a TAB switch
        // (the inactive tab's subtree is unmounted, then remounted on return). Route through the model's
        // `connectIfNeeded()`, which no-ops on a live/in-flight/supervised channel, so a tab switch never tears
        // down a healthy session or wipes the replay ring (the scrollback-lost-on-tab-switch regression). A genuinely
        // idle/dead channel still dials.
        await live?.connection?.connectIfNeeded()
    }

    /// What the `SLOPDESK_AUTOTYPE` seam waits for: the marked pane, actually CONNECTED.
    ///
    /// The seam's `.task` is keyed on this rather than on the leaf's mount, and that is its whole driver.
    /// `ConnectionViewModel` is `@Observable`, so the body re-runs as the pane's status moves and the task
    /// fires on the edge that matters — and re-fires on any later change, which is what lets an attempt
    /// cancelled inside the settle wait be retried. A mount-keyed task has neither property: it runs once,
    /// while the channel is still dialling, and a pane whose id never changes never remounts to run it
    /// again. That is an OUT path that is dead for the rest of the launch.
    private var autotypeTargetIfConnected: PaneID? {
        TerminalLeafPolicy.autotypeTaskKey(
            pane: live?.id,
            isTarget: live?.isAutotypeTarget ?? false,
            status: live?.connection?.status,
        )
    }

    /// Hands this leaf to the `SLOPDESK_AUTOTYPE` OUT-path proof seam (``AutotypeSeam``), which owns
    /// the once-per-launch latch. Unset in normal use, so a production launch is unaffected.
    private func runAutotypeIfRequested() async {
        guard let live else { return }
        let connected = if case .connected = live.connection?.status { true } else { false }
        let model = live.terminalModel
        await AutotypeSeam.run(
            command: ProcessInfo.processInfo.environment["SLOPDESK_AUTOTYPE"],
            isTarget: live.isAutotypeTarget,
            isConnected: connected,
            send: model.map { model in { model.sendInput($0) } },
        )
    }
}
#endif
