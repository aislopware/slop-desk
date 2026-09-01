import CoreGraphics
import Foundation
import Network
import SlopDeskAgentDetect
import SlopDeskClient
import SlopDeskInspector
import SlopDeskNet
import SlopDeskTransport
import SlopDeskWorkspaceModel

// MARK: - New-pane gesture (direct terminal mint)

/// The new-pane gesture: every ⌘T / ⌘D / `+` / context-menu split mints a terminal DIRECTLY.
///
/// Its own file rather than the primary body, for the reason `splitFromContextMenu` was already an
/// extension: the entry point stays OUT of the `WorkspaceStore` body's `type_body_length` budget —
/// and now out of that file's line count too.
public extension WorkspaceStore {
    /// Create a new TERMINAL pane placed by `context` and FOCUSED. Every new-pane gesture (⌘T / ⌘D /
    /// the `+` button / the context-menu splits) mints a terminal DIRECTLY — the in-pane kind chooser
    /// is retired: the default kind gets the hot path, and every non-terminal kind has its own
    /// explicit shortcut (⌥⌘N desktop; Open Quickly / the picker for windows), so a kind question on
    /// the hot path has no second answer left. cwd inheritance is the `newTab` / `splitActivePane`
    /// placement + inherit path, unchanged.
    func newTerminalPane(_ context: NewPanePlacement) {
        switch context {
        case let .split(axis, leading): splitActivePane(axis: axis, kind: .terminal, leading: leading)
        case .newTab: newTab(kind: .terminal)
        }
    }

    /// Pane `id`'s WORKING DIRECTORY — where its shell IS (`pane/cwd`, field 5), read through the
    /// mirror so a host frame and this client's own control-push overlay answer through one funnel.
    /// Shared by ``setLastKnownCwd(_:for:)``'s dirty guard, the attach-edge cwd-pull gate
    /// ``shouldRefreshCwdOnAttach(_:)`` and ``effectiveGitProjectKey(_:)``.
    ///
    /// Distinct from ``spawnCwd(for:)``, which is where the shell was asked to START.
    func paneCwd(for paneID: PaneID) -> String? {
        observeWorkspaceMirror()
        return workspaceMirror.string(.pane, documentPaneID(paneID), WorkspacePaneField.cwd)
    }

    /// Whether the connect/reconnect snapshot edge should pull pane `id`'s cwd from the host. TRUE
    /// only while `pane/cwd` is still empty — a POPULATE-ONCE gate so the ~3 s RTT-snapshot
    /// cadence never becomes a cwd poll. A shell that emits no OSC-7 (Starship / hookless) would otherwise
    /// sit at the "Terminal" fallback until its first command completes; one host `proc_pidinfo` pull on
    /// attach lands the folder-name title. Once any source populates the cwd this returns false and stops.
    func shouldRefreshCwdOnAttach(_ id: PaneID) -> Bool {
        paneCwd(for: id) == nil
    }

    /// Records the host-resolved working directory of pane `paneID` as `pane/cwd` — the single sink
    /// every cwd source (OSC 7, the `cwd` RPC, the palette resolver) funnels through, so the titlebar /
    /// rail / palette all mirror the same value. Writes the mirror's FAST PATH, which host truth erases
    /// the moment the document supplies the same key; guarded against an unchanged value so a re-focus
    /// spends nothing.
    func setLastKnownCwd(_ cwd: String, for paneID: PaneID) {
        // Both gates at once: drop a TRANSIENT plugin-cache-dir reading before it can poison the
        // inherit source, and drop an unchanged one. The live-cwd sources are `proc_pidinfo`-based
        // (`refreshCwd` on command completion, the palette's `cwd()` resolver), which race a plugin
        // manager's turbo `builtin cd`; without the first guard a later new-tab / split / relaunch
        // spawns its PTY in e.g. `…/zsh-users---zsh-autosuggestions` instead of the real project cwd.
        guard StoreSeed.acceptsCwd(cwd, current: paneCwd(for: paneID)) else { return }
        workspaceMirror.writeFastPath(
            pane: documentPaneID(paneID), field: WorkspacePaneField.cwd, string: cwd,
        )
        // Remember it for the next cold launch: the folder name is what the rail titles this row by,
        // and a client that starts with the host unreachable has no other way to know it.
        scheduleDocumentCacheSave()
        // The cwd just CHANGED (the guard above proves it differs from the stored value), so this is a
        // genuine visit — notify the frecency sink. Kept after the dirty guard so an unchanged re-focus is silent.
        onCwdVisited?(cwd)
        // The sidebar git line follows the cwd: a `cd` can enter/leave/switch repos, so refetch this
        // pane's summary. The stale line stays visible until the fresh reply lands (no flicker on a
        // same-repo `cd`); the post-completion `refreshCwd` funnels through here ONLY when the cwd
        // actually changed (the dirty guard above), so this never double-fetches a quiet completion.
        refreshGitSummary(for: paneID, from: (handle(for: paneID) as? LivePaneSession)?.connection)
    }

    /// Pane `id`'s HOST-computed By-Project key (`pane/projectKey`, field 6), read through the mirror —
    /// the ``setProjectKey(_:for:)`` dirty guard's mirror of ``paneCwd(for:)``.
    func projectKey(for paneID: PaneID) -> String? {
        observeWorkspaceMirror()
        return workspaceMirror.string(.pane, documentPaneID(paneID), WorkspacePaneField.projectKey)
    }

    /// Records the HOST-computed By-Project key (wire type 34) as `pane/projectKey` — the write sink
    /// ``ConnectionViewModel/onProjectKeyChanged`` funnels into, mirroring ``setLastKnownCwd(_:for:)``:
    /// a transient plugin-cache reading (``PaneSpec/looksLikeTransientPluginCwd(_:)`` — the host's resolver
    /// can race a zinit turbo `builtin cd` just as a client-side `gitStatus` sweep can) is DROPPED, and an
    /// unchanged value short-circuits so a reattach re-assert spends nothing.
    /// ``paneProjectKey(_:)`` reads it back for the sidebar sectioning.
    func setProjectKey(_ key: String, for paneID: PaneID) {
        guard StoreSeed.acceptsProjectKey(key, current: projectKey(for: paneID)) else { return }
        workspaceMirror.writeFastPath(
            pane: documentPaneID(paneID), field: WorkspacePaneField.projectKey, string: key,
        )
        // Persisted with the cwd, and for the same reason: without it a cold launch collapses every
        // By-Project section into one "Other" bucket until each pane's own channel reconnects.
        scheduleDocumentCacheSave()
    }

    // MARK: - Spawn cwd (where the shell STARTS)

    /// Where pane `id`'s shell was asked to start (`pane/spawnCwd`, field 21) — the value that rides
    /// the mux `channelOpen` so the host spawns the PTY there directly, with no visible startup `cd`.
    ///
    /// Deliberately NOT `pane/cwd`: that is where the shell IS right now. A respawn after a host
    /// restart has no live shell to ask, and starting it at the last-observed cwd would silently
    /// relocate a pane the user placed deliberately.
    ///
    /// Read through the MIRROR, so a host whose document carries this pane's spawn directory and a
    /// client that minted it locally answer with one value. A device-local dictionary here would give
    /// two clients of one document two different answers for where the same pane's shell belongs.
    ///
    /// The resolution order is the mirror's own: the TOPOLOGY (`entries`, where the intent that minted
    /// the pane put it) before the fast path, which is only reached for a pane the document does not
    /// name yet — a launch-time cache row whose leaf has not been re-published. That order is what
    /// makes a relaunch respawn a restored pane in its last spawn directory rather than `$HOME`.
    ///
    /// The empty string is RETIRED, not a directory — it maps back to `nil` so the host takes its own
    /// default rather than being handed a path of nothing.
    func spawnCwd(for id: PaneID) -> String? {
        observeWorkspaceMirror()
        guard let cwd = workspaceMirror.string(.pane, documentPaneID(id), WorkspacePaneField.spawnCwd),
              !cwd.isEmpty else { return nil }
        return cwd
    }

    /// Records where a pane's shell should start, on the FAST PATH.
    ///
    /// Not the mint path: a pane the client creates carries its spawn directory in the intent's own
    /// `cwd` argument (ops 6 / 12 / 13 / 18 all take one), so the value lands in the document's
    /// topology where every client and the host read the same answer. What is left for this is the
    /// facts that never went through an intent — the launch cache re-seeded at startup — which is why
    /// it writes the overlay lane and schedules the cache save.
    func setSpawnCwd(_ cwd: String?, for id: PaneID) {
        guard spawnCwd(for: id) != cwd else { return }
        workspaceMirror.writeFastPath(
            pane: documentPaneID(id), field: WorkspacePaneField.spawnCwd, string: cwd,
        )
        scheduleDocumentCacheSave()
    }

    /// cwd-freshness fallback: pull pane `id`'s current working directory from the host `cwd` RPC
    /// (`proc_pidinfo` — shell-agnostic, needs no OSC-7) and persist it via the dirty-guarded
    /// ``setLastKnownCwd(_:for:)``, so a `cd` in this pane becomes the inherit source for the NEXT new tab /
    /// split AND the folder-name title lands without waiting for the shell to emit anything. A `nil`
    /// connection / failed RPC is a silent no-op (validate-then-drop); the metadata client's 5 s timeout
    /// bounds the await.
    ///
    /// **Attach-edge retry.** On a fresh (re)connect the pane's `activeMetadataClient` can
    /// briefly be `nil` — the control plane is still being (re)established — so a single-shot pull can MISS
    /// and leave the title at "Terminal" until the next ~3 s RTT-snapshot retry (and the RECONNECT caller,
    /// whose `pane/cwd` is already non-nil, has NO populate-once retry at all). `retries > 0` re-arms a
    /// short-delayed retry up to `retries` times, stopping the instant the RPC answers — so the cwd lands in
    /// ~1 RTT on connect and a reconnect that respawned a fresh shell reliably re-reads the host cwd.
    /// `retries == 0` (the command-completion caller, where the client is long-since live) keeps the
    /// original single-shot behaviour. The bounded retry holds `connection` strongly only for its ~1 s
    /// window; a torn-down connection just answers `nil` and exhausts the budget.
    func refreshCwd(for id: PaneID, from connection: ConnectionViewModel?, retries: Int = 0) {
        guard let connection else { return }
        Task { @MainActor [weak self] in
            if let cwd = await connection.activeMetadataClient?.cwd() {
                self?.setLastKnownCwd(cwd, for: id)
                return
            }
            // Metadata client not ready yet (or the RPC failed): re-arm a bounded, short-delayed retry so
            // the attach-edge pull is not a one-shot. Stops as soon as `self`/the budget is gone.
            guard let self, retries > 0 else { return }
            try? await Task.sleep(for: .milliseconds(300))
            refreshCwd(for: id, from: connection, retries: retries - 1)
        }
    }

    // MARK: - Section git line (the PROJECT-scoped compact summary)

    /// Pane `id`'s effective SECTION key for the git-summary store: the ``paneProjectKey(_:)``
    /// precedence (host-pushed key, else the cwd fallback, plugin dirs guarded out) read
    /// model-agnostically and NORMALIZED (``TabOrderingEngine/normalizedProjectKey(_:)``) so it equals
    /// the sidebar's bucketing key exactly. `nil` ⇒ the pane has no section identity yet (no cwd) —
    /// no git bookkeeping.
    func effectiveGitProjectKey(_ id: PaneID) -> String? {
        StoreGitCadence.sectionKey(hostKey: projectKey(for: id), cwd: paneCwd(for: id))
    }

    /// Refreshes the git summary of pane `id`'s PROJECT (``projectGitSummary`` → the sidebar section
    /// header) from the host `gitStatus` RPC on the pane's OWN metadata channel. Fired on command
    /// completion (OSC 133;D, beside ``refreshCwd(for:from:)``), on a cwd CHANGE
    /// (``setLastKnownCwd(_:for:)`` — a `cd` can enter/leave/switch repos), on reconnect, and by the
    /// project-scoped snapshot scheduler. The stale value stays visible until the fresh reply lands (no
    /// flicker); a `nil` connection / failed RPC is a silent no-op (validate-then-drop). The in-flight
    /// set de-dupes BY PROJECT: N same-repo panes reconnecting / completing together collapse to one
    /// RPC — `git status --porcelain` output is repo-root-relative, so any pane in the project answers
    /// for all of them.
    func refreshGitSummary(for id: PaneID, from connection: ConnectionViewModel?) {
        guard let connection else { return }
        let key = effectiveGitProjectKey(id)
        // A keyless pane (no cwd landed yet) still de-dupes — per PANE, its only identity.
        let inFlightKey = key ?? "pane:\(id.raw.uuidString)"
        guard !projectGitInFlight.contains(inFlightKey) else { return }
        projectGitInFlight.insert(inFlightKey)
        // The alias/no-repo booking key must be the pane's CWD-ONLY fallback — never a host-pushed
        // key. A host key can be STALE across an un-re-pushed cross-repo `cd` (nothing client-side
        // invalidates it; the host re-pushes asynchronously), and booking the NEW repo's reply
        // under the OLD repo's key would overwrite an unrelated section's genuinely-correct header.
        let aliasKey = StoreGitCadence.aliasCandidate(
            hostKey: projectKey(for: id), cwd: paneCwd(for: id),
        )
        Task { @MainActor [weak self] in
            let payload = await connection.activeMetadataClient?.gitStatus()
            guard let self else { return }
            projectGitInFlight.remove(inFlightKey)
            guard let payload else { return }
            applyGitSummary(
                PaneGitSummary(payload: payload), toplevel: payload.repoRoot, fallbackKey: aliasKey,
            )
        }
    }

    /// Pane `id`'s HOST-pushed key alone (guarded like ``paneProjectKey(_:)``'s first leg), `nil`
    /// while the pane is still on its cwd fallback — the alias-booking eligibility test above, and
    /// the code panel's ensure gate (`MacCodePanelColumn`): ensuring on the transient pre-push cwd
    /// would spawn a stranded code-server for a root the project does not actually have.
    func hostPushedProjectKey(_ id: PaneID) -> String? {
        StoreGitCadence.hostPushedKey(projectKey(for: id))
    }

    /// Re-probe pane `id`'s project git line on demand through its OWN live connection. A video /
    /// faked pane (no ``LivePaneSession``) is a silent no-op via ``refreshGitSummary(for:from:)``'s
    /// `nil`-connection guard.
    func refreshGitSummary(for id: PaneID) {
        refreshGitSummary(for: id, from: (handle(for: id) as? LivePaneSession)?.connection)
    }

    /// The section-header context-menu "Refresh Git Status" entry: re-probe `key`'s project through
    /// the FIRST live pane sectioned under it. No live pane (a ghost section mid-teardown) ⇒ no-op.
    func refreshGitSummary(forProject key: String) {
        let normalized = TabOrderingEngine.normalizedProjectKey(key)
        guard let pane = tree.allPaneIDs().first(where: { id in
            effectiveGitProjectKey(id) == normalized
                && (handle(for: id) as? LivePaneSession)?.connection != nil
        }) else { return }
        refreshGitSummary(for: pane)
    }

    /// Applies a freshly-fetched git `summary` under its PROJECT key: the reply's `toplevel`
    /// (repo root) when the cwd is a repo, else `fallbackKey` (the probed pane's own section key — a
    /// no-repo dir books its "clean, no repo" reading so the scheduler backs off for that section too).
    /// When the probed pane is still sectioned by a cwd FALLBACK that differs from the toplevel (the
    /// host's type-34 for it hasn't landed), the summary is MIRRORED under that alias too, so the
    /// interim section's header is already correct; reconcile prunes the alias once the section
    /// re-keys. Both writes are dirty-guarded (no `@Observable` churn on a quiet re-fetch); the
    /// freshness stamp always lands. `now` is injectable for deterministic staleness tests.
    func applyGitSummary(
        _ summary: PaneGitSummary, toplevel: String, fallbackKey: String?, at now: Date = Date(),
    ) {
        // Which keys this reading is the truth for — including whether it is a truth at all. A reading
        // taken while the shell was transiently inside a plugin-cache dir (a zinit turbo `builtin cd`
        // the `gitStatus` RPC raced) is dropped WHOLE: its `toplevel` is the PLUGIN's repo and its
        // branch/changed counts are that plugin's, not the user's project.
        guard let plan = StoreGitCadence.booking(toplevel: toplevel, fallbackKey: fallbackKey) else {
            return
        }
        bookGitSummary(summary, under: plan.primary, at: now)
        // The alias is the caller's own fallback key, and it rides along only when the rule says it
        // sits INSIDE the toplevel's subtree — any other relation means a stale/foreign key, and
        // booking there would poison an unrelated section's header.
        if plan.alias, let fallbackKey { bookGitSummary(summary, under: fallbackKey, at: now) }
    }

    /// Files one reading under one key: dirty-guarded so a quiet re-fetch spends no `@Observable`
    /// churn, with the freshness stamp landing either way — that is what makes the cadence back off
    /// for a section whose line did not change.
    private func bookGitSummary(_ summary: PaneGitSummary, under key: String, at now: Date) {
        if projectGitSummary[key] != summary { projectGitSummary[key] = summary }
        projectGitFetchedAt[key] = now
    }

    /// Applies a HOST-PUSHED project git summary (wire type 35 — the FSEvents watcher's event-driven
    /// truth, already folded by the connection layer). Books the push clock so the snapshot-cadence
    /// poll backs off (``gitSummaryPushGraceWindow``) while pushes keep arriving.
    func applyPushedProjectGitSummary(_ summary: PaneGitSummary, repoRoot: String, at now: Date = Date()) {
        guard let key = StoreGitCadence.pushedKey(repoRoot: repoRoot) else { return }
        bookGitSummary(summary, under: key, at: now)
        projectGitPushedAt[key] = now
    }

    /// How long a BACKGROUND project's header line stays "fresh" on the ~3 s RTT-snapshot edge before
    /// a re-fetch is allowed — long enough that the snapshot cadence is never a git-status poll, short
    /// enough that every visible section self-heals within a minute.
    static var gitSummaryStaleWindow: TimeInterval { StoreGitCadence.staleWindow }

    /// The tighter window for the ACTIVE project (the section the focused pane sits in) — the header
    /// the user is most likely acting on tracks external changes (editor saves, another terminal's
    /// commit) within seconds, still only ~4 subprocess spawns per window host-side.
    static var gitSummaryStaleWindowActiveProject: TimeInterval {
        StoreGitCadence.staleWindowActiveProject
    }

    /// The poll back-off while HOST PUSHES (wire type 35) are fresh: the watcher already delivers
    /// event-driven updates, so the poll degrades to a slow safety net (it re-arms itself the moment
    /// pushes stop arriving for this long).
    static var gitSummaryPushGraceWindow: TimeInterval { StoreGitCadence.pushGraceWindow }

    /// Whether the ~3 s RTT-snapshot edge should re-fetch pane `id`'s PROJECT git line: ALWAYS when
    /// the project has no entry yet (initial populate), else when its entry is older than the
    /// project's staleness window — ``gitSummaryStaleWindowActiveProject`` for the focused pane's
    /// project, ``gitSummaryStaleWindow`` for background ones, ``gitSummaryPushGraceWindow`` while
    /// host pushes are fresh. Because the clock is PER PROJECT (stamped on every apply) and the
    /// in-flight set de-dupes across panes, N panes ticking every ~3 s still cost at most one RPC per
    /// project per window — background projects included, which is what keeps an inactive section's
    /// header honest without a per-pane poll.
    func shouldRefreshGitOnSnapshot(_ id: PaneID, now: Date = Date()) -> Bool {
        guard let key = effectiveGitProjectKey(id) else { return false }
        // The two clocks stay here and cross as INTERVALS; the two sets stay here and cross as the
        // booleans the rule actually reads. A project with no entry lends no interval, which is the
        // initial populate the rule answers `true` for.
        return StoreGitCadence.refreshDue(
            inFlight: projectGitInFlight.contains(key),
            sinceFetch: projectGitFetchedAt[key].map(now.timeIntervalSince),
            sincePush: projectGitPushedAt[key].map(now.timeIntervalSince),
            activeProject: isActiveProject(key),
        )
    }

    /// Whether `key` is the FOCUSED pane's project — the active session's active tab's active pane.
    /// Drives the tighter active-project staleness window.
    func isActiveProject(_ key: String) -> Bool {
        guard let focused = tree.activeSession?.activeTab?.activePane else { return false }
        return effectiveGitProjectKey(focused) == key
    }
}
