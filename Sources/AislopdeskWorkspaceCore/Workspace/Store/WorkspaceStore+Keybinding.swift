// WorkspaceStore+Keybinding — the per-pane WS-B / B4·B5 keybinding-interceptor wiring, factored out of
// `wireMaterializedLeaf` so the `WorkspaceStore` primary body stays under the SwiftLint type-body ceiling
// (the same split as `WorkspaceStore+Blocks.seedBlockBookmarks`). Pure wiring; no new behaviour.

import Foundation

/// The view-injected overlay-toggle closures the per-pane hardware-keyboard ``TerminalKeyInterceptor`` threads
/// into ``WorkspaceBindingRegistry/route`` (held on ``WorkspaceStore/overlayKeyToggles``). Each mirrors one
/// `route` toggle param. iOS wires these to the ``OverlayCoordinator`` so a focused-pane hardware chord opens
/// the matching overlay; macOS leaves them `nil` (its app-level NSEvent dispatcher owns those chords before the
/// surface). A `nil` member is a graceful no-op — the chord's `route` arm then falls back to its store path or
/// does nothing, never a dead/destructive control.
public struct WorkspaceOverlayKeyToggles {
    public var palette: (() -> Void)?
    public var cheatSheet: (() -> Void)?
    public var globalSearch: (() -> Void)?
    public var jumpTo: (() -> Void)?
    public var openQuickly: (() -> Void)?
    public var peekReply: (() -> Void)?

    public init(
        palette: (() -> Void)? = nil,
        cheatSheet: (() -> Void)? = nil,
        globalSearch: (() -> Void)? = nil,
        jumpTo: (() -> Void)? = nil,
        openQuickly: (() -> Void)? = nil,
        peekReply: (() -> Void)? = nil,
    ) {
        self.palette = palette
        self.cheatSheet = cheatSheet
        self.globalSearch = globalSearch
        self.jumpTo = jumpTo
        self.openQuickly = openQuickly
        self.peekReply = peekReply
    }
}

extension WorkspaceStore {
    /// Route a hardware-keyboard `action` resolved by a per-pane ``TerminalKeyInterceptor`` through
    /// ``WorkspaceBindingRegistry/route``, threading the view-injected ``overlayKeyToggles`` so an OVERLAY chord
    /// (⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J) fires its panel on a platform with no app-level NSEvent monitor (iOS).
    /// macOS installs no toggles here (its dispatcher owns the chord BEFORE the surface ever sees it), so this
    /// degenerates to the bare `route` there. A `nil` toggle is a graceful no-op (the `route` arm's own fallback).
    func routeInterceptedKey(_ action: WorkspaceAction) {
        WorkspaceBindingRegistry.route(
            action, to: self,
            togglePalette: overlayKeyToggles.palette,
            toggleCheatSheet: overlayKeyToggles.cheatSheet,
            togglePeekReply: overlayKeyToggles.peekReply,
            toggleGlobalSearch: overlayKeyToggles.globalSearch,
            toggleJumpTo: overlayKeyToggles.jumpTo,
            openQuickly: overlayKeyToggles.openQuickly,
        )
    }

    /// Hand pane `id`'s libghostty surface its PURE ``TerminalKeyInterceptor`` (prefix engine + the
    /// override-aware single-chord table). The surface's `keyDown` consults it BEFORE its own raw-byte
    /// branches, so (a) a tmux-style prefix sequence (⌃A → D) is claimed before the Ctrl+C0 path leaks the
    /// literal byte, and (b) the rebindable ⌘D/⌘⇧D split is owned by the shared engine (B5 removed the
    /// hard-coded split branch). A resolved action routes through the SAME `WorkspaceBindingRegistry.route`
    /// the app-level monitor (B3) uses; a new-pane action (split / new-tab / …) mints an in-pane `.chooser`
    /// pane directly via the store (no modal). A `nil` `terminal` (headless / non-terminal handle) is a no-op.
    func wireKeyInterceptor(terminal: TerminalViewModel?) {
        terminal?.keyInterceptor = TerminalKeyInterceptor(
            prefix: workspaceKeyPrefix,
            onAction: { [weak self] action in
                guard let self else { return }
                // Thread the view-injected overlay toggles (iOS hardware-keyboard path — macOS leaves them nil
                // and its NSEvent dispatcher owns overlay chords before the surface). `nil` ⇒ graceful no-op.
                routeInterceptedKey(action)
            },
        )
    }

    /// E16 ES-E16-4 — hand pane `id`'s libghostty surface its PURE ``SnippetAliasExpander`` (at-prompt
    /// snippet-alias auto-expansion). The surface's `keyDown` consults it on a bare Tab/Space (via
    /// ``TerminalViewModel/expandSnippetAlias()``); the expander's line mirror is fed by the model's
    /// ``TerminalViewModel/sendInput(_:)`` (outbound bytes) + the OSC-133;A prompt mark in the ingest path. The
    /// injected gates keep it faithful + default-OFF: the live `snippets` list, the `snippetAutoExpand` setting
    /// (default off), THIS model's `isAtShellPrompt`, and ``autoExpandBytes(for:)`` (reserved vars + `{{cursor}}`,
    /// declining still-parameterized snippets). A `nil` `terminal` (headless / non-terminal handle) is a no-op.
    func wireSnippetExpander(terminal: TerminalViewModel?) {
        guard let terminal else { return }
        terminal.snippetExpander = SnippetAliasExpander(
            snippets: { [weak self] in self?.snippets ?? [] },
            isEnabled: { SettingsKey.snippetAutoExpandEnabled },
            isAtPrompt: { [weak terminal] in terminal?.isAtShellPrompt ?? false },
            resolveBytes: { [weak self] snippet in self?.autoExpandBytes(for: snippet) ?? [] },
        )
    }

    /// The terminal surface's right-click "Split Right/Down" landing (factored out of `wireMaterializedLeaf`
    /// to keep the `WorkspaceStore` body under the lint ceiling). A split MINTS a pane, so — like the `+` /
    /// ⌘D / title-menu split — it creates an in-pane CHOOSER pane (Terminal / Remote window) and focuses it.
    /// Focuses `paneID` first so the chooser's active-pane split targets the surface the user acted on.
    /// `horizontal == true` → side-by-side.
    func splitFromContextMenu(paneID: PaneID, horizontal: Bool) {
        let axis: SplitAxis = horizontal ? .horizontal : .vertical
        focusPaneTree(paneID)
        openChooserPane(.split(axis: axis))
    }
}
