import Foundation

// MARK: - ComposerProviding (the store↔live-session seam the composer ops resolve through)

/// The capability seam the E12 active-pane Composer / Prompt-Queue ops resolve through — the exact mirror
/// of ``TerminalModelProviding`` for the WB2/WB3 block ops: an `as?`-castable handle exposing the pane's
/// durable ``ComposerModel``. The production conformer is ``LivePaneSession`` (returns its `composer`); a
/// non-terminal session (`.remoteGUI` / `.systemDialog`) has none, so `composerModel` is `nil` and every
/// composer op degrades to a graceful no-op. Resolving through this seam (rather than an `as? LivePaneSession`
/// cast) keeps the routing exercisable by a recording test double that carries a real ``ComposerModel``.
@MainActor
protocol ComposerProviding: AnyObject {
    /// The pane's Composer + Prompt Queue view-model, or `nil` for a non-terminal session.
    var composerModel: ComposerModel? { get }
    /// Whether this pane currently hosts an agent (`claudeStatus != .none`) — drives the float-panel
    /// title ("Aislopdesk Composer — Claude Code" vs "Aislopdesk Composer"). Defaults to `false` so a
    /// non-agent session / a test double need not implement it.
    var composerAgentActive: Bool { get }
}

@MainActor
extension ComposerProviding {
    /// Default: no agent (a plain terminal / a test double that carries no `claudeStatus`).
    var composerAgentActive: Bool { false }
}

extension LivePaneSession: ComposerProviding {
    /// The per-pane Composer view-model (`nil` for a `.remoteGUI` / `.systemDialog` pane — no terminal,
    /// no composer).
    var composerModel: ComposerModel? { composer }

    /// Whether this pane hosts an agent — `claudeStatus` has lifted off `.none` (host-detected, wire
    /// type 27). The float-panel title appends " — Claude Code" only then (no agent-name guessing).
    var composerAgentActive: Bool { claudeStatus != .none }
}

// MARK: - ResolvedComposer (the window-level pin / float mount target the client UI promotes)

/// A composer the client UI must mount OUTSIDE its origin pane's subtree (E12 WI-6): the pinned
/// window-level mount or the floating panel / sheet. Bundles the durable ``ComposerModel`` with the
/// resolved agent flag (for the float title) so the resolver reads both in one pass over the live
/// sessions. A plain value type (holding the `@MainActor` ``ComposerModel`` reference) — it is built and
/// read entirely on the main actor (the `@MainActor` store resolver / a SwiftUI body), so it needs no
/// isolation annotation of its own; storing the reference never touches the model's isolated members.
public struct ResolvedComposer {
    /// The durable per-pane composer to mount at the window level / in the float panel.
    public let composer: ComposerModel
    /// Whether the origin pane hosts an agent — drives the float-panel title suffix.
    public let agentActive: Bool

    public init(composer: ComposerModel, agentActive: Bool) {
        self.composer = composer
        self.agentActive = agentActive
    }
}

// MARK: - WorkspaceStore × Composer + Prompt Queue (E12)

/// The E12 active-pane Composer (`⌘⇧E`) / Prompt-Queue (`⌘⇧M`) ops, split into their own extension (like
/// ``WorkspaceStore`` × Blocks) so the already-large store body stays under the lint type-body ceiling.
/// They mirror ``WorkspaceStore/requestCopyModeInActivePane()``: resolve the active pane's DURABLE composer
/// (in whichever live model is active) + its terminal model, then drive the composer verb and fire the
/// per-pane view-focus callback. A no-op for a non-terminal active pane (`.remoteGUI`) or an empty shell.
public extension WorkspaceStore {
    /// The active pane's durable ``ComposerModel`` in WHICHEVER live model is active (mirrors
    /// ``activeTerminalModel``): the tree's active pane on the IDE shell, the canvas focus on the
    /// retained-but-dead path. `nil` for a non-terminal active pane (`.remoteGUI`) or an empty shell.
    internal var activeComposerModel: ComposerModel? {
        guard let activeID = activePaneID,
              let provider = handle(for: activeID) as? ComposerProviding else { return nil }
        return provider.composerModel
    }

    /// `⌘⇧E` — TOGGLES the Composer over the active pane: flips the durable ``ComposerModel/isVisible`` (the
    /// bar mounts at the pane bottom via the leaf view, E12 WI-5) and fires the pane's
    /// ``TerminalViewModel/onRequestComposer`` so the view can move keyboard focus into the field. A no-op
    /// for a non-terminal active pane or an empty shell.
    func requestComposerInActivePane() {
        activeComposerModel?.toggle()
        activeTerminalModel?.onRequestComposer?()
    }

    /// `⌘⇧M` — OPENS the Composer in Prompt-Queue input mode over the active pane: shows the durable
    /// ``ComposerModel`` (OPEN, not toggle — a second ⌘⇧M leaves the queue open) and fires the pane's
    /// ``TerminalViewModel/onRequestPromptQueue`` so the leaf view switches to the queue-input affordance
    /// (placeholder + `↩`-adds-a-line, E12 WI-5) and takes focus. A no-op off-terminal / empty shell.
    func requestPromptQueueInActivePane() {
        activeComposerModel?.open()
        activeTerminalModel?.onRequestPromptQueue?()
    }

    // MARK: - Pin / float resolution (E12 WI-6 — the window-level / float mount the client UI promotes)

    /// The composer currently PINNED, in WHICHEVER live pane owns it — `nil` when none is pinned. The
    /// client UI mounts this at the WINDOW level (above the split / tab switcher) so a pinned composer
    /// rides along across tab switches (the otty pin: "stays visible regardless of which tab is active"),
    /// instead of inside the origin pane's subtree. Resolves across ALL live sessions (not just the active
    /// one) — that is exactly what lets the pinned bar survive switching to a different tab. Reading it in a
    /// SwiftUI body registers observation on each composer's ``ComposerModel/isPinned`` so the mount tracks
    /// the toggle. First match wins (one composer is pinned at a time in practice).
    var pinnedComposer: ResolvedComposer? { resolveComposer { $0.isPinned } }

    /// The composer currently FLOATING — `nil` when none is floating. The client UI presents this in a
    /// non-activating `NSPanel` (macOS) / bottom sheet (iOS), keeping the SAME ``ComposerModel`` so `⌘↩`
    /// still injects into the origin pane's PTY. Resolves across ALL live sessions (the float detaches from
    /// its origin pane). Reading it in a SwiftUI body registers observation on each composer's
    /// ``ComposerModel/isFloating`` so the presentation opens / closes with the toggle.
    var floatingComposer: ResolvedComposer? { resolveComposer { $0.isFloating } }

    /// Scan the live sessions for the FIRST whose composer matches `predicate`, bundling it with its
    /// resolved agent flag. A pure read — never mutates the tree / registry. The `as? ComposerProviding`
    /// cast skips non-terminal sessions (`.remoteGUI` has no composer). Reading `allSessions` +
    /// `composer.isPinned` / `.isFloating` here is what makes the result reactive in a SwiftUI body.
    private func resolveComposer(_ predicate: (ComposerModel) -> Bool) -> ResolvedComposer? {
        for session in allSessions {
            guard let provider = session as? ComposerProviding,
                  let composer = provider.composerModel, predicate(composer) else { continue }
            return ResolvedComposer(composer: composer, agentActive: provider.composerAgentActive)
        }
        return nil
    }
}
