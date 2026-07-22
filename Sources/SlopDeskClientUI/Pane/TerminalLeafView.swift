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
// DEFERRED (clean seam, not wired yet):
//   - TODO: the `TerminalBlocksView` command-block decoration overlay.

#if canImport(SwiftUI)
import Defaults // observe the Auto-Secure-Input / indicator defaults so the toggle is LIVE.
import Foundation
import SlopDeskWorkspaceCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct TerminalLeafView: View {
    /// The live session backing this pane (terminal model + input bar). When `nil` (no live handle yet, or
    /// a non-terminal kind) the leaf shows the placeholder only.
    let live: LivePaneSession?
    /// Workspace focus → drives the production renderer's first responder (only the focused pane types).
    let isFocused: Bool
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// The host-reported working directory (`PaneSpec.lastKnownCwd`, live-set from OSC 7)
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
    /// leaf and `showSecureInputPill` re-evaluates at once — turning the pill off mid-prompt without waiting for a
    /// pane swap or the next echo edge.
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

    var body: some View {
        VStack(spacing: 0) {
            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Inner breathing room so terminal content isn't flush against the pane edges / split divider
                // (issue: the user asked for padding around the panes). `NativePaneColor.terminalBackground` on the VStack fills
                // the inset gutter (flat, no card). NB the inset shrinks the libghostty surface, so the host PTY
                // grid loses ~1 col/row each side — it reflows through the existing PaneContainer.size →
                // resize-scrim → host TIOCSWINSZ path, no new signal needed.
                .padding(Slate.Metric.space2)
            // NO per-pane status strip on a TERMINAL pane (issue: the user judged the terminal pane footer
            // low-value and asked to drop it). The cwd / exit / progress cues are low-value; host + connection status now
            // live ONCE in the sidebar footer (`NavigatorColumn` → `ConnectionCluster`; titlebar trailing when collapsed), not per pane. The
            // GUI/window pane keeps a bottom bar, but as a CONTROL bar (resize / lock / zoom), not a status strip.
        }
        .background(NativePaneColor.terminalBackground)
        .task(id: live?.id) { await connectIfNeeded() }
        // Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks on appear AND on every live-session swap (`initial: true`
        // fires once up-front, then on each `live?.id` change). Synchronous `@MainActor` closure — no actor
        // hop, unlike the `@Sendable async` `.task` above.
        .onChange(of: live?.id, initial: true) { wirePaneCallbacks() }
        // Keep Secure Input LIVE to a Settings toggle. `wireSecureInputCallbacks()` only
        // re-syncs on a pane swap, so without this an engaged process-global lock + the pill would linger past
        // the user turning "Auto Secure Input" OFF — the carryover footgun. Pushing the new value into BOTH the
        // controller (releases the lock on the OFF edge) AND the model's pill mirror reconciles them at once.
        // The indicator change needs no push — `secureInputIndicator` as `@Default` already re-renders
        // `showSecureInputPill`; the reconcile keeps the model mirror authoritative if a future read moves off it.
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
    /// stacked in one overlay so they never collide; the vi key-hint bar floats along the bottom — never in the
    /// static-mirror snapshot path.
    private var terminalSurface: some View {
        ZStack(alignment: .topLeading) {
            if let model = live?.terminalModel {
                if TerminalRendererFactory.shared != nil {
                    TerminalRendererFactory.make(model: model, isFocused: isFocused)
                } else {
                    BuildStatusPlaceholderView(model: model)
                }
                // The ⌘-hold link underline, a DECORATION overlay over the surface (never a
                // content branch — libghostty-freeze guardrail). Coincident with the surface (both fill this
                // top-leading ZStack), so the cell metrics (origin 0,0 = surface top-left) map straight to
                // the Canvas. Inert unless the renderer set `linkHighlightActive` (macOS ⌘); a placeholder
                // surface doesn't conform to the viewport seam, so it draws nothing.
                if !staticMirror {
                    LinkHighlightOverlay(model: model, cwd: cwd)
                }
                // The prompt-jump landed flash — one ~240ms accent fade over the row libghostty pinned
                // the jumped-to prompt at, anchoring the eye after the viewport hard-cuts. Also a
                // DECORATION overlay coincident with the surface; inert until a jump settles.
                if !staticMirror {
                    PromptJumpFlashOverlay(model: model)
                }
                // The copy-mode block cursor — one accent-outlined cell at the vi cursor (the
                // selection itself renders natively via the fork's set_selection ABI). Also a DECORATION
                // overlay coincident with the surface; inert outside copy-mode / when the cursor is
                // scrolled off-viewport / over a placeholder surface.
                if !staticMirror {
                    ViCursorOverlay(model: model)
                }
                // The Vimium Hint Mode overlay — dims the surface + draws yellow 2-letter
                // labels when armed (⌘⇧J open / ⌘⇧Y copy / reveal). Also a DECORATION overlay coincident with the
                // surface (origin 0,0). Inert unless the renderer armed `hintMode` (or an iOS tap-on-label); a
                // placeholder surface draws nothing.
                if !staticMirror {
                    HintModeOverlay(model: model)
                }
                // The Command Navigator (⌃⌘O) — a scrimmed, centered card listing the pane's
                // recent OSC-133 command blocks (search + All/Failed/Bookmarked filter), jumping the scrollback
                // on ↩. Toggled by `onRequestBlockNavigator` (wired in `wireNavigatorCallbacks`); the store fires
                // that only on the ACTIVE pane, so this card only mounts over the focused pane. Never in the
                // static-mirror path.
                if !staticMirror, navigatorChrome.isVisible {
                    CommandNavigatorView(
                        model: model,
                        store: store,
                        onClose: { navigatorChrome.isVisible = false },
                    )
                    .transition(.opacity)
                }
                // TODO(L3): layer `TerminalBlocksView` here as a decoration OVERLAY (never a content
                // branch — libghostty-freeze guardrail).
            } else {
                Color.clear
            }
        }
        // ONE top-trailing overlay holds the vi-mode pill, read-only pill, SECURE INPUT
        // pill and find bar, stacked top→down so an open find bar reflows BELOW the persistent
        // pills instead of overlapping them. slopdesk has no persistent titlebar, so the pane hosts these pills
        // directly (see `PaneStatusPills.swift` / `ViModeOverlay.swift`). The vi pill and read-only pill are
        // mutually exclusive: `showReadOnlyPill` is gated `!copyModeBadgeActive`, so the lock pill steps aside
        // while vi mode owns the slot.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: Slate.Metric.space2) {
                if !staticMirror, showViModePill, let model = live?.terminalModel {
                    ViModePill(model: model, onExit: { model.exitCopyMode() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !staticMirror, showReadOnlyPill {
                    ReadOnlyPill(onDeactivate: { live?.terminalModel?.exitReadOnly() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !staticMirror, showSecureInputPill {
                    SecureInputPill()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                // SAFETY chrome, never hidden by read-only/vi gates: while this pane's tab is armed for
                // synchronized input (⌘⇧I), every keystroke here fans into the tab's siblings — a mode
                // that MUST be visible wherever it acts (an invisibly-armed tab reads as a cross-pane
                // input leak). The `×` disarms the whole tab.
                if !staticMirror, showSyncInputPill, let paneID = live?.id {
                    SyncInputPill(onDisarm: { store.disarmSyncInput(for: paneID) })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !staticMirror, findBar.visible, live?.terminalModel != nil {
                    TerminalFindBar(model: findBar)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(Slate.Metric.space2)
        }
        // The vi key-hint bar floats along the pane BOTTOM when `⌘/` has toggled it on during a vi
        // session — `showViHintBar` gates it on `copyModeBadgeActive` so it tears down the instant vi mode exits
        // (which also resets `showViKeyHints`).
        .overlay(alignment: .bottom) {
            if !staticMirror, showViHintBar {
                ViKeyHintBar()
                    .padding(Slate.Metric.space2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // The transient `COPIED · N` receipt chip — bottom-TRAILING, its own overlay slot so appearing
        // never reflows the top-trailing pill stack (no layout shift for a frequent action). Fade-only
        // (no travel), hit-transparent, self-expiring: the chip's dwell task calls `clearCopyReceipt()`
        // and the `smallFade` below fades it out. Reading `copyReceipt` here registers observation, so
        // every pane-scoped copy path (⌘C, yank, navigator, hints) lights it reactively.
        .overlay(alignment: .bottomTrailing) {
            if !staticMirror, let model = live?.terminalModel, let receipt = model.copyReceipt {
                CopyReceiptChip(receipt: receipt, onExpire: { model.clearCopyReceipt() })
                    .padding(Slate.Metric.space2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Slate.Anim.smallFade, value: live?.terminalModel?.copyReceipt)
        .animation(Slate.Anim.reveal, value: findBar.visible)
        .animation(Slate.Anim.reveal, value: showReadOnlyPill)
        .animation(Slate.Anim.reveal, value: showSecureInputPill)
        .animation(Slate.Anim.reveal, value: showSyncInputPill)
        .animation(Slate.Anim.reveal, value: showViModePill)
        .animation(Slate.Anim.reveal, value: showViHintBar)
        .animation(Slate.Anim.reveal, value: navigatorChrome.isVisible)
    }

    /// Whether the `🛡 SECURE INPUT` pill is shown. Visible iff secure input is active
    /// (``TerminalViewModel/secureInputActive`` — auto password-prompt path or manual toggle), the indicator
    /// setting is on, AND the pane is NOT read-only (under read-only no input can fire, so the cue is moot —
    /// spec). `secureInputActive` is always `false` off macOS, so the pill never lights on iOS. `false` for a
    /// not-yet-live pane.
    /// Whether the `⚠ SYNC INPUT ×` pill is shown: the pane's TAB is armed for synchronized input.
    /// Deliberately NOT gated by read-only / vi mode (unlike the other pills): the mode leaks INTO this
    /// pane from siblings regardless of this pane's own input gate, so the warning must stay up.
    /// `store.syncInputArmed(for:)` reads the observable `syncInputTabs` — arming/disarming anywhere
    /// re-renders this leaf live. `false` for a not-yet-live pane.
    private var showSyncInputPill: Bool {
        guard let paneID = live?.id else { return false }
        return store.syncInputArmed(for: paneID)
    }

    private var showSecureInputPill: Bool {
        guard let model = live?.terminalModel else { return false }
        // Read the OBSERVED `secureInputIndicator` default (not the bare `SettingsKey` accessor) so SwiftUI
        // tracks the dependency: toggling "Show Secure Input Indicator" re-renders this leaf and hides the pill
        // at once (the live-toggle contract), instead of waiting for a pane swap.
        return model.secureInputActive && secureInputIndicator && !model.readOnlyBadgeActive
    }

    /// Whether the `🔒 READ ONLY ×` pill is shown. Reads the model's OBSERVABLE mirrors so
    /// it lights / clears reactively: visible iff the input gate is armed (``TerminalViewModel/readOnlyBadgeActive``)
    /// AND NOT in vi / copy mode (``TerminalViewModel/copyModeBadgeActive``) — copy mode hides the pill per spec
    /// (its keybindings drive selection, not the shell, so the lock isn't needed). `false` for a non-terminal /
    /// not-yet-live pane.
    private var showReadOnlyPill: Bool {
        guard let model = live?.terminalModel else { return false }
        return model.readOnlyBadgeActive && !model.copyModeBadgeActive
    }

    /// Whether the vi-mode pill is shown. Reads the OBSERVABLE
    /// ``TerminalViewModel/copyModeBadgeActive`` mirror (NOT the `@ObservationIgnored` `isCopyMode` the keyDown
    /// path reads) so the pill lights / clears reactively. `false` for a non-terminal / not-yet-live pane.
    /// Steps aside while HINT MODE is armed on top (`f` / ⌘⇧J / ⌘⇧Y during vi): the `HINTS` badge owns the
    /// same top-trailing corner (it lives in ``HintModeOverlay``, outside this pill stack), so without the
    /// gate the two overlapped — one corner, one mode chip; the vi pill returns the instant hints cancel.
    private var showViModePill: Bool {
        guard let model = live?.terminalModel else { return false }
        return model.copyModeBadgeActive && model.hintMode == nil
    }

    /// Whether the vi key-hint bar is shown: in vi mode AND the per-session `⌘/` toggle is
    /// on. Both reads are OBSERVABLE mirrors, so it reveals / hides reactively; the `copyModeBadgeActive` gate
    /// makes teardown unconditional so it can never linger after vi mode exits (``TerminalViewModel/exitCopyMode()``
    /// also resets ``TerminalViewModel/showViKeyHints``).
    private var showViHintBar: Bool {
        guard let model = live?.terminalModel else { return false }
        return model.copyModeBadgeActive && model.showViKeyHints
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
        HostPathActions.wire(
            model: model,
            client: { [weak live] in live?.connection?.activeMetadataClient },
            onResult: { action, path, ok in
                guard !ok else { return }
                overlay?.pushToast(Toast(
                    id: "host-path-action",
                    flavor: .error,
                    title: action == .open ? "Couldn't open on host" : "Couldn't reveal on host",
                    body: path,
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
            Self.performHintAction(target, intent: intent, model: model)
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

    private func connectIfNeeded() async {
        guard !staticMirror else { return }
        // IDEMPOTENT: SwiftUI re-fires this `.task` on every remount — including a pane REMOUNT on a TAB switch
        // (the inactive tab's subtree is unmounted, then remounted on return). Route through the model's
        // `connectIfNeeded()`, which no-ops on a live/in-flight/supervised channel, so a tab switch never tears
        // down a healthy session or wipes the replay ring (the scrollback-lost-on-tab-switch regression). A genuinely
        // idle/dead channel still dials.
        await live?.connection?.connectIfNeeded()
        await runAutotypeIfRequested()
    }

    /// The `SLOPDESK_AUTOTYPE` OUT-path proof seam (docs/22 §7): keeps `LivePaneSession.isAutotypeTarget`
    /// actually consumed so `check-macos.sh --connect`'s OUT-path proof stays green. After tab0/pane0's terminal
    /// connects, if `SLOPDESK_AUTOTYPE` is set, push the command bytes through the REAL OUT path —
    /// `terminalModel.sendInput` → the ordered drain → host PTY: the exact keystroke→host chain the
    /// renderer drives, so the typed command actually executes on the host and renders back. IDEMPOTENT
    /// per process: the `.task` re-fires on every tab-switch remount; the latch keeps a second copy of
    /// the command off the shell. Unset in normal use, so a production launch is unaffected.
    private func runAutotypeIfRequested() async {
        guard let live, live.isAutotypeTarget, !Self.autotypeFired,
              let cmd = ProcessInfo.processInfo.environment["SLOPDESK_AUTOTYPE"], !cmd.isEmpty,
              let connection = live.connection, case .connected = connection.status,
              let terminalModel = live.terminalModel else { return }
        Self.autotypeFired = true
        try? await Task.sleep(nanoseconds: 1_500_000_000) // let the remote prompt come up
        terminalModel.sendInput(Data((cmd + "\n").utf8))
    }

    /// Once-per-process latch for ``runAutotypeIfRequested()`` — the `.task` re-fires on every remount,
    /// and the proof command must land exactly once. `@MainActor`-confined (the leaf body/task both are).
    @MainActor private static var autotypeFired = false

    // MARK: - Hint Mode actuation

    /// Actuate a resolved hint `target` for `intent`. A path/URL link routes through the SAME pure
    /// ``LinkActionPolicy`` the ⌘click / Jump-To paths use (no parallel mapping to drift); an IP OPENS
    /// (`http://<ip>`) on Hint-to-Open and copies otherwise; a git-hash copies its text on every intent (no open
    /// target for a bare hash — a deliberate gap, see DECISIONS.md); a custom `hint-pattern` runs its `{0}`
    /// action template (a known-safe `open <url>` on the client, else verbatim on the HOST shell — the mapping
    /// note's "arbitrary shell strings run on the host"). `static` so the closure needs no leaf `self`.
    private static func performHintAction(_ target: HintTarget, intent: HintIntent, model: TerminalViewModel) {
        switch target.kind {
        case let .link(link):
            actuate(linkAction(for: intent, link: link), model: model)
        case .ipAddress:
            // Hint-to-OPEN on a bare IP browses to it as a host. `copy`/`reveal` copy the text — no Finder
            // target for an IP. `http://` (not `https://`): a bare IP almost always serves plain HTTP and a TLS
            // cert won't match a raw address.
            switch intent {
            case .open: openURLString("http://" + target.raw)
            case .copy,
                 .reveal: copyToPasteboard(target.raw, model: model)
            }
        case .gitHash:
            // A bare commit hash has NO open target (no repo URL to resolve it against), so every intent copies
            // the text — a deliberate gap in docs/DECISIONS.md rather than faking an open.
            copyToPasteboard(target.raw, model: model)
        case let .custom(actionTemplate):
            switch intent {
            case .copy: copyToPasteboard(target.raw, model: model)
            case .open,
                 .reveal: runCustomHintAction(template: actionTemplate, raw: target.raw, model: model)
            }
        }
    }

    /// Map a hint `intent` on a detected `link` to a ``LinkAction`` through the SAME pure ``LinkActionPolicy``
    /// the Jump-To (copy) / ⌘⇧click (reveal) paths use — open = best handler, copy = copy path/URL, reveal =
    /// reveal-in-Finder (a no-op for a URL). The OPEN intent is an EXPLICIT open (⌘⇧J Hint-to-Open), so it routes
    /// through the config-INDEPENDENT ``LinkActionPolicy/explicitOpenAction`` — NOT the configurable ⌘click
    /// gesture, which would silently copy / no-op under `link-cmd-click = copy/nothing`. The
    /// renderer's mouse ⌘click / ⌘⇧click keeps the gesture path.
    private static func linkAction(for intent: HintIntent, link: DetectedLink) -> LinkAction {
        switch intent {
        case .open: LinkActionPolicy.explicitOpenAction(link: link)
        case .copy: LinkActionPolicy.action(for: .copyPath, link: link)
        case .reveal: LinkActionPolicy.action(for: .revealInFinder, link: link)
        }
    }

    /// The thin platform dispatch behind a resolved ``LinkAction`` (mirrors the renderer's `performLinkAction` /
    /// the Jump-To `actuate`): copy → client pasteboard; cd → verbatim-UTF-8 down the PTY; open/reveal → the
    /// host RPC seams on the model; URL → client open.
    private static func actuate(_ action: LinkAction, model: TerminalViewModel) {
        switch action {
        case .nothing:
            return
        case let .copyPathClient(text):
            copyToPasteboard(text, model: model)
        case let .changeDirectoryPTY(path):
            model.sendInput(Data(LinkActionPolicy.changeDirectoryCommandLine(path).utf8))
        case let .openURLClient(urlString):
            openURLString(urlString)
        case let .openHost(path):
            model.onRequestOpenHostPath?(path)
        case let .revealHost(path):
            model.onRequestRevealHostPath?(path)
        }
    }

    /// Run a custom `hint-pattern`'s action template with `{0}` replaced by the matched text. A known-safe
    /// `open <url>` opens the URL on the CLIENT; anything else runs on the HOST shell (the correct execution
    /// context per the hint-mode mapping note) by injecting it verbatim down the PTY. No template ⇒ copy the text.
    private static func runCustomHintAction(template: String?, raw: String, model: TerminalViewModel) {
        guard let template, !template.isEmpty else {
            copyToPasteboard(raw, model: model)
            return
        }
        let resolved = template.replacingOccurrences(of: "{0}", with: raw)
        if resolved.hasPrefix("open ") {
            let rest = String(resolved.dropFirst("open ".count)).trimmingCharacters(in: .whitespaces)
            if let url = URL(string: rest), url.scheme != nil {
                openURLString(rest)
                return
            }
        }
        model.sendInput(Data((resolved + "\n").utf8))
    }

    /// Open a URL string on the CLIENT (a URL / IP is host-agnostic). A no-op for an unparseable string.
    private static func openURLString(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Copy text to the platform pasteboard (the Jump-To / context-menu idiom) and publish the pane's
    /// `COPIED · N` receipt. A no-op for empty text.
    private static func copyToPasteboard(_ text: String, model: TerminalViewModel) {
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        ClientPasteboard.write(text)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        model.noteClipboardCopy(text)
    }
}
#endif
