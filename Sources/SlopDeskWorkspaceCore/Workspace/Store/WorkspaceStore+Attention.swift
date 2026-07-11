import Foundation
import SlopDeskAgentDetect

// MARK: - Supervision cockpit (P3 — attention edge, jump-to-unread, sidebar summary + liveness)

/// The P3 supervision logic factored out of ``WorkspaceStore`` so the class body stays under the
/// type-body-length ceiling (like `WorkspaceStore+Completion.swift` / `WorkspaceStore+Blocks.swift`).
/// The stored state (`paneAgentLabel`, `lastNotifiedStatus`, `onAgentAttention`) lives on the class —
/// `@Observable` synthesises on it; only the derivations + actions are here.
///
/// Three surfaces, all CHEAP + client-side (no host round-trip, no LLM, never on the latency path):
///  - the attention-EDGE fire (`fireAgentAttention`, called from `setAgentStatus`'s coalesced edge);
///  - the host-label capture + the sidebar activity summary / liveness;
///  - the ⌘⇧U jump-to-oldest-attention selection (the pure ``AttentionJump`` drives the ordering).
public extension WorkspaceStore {
    // MARK: Per-pane status / label reads

    /// The rolled-up agent status for `id` (`.none` when unknown — the common case until W10/W11).
    func agentStatus(for id: PaneID) -> ClaudeStatus {
        paneAgentStatus[id] ?? .none
    }

    /// The host-provided agent label for `id` (the cheap blocking prompt / last line), or `nil`.
    func agentLabel(for id: PaneID) -> String? {
        paneAgentLabel[id]
    }

    /// Sets the per-pane agent status (the W10/W11 detection sink — the sidebar/chrome dots' write path).
    /// Idempotent: a no-op when unchanged so it never churns the views.
    ///
    /// P3: this is the SINGLE centralized chokepoint for every per-pane status write, so the attention
    /// EDGE detection runs here. It captures the last-notified state before the mutation and, after
    /// committing, runs ``applyAttentionEdge(for:lastNotified:status:)`` — a genuine entry into
    /// needsPermission/done notifies once (coalesced), a flap does not.
    func setAgentStatus(_ status: ClaudeStatus, for id: PaneID, at date: Date = Date()) {
        guard paneAgentStatus[id] != status else { return }
        let lastNotified = lastNotifiedStatus[id] ?? .none
        if status == .none { paneAgentStatus.removeValue(forKey: id) } else { paneAgentStatus[id] = status }
        applyAttentionEdge(for: id, lastNotified: lastNotified, status: status)
        // The NEEDS-ATTENTION `since` fallback: a genuine status transition (past the idempotency guard)
        // stamps the pane — a BLOCKED `needsPermission` agent never stamps `paneCompletedAt`, so this is
        // where its menu-row age comes from.
        paneAttentionAt[id] = date
        // Drive the checkmark→accent-dot decay for an agent turn: a genuine entry into `.done` stamps
        // the ephemeral `completedAt` (brief `.completed` flash, settling to `.finished`). Only the
        // positive edge stamps — a stale stamp is harmless (the resolver reads it ONLY in the
        // completed/finished branch, it is refreshed on the next `.done`/`.success`, and pruned on
        // reconcile), so this never clobbers a coexisting completion-badge stamp. FIX 1: arm the one-shot
        // that decays the flash so a quiet `.done` row settles to the dot without a further mutation.
        if status == .done {
            paneCompletedAt[id] = date
            armCompletionFlashDecay()
        }
    }

    /// Sets (or clears, on empty) the per-pane host agent label. Idempotent. The cheap activity summary
    /// the sidebar surfaces (P3 piece 5).
    func setAgentLabel(_ label: String?, for id: PaneID) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        guard paneAgentLabel[id] != value else { return }
        if let value { paneAgentLabel[id] = value } else { paneAgentLabel.removeValue(forKey: id) }
    }

    /// Sets (or clears, on empty / whitespace) the per-pane COARSE foreground-process name (wire type 26) —
    /// the trailing process label the E6 sidebar rail shows and the input the ``TabBadgeResolver`` classifies
    /// into a `caffeinate`/`sudo` badge. Idempotent (a no-op when unchanged so it never churns the sidebar);
    /// an empty / whitespace-only name removes the key (treated as "no process"). Mirrors ``setAgentLabel``;
    /// the stored ``WorkspaceStore/paneForegroundProcess`` is PRUNED to the live leaf set on reconcile.
    func setForegroundProcess(_ name: String?, for id: PaneID) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        guard paneForegroundProcess[id] != value else { return }
        if let value { paneForegroundProcess[id] = value } else { paneForegroundProcess.removeValue(forKey: id) }
    }

    // MARK: E13 WI-3 — agent-badge gating (per-pane override + Clear-Badge)

    /// The effective ``AgentBadgeGates`` for pane `id`: the per-pane OVERRIDE if one is set (the tab
    /// context-menu badge toggles), else the GLOBAL default from ``SettingsKey/agentBadgeGates``. One of the
    /// two gate sets ``RailRowsBuilder`` feeds to ``TabBadgeGating/resolve(...)``.
    func agentBadgeGates(for id: PaneID) -> AgentBadgeGates {
        paneAgentBadgeOverrides[id] ?? SettingsKey.agentBadgeGates
    }

    /// The GLOBAL ``CommandBadgeGates`` (the Settings → Shell "TAB BADGE" toggles). Command badges have no
    /// per-pane override (unlike the agent gates' tab-context-menu override), so this reads the global default
    /// directly — the second gate set ``RailRowsBuilder`` / the control backend feed to ``TabBadgeGating``.
    var commandBadgeGates: CommandBadgeGates { SettingsKey.commandBadgeGates }

    /// Sets (or clears, on `nil`) pane `id`'s per-pane badge override. Idempotent (a no-op when unchanged so
    /// it never churns the rail). Passing `nil` drops the override so the pane follows the global default again.
    func setAgentBadgeOverride(_ gates: AgentBadgeGates?, for id: PaneID) {
        guard paneAgentBadgeOverrides[id] != gates else { return }
        if let gates { paneAgentBadgeOverrides[id] = gates } else { paneAgentBadgeOverrides.removeValue(forKey: id) }
    }

    /// Flips ONE per-pane badge gate (the tab context-menu toggle): seeds the override from the pane's
    /// CURRENT effective gates (override-else-global) so the first flip preserves the other two bits, then
    /// stores the toggled copy.
    func toggleAgentBadgeGate(_ gate: AgentBadgeGate, for id: PaneID) {
        setAgentBadgeOverride(agentBadgeGates(for: id).toggling(gate), for: id)
    }

    // MARK: E20 ES-E20-3 — manual per-tab status-badge override (the `tab badge --kind` CLI)

    /// The MANUAL status-badge override for tab `id` (`nil` ⇒ the tab follows its DERIVED per-pane badge).
    /// Set by the client-control `tab badge --kind` verb (``setTabBadgeOverride(_:for:)``); consulted by
    /// ``RailRowsBuilder`` for the tab's representative pane row and by the control backend's `tab list`
    /// badge column, AHEAD of the resolved badge.
    func tabBadgeOverride(for id: TabID) -> TabBadgeKind? {
        tabBadgeOverrides[id]
    }

    /// Sets (or clears, on `nil`) tab `id`'s MANUAL status-badge override (the `tab badge --kind` CLI).
    /// Idempotent (a no-op when unchanged so it never churns the rail). Passing `nil` drops the override so
    /// the tab follows its derived per-pane badge again. This is the seam the E20 client-control backend
    /// writes — the override the rail/`tab list` actually render, so `tab badge --kind` is no longer a no-op.
    func setTabBadgeOverride(_ kind: TabBadgeKind?, for id: TabID) {
        guard tabBadgeOverrides[id] != kind else { return }
        if let kind { tabBadgeOverrides[id] = kind } else { tabBadgeOverrides.removeValue(forKey: id) }
    }

    /// The "Clear Badge" tab right-click action: ACKNOWLEDGE pane `id`'s completion / attention so its
    /// badge drops. Clears any pending ✓/✗ completion badge AND, when the agent is at ``ClaudeStatus/done``
    /// (the finished-turn dot), settles it to ``ClaudeStatus/idle`` (acknowledged — contributes no badge). A
    /// LIVE state (running / awaiting-input / a held progress error) is deliberately left alone — Clear-Badge
    /// acknowledges unread output, it never fakes-away a still-active signal (and NEVER an approval gate).
    func clearAgentBadge(_ id: PaneID) {
        setCompletionBadge(nil, for: id)
        if agentStatus(for: id) == .done { setAgentStatus(.idle, for: id) }
    }

    // MARK: Rollups (the sidebar/tab/chrome dot derivations)

    /// The most-urgent agent status over every leaf of session `sessionID` (Herdr rollup:
    /// blocked > working > done > idle > none) — the sidebar session-row dot. `.none` for an unknown
    /// session or one whose panes are all `.none`.
    func rollupStatus(forSession sessionID: SessionID) -> ClaudeStatus {
        guard let session = tree.sessions.first(where: { $0.id == sessionID }) else { return .none }
        return ClaudeStatus.rollup(session.allPaneIDs().map { agentStatus(for: $0) })
    }

    /// The most-urgent agent status over every leaf of tab `tabID` (the tab-pill dot).
    func rollupStatus(forTab tabID: TabID) -> ClaudeStatus {
        for session in tree.sessions {
            if let tab = session.tabs.first(where: { $0.id == tabID }) {
                return ClaudeStatus.rollup(tab.allPaneIDs().map { agentStatus(for: $0) })
            }
        }
        return .none
    }

    // MARK: The titlebar attention dot (bell-style "something needs you" rollup)

    /// Whether ANY pane other than the focused leaf currently carries an ATTENTION-class badge — the
    /// bell-style dot next to the titlebar's centre title. Derived from ``unseenAttentionPanes`` so the
    /// dot and the title menu's NEEDS-ATTENTION section agree by construction.
    var hasUnseenAttention: Bool { !unseenAttentionPanes.isEmpty }

    /// Every pane other than the focused leaf that currently carries an ATTENTION-class badge
    /// (``TabBadgeKind/needsAttention``: agent blocked / unread finish / failed command) — the titlebar
    /// dot's per-pane breakdown, listed in the title menu. Spans ALL sessions (the dot is global; the
    /// rail only shows the active one) and resolves each pane through the SAME gated pipeline the rail
    /// renders (``TabBadgeGating/resolve(...)`` + the manual ``tabBadgeOverride(for:)`` on the tab's
    /// representative pane), so this and the sidebar can never disagree — a badge the user silenced never
    /// lights the dot or lists here. The focused leaf is excluded via the B3 gate (``isPaneFocused(_:)``):
    /// while the app is inactive nothing is focused, so even the active leaf counts until the user
    /// returns. Freshness is pinned ``TabBadgeResolver/CompletionFreshness/settled`` — `.completed` and
    /// `.finished` are BOTH attention-class, so the flash clock cannot change the verdict (no `Date()`
    /// here; the derivation stays deterministic).
    ///
    /// Order: BLOCKED-FIRST — awaitingInput, then error, then the unread finishes — traversal-stable
    /// within each class (session → tab → pre-order DFS), the same "answer the blocked agent before
    /// reading the finished one" philosophy as ``AttentionJump`` / ⌘⇧U.
    var unseenAttentionPanes: [UnseenAttentionEntry] {
        var found: [UnseenAttentionEntry] = []
        for session in tree.sessions {
            for tab in session.tabs {
                let representative = tab.activePane ?? tab.allPaneIDs().first
                let manual = tabBadgeOverride(for: tab.id)
                for paneID in tab.allPaneIDs() where !isPaneFocused(paneID) {
                    let badge: TabBadgeKind? =
                        if paneID == representative, let manual {
                            manual
                        } else {
                            TabBadgeGating.resolve(
                                agent: agentStatus(for: paneID),
                                completion: panePendingCompletion[paneID],
                                // Reveal-thresholded, matching the rail's `chrome(...)` input — the two
                                // resolution sites may never disagree.
                                isBusy: paneShowsBusyDot(paneID),
                                foregroundProcess: paneForegroundProcess[paneID],
                                completionFreshness: .settled,
                                progress: progress(for: paneID),
                                agentGates: agentBadgeGates(for: paneID),
                                commandGates: commandBadgeGates,
                            )
                        }
                    if let badge, badge.needsAttention {
                        found.append(UnseenAttentionEntry(
                            pane: paneID,
                            badge: badge,
                            label: agentLabel(for: paneID),
                            since: paneCompletedAt[paneID] ?? paneAttentionAt[paneID],
                        ))
                    }
                }
            }
        }
        // Stable urgency sort (Swift's sort is not guaranteed stable — the enumerated offset is the tie).
        return found.enumerated()
            .sorted { lhs, rhs in
                let lRank = lhs.element.badge.attentionRank
                let rRank = rhs.element.badge.attentionRank
                if lRank != rRank { return lRank < rRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: Attention edge (the notification fire)

    /// The coalesced attention-EDGE handler called from ``setAgentStatus(_:for:)`` after it commits the
    /// new status: fires the notification on a genuine transition INTO needsPermission/done from the
    /// LAST-NOTIFIED state (not just the previous status, so a flap can't re-fire), and re-arms the
    /// coalescing memory when the pane leaves the attention bucket.
    internal func applyAttentionEdge(for id: PaneID, lastNotified: ClaudeStatus, status: ClaudeStatus) {
        if AttentionEdge.shouldNotify(prev: lastNotified, current: status) {
            lastNotifiedStatus[id] = status
            fireAgentAttention(for: id, status: status)
        } else if status == .idle || status == .working || status == .none {
            // Left the attention bucket → re-arm so the NEXT entry notifies again.
            lastNotifiedStatus.removeValue(forKey: id)
        }
    }

    /// Fires the attention sink for a needsPermission/done edge on `id`, resolving the display name (the
    /// spec title) and the cheap host label as the optional detail line. Called from the coalesced edge in
    /// `setAgentStatus`; a no-op when the sink is unwired (tests / iOS).
    internal func fireAgentAttention(for id: PaneID, status: ClaudeStatus) {
        guard let onAgentAttention else { return }
        let name = tree.spec(for: id)?.title ?? "Pane"
        onAgentAttention(id.raw.uuidString, name, status == .needsPermission, agentLabel(for: id))
    }

    // MARK: Jump-to-unread (⌘⇧U)

    /// Jump-to-unread (⌘⇧U, P3 piece 4): focuses the OLDEST pane currently needing attention across ALL
    /// sessions/tabs — ``ClaudeStatus/needsPermission`` (blocked) first, then ``ClaudeStatus/done``, each
    /// in canonical traversal order (`tree.allPaneIDs()` is session → tab → pre-order DFS, so the first is
    /// the oldest/top-most). Switches session + tab as needed via ``focusPaneTree(_:)``. A no-op when no
    /// pane needs attention. The selection is the pure ``AttentionJump`` so the ordering is unit-tested
    /// without the store.
    func jumpToOldestAttentionPane() {
        guard let target = AttentionJump.oldestPane(
            in: tree.allPaneIDs(), status: { agentStatus(for: $0) },
        ) else { return }
        focusPaneTree(target)
    }

    // MARK: Peek & Reply (⌘⇧J, P4 — answer a blocked agent INLINE)

    /// The pane the P4 "Peek & Reply" overlay (⌘⇧J) should target: the FOCUSED pane when it is itself
    /// blocked (`.needsPermission` — you are already looking at it), else the oldest attention pane across
    /// all tabs/sessions (``AttentionJump`` order: needsPermission before done, oldest-first). `nil` when
    /// nothing needs attention. The selection is the pure ``PeekReplyTarget`` so it is unit-tested without
    /// the store.
    ///
    /// `excluding` is the advance-to-next exclusion (default empty): after a reply lands, the just-answered
    /// pane may still report `.needsPermission` until the host re-reports, so the immediate advance passes
    /// it here to skip re-targeting the same pane.
    func peekReplyTargetPane(excluding: Set<PaneID> = []) -> PaneID? {
        PeekReplyTarget.select(
            focused: tree.activeSession?.activeTab?.activePane,
            status: { agentStatus(for: $0) },
            panes: tree.allPaneIDs(),
            excluding: excluding,
        )
    }

    /// The cheap, headless peek DTO for pane `id` (P4 piece 2): its display name, its host-provided blocking
    /// question (the type-27 ``paneAgentLabel``, or `nil`), and the last few command-block lines as the
    /// "recent output" stand-in. ALL client-side + swift-build-visible — the spec title from the tree, the
    /// label from ``agentLabel(for:)``, and the recent lines from the per-pane ``TerminalBlockModel`` (no
    /// `GhosttySurface`/`scrollbackTextLines()` app-target dependency, so the overlay compiles + tests
    /// headlessly). When neither a label nor any block exists, `recent` is empty (the view shows a
    /// "no recent output" note).
    func peekContent(for id: PaneID, recentLimit: Int = 4) -> PeekContent {
        let title = tree.spec(for: id)?.title ?? "Pane"
        let question = agentLabel(for: id)
        let recent = recentBlockLines(for: id, limit: recentLimit)
        return PeekContent(title: title, question: question, recent: recent)
    }

    /// The newest `limit` command blocks for pane `id`, formatted one line each ("`<command>` · <status>"),
    /// oldest-first — the cheap "last N lines" the peek overlay shows. Empty for a non-terminal pane, an
    /// unmaterialized pane, or one with no blocks. Reads the per-pane ``TerminalBlockModel`` through the
    /// ``TerminalModelProviding`` seam (NOT the renderer), so it stays headless.
    private func recentBlockLines(for id: PaneID, limit: Int) -> [String] {
        guard limit > 0, let model = (handle(for: id) as? TerminalModelProviding)?.terminalModel else { return [] }
        return PeekContent.recentLines(from: model.blocks.blocks, limit: limit)
    }

    /// Sends `text` (plus one trailing newline) to pane `id`'s PTY — the ONE testable chokepoint the P4
    /// overlay routes every reply through, so the view never touches the private `registry`. Goes through
    /// the public ``handle(for:)`` to the same `sendText` per-pane funnel the broadcast / sync-input fan-out
    /// uses — so a reply reaches a pane that is NOT focused. A no-op for an unmaterialized / non-text pane
    /// (``LivePaneSession`` / ``FakePaneSession`` drop text for video kinds).
    ///
    /// The caller pre-formats with ``PeekReplyFormatter`` (digit / bang-shell / plain), which already
    /// appends the newline — so this method sends the formatted string VERBATIM (it does not re-append).
    func sendPeekReply(_ text: String, to id: PaneID) {
        guard !text.isEmpty else { return }
        handle(for: id)?.sendText(text)
    }

    // MARK: Sidebar activity summary + liveness (P3 piece 5)

    /// A coarse session liveness verdict for the sidebar glyph: `alive` when ANY pane in the session has a
    /// live (connected) connection, else `exitedResumable` (every pane disconnected/failed/unreachable —
    /// the shell is detached but reattachable). Derived purely from the per-pane connection status the
    /// client already holds (no host round-trip, no new wire field).
    enum SessionLiveness: Sendable, Equatable { case alive, exitedResumable }

    /// The session's liveness (P3 piece 5): `alive` iff at least one of its panes is connected.
    func sessionLiveness(forSession sessionID: SessionID) -> SessionLiveness {
        guard let session = tree.sessions.first(where: { $0.id == sessionID }) else { return .exitedResumable }
        for id in session.allPaneIDs() {
            if case .connected = (handle(for: id) as? LivePaneSession)?.connection?.status { return .alive }
        }
        return .exitedResumable
    }

    /// The cheap one-line activity summary for a session row (P3 piece 5): the rolled-up MOST-URGENT
    /// pane's host-provided label (the type-27 blocking prompt / last assistant line) when present —
    /// genuinely cheap (no scrollback, no LLM, no round-trip). When no pane carries a label, falls back to
    /// the human STATE label ("needs permission" / "working" / "done" / "idle"). `nil` when the session is
    /// entirely `.none` (no agent anywhere → the row stays clean).
    func activitySummary(forSession sessionID: SessionID) -> String? {
        guard let session = tree.sessions.first(where: { $0.id == sessionID }) else { return nil }
        let rollup = rollupStatus(forSession: sessionID)
        guard rollup != .none else { return nil }
        // Prefer the label of the most-urgent pane (the one driving the rollup); else any non-empty label.
        let urgentLabel = session.allPaneIDs()
            .filter { agentStatus(for: $0) == rollup }
            .compactMap { agentLabel(for: $0) }
            .first
        if let urgentLabel { return urgentLabel }
        if let anyLabel = session.allPaneIDs().compactMap({ agentLabel(for: $0) }).first { return anyLabel }
        // No host label: only fall back to the STATE label for the genuinely-informative attention states
        // (needs permission / done). For a merely idle/working session the trailing AgentStatusDot already
        // encodes that by colour, so an always-on "idle"/"working" caption would be pure chatter under the
        // name — return nil and keep the row clean.
        switch rollup {
        case .needsPermission,
             .done: return rollup.displayLabel
        case .none,
             .idle,
             .working: return nil
        }
    }
}

// MARK: - The titlebar dot's per-pane breakdown

/// One pane currently WAITING on the user — an item of ``WorkspaceStore/unseenAttentionPanes`` (the
/// titlebar dot's breakdown, listed in the title menu's NEEDS-ATTENTION section). Carries the RESOLVED
/// gated badge so the menu row shows the same glyph vocabulary as the sidebar rail, plus the cheap
/// context the row's second line + trailing age speak.
public struct UnseenAttentionEntry: Equatable, Sendable {
    public let pane: PaneID
    public let badge: TabBadgeKind
    /// The host-provided agent label (the type-27 blocking prompt / last assistant line), when present —
    /// the row's second line ("Allow Bash(npm install)?"). `nil` ⇒ the view shows a per-badge caption.
    public let label: String?
    /// The best-known instant the pane ENTERED attention — the completion stamp
    /// (``WorkspaceStore/paneCompletedAt``) when one exists, else the pane's attention-edge stamp
    /// (``WorkspaceStore/paneAttentionAt``, stamped by the same agent-status/completion edges). `nil`
    /// when neither is known (e.g. a manual CLI badge override) — the view then shows no age.
    public let since: Date?

    public init(pane: PaneID, badge: TabBadgeKind, label: String? = nil, since: Date? = nil) {
        self.pane = pane
        self.badge = badge
        self.label = label
        self.since = since
    }
}

private extension TabBadgeKind {
    /// The urgency rank for the NEEDS-ATTENTION list: blocked (answer it) before a failure (read it)
    /// before an unread finish (skim it) — the ``AttentionJump`` ordering philosophy. Non-attention kinds
    /// never reach the list; their rank is the total-switch tail.
    var attentionRank: Int {
        switch self {
        case .awaitingInput: 0
        case .error: 1
        case .completed,
             .finished: 2
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: 3
        }
    }
}
