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
    /// placeholder. This library NEVER imports libghostty/Metal: it only calls the factory seam. The ⌘F find
    /// bar floats top-trailing OVER the surface (it does not reflow the buffer) — never in the static-mirror
    /// snapshot path.
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
        .overlay(alignment: .topTrailing) {
            if !staticMirror, findBar.visible, live?.terminalModel != nil {
                TerminalFindBar(model: findBar)
                    .padding(Otty.Metric.space2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Otty.Anim.reveal, value: findBar.visible)
    }

    /// Wire all per-pane view callbacks (find + Composer) on appear / live-session swap.
    private func wirePaneCallbacks() {
        wireFindCallbacks()
        wireComposerCallbacks()
    }

    /// Clear all per-pane view callbacks on teardown so a surviving model can't drive a dead leaf's `@State`.
    private func clearPaneCallbacks() {
        clearFindCallbacks()
        clearComposerCallbacks()
    }

    /// Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks to the find-bar holder (the seam the store fires via
    /// `requestFind*InActivePane()`). No-op for a non-terminal / not-yet-live pane (`terminalModel == nil`);
    /// `terminalModel` is non-nil from session creation for a terminal pane, so this lands on first `.task`.
    private func wireFindCallbacks() {
        guard let model = live?.terminalModel else { return }
        let bar = findBar
        bar.attach(model)
        model.onRequestFind = { bar.open() }
        model.onRequestFindNext = { bar.next() }
        model.onRequestFindPrev = { bar.previous() }
    }

    /// Detach the holder + nil the callbacks so the model stops referencing a torn-down leaf's `@State`.
    private func clearFindCallbacks() {
        findBar.attach(nil)
        guard let model = live?.terminalModel else { return }
        model.onRequestFind = nil
        model.onRequestFindNext = nil
        model.onRequestFindPrev = nil
    }

    /// Wire the pane's ⌘⇧E / ⌘⇧M callbacks (the store fires these AFTER it has toggled / opened the durable
    /// ``ComposerModel`` via `requestComposerInActivePane()` / `requestPromptQueueInActivePane()`): the view's
    /// job is to switch the queue-input affordance and re-focus the field. Also routes the context-menu
    /// "Paste and continue in Composer" seam (`onPasteToComposer`) into the Composer draft (rich paste). No-op
    /// for a non-terminal pane. The chrome is leaf `@State` (per-pane); the Composer model is durable.
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
        model.onPasteToComposer = { text in composer.pasteRich(text) }
    }

    /// Nil the Composer callbacks so the durable terminal model stops referencing this torn-down leaf's
    /// `@State` chrome (the leaf is `.id(PaneID)`-keyed and can be rebuilt while the live session survives).
    private func clearComposerCallbacks() {
        guard let model = live?.terminalModel else { return }
        model.onRequestComposer = nil
        model.onRequestPromptQueue = nil
        model.onPasteToComposer = nil
    }

    private func connectIfNeeded() async {
        guard !staticMirror else { return }
        await live?.connection?.connect()
    }
}
#endif
