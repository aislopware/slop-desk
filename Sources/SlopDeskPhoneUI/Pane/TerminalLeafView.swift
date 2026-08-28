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
//
// WHAT IS LEFT HERE IS THE DRAWING AND THE TRIGGER. Everything this leaf DOES on appear, on a
// live-session swap and on teardown is ``TerminalPaneWiring``'s (`SlopDeskClientCore`) — the five
// callback pairs, the dial, the autotype seam, the secure-input reconcile and the chip `×`. None of
// them read a token, laid anything out or named a view type, and an AppKit canvas would have had to
// hand-translate the retain-cycle discipline, the teardown ORDER and the `EnableSecureEventInput`
// reference balance into a second language to reach them (docs/56 §3, increment 56c). This file keeps
// SwiftUI's `.task` / `.onChange` / `.onDisappear` and nothing else; the AppKit half keeps its
// `withObservationTracking` and nothing else.

#if os(iOS)
import Foundation
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskTerminal // TerminalViewportSnapshotting — the letterbox reads the live cell advance.
import SlopDeskVideoProtocol // ConfigRevision — what makes the two secure-input reads live
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

    /// The single overlay coordinator, used ONLY to surface a transient error toast when a host
    /// open/reveal RPC fails — so the action is never a SILENT no-op. `nil` in tests/previews ⇒ the
    /// failure is swallowed there, never a crash.
    ///
    /// A PARAMETER, not `@Environment(\.overlayCoordinator)` (docs/62 stage B): a `UIViewController`
    /// inherits no environment, so a value every ported surface would otherwise need TWO paths to
    /// reach is handed down the pane tree the way the Mac's ``SlopDeskMacUI/MacPaneContainer``
    /// already hands it down.
    let overlayCoordinator: OverlayCoordinator?

    /// The shared chrome model, used ONLY to reveal the RIGHT code panel when an open-in-code-panel
    /// action lands in the workbench. `nil` in previews/tests ⇒ the file still opens (host-side),
    /// the panel just isn't auto-revealed. Threaded for the same reason as ``overlayCoordinator``.
    let workspaceChrome: WorkspaceChromeState?

    /// This pane's wiring — the find bar, the Secure Keyboard Entry actuator and the Command Navigator
    /// chrome, plus every callback they are driven by. Per-pane `@State` (the leaf is `.id(PaneID)`-keyed,
    /// so no cross-pane bleed) and BELOW the view layer, because none of it is a drawing: an AppKit canvas
    /// holds the same object and triggers it from `withObservationTracking`. The three holders are `let`
    /// on it, so reading `wiring.findBar.visible` here observes the FIND BAR, exactly as the three separate
    /// `@State`s this replaced did.
    @State private var wiring = TerminalPaneWiring()

    /// The LIVE `controls.auto-secure-input` setting, re-read on every ``ConfigRevision`` bump rather
    /// than once at wire time, so a saved config file reconciles every open pane at once. Reading the
    /// revision registers the observation, so the body re-renders on the change edge and
    /// ``onChange(of:)`` pushes the new value into this pane's ``SecureKeyboardEntryController``
    /// (releasing an engaged process-global lock when turned OFF) AND the model's pill mirror — which
    /// is what keeps the carryover footgun shut.
    private var autoSecureInput: Bool {
        _ = ConfigRevision.shared.generation
        return SettingsKey.autoSecureInputEnabled
    }

    /// The LIVE `controls.secure-input-indicator` setting, live for the same reason: flipping it
    /// re-renders the leaf and ``PaneStatusPillPresentation`` re-evaluates the secure-input pill at
    /// once, rather than waiting for a pane swap or the next echo edge.
    private var secureInputIndicator: Bool {
        _ = ConfigRevision.shared.generation
        return SettingsKey.secureInputIndicatorEnabled
    }

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
        .task(id: dialTaskKey) { await TerminalPaneWiring.connectIfNeeded(live: live, store: store) }
        // The `SLOPDESK_AUTOTYPE` OUT-path proof (docs/22 §7) rides its OWN task, keyed on the pane
        // being connected rather than on this leaf appearing — see `autotypeTargetIfConnected`.
        .task(id: autotypeTargetIfConnected) { await TerminalPaneWiring.runAutotypeIfRequested(live: live) }
        // Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks on appear AND on every live-session swap (`initial: true`
        // fires once up-front, then on each `live?.id` change). Synchronous `@MainActor` closure — no actor
        // hop, unlike the `@Sendable async` `.task` above.
        .onChange(of: live?.id, initial: true) {
            wiring.wire(live: live, store: store, overlay: overlayCoordinator, chrome: workspaceChrome)
        }
        // Keep Secure Input LIVE to a Settings toggle. The wiring above only re-syncs on a pane
        // swap, so without this an engaged process-global lock + the pill would linger past
        // the user turning "Auto Secure Input" OFF — the carryover footgun. Pushing the new value into BOTH the
        // controller (releases the lock on the OFF edge) AND the model's pill mirror reconciles them at once.
        // The indicator change needs no push — `secureInputIndicator` re-reads on the same edge and
        // already re-renders the pill gate; the reconcile keeps the model mirror authoritative if a future read moves off it.
        .onChange(of: autoSecureInput) {
            wiring.reconcileSecureInput(live: live, autoSecureInput: autoSecureInput)
        }
        // Mirror the host cwd onto the model so the renderer's ⌘-hover hit-test can resolve a
        // RELATIVE detected path to its absolute form. The cwd arrives reactively from `PaneContainer`
        // (OSC 7) and changes independently of the live-session id, so it gets its own `onChange`; `initial: true`
        // seeds it once on mount. No-op when no model yet.
        .onChange(of: cwd, initial: true) {
            live?.terminalModel?.linkCwd = cwd
        }
        // Clear the callbacks when the leaf is torn down so a dead `@State` holder can't be driven by a
        // surviving model (the model is owned by the live session, which can outlive this `.id(PaneID)` leaf).
        .onDisappear { wiring.clear(live: live) }
    }

    /// The terminal pixels (the seam) — production renderer if the app registered one, else the headless
    /// placeholder. This library NEVER imports libghostty/Metal: it only calls the factory seam.
    ///
    /// This is the seam's SwiftUI shape, and the phone's only one. The AppKit canvas takes the same
    /// renderer through `TerminalRendererFactory.nativeShared`, which hands back the layer-hosting `NSView`
    /// itself rather than an `AnyView` an `NSHostingView` would have to claim the hit-test for (docs/56
    /// stage F, risk 2). Both shapes resolve to one `GhosttyLayerBackedView` per pane and one libghostty
    /// surface; nothing that must happen for BOTH may live in `GhosttyTerminalView.body` or here.
    ///
    /// The vi-mode
    /// pill, `🔒 READ ONLY ×` pill and ⌘F find bar float top-trailing OVER the surface (none reflow the buffer),
    /// stacked in one overlay so they never collide; the vi key-hint bar floats along the bottom.
    private var terminalSurface: some View {
        ZStack(alignment: .topLeading) {
            if let model = live?.terminalModel {
                // THE pane's key responder, under the pixels and behind every overlay. The renderer is
                // a Metal layer that answers no key event, so without this mount the pane cannot
                // receive a keystroke at all. Zero-sized and touch-transparent — it holds first
                // responder, the accessory row and the press handlers, nothing visual.
                if let live {
                    TerminalInputHost(live: live, store: store, focusCoordinator: store.focusCoordinator)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
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
                // on ↩. Toggled by `onRequestBlockNavigator` (wired by ``TerminalPaneWiring``); the store fires
                // that only on the ACTIVE pane, so this card only mounts over the focused pane.
                if wiring.navigatorChrome.isVisible {
                    CommandNavigatorView(
                        model: model,
                        store: store,
                        onClose: { wiring.navigatorChrome.isVisible = false },
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
                // SEND A FILE. The pane's only door for one on a phone: `PaneDropReceiver` is mounted
                // under this leaf and reachable on an iPad in Split View, but an iPhone has no second
                // app to drag OUT of, so the receiver has nothing to receive. Offered on the FOCUSED
                // pane only — it is a control, not a status chip, and a workspace of them would be one
                // per pane competing for the same corner. See ``PaneFileImporter``.
                if isFocused, let live {
                    PaneFileImportButton(
                        paneID: live.id,
                        store: store,
                        terminalModel: live.terminalModel,
                        overlayCoordinator: overlayCoordinator,
                    )
                    .transition(.opacity)
                }
                if PaneStatusPillPresentation.showsViModePill(pillConditions),
                   let model = live?.terminalModel
                {
                    ViModePill(model: model, onExit: { model.exitCopyMode() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ForEach(visiblePills, id: \.self) { pill in
                    PaneStatusPillView(
                        pill: pill,
                        onDismiss: { TerminalPaneWiring.dismiss(pill, live: live, store: store) },
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if wiring.findBar.visible, live?.terminalModel != nil {
                    TerminalFindBar(model: wiring.findBar)
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
        .animation(Slate.Anim.reveal, value: wiring.findBar.visible)
        .animation(Slate.Anim.reveal, value: visiblePills)
        // The send-a-file plate fades with focus rather than snapping — same rung as the chips it
        // shares the corner with, so a pane swap moves one piece of chrome, not two at two speeds.
        .animation(Slate.Anim.reveal, value: isFocused)
        .animation(Slate.Anim.reveal, value: PaneStatusPillPresentation.showsViModePill(pillConditions))
        .animation(Slate.Anim.reveal, value: showViHintBar)
        .animation(Slate.Anim.reveal, value: wiring.navigatorChrome.isVisible)
    }

    /// Places the terminal pixels.
    ///
    /// The pane holds a grid it did NOT choose — a phone is size-passive host-side (docs/45 §8.3), so
    /// the resolved grid belongs to whichever Mac clamped the fold — and the surface is centred with
    /// letterbox bars plus the `120×40 · sized by MacBook Pro` readout, which names the client that
    /// picked the size so the fold does not read as a bug.
    private func letterboxed(
        model: TerminalViewModel,
        @ViewBuilder _ content: @escaping () -> some View,
    ) -> some View {
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

    /// What the connect-on-appear task waits for: this pane, once its id is one the host answers for.
    ///
    /// `nil` while this launch's `adoptWorkspace` is outstanding. The layout on screen is then the one
    /// read off `workspace.json`, staged optimistically — a PREDICTION — and a host that already has
    /// a workspace is about to replace every pane in it. Dialling inside that window spawns a shell
    /// per stale id on the host and abandons it a round trip later (``WorkspaceStore/panesMayDial``).
    private var dialTaskKey: PaneID? {
        TerminalLeafPolicy.dialTaskKey(pane: live?.id, mayDial: store.panesMayDial)
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
}
#endif
