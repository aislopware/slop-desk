// TerminalLeafView — the content of a terminal pane leaf (REBUILD-V2, L2 MINIMAL). Composes, top→bottom:
//   [ terminal surface seam (TerminalRendererFactory.make — the SEAM, else BuildStatusPlaceholderView) ]
//   [ PromptQueueStrip — chips above the Composer (E12; self-hides when the queue is empty)            ]
//   [ ComposerBar — the ⌘⇧E / ⌘⇧M Composer + Prompt-Queue input (E12; mounted only when visible)       ]
// otty shows NO persistent cwd chrome in the resting window — the working-directory chip only appears in
// menus/overlays — so there is no bottom cwd pill here. The bottom command `InputBar` is likewise NOT
// persistently mounted: otty has no persistent composer in the resting window (it toggles one with ⌘⇧E).
// The E12 ``ComposerBar`` reflows in below the surface ONLY while the durable ``ComposerModel/isVisible``
// (and the queue strip while items are pending), exactly as `composer.png` shrinks the terminal to make room.
//
// SEAM usage: the terminal pixels come from `TerminalRendererFactory.make(model:isFocused:)`. The Xcode
// app target injects the production `GhosttyTerminalView`; a headless `swift build` registers no factory,
// so we mount `BuildStatusPlaceholderView` instead — this library NEVER imports libghostty/Metal.
//
// Lazy connect: `live.connection?.connect()` is called in a `.task` on appear (so restoring N panes does
// not slam N sockets). The whole leaf is keyed `.id(PaneID)` by the caller (PaneContainer) so the surface
// / connection is never reused across panes (identity hazard). SYSTEM colours only.
//
// DEFERRED (clean seams, do NOT wire in L2):
//   - TODO(L3): the `TerminalBlocksView` command-block decoration overlay.
//   - TODO(L5): the `AgentInputFooter` (Claude bottom bar) at the pane bottom.
//   - TODO(L5): the `FileExplorerPanel` side panel.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct TerminalLeafView: View {
    /// The live session backing this pane (terminal model + input bar). When `nil` (no live handle yet, or
    /// a non-terminal kind) the leaf shows the placeholder only.
    let live: LivePaneSession?
    /// Workspace focus → drives the production renderer's first responder (only the focused pane types).
    let isFocused: Bool
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// E5 ES-E5-1..4: the in-pane ⌘F find bar's view-model (pure ``TerminalSearchController`` + the libghostty
    /// `search:` passthrough). Owned per-leaf and wired to the pane's `onRequestFind*` callbacks in `.task`;
    /// the leaf is `.id(PaneID)`-keyed by `PaneContainer`, so this `@State` is per-pane (no cross-pane bleed).
    @State private var findBar = TerminalFindBarModel()

    /// E12: the per-leaf Composer chrome (queue-input mode + focus token) the pane's `onRequestComposer` /
    /// `onRequestPromptQueue` callbacks mutate. Per-pane (`.id(PaneID)`-keyed leaf) — never the DURABLE
    /// ``ComposerModel``'s concern (that lives on the live session so the draft survives tab switches).
    @State private var composerChrome = ComposerLeafChrome()

    /// E17 ES-E17-4 / WI-7: the per-pane macOS Secure Keyboard Entry actuator. Driven (in `wirePaneCallbacks`)
    /// from the pane model's `onHostEchoChanged` (auto, on a host no-echo password prompt) + the manual
    /// `onManualSecureInputChanged` toggle, it engages / disengages process-global `EnableSecureEventInput`
    /// with a strict single-reference balance. It also observes the app-frontmost edge (see
    /// ``SecureKeyboardEntryController/observeAppActivity()``), so the lock is released whenever aislopdesk is
    /// backgrounded / window-resigned and re-acquired on return — never leaked to other apps' keyboards. Per-pane
    /// (`.id(PaneID)`-keyed leaf), torn down on disappear so the lock can never leak past a pane close either.
    /// Inert off macOS (the controller is a no-op).
    @State private var secureInput = SecureKeyboardEntryController()

    var body: some View {
        VStack(spacing: 0) {
            // TODO(L5): mount `FileExplorerPanel` beside the surface when the per-pane explorer is open.
            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomComposer
            // TODO(L5): mount `AgentInputFooter` at the pane bottom (agent-gated).
        }
        .background(NativePaneColor.terminalBackground)
        .task(id: live?.id) { await connectIfNeeded() }
        // Wire the pane's ⌘F / ⌘G / ⇧⌘G + ⌘⇧E / ⌘⇧M callbacks on appear AND on every live-session swap
        // (`initial: true` fires once up-front, then on each `live?.id` change). A synchronous `@MainActor`
        // closure — no actor hop, unlike the `@Sendable async` `.task` action above.
        .onChange(of: live?.id, initial: true) { wirePaneCallbacks() }
        // Clear the callbacks when the leaf is torn down so a dead `@State` holder can't be driven by a
        // surviving model (the model is owned by the live session, which can outlive this `.id(PaneID)` leaf).
        .onDisappear { clearPaneCallbacks() }
        .animation(Otty.Anim.reveal, value: live?.composer?.isVisible)
    }

    /// The bottom Composer chrome — the Prompt-Queue chip strip + the ``ComposerBar``, reflowed in below the
    /// terminal surface. Mounted only when the durable Composer is visible OR has queued items, and ONLY when
    /// it is not pinned / floating (pin + float promote the Composer OUT of the pane subtree to a window-level
    /// / float mount, WI-6). The strip self-hides when the queue is empty, so a visible-but-empty Composer
    /// shows just the bar. Never in the static-mirror snapshot path.
    @ViewBuilder private var bottomComposer: some View {
        if let composer = live?.composer, mountBottomComposer(composer) {
            VStack(spacing: 0) {
                PromptQueueStrip(composer: composer)
                if composer.isVisible {
                    ComposerBar(composer: composer, chrome: composerChrome, maxLines: composerMaxLines)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Whether the in-pane Composer chrome should mount: a live terminal pane, not the static mirror, the
    /// Composer not promoted out (pin/float), and either visible or holding queued chips.
    private func mountBottomComposer(_ composer: ComposerModel) -> Bool {
        guard !staticMirror, live?.terminalModel != nil else { return false }
        guard !composer.isPinned, !composer.isFloating else { return false }
        return composer.isVisible || !composer.promptQueue.isEmpty
    }

    /// The Composer field's growing line budget, derived from the `composerMaxHeight` pref (a fraction of the
    /// pane height) against a reference pane of ~32 rows, clamped to a sane `4…24`. A geometry-exact
    /// pane-height fraction is a documented refinement (WI-5 keeps the InputBar line-limit idiom — lowest risk).
    private var composerMaxLines: Int {
        let lines = Int((SettingsKey.composerMaxHeightFraction * 32).rounded())
        return min(24, max(4, lines))
    }

    /// The terminal pixels (the seam) — production renderer if the app registered one, else the headless
    /// placeholder. This library NEVER imports libghostty/Metal: it only calls the factory seam. The E17 vi-mode
    /// pill, the `🔒 READ ONLY ×` pill and the ⌘F find bar float top-trailing OVER the surface (none reflow the
    /// buffer), stacked in one overlay so they never collide; the E17 vi key-hint bar floats along the bottom —
    /// never in the static-mirror snapshot path.
    private var terminalSurface: some View {
        ZStack(alignment: .topLeading) {
            if let model = live?.terminalModel {
                if TerminalRendererFactory.shared != nil {
                    TerminalRendererFactory.make(model: model, isFocused: isFocused)
                } else {
                    BuildStatusPlaceholderView(model: model)
                }
                // TODO(L3): layer `TerminalBlocksView` here as a decoration OVERLAY (never a content
                // branch — libghostty-freeze guardrail).
            } else {
                Color.clear
            }
        }
        // ONE top-trailing overlay holds the vi-mode pill (E17 WI-5), the read-only pill (E17 WI-3), the
        // SECURE INPUT pill (E17 WI-7) and the find bar (E5), stacked top→down so an open find bar reflows
        // BELOW the persistent pills instead of overlapping them. otty places the pills in the window
        // titlebar's top-right; aislopdesk has no
        // persistent titlebar, so the pane's top-trailing overlay is the faithful equivalent (see
        // `PaneStatusPills.swift` / `ViModeOverlay.swift`). The vi pill and the read-only pill are mutually
        // exclusive by construction — `showReadOnlyPill` is gated `!copyModeBadgeActive`, so the lock pill
        // steps aside while vi mode owns the slot.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: Otty.Metric.space2) {
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
                if !staticMirror, findBar.visible, live?.terminalModel != nil {
                    TerminalFindBar(model: findBar)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(Otty.Metric.space2)
        }
        // The vi key-hint bar (E17 WI-5) floats along the pane BOTTOM (the vi-mode spec's likely position) when
        // `⌘/` has toggled it on during a vi session — `showViHintBar` gates it on `copyModeBadgeActive` so it
        // tears down the instant vi mode exits (which also resets `showViKeyHints`).
        .overlay(alignment: .bottom) {
            if !staticMirror, showViHintBar {
                ViKeyHintBar()
                    .padding(Otty.Metric.space2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Otty.Anim.reveal, value: findBar.visible)
        .animation(Otty.Anim.reveal, value: showReadOnlyPill)
        .animation(Otty.Anim.reveal, value: showSecureInputPill)
        .animation(Otty.Anim.reveal, value: showViModePill)
        .animation(Otty.Anim.reveal, value: showViHintBar)
    }

    /// Whether the `🛡 SECURE INPUT` pill is shown (E17 ES-E17-4 / WI-7). Visible iff secure input is active for
    /// the pane (``TerminalViewModel/secureInputActive`` — the auto password-prompt path or the manual toggle),
    /// the indicator setting is on (``SettingsKey/secureInputIndicatorEnabled``), AND the pane is NOT read-only
    /// (under read-only no input path can fire, so the secure-input cue is moot — spec). `secureInputActive` is
    /// always `false` off macOS, so the cross-platform pill never lights on iOS. `false` for a not-yet-live pane.
    private var showSecureInputPill: Bool {
        guard let model = live?.terminalModel else { return false }
        return model.secureInputActive && SettingsKey.secureInputIndicatorEnabled && !model.readOnlyBadgeActive
    }

    /// Whether the `🔒 READ ONLY ×` pill is shown (E17 ES-E17-1 / WI-3). Reads the pane model's OBSERVABLE
    /// mirrors so it lights / clears reactively: visible iff the pane's input gate is armed
    /// (``TerminalViewModel/readOnlyBadgeActive``) AND it is NOT in vi / copy mode
    /// (``TerminalViewModel/copyModeBadgeActive``) — copy mode temporarily hides the pill per the spec (its
    /// keybindings drive selection, not the shell, so the lock is not needed while it is active). `false`
    /// for a non-terminal / not-yet-live pane.
    private var showReadOnlyPill: Bool {
        guard let model = live?.terminalModel else { return false }
        return model.readOnlyBadgeActive && !model.copyModeBadgeActive
    }

    /// Whether the vi-mode pill (E17 ES-E17-2 / WI-5) is shown. Reads the pane model's OBSERVABLE
    /// ``TerminalViewModel/copyModeBadgeActive`` mirror (NOT the `@ObservationIgnored` `isCopyMode` the keyDown
    /// path reads) so the pill lights / clears reactively as copy-mode arms / exits. `false` for a non-terminal
    /// / not-yet-live pane.
    private var showViModePill: Bool {
        live?.terminalModel?.copyModeBadgeActive == true
    }

    /// Whether the vi key-hint bar (E17 ES-E17-2 / WI-5) is shown: in vi mode AND the per-session `⌘/` toggle is
    /// on. Both reads are OBSERVABLE mirrors, so the bar reveals / hides reactively; it is gated on
    /// `copyModeBadgeActive` too so it can never linger after vi mode exits (``TerminalViewModel/exitCopyMode()``
    /// resets ``TerminalViewModel/showViKeyHints``, but the extra gate makes the teardown unconditional).
    private var showViHintBar: Bool {
        guard let model = live?.terminalModel else { return false }
        return model.copyModeBadgeActive && model.showViKeyHints
    }

    /// Wire all per-pane view callbacks (find + Composer + secure input) on appear / live-session swap.
    private func wirePaneCallbacks() {
        wireFindCallbacks()
        wireComposerCallbacks()
        wireSecureInputCallbacks()
    }

    /// Clear all per-pane view callbacks on teardown so a surviving model can't drive a dead leaf's `@State`.
    private func clearPaneCallbacks() {
        clearFindCallbacks()
        clearComposerCallbacks()
        clearSecureInputCallbacks()
    }

    /// Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks to the find-bar holder (the seam the store fires via
    /// `requestFind*InActivePane()`). No-op for a non-terminal / not-yet-live pane (`terminalModel == nil`);
    /// `terminalModel` is non-nil from session creation for a terminal pane, so this lands on first `.task`.
    private func wireFindCallbacks() {
        guard let model = live?.terminalModel else { return }
        let bar = findBar
        bar.attach(model)
        model.onRequestFind = { bar.open() }
        // E17 ES-E17-2 / WI-5: copy-mode `?` opens the SAME bar biased BACKWARD so its `n`/`N` step against the
        // forward sense (vim parity). Without this the `?` handler falls back to `onRequestFind` (forward) and
        // the backward bias never lands.
        model.onRequestFindBackward = { bar.open(backward: true) }
        model.onRequestFindNext = { bar.next() }
        model.onRequestFindPrev = { bar.previous() }
    }

    /// Detach the holder + nil the callbacks so the model stops referencing a torn-down leaf's `@State`.
    private func clearFindCallbacks() {
        findBar.attach(nil)
        guard let model = live?.terminalModel else { return }
        model.onRequestFind = nil
        model.onRequestFindBackward = nil
        model.onRequestFindNext = nil
        model.onRequestFindPrev = nil
    }

    /// Wire the pane's ⌘⇧E / ⌘⇧M callbacks (the store fires these AFTER it has toggled / opened the durable
    /// ``ComposerModel`` via `requestComposerInActivePane()` / `requestPromptQueueInActivePane()`): the view's
    /// job is to switch the queue-input affordance and re-focus the field. Also wires the right-click
    /// "Paste and continue in Composer" seam (`onPasteToComposer`) — it reads the richest clipboard flavour,
    /// converts HTML/RTF→Markdown via the SAME ``ComposerPasteboard`` the in-field ⌘V uses, and splices it at
    /// the Composer's caret (so the context path converts AND inserts at the caret, just like ⌘V). No-op for a
    /// non-terminal pane. The chrome is leaf `@State` (per-pane); the Composer model is durable.
    private func wireComposerCallbacks() {
        guard let model = live?.terminalModel, let composer = live?.composer else { return }
        let chrome = composerChrome
        model.onRequestComposer = {
            chrome.queueMode = false
            chrome.focusToken &+= 1
        }
        model.onRequestPromptQueue = {
            chrome.queueMode = true
            chrome.focusToken &+= 1
        }
        model.onPasteToComposer = { [weak composer] in
            guard let markdown = ComposerPasteboard.richMarkdown() else { return }
            composer?.pasteRich(markdown)
        }
    }

    /// Nil the Composer callbacks so the durable terminal model stops referencing this torn-down leaf's
    /// `@State` chrome (the leaf is `.id(PaneID)`-keyed and can be rebuilt while the live session survives).
    private func clearComposerCallbacks() {
        guard let model = live?.terminalModel else { return }
        model.onRequestComposer = nil
        model.onRequestPromptQueue = nil
        model.onPasteToComposer = nil
    }

    /// Wire the pane's SECURE-INPUT actuator (E17 ES-E17-4 / WI-7): sync the controller to the model's current
    /// secure-input inputs + the live Auto-Secure-Input setting, then drive it on each change so macOS
    /// process-global Secure Keyboard Entry engages on a host no-echo password prompt (auto) or the manual
    /// toggle, and disengages on the inverse edge. Also starts the controller observing the app-frontmost edge
    /// (idempotent) so an engaged lock is RELEASED whenever aislopdesk is backgrounded (the user ⌘-Tabs away
    /// while a remote prompt is still up) and re-acquired on return — never leaked process-wide to other apps'
    /// keyboards. No-op for a non-terminal / not-yet-live pane; inert off macOS (the controller is a stub there).
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
        await live?.connection?.connect()
    }
}
#endif
