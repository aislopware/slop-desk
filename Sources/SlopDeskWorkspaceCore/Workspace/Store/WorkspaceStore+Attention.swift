import Foundation
import SlopDeskAgentDetect
import SlopDeskWorkspaceModel

// MARK: - Supervision cockpit — attention edge, jump-to-unread, sidebar summary + liveness

/// The supervision logic factored out of ``WorkspaceStore`` so the class body stays under the
/// type-body-length ceiling (like `WorkspaceStore+Completion.swift` / `WorkspaceStore+Blocks.swift`).
/// The stored state (`paneAgentLabel`, `lastNotifiedStatus`, `onAgentAttention`) lives on the class —
/// `@Observable` synthesises on it; only the derivations + actions are here.
///
/// Three surfaces, all CHEAP + client-side (no host round-trip, no LLM, never on the latency path):
///  - the attention-EDGE fire (`fireAgentAttention`, called from `setAgentStatus`'s coalesced edge);
///  - the host-label capture + the sidebar activity summary / liveness;
///  - the ⌘⇧U jump-to-oldest-attention WALK (``AttentionWalk`` drives the per-press step-vs-pop-home
///    decision over ``unseenAttentionPanes``).
public extension WorkspaceStore {
    // MARK: Per-pane status / label reads

    /// The rolled-up agent status for `id` (`.none` when unknown — the common case before an agent-status
    /// detector has attached to the pane).
    func agentStatus(for id: PaneID) -> ClaudeStatus {
        paneAgentStatus[id] ?? .none
    }

    /// The host-provided agent label for `id` (the cheap blocking prompt / last line), or `nil`.
    func agentLabel(for id: PaneID) -> String? {
        paneAgentLabel[id]
    }

    /// Sets the per-pane agent status (the detection sink — the sidebar/chrome dots' write path).
    /// Idempotent: a no-op when unchanged so it never churns the views.
    ///
    /// This is the SINGLE centralized chokepoint for every per-pane status write, so the whole
    /// supervision LADDER runs here — as ``PaneFacts/commit(previous:lastNotified:status:quiet:)``
    /// answers it, in one call. The verdict's fields are applied in order and nothing else is asked:
    /// the decision lives in `slopdesk-workspace::pane_facts`, the storage lives here.
    ///
    /// `quiet` = the host qualified this transition as BOOKKEEPING (wire `kind` ==
    /// ``AgentStatusKind/quiet``; today only the `/compact` boundary). Everything visual still
    /// happens — the dots, the recency stamp, the rollups — but no attention is raised: neither the
    /// coalesced edge nor the hook-less completion edge may fire for it. Defaulted `false` so every
    /// non-wire writer (tests, the seen-sweep's `.done → .idle`) keeps its behaviour verbatim.
    func setAgentStatus(_ status: ClaudeStatus, for id: PaneID, at date: Date = Date(), quiet: Bool = false) {
        let previous = paneAgentStatus[id] ?? .none
        guard let verdict = PaneFacts.commit(
            previous: previous, lastNotified: lastNotifiedStatus[id] ?? .none, status: status, quiet: quiet,
        ) else { return }
        // ANY genuine status change supersedes a parked notification (herdr: pending is replaced on
        // every state change) — either a schedule below re-parks for the NEW edge, or the pane moved
        // on and the stale ring must never sound.
        pendingAgentAttention.removeValue(forKey: id)
        if status == .none { paneAgentStatus.removeValue(forKey: id) } else { paneAgentStatus[id] = status }
        if verdict.notify_edge {
            lastNotifiedStatus[id] = status
            scheduleAgentAttention(for: id, status: status)
        } else if verdict.rearm_notified {
            // Left the attention bucket → forget the coalescing memory so the NEXT entry rings.
            lastNotifiedStatus.removeValue(forKey: id)
        }
        // The HOOK-LESS completion edge: a screen-detected agent (codex, gemini, … — no Stop hook to
        // mint `.done`) finishing its turn fires the SAME attention sink as a Claude Stop, so its
        // toast/banner/sound coverage matches herdr's. Independent of the edge above: the two read
        // different histories, and idle is not itself an attention state.
        if verdict.schedule_completion { scheduleAgentAttention(for: id, status: status) }
        // The NEEDS-ATTENTION `since` fallback: a genuine status transition stamps the pane — a
        // BLOCKED `needsPermission` agent never stamps `paneCompletedAt`, so this is where its
        // menu-row age comes from. Unconditional on purpose; it follows from the CHANGE, not its shape.
        paneAttentionAt[id] = date
        if verdict.stamp_completed {
            // The completion-flash decay for an agent turn. A stale stamp is harmless (the resolver
            // reads it ONLY in the completed/finished branch, it is refreshed on the next
            // `.done`/`.success`, and pruned on reconcile), so this never clobbers a coexisting
            // completion-badge stamp. The one-shot decays the flash so a quiet `.done` row settles
            // to `.finished` without a further mutation.
            paneCompletedAt[id] = date
            armCompletionFlashDecay()
            // UNREAD marker: a turn finishing while the user is NOT watching stays marked until the
            // pane is visited — the host's own done→idle decay (seconds) must not take the badge
            // with it. Expressed as a COUNTER, not a bit. This bump is the client's own — refused
            // the moment host truth holds the key, so with the document live the host's count is
            // what everyone compares against and no client's local edge can disagree with another's.
            bumpOwnCompletionEpoch(for: id)
            refreshUnseenDone(for: id)
        }
        if verdict.mark_seen {
            // The agent moved on — new activity supersedes the unread finish. Marking SEEN rather
            // than clearing a bit: the next host frame re-asserts the same counter, and a cleared
            // bit would come back.
            markCompletionSeen(id)
            refreshUnseenDone(for: id)
        }
        // The trailing-slot elapsed readout's anchor: entering `.working` starts the turn clock,
        // leaving it RETIRES it — an anchor outliving its turn prints an elapsed time that never
        // stops. Label-only re-emissions never reach here (same status ⇒ no verdict), so mid-turn
        // PreToolUse/PostToolUse churn cannot reset the clock.
        if verdict.stamp_working {
            paneWorkingSince[id] = date
        } else {
            paneWorkingSince.removeValue(forKey: id)
        }
        // Re-evaluate the focused-pane finish watch: this transition either starts one (a finish on the
        // pane under the user's eyes) or retires a pending one (the agent moved on).
        refreshFocusedDoneSettle(at: date)
    }

    /// Sets (or clears, on empty) the per-pane host agent label. Idempotent. The cheap activity summary
    /// the sidebar surfaces.
    func setAgentLabel(_ label: String?, for id: PaneID) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        guard paneAgentLabel[id] != value else { return }
        if let value { paneAgentLabel[id] = value } else { paneAgentLabel.removeValue(forKey: id) }
    }

    /// Sets (or clears, on empty) the per-pane host-latched agent-session INTENT (wire type 36) —
    /// the sticky "why this session exists" line the sidebar titles an agent row by. Idempotent;
    /// the empty push (session ended) removes the key so the row title falls back down its chain.
    /// Mirrors ``setAgentLabel``; pruned to the live leaf set on reconcile.
    func setAgentIntent(_ intent: String?, for id: PaneID) {
        let trimmed = intent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        guard paneAgentIntent[id] != value else { return }
        if let value { paneAgentIntent[id] = value } else { paneAgentIntent.removeValue(forKey: id) }
    }

    /// Sets (or clears, on empty / whitespace) the per-pane COARSE foreground-process name (wire type 26) —
    /// the trailing process label the sidebar rail shows and the input the ``TabBadgeResolver`` classifies
    /// into a `caffeinate`/`sudo` badge. Idempotent (a no-op when unchanged so it never churns the sidebar);
    /// an empty / whitespace-only name removes the key (treated as "no process"). Mirrors ``setAgentLabel``;
    /// the stored ``WorkspaceStore/paneForegroundProcess`` is PRUNED to the live leaf set on reconcile.
    func setForegroundProcess(_ name: String?, for id: PaneID) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        guard paneForegroundProcess[id] != value else { return }
        if let value { paneForegroundProcess[id] = value } else { paneForegroundProcess.removeValue(forKey: id) }
    }

    // MARK: Agent-badge gating (per-pane override + Clear-Badge)

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

    // MARK: Manual per-tab status-badge override (the `tab badge --kind` CLI)

    /// The MANUAL status-badge override for tab `id` (`nil` ⇒ the tab follows its DERIVED per-pane badge).
    /// Set by the client-control `tab badge --kind` verb (``setTabBadgeOverride(_:for:)``); consulted by
    /// ``RailRowsBuilder`` for the tab's representative pane row and by the control backend's `tab list`
    /// badge column, AHEAD of the resolved badge.
    func tabBadgeOverride(for id: TabID) -> TabBadgeKind? {
        tabBadgeOverrides[id]
    }

    /// Sets (or clears, on `nil`) tab `id`'s MANUAL status-badge override (the `tab badge --kind` CLI).
    /// Idempotent (a no-op when unchanged so it never churns the rail). Passing `nil` drops the override so
    /// the tab follows its derived per-pane badge again. This is the seam the client-control backend
    /// writes — the override the rail/`tab list` actually render, so `tab badge --kind` takes effect here.
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
        markCompletionSeen(id)
        refreshUnseenDone(for: id)
        // The acknowledge already happened — a watch still ticking on this pane has nothing left to settle.
        paneDoneDwellSince.removeValue(forKey: id)
        if agentStatus(for: id) == .done { setAgentStatus(.idle, for: id) }
    }

    // MARK: The focused-pane finish settle (a marker you have READ stops being unread)

    /// Advances the focused-pane finish WATCH at `now`: starts a dwell clock on every pane that is focused
    /// (in an active app) while carrying a finished-turn marker, drops the clock for every pane that stopped
    /// being either, and ACKNOWLEDGES — ``clearAgentBadge(_:)`` — the ones that have been watched for a full
    /// ``WorkspaceStore/focusedDoneSettleWindow``.
    ///
    /// **Why.** The marker's only clear path is a SELECTION change (tab switch / rail click / ⌘⇧U). Coming
    /// back to the app selects nothing, so a turn that finished while you were away kept its marker on the
    /// very pane you were already looking at, until you clicked away and back. Reading it is seeing it.
    ///
    /// **Scope, deliberately narrow.** Only a FOCUSED pane in an ACTIVE app ever gets a clock. An unfocused
    /// pane keeps the original contract exactly — unread until visited, however long that takes — so nothing
    /// can expire behind the user's back. The window measures an UNBROKEN watch: focus leaving (or the app
    /// backgrounding) abandons the clock, and a later return starts a fresh one.
    ///
    /// Driven by the three edges that can change the answer — an agent-status transition, a focus change
    /// (`reconcileTree`), and the `isAppActive` edge — plus a one-shot armed at the boundary
    /// (``WorkspaceStore/doneSettleScheduler``), because a finished agent stops mutating the store and
    /// nothing else would look again. Re-entrant-safe: the acknowledge feeds back through
    /// ``setAgentStatus(_:for:at:)``, and by then the pane is no longer a candidate, so the recursion ends.
    internal func refreshFocusedDoneSettle(at now: Date = Date()) {
        if !paneDoneDwellSince.isEmpty {
            for id in paneDoneDwellSince.keys where !isFinishSettleCandidate(id) {
                paneDoneDwellSince.removeValue(forKey: id)
            }
        }
        var due: [PaneID] = []
        var startedAWatch = false
        for id in focusedFinishSettleCandidates() {
            guard let since = paneDoneDwellSince[id] else {
                paneDoneDwellSince[id] = now
                startedAWatch = true
                continue
            }
            if PaneFacts.settleDue(watched: now.timeIntervalSince(since), window: Self.focusedDoneSettleWindow) {
                due.append(id)
            }
        }
        for id in due { clearAgentBadge(id) }
        if startedAWatch {
            doneSettleScheduler(Self.focusedDoneSettleWindow) { [weak self] in
                self?.refreshFocusedDoneSettle()
            }
        }
    }

    /// The panes a watch may run on right now: the focused leaf and, when a satellite window holds key, its
    /// detached pane — each only while it still carries a finished-turn marker.
    private func focusedFinishSettleCandidates() -> [PaneID] {
        guard isAppActive else { return [] }
        var out: [PaneID] = []
        if let active = tree.activeSession?.activeTab?.activePane, isFinishSettleCandidate(active) {
            out.append(active)
        }
        if let satellite = keySatellitePaneID, !out.contains(satellite), isFinishSettleCandidate(satellite) {
            out.append(satellite)
        }
        return out
    }

    /// Whether pane `id` is one a watch applies to: focused in an ACTIVE app (a key satellite counts as
    /// focused, but only while the app itself is frontmost — nobody is reading a background window) and
    /// carrying a finished-turn marker (a live ``ClaudeStatus/done`` or the unread latch). A live
    /// `.working`/`.needsPermission` is never unread OUTPUT, so it never starts a clock — the settle can
    /// therefore never silence a waiting approval gate.
    private func isFinishSettleCandidate(_ id: PaneID) -> Bool {
        guard isAppActive, isPaneFocused(id) else { return false }
        return agentStatus(for: id) == .done || paneUnseenDone.contains(id)
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

    // MARK: The unseen-attention queue ("something needs you" rollup)

    /// Whether ANY pane other than the focused leaf currently carries an ATTENTION-class badge —
    /// derived from ``unseenAttentionPanes``.
    var hasUnseenAttention: Bool { !unseenAttentionPanes.isEmpty }

    /// Every pane other than the focused leaf that currently carries an ATTENTION-class badge
    /// (``TabBadgeKind/needsAttention``: agent blocked / unread finish / failed command) — the
    /// unseen-attention QUEUE. Spans ALL sessions (the queue is global; the
    /// rail only shows the active one) and resolves each pane through the SAME gated pipeline the rail
    /// renders (``TabBadgeGating/resolve(...)`` + the manual ``tabBadgeOverride(for:)`` on the tab's
    /// representative pane), so this and the sidebar can never disagree — a badge the user silenced never
    /// lists here. The focused leaf is excluded via ``isPaneFocused(_:)``:
    /// while the app is inactive nothing is focused, so even the active leaf counts until the user
    /// returns. Freshness is pinned ``TabBadgeResolver/CompletionFreshness/settled`` — `.completed` and
    /// `.finished` are BOTH attention-class, so the flash clock cannot change the verdict (no `Date()`
    /// here; the derivation stays deterministic).
    ///
    /// Order: BLOCKED-FIRST — awaitingInput, then error, then the unread finishes — and, WITHIN a rank,
    /// `since`-ASCENDING (the longer-waiting entry is topmost; a `since == nil` manual-override entry
    /// carries no age evidence, so it sorts after every dated entry of the same rank), traversal-stable as
    /// the final tie. This is the queue ⌘⇧U's walk steps through (``jumpToOldestAttentionPane()``).
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
                                unseenAgentDone: paneUnseenDone.contains(paneID),
                                agentGates: agentBadgeGates(for: paneID),
                                commandGates: commandBadgeGates,
                            )
                        }
                    if let badge, badge.needsAttention {
                        found.append(UnseenAttentionEntry(
                            pane: paneID,
                            badge: badge,
                            since: paneCompletedAt[paneID] ?? paneAttentionAt[paneID],
                        ))
                    }
                }
            }
            // DETACHED (satellite-window) panes live outside every tab's split tree, so the loop above
            // never sees them — without this, a blocked/failed satellite pane is invisible to the
            // attention queue / ⌘⇧U jump while it sits unfocused in the background (no tab pill of
            // its own, so no manual override to consult).
            for entry in session.detached where !isPaneFocused(entry.pane) {
                let paneID = entry.pane
                let badge = TabBadgeGating.resolve(
                    agent: agentStatus(for: paneID),
                    completion: panePendingCompletion[paneID],
                    isBusy: paneShowsBusyDot(paneID),
                    foregroundProcess: paneForegroundProcess[paneID],
                    completionFreshness: .settled,
                    progress: progress(for: paneID),
                    unseenAgentDone: paneUnseenDone.contains(paneID),
                    agentGates: agentBadgeGates(for: paneID),
                    commandGates: commandBadgeGates,
                )
                if let badge, badge.needsAttention {
                    found.append(UnseenAttentionEntry(
                        pane: paneID,
                        badge: badge,
                        since: paneCompletedAt[paneID] ?? paneAttentionAt[paneID],
                    ))
                }
            }
        }
        // The urgency order is `slopdesk-workspace::pane_facts`, which answers POSITIONS into the
        // list it was handed — so the traversal above stays the tie without an enumerated offset.
        return PaneFacts.attentionOrder(found)
    }

    // MARK: Attention edge (the notification fire)

    /// The park window between a notify-worthy edge and its delivery (herdr's `ui.toast.delay_seconds`,
    /// default 1): long enough to swallow a flap that resolves itself (an agent that pauses a beat and
    /// resumes, a permission prompt auto-approved by a rule), short enough that a genuine ring still
    /// feels immediate. Fixed, not a setting — herdr ships the same default and this repo does not grow
    /// tuning flags for behavior that has no valid OFF.
    internal static let agentAttentionDeliveryDelay: TimeInterval = 1.0

    /// PARKS a notify-worthy edge for ``agentAttentionDeliveryDelay`` instead of ringing on the spot
    /// (herdr's `pending_agent_notifications`): the one-shot re-validates at the deadline via
    /// ``deliverPendingAgentAttention(for:expected:generation:)``, so an edge the pane has already left
    /// never reaches the user. Re-parking (a flap re-entering within the window) REPLACES the entry and
    /// pushes the deadline back; the superseded one-shot dies on the generation guard. Focus suppression
    /// is NOT evaluated here — the sink's closure reads focus when it actually runs (herdr evaluates
    /// suppression at delivery too), so a pane the user switches onto mid-window rings correctly for
    /// its situation at the deadline, not the stale one.
    internal func scheduleAgentAttention(for id: PaneID, status: ClaudeStatus) {
        agentAttentionGeneration &+= 1
        let generation = agentAttentionGeneration
        pendingAgentAttention[id] = (status: status, generation: generation)
        agentAttentionScheduler(Self.agentAttentionDeliveryDelay) { [weak self] in
            self?.deliverPendingAgentAttention(for: id, expected: status, generation: generation)
        }
    }

    /// The deadline half of ``scheduleAgentAttention(for:status:)``: delivers the parked notification
    /// IFF (a) this one-shot's park is still the pane's pending entry (the generation guard — a re-park
    /// or supersession orphans older one-shots) and (b) the pane STILL holds the status that earned the
    /// ring (herdr's re-validation — `setAgentStatus` clears pending on every genuine change, so this
    /// second guard is belt-and-braces against any write path that bypasses the chokepoint). A pruned
    /// pane (closed within the window) has no pending entry left, so it exits on the first guard.
    internal func deliverPendingAgentAttention(for id: PaneID, expected: ClaudeStatus, generation: UInt64) {
        guard let pending = pendingAgentAttention[id], pending.generation == generation else { return }
        pendingAgentAttention.removeValue(forKey: id)
        guard agentStatus(for: id) == expected else { return }
        fireAgentAttention(for: id, status: expected)
    }

    /// Fires the attention sink for a notify-worthy edge on `id`, resolving the display name (the
    /// spec title) and the cheap host label as the optional detail line. Reached only through
    /// ``deliverPendingAgentAttention(for:expected:generation:)`` (the parked delivery); a no-op when
    /// the sink is unwired (tests / iOS).
    internal func fireAgentAttention(for id: PaneID, status: ClaudeStatus) {
        guard let onAgentAttention else { return }
        let name = tree.spec(for: id)?.title ?? "Pane"
        onAgentAttention(id.raw.uuidString, name, status == .needsPermission, agentLabel(for: id))
    }

    // MARK: Jump-to-unread (⌘⇧U walks the queue)

    /// Jump-to-unread (⌘⇧U): WALKS the unseen-attention queue (``unseenAttentionPanes``)
    /// one pane per press, remembering
    /// every pane it has already stepped onto (``AttentionWalk``) so a re-press advances instead of
    /// bouncing back to a still-blocked pane the instant focus leaves it. Exhausting the queue (every
    /// currently-listed pane visited) pops focus back to the pane the walk started from; the press after
    /// that starts a fresh walk over whatever the queue then holds.
    ///
    /// The walk's memory is invisible by design and is discarded the instant ANY focus change happens that
    /// did NOT come from this method's own ``focusPaneTree(_:)`` call below — a manual tab click, ⌘1-9, a
    /// session switch, Peek & Reply — detected lazily here (on the NEXT press) by comparing the current
    /// focus to what the walk itself last set.
    ///
    /// Visiting a pane runs ``clearAgentBadge(_:)`` on it UNCONDITIONALLY before advancing — a genuinely
    /// STRONGER acknowledge than a plain focus change (which only runs the completion-badge clear and never
    /// settles `.done → .idle`): the chord is an explicit triage action ("I've seen this"), so a `.done`
    /// visit clears its badge for good. `clearAgentBadge` no-ops on a live `.needsPermission` gate by its
    /// own contract, so a still-blocked pane re-enters the queue the moment focus leaves it — it left THIS
    /// walk by visited-set membership only, never by faking the gate closed.
    func jumpToOldestAttentionPane() {
        let box = attentionWalk
        let focusedBeforeStep = tree.activeSession?.activeTab?.activePane
        if box.origin != nil, focusedBeforeStep != box.lastWalkFocused {
            box.reset() // an external focus change intervened since the last press — abandon the old walk
        }
        let queue = unseenAttentionPanes.map(\.pane)
        switch AttentionWalk.step(queue: queue, visited: box.visited, origin: box.origin, isPaneLive: tree.contains) {
        case let .advance(target):
            if box.origin == nil { box.origin = focusedBeforeStep }
            clearAgentBadge(target)
            box.visited.insert(target)
            jumpToPaneTree(target) // every walk step is a teleport — breadcrumb when it crossed a tab
            box.lastWalkFocused = tree.activeSession?.activeTab?.activePane
        case let .popHome(origin):
            if let origin { jumpToPaneTree(origin) } // popping home teleports back too
            box.reset()
        }
    }

    // MARK: Peek & Reply (⌘⇧J — answer a blocked agent INLINE)

    /// The pane the "Peek & Reply" overlay (⌘⇧J) should target: the FOCUSED pane when it is itself
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

    /// The cheap, headless peek DTO for pane `id`: its display name, its host-provided blocking
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

    /// Sends `text` (plus one trailing newline) to pane `id`'s PTY — the ONE testable chokepoint the Peek &
    /// Reply overlay routes every reply through, so the view never touches the private `registry`. Goes through
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
}

// MARK: - The ⌘⇧U walk's mutable state

/// One walk's mutable memory: which panes it has already visited, the pane focus returns to on
/// exhaustion, and the pane the walk itself last focused (so the NEXT press can tell a manual focus
/// change apart from its own step — see ``WorkspaceStore/jumpToOldestAttentionPane()``). A reference
/// type on purpose: the store holds it as a `let` (``WorkspaceStore/attentionWalk``), keeping the walk's
/// bookkeeping OUT of Observation — no view reads it, so a step must never invalidate view bodies.
final class AttentionWalkBox {
    var visited: Set<PaneID> = []
    var origin: PaneID?
    var lastWalkFocused: PaneID?

    func reset() {
        visited.removeAll()
        origin = nil
        lastWalkFocused = nil
    }
}

// MARK: - The unseen-attention queue's entries

/// One pane currently WAITING on the user — an item of ``WorkspaceStore/unseenAttentionPanes``.
/// Carries the RESOLVED gated badge (the same vocabulary the sidebar rail renders), plus the cheap
/// context a consumer can speak (the host agent label and the waiting-since instant).
public struct UnseenAttentionEntry: Equatable, Sendable {
    public let pane: PaneID
    public let badge: TabBadgeKind
    /// The best-known instant the pane ENTERED attention — the completion stamp
    /// (``WorkspaceStore/paneCompletedAt``) when one exists, else the pane's attention-edge stamp
    /// (``WorkspaceStore/paneAttentionAt``, stamped by the same agent-status/completion edges). `nil`
    /// when neither is known (e.g. a manual CLI badge override) — a dated entry then outranks it
    /// within the same urgency rank.
    public let since: Date?

    public init(pane: PaneID, badge: TabBadgeKind, since: Date? = nil) {
        self.pane = pane
        self.badge = badge
        self.since = since
    }
}
