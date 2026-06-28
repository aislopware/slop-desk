// WorkspaceStore+Keybinding — the per-pane WS-B / B4·B5 keybinding-interceptor wiring, factored out of
// `wireMaterializedLeaf` so the `WorkspaceStore` primary body stays under the SwiftLint type-body ceiling
// (the same split as `WorkspaceStore+Blocks.seedBlockBookmarks`). Pure wiring; no new behaviour.

import Foundation

extension WorkspaceStore {
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
                WorkspaceBindingRegistry.route(action, to: self)
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
