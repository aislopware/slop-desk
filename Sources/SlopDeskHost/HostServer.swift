import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import SlopDeskTransport

/// The host daemon: owns the ``HostTransport`` (`NWListener`), accepts shared-mux connections, and
/// spawns a fresh login shell + per-channel relay for every channel a client opens on them.
///
/// ## Lifecycle
/// `start()` brings up the listener and consumes newly-accepted mux connections, installing a
/// per-channel-open handler on each. Every `channelOpen` mints a PTY + per-channel relay
/// (``MuxChannelSession``) and acks. `stop()` cancels the listener and shuts every channel down.
///
/// ## Session survival & reconnect
/// MANY panes ride ONE shared connection, each as a logical channel. A clean `bye` keeps the shell
/// alive (keep-alive); a peer `channelClose` or link drop reaps it (no per-channel reconnect/resume
/// yet). The daemon never kills a shell on a transient client disconnect.
///
/// `@unchecked Sendable`: mutable state (`muxSessions`, `acceptTasks`) is guarded by `lock`.
public final class HostServer: @unchecked Sendable {
    /// Requested TCP port (`0` lets the OS pick; read the result from ``boundPort()``).
    public let port: UInt16

    /// Absolute path to the shell to spawn (defaults to the user's login shell).
    public let shellPath: String

    /// What every new channel spawns: a plain login shell. Not a daemon mode — a Claude session is
    /// just a `.terminal` pane running `claude`, auto-detected by the host foreground-process watch
    /// + hook listener (Decision #5/#9). The curated env is a client-side launch preset, not a
    /// host launch mode.
    public enum LaunchMode: Sendable, Equatable {
        /// Plain login shell: `[shell] argv0=-shell`, curated generic env.
        case shell
    }

    /// The launch mode for new channels.
    public let launchMode: LaunchMode

    /// Whether new channels run the host-side foreground-process watch (the PRIMARY,
    /// zero-config Claude-Code detection signal, Decision #5). Resolved by the daemon from
    /// `SLOPDESK_AGENT_DETECT` (default-ON; only `"0"` disables). When false, the channel's byte
    /// pipeline is byte-identical to one with no watch at all.
    public let agentDetectEnabled: Bool

    /// The OPT-IN Claude-hook listener (the `AF_UNIX` socket), or `nil` when hooks are
    /// disabled (Decision #5: hooks are SECOND/opt-in — the foreground watcher runs regardless).
    /// When set, each new channel exports the socket path + a pane id into its PTY env and
    /// registers a per-pane sink; an installed hook then POSTs status events for that pane.
    public let agentHookListener: AgentHookListener?

    /// The filesystem path of the bound hook socket, exported as `SLOPDESK_SOCKET_PATH` into
    /// every PTY env when ``agentHookListener`` is set. Empty when hooks are disabled.
    public let agentHookSocketPath: String

    /// The filesystem path of the agent-control socket, exported as `SLOPDESK_CONTROL_SOCKET`
    /// into every PTY env when ``agentControlEnabled`` is true. Empty when control is disabled.
    public let agentControlSocketPath: String

    /// The absolute path to the `slopdesk-ctl` binary, exported as `SLOPDESK_CTL_BIN` into a
    /// control-spawned pane's env (P1) so an agent self-orients with zero discovery. Empty → not
    /// exported (the agent falls back to a PATH lookup). Resolved by the daemon (sibling of hostd).
    public let ctlBinaryPath: String

    private let transport: HostTransport
    private let lock = NSLock()
    private var muxAcceptTask: Task<Void, Never>?

    /// Agent-control: standalone sessions spawned by the `spawn` verb (no client connection).
    /// Keyed by `sessionID` (UUID), guarded by `lock`.  Drained on `stop()` alongside
    /// `muxSessions` so no orphan PTY outlives the daemon.
    private var controlSessions: [UUID: MuxChannelSession] = [:]

    /// Server-level cross-pane `agent_status_changed` observers, keyed by a
    /// per-subscription `UUID`, guarded by `agentStatusObserversLock`. Each ``MuxChannelSession``
    /// (mux OR control) is wired with an `onAgentStatusChanged` closure that calls
    /// ``fanAgentStatusChanged(paneId:title:status:)``, which snapshots this map and invokes every
    /// observer with `(paneId, state, agentPresent, title, ts)`. A top-level `subscribe` (no paneId)
    /// registers one here and deregisters on disconnect. Separate lock from `lock` so a status
    /// fan-out never contends with the session maps (the closure may run on the foreground-poll
    /// task thread).
    private let agentStatusObserversLock = NSLock()
    private var agentStatusObservers: [UUID: @Sendable (
        _ paneId: String,
        _ state: String,
        _ agentPresent: Bool,
        _ title: String,
        _ ts: Double,
    ) -> Void] = [:]

    /// Live per-channel mux sessions, keyed by `(connectionID, channelID)`, guarded by `lock`.
    ///
    /// ⚠️ The key is the COMPOSITE, not `channelID` alone: every distinct client connection
    /// allocates `channelID` 1 for its first pane (``ChannelTable/allocate()`` starts at 1 per
    /// connection), so a channelID-only key made connection B's `channelOpen(1)` silently
    /// OVERWRITE connection A's live session at `1` (orphaning A's PTY/master-fd), and made A's
    /// close-hook `removeMuxSession(1)` shut DOWN B's live pane — cross-shutting a different
    /// client. Namespacing by the per-connection identity gives each connection its own keyspace.
    private var muxSessions: [MuxSessionKey: MuxChannelSession] = [:]

    /// Which SUBSCRIBER of its session each live key is, guarded by `lock`.
    ///
    /// Several keys map to ONE `MuxChannelSession`, and every per-client action — a link drop, a
    /// peer `channelClose`, an eviction — has to name the ONE member it concerns rather than the
    /// session. A key with no entry is the pane's original
    /// channel (``MuxChannelSession/primarySubscriberID``), and that is the ONLY thing a missing
    /// entry may mean: a JOIN writes its entry in the same critical section that writes
    /// `muxSessions` (``registerJoiningKeyLocked(_:key:)``), so no key is ever briefly
    /// indistinguishable from the primary.
    private var muxSubscriberIDs: [MuxSessionKey: MuxSubscriberID] = [:]

    /// Accepted shared mux connections, keyed by their stable `connectionID`, guarded by `lock`.
    /// The host must RETAIN every accepted ``MuxNWConnection`` so it can `close()` it —
    /// cancelling its 2 receive loops + 2 `NWConnection`s/sockets — on ``stop()`` or link drop.
    /// Without this map, `stop()` would close nothing and the open handler would capture the connection
    /// strongly (a retain cycle), so every Start→Stop cycle on the long-lived menu-bar host would abandon
    /// one live connection + 2 sockets + 2 tasks, accumulating toward EMFILE. The map is also the strong
    /// ref the open handler resolves the connection from (instead of capturing it).
    private var muxConnections: [UUID: MuxNWConnection] = [:]

    /// Set true by ``stop()`` (under `lock`) before draining sessions. The accepted connections' receive
    /// loops keep running after `stop()` (the listener cancel does not cancel them), so a `channelOpen`
    /// already buffered / in flight can still reach ``spawnMuxChannel`` AFTER the session map is drained
    /// — which would fork a login shell that is never reaped and OUTLIVES the daemon (SIGINT during an
    /// active channel-open). `spawnMuxChannel` checks this flag (early, and again at the insert) and
    /// REFUSES the channel once stopping, so no orphan PTY is minted past shutdown. Monotonic; guarded
    /// by `lock`.
    private var stopping = false

    /// The ORIGINAL hook-routing pane id per live session, keyed by the session's stable
    /// `sessionID`, guarded by `lock`. The pane id is exported ONCE into the child env as
    /// `SLOPDESK_PANE_ID` at fresh spawn and is immutable for the shell's life — the agent's
    /// hook POSTs are forever tagged with it, so the ``AgentHookListener`` sink key must stay
    /// pinned to this original id across every detach/reattach cycle (a per-reattach
    /// new-connection key would both leak one dead sink per cycle and never route). Entries
    /// are removed on every end of life: deliberate close (``removeMuxSession``), detached exit,
    /// TTL/overflow eviction (``DetachedSessionStore/onEvicted``), and the failed-rebind
    /// dead-child reap.
    private var hookPaneIDsBySession: [UUID: HookSinkRegistration] = [:]

    /// One session's hook-sink routing entry. `owner` (the registering session's object
    /// identity) makes teardown IDENTITY-GUARDED: a stale end-of-life for a same-UUID ghost —
    /// the detach-window race can mint a fresh session under a sessionID whose predecessor is
    /// still winding down — must never remove the entry the live successor just registered
    /// (the successor's agent-status hook POSTs would silently stop routing forever).
    private struct HookSinkRegistration {
        let paneID: String
        let owner: ObjectIdentifier
    }

    /// Cache of the resolved effective TERM keyed by `requested|explicitOverride`, guarded by `lock`.
    /// The host's terminfo state doesn't change during a session, so the (possibly `infocmp`-spawning)
    /// probe runs at most ~once per key instead of on EVERY channel-open (new pane/tab), and the
    /// fallback diagnostic is logged exactly once — no per-open re-probe, no unbounded synchronous
    /// `infocmp` on the channel-open path.
    private var resolvedTermCache: [String: ClaudeCodeProfile.Term] = [:]

    /// A hook the daemon can set to log session lifecycle to stderr.
    public var onLog: (@Sendable (String) -> Void)?

    /// An optional hook called with the current count of distinct client *connections* (one
    /// shared TCP mux connection per client, regardless of panes/channels — same semantics as
    /// ``liveSessionIDs()``). Fired whenever a channel is added or removed, and reset to 0 on
    /// ``stop()``.
    ///
    /// Purely observational and ADDITIVE: defaults to `nil`, so the headless `slopdesk-hostd`
    /// daemon (which never sets it) is byte-identical. Exists for the menu-bar host app's live
    /// "N client(s) connected" line. The closure is `@Sendable` and may be invoked off the main
    /// actor (from the lock-guarded spawn/remove paths) — the app hops to its actor before touching UI.
    public var onConnectionCountChanged: (@Sendable (Int) -> Void)?

    /// Fired when the listener fails AFTER it became ready — a post-bind interface drop /
    /// socket error that the one-shot `start()` result cannot report. Purely observational and
    /// ADDITIVE (defaults `nil`, so the headless `slopdesk-hostd` daemon is byte-identical): the
    /// menu-bar host app sets it to re-classify its "running" badge to "failed" when the listener
    /// silently dies. May be invoked off the main actor; the app hops to its actor.
    public var onListenerFailed: (@Sendable (SlopDeskTransportError) -> Void)?

    /// Whether new channels run the additive "Blocks" tap (the ``CommandBlockSegmenter`` +
    /// the type-28/29 wire). Resolved from `SLOPDESK_BLOCKS` (default-ON; only `"0"` disables) by
    /// the daemon and passed in. When false, a channel's byte pipeline is byte-identical to one with
    /// no Blocks tap at all.
    public let blocksEnabled: Bool

    /// Whether detach/reattach is enabled (env `SLOPDESK_DETACH_ENABLED`). Default-ON idiom:
    /// when the env var equals `"0"`, detach is off and a disconnect routes to the existing immediate
    /// shutdown. Any other value (or absence) enables detach. Resolved once at init so
    /// every handler reads a single immutable Bool.
    public let detachEnabled: Bool

    /// How long a detached session's shell survives before being killed, or `nil` for
    /// INDEFINITELY (the tmux/zellij semantics — a detached session lives until the daemon dies,
    /// the client explicitly ends it, or the ``DetachedSessionStore`` 64-session cap evicts the
    /// oldest). Env `SLOPDESK_DETACH_TTL_SECS`: unset or `0` = never (the default); a positive
    /// value opts back into timed eviction. Resolved once at init.
    public let detachTTL: Duration?

    /// The "Resume Session on Recovery" host policy (client toggle
    /// ``AgentPreferences/resumeOnRecovery`` → `SLOPDESK_AGENT_RESUME_ON_RECOVERY`, default-ON `!= "0"`).
    /// Maps onto ``DetachedSessionStore`` (spec `getting-started__first-launch` §"Resume Session on
    /// Recovery"): ON → a recovered terminal reattaches to the still-running detached session; OFF →
    /// the host neither keeps nor reattaches, so recovery yields a FRESH shell. Resolved once at init
    /// and AND-ed into ``detachEnabled`` (the single reattach gate) so this flag actuates.
    public let resumeOnRecovery: Bool

    /// Resolved detached-session cap: `nil` = UNBOUNDED (the default — tmux/zellij have no
    /// session cap and never silently kill a live detached session; per-session byte caps + the
    /// fd headroom are the real bounds). A positive `SLOPDESK_DETACH_MAX_SESSIONS` opts into
    /// oldest-evicted capping. See ``DetachedSessionStore/maxSessions``.
    public let detachMaxSessionsResolved: Int?

    /// The store for detached sessions. `nil` when `detachEnabled == false`.
    private let detachedStore: DetachedSessionStore?

    /// The event-driven git-status source (wire type 35): one FSEvents stream per repo with live
    /// panes, fed by every session's ``MuxChannelSession/onProjectKeyResolved`` and drained by its
    /// `onTeardown`. Gated by ``gitWatchEnabled``; its `push`/`shouldProbe` closures are wired at
    /// the end of `init` (they capture `weak self`).
    private let repoWatcher = RepoStatusWatcher()

    /// `SLOPDESK_GIT_WATCH` (default-ON; only `"0"` disables): whether sessions feed the
    /// ``RepoStatusWatcher``. The kill switch for the FSEvents + probe machinery — with it off the
    /// wire never carries a type 35 and the client falls back to its poll cadence alone.
    public let gitWatchEnabled: Bool

    /// Disk scrollback journals (history that survives the daemon — see ``ScrollbackJournalStore``).
    /// AND-ed with the detach gate: without detach the client never re-presents a session ID (so a
    /// journal could never be restored) and a link drop routes through the journal-DELETING
    /// `removeMuxSession` path. `nil` = disk persistence off (also the unit-test default, so tests
    /// never touch the real Application Support dir — hostd main wires `makeFromEnvironment()`).
    private let scrollbackJournals: ScrollbackJournalStore?

    /// Cadence for the periodic ``ScrollbackJournalStore/sweep()`` pass that runs for the life of
    /// the daemon (see ``scrollbackJournals``'s docs). hostd is a week/month-long process: a
    /// single sweep at init leaves orphaned `<uuid>.scrollback` files from link-drop detaches and
    /// TTL evictions unbounded until a daemon restart. Injectable so tests can drive the loop
    /// without a wall-clock day; production default = daily.
    public let scrollbackSweepInterval: Duration

    /// Handle for the periodic sweep loop (nil when disk persistence/detach is off). Cancelled in
    /// ``stop()`` so a repeated Start→Stop cycle never leaks a background loop (mirrors
    /// ``HostTransport``'s `reaperTask`).
    private var journalSweepTask: Task<Void, Never>?

    /// The host's single copy of the workspace (docs/45). Every host serves one: a client renders its
    /// tree FROM this document, so a host without one is a host a client cannot draw.
    let workspaceDocument: HostWorkspaceDocument

    /// Where that copy lives between daemon runs, and where the first-run default comes from. `nil`
    /// when Application Support cannot be resolved — a host that cannot persist still serves a
    /// workspace, it just mints a fresh one every start.
    let workspaceStore: HostWorkspaceStore?

    /// At most ONE workspace channel per mux connection, keyed by `connectionID` and guarded by
    /// `lock`. A second `channelClass == 1` open on the same connection is refused: two subscribers
    /// behind one link would each keep their own acked base for the same viewer, and the roster
    /// would show one device twice.
    private var workspaceChannels: [UUID: WorkspaceChannelSession] = [:]

    /// Reconciler cadence — how often every live pane is re-captured into the document.
    ///
    /// A tick is the BACKSTOP, not the mechanism: the event sites kick a reconcile directly, so the
    /// steady-state latency is one hop rather than half a period. The tick exists because a fact can
    /// change with no edge to hang a kick on (a foreground process the watcher sampled, a window
    /// resize), and because an unchanged capture costs nothing — it produces no version bump and
    /// therefore no frame.
    public let workspaceReconcileInterval: Duration

    private var workspaceReconcileTask: Task<Void, Never>?

    /// Stable document object ids for projects, keyed by the project's absolute toplevel path and
    /// guarded by `lock`.
    ///
    /// MINTED, not hashed. docs/45 §5.3 proposed `UUIDv5(projectKey)`, which would need a SHA-1 this
    /// target does not otherwise link. A minted id is exact where a hash is merely unlikely to
    /// collide, and its only cost — a different id after a restart — is invisible: a restart mints a
    /// new `epoch`, every client resets and re-snapshots, and `project/key` carries the actual path,
    /// which is what the client joins on.
    private var projectObjectIDs: [String: UUID] = [:]
    /// Depth-1 coalescing for the reconciler: a kick arriving while one runs sets the "again" flag
    /// instead of stacking another pass. Guarded by `lock`.
    private var workspaceReconcileInFlight = false
    private var workspaceReconcileAgain = false

    public init(
        port: UInt16,
        shellPath: String? = nil,
        launchMode: LaunchMode = .shell,
        agentDetectEnabled: Bool = false,
        agentHookListener: AgentHookListener? = nil,
        agentHookSocketPath: String = "",
        agentControlSocketPath: String = "",
        ctlBinaryPath: String = "",
        blocksEnabled: Bool = true,
        detachEnabled: Bool? = nil,
        detachTTLSecs: Int? = nil,
        detachMaxSessions: Int? = nil,
        resumeOnRecovery: Bool? = nil,
        scrollbackJournals: ScrollbackJournalStore? = nil,
        scrollbackSweepInterval: Duration = .seconds(24 * 3600),
        workspaceStore: HostWorkspaceStore? = nil,
        workspaceReconcileInterval: Duration = .milliseconds(500),
    ) {
        self.port = port
        self.shellPath = shellPath ?? HostEnvironment.loginShell()
        self.launchMode = launchMode
        self.agentDetectEnabled = agentDetectEnabled
        self.agentHookListener = agentHookListener
        self.agentHookSocketPath = agentHookSocketPath
        self.agentControlSocketPath = agentControlSocketPath
        self.ctlBinaryPath = ctlBinaryPath
        self.blocksEnabled = blocksEnabled
        self.scrollbackSweepInterval = scrollbackSweepInterval
        self.workspaceReconcileInterval = workspaceReconcileInterval
        // A fresh `epoch` per HostServer instance — which is per hostd start. Without it a restarted
        // daemon counts `stateNum` back up from 1 and a returning client one behind would accept a
        // delta computed against a completely different document.
        workspaceDocument = HostWorkspaceDocument()
        // Injected by tests, which must never read or write the developer's real Application
        // Support: `load()` mints and `scheduleSave` writes, and one test doing either against the
        // shared path would silently replace a workspace somebody is using. Every test that calls
        // ``start()`` has to inject one (or point `SLOPDESK_WORKSPACE_STATE_DIR` at a scratch
        // directory) — construction alone reaches no disk, `load()` does.
        self.workspaceStore = workspaceStore
            ?? HostWorkspaceStore.make(hostDisplayName: HostWorkspaceStore.hostDisplayName())
        gitWatchEnabled = ProcessInfo.processInfo.environment["SLOPDESK_GIT_WATCH"] != "0"
        transport = HostTransport()

        // Resolve detach from env (default-ON: only "0" disables) unless overridden by the caller.
        let envDetach = ProcessInfo.processInfo.environment["SLOPDESK_DETACH_ENABLED"]
        // "Resume on Recovery" gates the SAME reattach machinery. AND it into the
        // detach gate — when OFF, detached sessions are neither kept (handleLinkDown hard-shuts down) nor
        // reattached (spawnMuxChannel sees a nil store), so recovery yields a fresh shell.
        let effectiveResume = resumeOnRecovery ?? HostEnvironment.agentResumeOnRecoveryEnabled()
        self.resumeOnRecovery = effectiveResume
        let effectiveDetach = (detachEnabled ?? (envDetach != "0")) && effectiveResume
        self.detachEnabled = effectiveDetach

        // TTL default = NEVER (tmux/zellij semantics): a detached shell — often a running
        // agent the user deliberately left working — is never reaped on a timer. `0` (or any
        // non-positive value) also means never; a positive value opts into timed eviction.
        // The DetachedSessionStore session cap stays as the resource bound.
        let envTTL = ProcessInfo.processInfo.environment["SLOPDESK_DETACH_TTL_SECS"]
            .flatMap { Int($0) }
        let ttlSecs = detachTTLSecs ?? envTTL ?? 0
        detachTTL = ttlSecs > 0 ? .seconds(ttlSecs) : nil

        // Detached-session cap: default UNBOUNDED (tmux semantics — see
        // ``DetachedSessionStore/maxSessions``). SLOPDESK_DETACH_MAX_SESSIONS > 0 opts into
        // oldest-evicted capping; unset/non-positive = no cap.
        let envCap = ProcessInfo.processInfo.environment["SLOPDESK_DETACH_MAX_SESSIONS"]
            .flatMap { Int($0) }
        let cap = detachMaxSessions ?? envCap ?? 0
        detachMaxSessionsResolved = cap > 0 ? cap : nil
        detachedStore = effectiveDetach ? DetachedSessionStore(maxSessions: detachMaxSessionsResolved) : nil

        // Disk scrollback journals ride the same gate as detach (see the property docs). Sweep
        // orphans OFF the init path — a cold Application Support scan must never delay startup —
        // then keep re-sweeping on ``scrollbackSweepInterval`` for the life of the daemon: hostd
        // is a week/month-long process, and a single init-time sweep would leave orphans from
        // link-drop detaches and TTL evictions unbounded until a daemon restart.
        let journals = effectiveDetach ? scrollbackJournals : nil
        self.scrollbackJournals = journals
        if let journals {
            startJournalSweep(journals: journals)
        }

        // Non-deliberate ends of life the store handles ITSELF (TTL + overflow eviction) never
        // reach `removeMuxSession` — release the evictee's journal writer (fd + map entry; the
        // FILE survives as the restore source) and drop its hook-sink key here, or both leak
        // once per eviction for the daemon's lifetime. Fired outside the store lock; neither
        // eviction path runs under `HostServer.lock` (see `DetachedSessionStore.onEvicted`).
        detachedStore?.onEvicted = { [weak self] session in
            // Identity-guarded: `instance`/`owner` matching means evicting a same-UUID ghost
            // can never close the journal writer / hook-sink key a live successor session owns.
            self?.scrollbackJournals?.release(
                sessionID: session.sessionID, instance: session.scrollbackJournal,
            )
            self?.unregisterHookSink(session: session)
            // The store killed a session behind the document's back. Without this the document goes
            // semantically stale with no signal and every client keeps rendering a live row for a
            // shell that was reaped on a TTL.
            guard let self else { return }
            let document = workspaceDocument
            let paneID = session.sessionID
            Task { await document.markPaneDead(paneID) }
        }

        // Repo-watch push wiring (the closures capture weak self, so they wire AFTER init's stored
        // properties). A push fans to every live session sectioned under the repo — attached ones
        // deliver, detached ones drop it in their wiped control-out (the reconnect pull catches up).
        repoWatcher.push = { [weak self] status in
            guard let self else { return }
            lock.lock()
            let sessions = Self.distinct(muxSessions.values) + Array(controlSessions.values)
            lock.unlock()
            for session in sessions { session.pushProjectGitStatusIfMatching(status) }
            // …and into the document, keyed by PROJECT. Type 35 keeps pushing as the fast path; this
            // is the retained value, so a client that has never seen this host renders the git line
            // from the snapshot instead of waiting for the next FSEvents edge to fire.
            publishProjectGitSummary(status)
        }
        // No client connection ⇒ nobody to tell: skip the git subprocess entirely (a wall of
        // detached agents churning a repo must not keep probing for an empty audience).
        repoWatcher.shouldProbe = { [weak self] in
            guard let self else { return false }
            lock.lock()
            defer { lock.unlock() }
            return !muxConnections.isEmpty
        }
    }

    /// Launches the periodic disk-scrollback sweep — ``ScrollbackJournalStore/sweep()`` re-run at
    /// ``scrollbackSweepInterval`` cadence for the life of the daemon (see ``scrollbackJournals``'s
    /// docs for why a single init-time sweep is not enough). Mirrors `HostTransport.startReaper()`'s
    /// shape. No `self` capture needed: `journals` and the interval are plain values, and the loop
    /// is torn down by cancelling ``journalSweepTask`` (``stop()``), not by `self` deallocating.
    private func startJournalSweep(journals: ScrollbackJournalStore) {
        let interval = scrollbackSweepInterval
        journalSweepTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                journals.sweep()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return // cancelled
                }
            }
        }
    }

    /// Launches the workspace reconciler's backstop tick (see ``workspaceReconcileInterval``). Lives
    /// here rather than in `HostServer+Workspace` because it owns a stored task, and the task is
    /// cancelled by ``stop()`` so a repeated Start→Stop cycle never leaks a loop — the same contract
    /// `startJournalSweep` has.
    private func startWorkspaceReconciler() {
        let interval = workspaceReconcileInterval
        workspaceReconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return // cancelled
                }
                await self?.reconcileWorkspaceDocument()
            }
        }
    }

    /// The document object id for a project path, minting one on first sight.
    func projectObjectID(forKey key: String) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let existing = projectObjectIDs[key] { return existing }
        let minted = UUID()
        projectObjectIDs[key] = minted
        return minted
    }

    /// Publishes one repo's git summary into the document.
    ///
    /// The value is the type-35 BODY verbatim — the same bytes the fast path pushes — so
    /// `project/gitSummary` costs no new codec on either end: the client already has a decoder for
    /// exactly these bytes.
    private func publishProjectGitSummary(_ status: WireMessage.ProjectGitStatus) {
        let document = workspaceDocument
        let id = projectObjectID(forKey: status.repoRoot)
        let key = status.repoRoot
        let body = Self.wireBody(of: .projectGitStatus(status))
        Task { await document.setProject(id: id, key: key, gitSummary: body) }
    }

    /// A message's body — `encode()` minus the 4-byte length prefix and the 1-byte type tag.
    static func wireBody(of message: WireMessage) -> Data {
        let framed = message.encode()
        guard framed.count > 5 else { return Data() }
        return framed.subdata(in: (framed.startIndex + 5)..<framed.endIndex)
    }

    /// The stable pane id for a channel — the composite `(connectionID, channelID)` key, which
    /// uniquely identifies one pane across simultaneous client connections. Exported into the
    /// PTY env as `SLOPDESK_PANE_ID` and used as the hook-listener routing key.
    static func paneID(connectionID: UUID, channelID: UInt32) -> String {
        "\(connectionID.uuidString):\(channelID)"
    }

    /// The port the listener actually bound to (resolved after ``start()``).
    public func boundPort() async -> UInt16? {
        await transport.boundPort
    }

    /// Starts the listener and begins accepting shared mux connections. Returns once the listener
    /// is ready (so the caller can read ``boundPort()``).
    public func start() async throws {
        // Forward a POST-ready listener failure to this server's hook. Read the hook lazily
        // at failure time (`self?.onListenerFailed`) so the app's assignment after init is honoured;
        // `[weak self]` avoids retaining the server through the transport's listener handler.
        try await transport.start(port: port, onListenerFailed: { [weak self] err in
            self?.onListenerFailed?(err)
        })
        // Pre-warm the terminfo resolution OFF any connection's receive loop: the resolution can run a
        // directory probe and (on a host lacking the ghostty terminfo) spawn `infocmp`, which done lazily
        // inside `spawnMuxChannel` would block the MuxNWConnection actor's receive loop on the first
        // channel-open. Resolving the common key (.ghostty, false) here in a detached task
        // warms `resolvedTermCache`, so `spawnMuxChannel` reads it with no probe/IO on the connection's
        // actor. (The .xterm256-explicit path short-circuits the probe entirely.)
        Task.detached(priority: .utility) { [weak self] in
            _ = self?.resolveEffectiveTerm(requested: .ghostty, explicitOverride: false)
        }
        await installWorkspaceDocument()
        startWorkspaceReconciler()
        let muxStream = transport.muxConnections
        muxAcceptTask = Task { [weak self] in
            for await muxConnection in muxStream {
                await self?.handleNewMuxConnection(muxConnection)
            }
        }
    }

    /// Stops the listener and shuts down every live and detached channel.
    public func stop() async {
        // Mark stopping FIRST so any `channelOpen` racing this shutdown (the accepted connections'
        // receive loops keep running past the listener cancel) is REFUSED by `spawnMuxChannel` rather
        // than forking a shell that would be minted after the drain below and outlive the daemon.
        markStopping()
        muxAcceptTask?.cancel()
        journalSweepTask?.cancel()
        journalSweepTask = nil
        await transport.stop()
        // Tear the channels down in PARALLEL on the concurrent teardown queue rather than serially:
        // each `shutdown()` blocks up to ~0.25s for an interactive shell that ignores SIGTERM, so N
        // panes would cost ~N×0.25s serially while parking a cooperative-pool thread. `shutdownDetached`
        // runs each on `MuxChannelSession.teardownQueue` (concurrent); we still AWAIT every completion
        // before returning, preserving the CLI reap-before-exit invariant (children fully reaped + master
        // fds closed before `slopdesk-hostd` calls `exit(0)`).
        let liveMux = drainMuxSessions()
        let liveControl = drainControlSessions()
        await withTaskGroup(of: Void.self) { group in
            for session in liveMux + liveControl {
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        session.shutdownDetached { c.resume() }
                    }
                }
            }
            await group.waitForAll()
        }
        workspaceReconcileTask?.cancel()
        workspaceReconcileTask = nil
        // A debounce that outlives the process loses the last thing the user did.
        await workspaceStore?.flush()
        await workspaceDocument.shutdown()
        drainWorkspaceChannels()
        // Kill every detached session — shells that were kept alive across a client disconnect.
        detachedStore?.drainAll()
        // Cancel every repo FSEvents stream (the per-session teardown signals already released the
        // refcounts above; this is the belt-and-braces daemon-stop sweep).
        repoWatcher.shutdown()
        // Close every accepted connection so its 2 receive loops + 2 NWConnections/sockets are torn
        // down (and its handler retain cycle broken). Without this, each Start→Stop cycle on the
        // long-lived menu-bar host abandons one live connection → accumulation toward EMFILE.
        let liveConns = drainMuxConnections()
        for conn in liveConns { await conn.close() }
    }

    /// Synchronously sets the `stopping` flag (NSLock is unavailable from the async `stop()` directly).
    private func markStopping() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    /// Synchronously removes and returns every live mux channel session (no `await` across the lock).
    private func drainMuxSessions() -> [MuxChannelSession] {
        lock.lock()
        // DEDUPED by object identity: under a fan-out N keys alias ONE session, and returning it N
        // times would fire N `fanAgentTeardown` calls against a strictly-balanced prevent-sleep
        // counter and N shutdowns of the same PTY.
        let live = Self.distinct(muxSessions.values)
        muxSessions.removeAll()
        muxSubscriberIDs.removeAll()
        lock.unlock()
        // The map is now empty → report 0 distinct client connections (the `stop()` path).
        onConnectionCountChanged?(0)
        return live
    }

    /// Synchronously removes and returns every standalone control session so `stop()` can drain them
    /// in parallel (same pattern as `drainMuxSessions()`). NSLock is unavailable from async `stop()`.
    private func drainControlSessions() -> [MuxChannelSession] {
        lock.lock()
        let live = Array(controlSessions.values)
        controlSessions.removeAll()
        lock.unlock()
        return live
    }

    // MARK: - Workspace-document registry (the lock discipline stays in THIS file)

    //
    // `lock`, `stopping` and the session maps are file-private on purpose, so `HostServer+Workspace`
    // reaches them only through these — the same idiom `pushProjectGitStatusIfMatching` uses for the
    // project-key latch. Each one takes the lock, does one thing, and releases it; none of them can
    // be held across an `await`.

    /// Registers the connection's ONE workspace subscriber. Returns `nil` when refused — the daemon
    /// is stopping, or this connection already has one.
    func registerWorkspaceChannel(
        connectionID: UUID,
        make: () -> WorkspaceChannelSession,
    ) -> WorkspaceChannelSession? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, workspaceChannels[connectionID] == nil else { return nil }
        let session = make()
        workspaceChannels[connectionID] = session
        return session
    }

    func workspaceChannel(for connectionID: UUID) -> WorkspaceChannelSession? {
        lock.lock()
        defer { lock.unlock() }
        return workspaceChannels[connectionID]
    }

    /// Whether a pane opened on `connectionID` votes in that pane's size fold (docs/45 §8.3 rule 3).
    ///
    /// Resolved HOST-side from the workspace channel's `clientKind`, because `MuxChannelOpen` carries
    /// no client kind and the client's own resize path has no platform gate — a client-side rule
    /// alone would be defeated by any build that predates it.
    ///
    /// **No workspace channel means CONTRIBUTES.** That is the shipped `slopdesk-client` CLI, which
    /// only ever opens class 0 or 2, and the window before a GUI client's subscribe lands (closed by
    /// ``reresolveSizePassivity(connectionID:)``); defaulting them to passive would leave a CLI unable
    /// to size its own pane.
    func sizePassiveForConnection(_ connectionID: UUID) -> Bool {
        guard let channel = workspaceChannel(for: connectionID) else { return false }
        // A phone must never crush a Mac. The subscribe's own `contributesSize` flag is a client
        // OFFER and is not yet sent by anything, so the kind — which the host can check — is what is
        // enforced.
        return channel.clientKind == WorkspaceClientKind.iOS.rawValue
    }

    /// Re-resolves size-passivity for every pane already open on `connectionID`.
    ///
    /// A pane channel and the workspace channel are announced independently on one mux connection, so
    /// a client that opens its panes before it subscribes would otherwise have every pane resolved
    /// against a workspace channel that did not exist yet — an iPhone silently contributing for the
    /// life of the connection. The subscribe is the edge that settles it.
    ///
    /// The re-resolve is addressed to the SUBSCRIBER this connection rides, never to the pane's
    /// primary: under a fan-out one session is named by N keys, and a phone subscribing would
    /// otherwise mark the MAC's contribution passive and hand the phone the vote it was denied.
    func reresolveSizePassivity(connectionID: UUID) {
        let passive = sizePassiveForConnection(connectionID)
        lock.lock()
        let members = muxSessions
            .filter { $0.key.connectionID == connectionID }
            .map { (session: $0.value, subscriber: muxSubscriberIDs[$0.key] ?? MuxChannelSession.primarySubscriberID) }
        lock.unlock()
        for member in members {
            member.session.addResizeContributor(member.subscriber, sizePassive: passive)
        }
    }

    @discardableResult
    func unregisterWorkspaceChannel(connectionID: UUID) -> WorkspaceChannelSession? {
        lock.lock()
        defer { lock.unlock() }
        return workspaceChannels.removeValue(forKey: connectionID)
    }

    /// `true` when the caller may proceed with a reconcile pass; `false` when one is already running
    /// (in which case the "again" flag is set instead — depth-1 coalescing, not a queue).
    func beginWorkspaceReconcile() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if workspaceReconcileInFlight {
            workspaceReconcileAgain = true
            return false
        }
        workspaceReconcileInFlight = true
        return true
    }

    /// Ends a pass. Returns `true` if a kick arrived while it ran and another pass is owed.
    func endWorkspaceReconcile() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        workspaceReconcileInFlight = false
        let again = workspaceReconcileAgain
        workspaceReconcileAgain = false
        return again
    }

    /// `true` when a reconcile is already running — the cheap pre-check a kick makes before
    /// spawning a task.
    func workspaceReconcileIsRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if workspaceReconcileInFlight {
            workspaceReconcileAgain = true
            return true
        }
        return false
    }

    /// Every pane the host knows about, split by how live it is.
    ///
    /// The three inventories are disjoint by construction — `detachMuxSession` removes from
    /// `muxSessions` before inserting into the store, and `claim` removes before the reattach
    /// re-registers — the same argument `listPanesForControl()` relies on. `detachedStore` is read
    /// OUTSIDE `lock`: the store takes its own, and the nesting contract is one-way.
    func paneSessionsForWorkspace() -> (attachedToClient: [MuxChannelSession], unattached: [MuxChannelSession]) {
        lock.lock()
        // DEDUPED: N keys can alias one session under a fan-out, and a pane listed twice would be
        // captured twice by the workspace reconcile.
        let mux = Self.distinct(muxSessions.values)
        let ctrl = Array(controlSessions.values)
        lock.unlock()
        return (mux, ctrl + (detachedStore?.allSessions() ?? []))
    }

    /// Every pane's RESOLVED grid and who is holding it there — the presence roster's `panes` half.
    ///
    /// The join from a pane to a human-readable device is `MuxSessionKey.connectionID →
    /// workspaceChannels[connectionID].clientInstanceID`, because panes and the workspace channel
    /// share one `MuxNWConnection` per (host, port). The join is OPTIONAL and legitimately misses:
    /// `slopdesk-client` opens no workspace channel at all. An unlabelled attachment still COUNTS —
    /// it is a real client holding a real pane at a real size — so it is published with the all-zero
    /// id rather than dropped.
    ///
    /// Sessions are copied out under `lock` and read afterwards: the reads take the PTY's `exitLock`,
    /// and this file's one-way nesting contract keeps `lock` off that path.
    func paneRosterRecords() -> [WorkspaceRosterPane] {
        lock.lock()
        // ONE record per PANE, whoever many clients hold it: the join from a SUBSCRIBER to a
        // connection is `muxSubscriberIDs` (a key with no entry is the pane's original channel), so
        // a fanned-out pane publishes one row carrying one attachment per watching device rather
        // than N duplicate rows the diff would read as churn.
        var connectionBySubscriber: [ObjectIdentifier: [MuxSubscriberID: UUID]] = [:]
        for (key, session) in muxSessions {
            let subscriber = muxSubscriberIDs[key] ?? MuxChannelSession.primarySubscriberID
            connectionBySubscriber[ObjectIdentifier(session), default: [:]][subscriber] =
                key.connectionID
        }
        let attached = Self.distinct(muxSessions.values)
        let ctrl = Array(controlSessions.values)
        let identities = workspaceChannels.mapValues(\.clientInstanceID)
        lock.unlock()

        var records: [WorkspaceRosterPane] = []
        records.reserveCapacity(attached.count + ctrl.count)
        for session in attached {
            let grid = session.resolvedGridForWorkspace
            let connections = connectionBySubscriber[ObjectIdentifier(session)] ?? [:]
            records.append(WorkspaceRosterPane(
                paneID: session.sessionID,
                resolvedCols: grid.cols,
                resolvedRows: grid.rows,
                attachments: session.resizeContributionsForWorkspace.map { attachment in
                    let connectionID = connections[attachment.subscriber]
                    let identity = connectionID.flatMap { identities[$0] } ?? WireMessage.newSessionID
                    return WorkspaceRosterPane.Attachment(
                        clientInstanceID: identity,
                        contributes: attachment.contributes,
                        cols: attachment.cols,
                        rows: attachment.rows,
                    )
                },
            ))
        }
        // A ctl-spawned or detached pane has ZERO attachments by construction — nobody is watching
        // it. It keeps its last size (§8.3 rule 4), and the empty list is what says so.
        for session in ctrl + (detachedStore?.allSessions() ?? []) {
            let grid = session.resolvedGridForWorkspace
            records.append(WorkspaceRosterPane(
                paneID: session.sessionID,
                resolvedCols: grid.cols,
                resolvedRows: grid.rows,
                attachments: [],
            ))
        }
        // Deterministic order, like the client half: a roster that reshuffled every broadcast would
        // make every diff of it look like a change.
        return records.sorted { $0.paneID.uuidString < $1.paneID.uuidString }
    }

    /// Synchronously drops every workspace subscriber (NSLock is unavailable from async `stop()`).
    /// The document's own `shutdown()` already closed them; this clears the map so a Start→Stop→Start
    /// cycle does not refuse the returning client's channel as a duplicate.
    private func drainWorkspaceChannels() {
        lock.lock()
        workspaceChannels.removeAll()
        lock.unlock()
    }

    /// Synchronously removes and returns every retained accepted connection. The caller `close()`s them
    /// outside the lock (cancelling receive loops + sockets + breaking the handler cycle).
    private func drainMuxConnections() -> [MuxNWConnection] {
        lock.lock()
        let live = Array(muxConnections.values)
        muxConnections.removeAll()
        lock.unlock()
        return live
    }

    /// Synchronously retains an accepted connection (NSLock is unavailable from the async
    /// `handleNewMuxConnection` directly — same discipline as ``markStopping()``).
    private func retainMuxConnection(_ id: UUID, _ connection: MuxNWConnection) {
        lock.lock()
        muxConnections[id] = connection
        lock.unlock()
    }

    /// Looks up a retained accepted connection by id — the open handler resolves the connection HERE
    /// (the map's strong ref) instead of capturing it strongly, which would form a retain cycle.
    private func muxConnection(for id: UUID) -> MuxNWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return muxConnections[id]
    }

    /// Removes a connection from the retention map and closes it (cancels its 2 receive loops + 2
    /// NWConnections, nils its handlers to break the retain cycle). Reached when the physical link drops
    /// (the `setLinkDownHandler` reap). Idempotent: a second call after the map entry is gone is a no-op.
    private func removeMuxConnection(_ id: UUID) {
        lock.lock()
        let conn = muxConnections.removeValue(forKey: id)
        // A workspace subscriber lives and dies with its link: presence is connection-scoped, so the
        // connection going away IS the expiry. Dropping it here also fans the departure to everyone
        // else, because a roster that merely stops arriving is indistinguishable from a stalled host.
        let workspace = workspaceChannels.removeValue(forKey: id)
        lock.unlock()
        if let workspace {
            let document = workspaceDocument
            Task { await document.removeSubscriber(id: workspace.id) }
        }
        if let conn { Task { await conn.close() } }
    }

    /// Snapshots the count of distinct client *connections* carrying channels (one shared mux
    /// connection per client, matching ``liveSessionIDs()``) under the lock, then fires the
    /// optional `onConnectionCountChanged` hook outside the lock. No-op when the hook is unset
    /// (the headless daemon path) — but the cheap lock/count is skipped entirely in that case.
    private func emitConnectionCount() {
        guard let hook = onConnectionCountChanged else { return }
        lock.lock()
        let count = Set(muxSessions.keys.map(\.connectionID)).count
        lock.unlock()
        hook(count)
    }

    /// Recovers a claimed session whose `rebindRelay` refused — the failed-rebind path in
    /// ``performReattach``: unregisters `key` from the live map iff it still points at
    /// `session` (registration itself happens inside ``spawnMuxChannel``'s claim critical
    /// section), then re-parks or reaps the session. NSLock is unavailable from the async
    /// ``performReattach`` directly — same discipline as ``markStopping()`` / ``drainMuxSessions()``.
    ///
    /// Recovery contract: the claim already removed the session from the store, so merely
    /// unregistering the map key would strand a live shell + running agent in NO map and NO store
    /// — unreachable by `stop()`, TTL, `killPaneForControl`, and every future reconnect, forever
    /// (PTY + master fd + read-loop/reaper threads leaked per wifi flap, and the replacement fresh
    /// shell double-writing the same sessionID journal). One `lock` snapshot decides — atomic
    /// w.r.t. `spawnMuxChannel`'s claim critical section, so no reconnect can claim mid-decision:
    /// - attached under another key → a later reconnect owns it; leave it alone.
    /// - already back in the store → `handleLinkDown` won the race and re-parked it; done.
    /// - child exited → reap it (nothing left to park).
    /// - otherwise → re-park it (tmux semantics: the running agent survives, claimable again).
    private func recoverFailedRebind(session: MuxChannelSession, key: MuxSessionKey) {
        lock.lock()
        if muxSessions[key] === session { muxSessions[key] = nil }
        let attachedElsewhere = muxSessions.contains { $0.value === session }
        let parked = detachedStore?.contains(session.sessionID) ?? false
        lock.unlock()
        if attachedElsewhere || parked { return }
        if session.isChildExited() {
            // Mirror `removeMuxSession`'s dead-child discipline: fan a final `.none` for the
            // prevent-sleep strict balance, then the non-blocking reap (idempotent). This is a
            // non-deliberate end of life reached OUTSIDE `removeMuxSession`, so release the
            // journal writer (file kept — a reconnect may still cold-restore) + hook-sink key.
            fanAgentTeardown(session)
            session.shutdownDetached()
            scrollbackJournals?.release(sessionID: session.sessionID, instance: session.scrollbackJournal)
            unregisterHookSink(session: session)
            return
        }
        // Re-park. Idempotent end-to-end even if `handleLinkDown` lands between the snapshot
        // above and here: `detach()` no-ops past its exit-handler refresh on an already-detached
        // session, and `DetachedSessionStore.insert` keeps an existing entry for the same session.
        detachMuxSession(key: key, session: session)
    }

    /// Every DISTINCT session in `values`, first-seen order stabilised by object identity.
    ///
    /// `muxSessions` is keyed per CHANNEL, and a fanned-out pane is one session under N keys. Every
    /// reader that means "the panes" rather than "the attachments" has to collapse that, or the
    /// same PTY is shut down N times, teardown-fanned N times against a strictly-balanced
    /// prevent-sleep counter, and listed N times to an orchestrator.
    private static func distinct(
        _ values: some Sequence<MuxChannelSession>,
    ) -> [MuxChannelSession] {
        var seen = Set<ObjectIdentifier>()
        var result: [MuxChannelSession] = []
        for session in values where seen.insert(ObjectIdentifier(session)).inserted {
            result.append(session)
        }
        return result
    }

    /// Snapshot of the live connection ids carrying channels (diagnostics / tests).
    public func liveSessionIDs() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Set(muxSessions.keys.map(\.connectionID)))
    }

    // MARK: New mux connection / channel

    /// Installs the per-channel-open handler on a freshly-accepted shared mux connection. Every
    /// `channelOpen` the client sends on this connection mints a PTY + per-channel relay and acks.
    ///
    /// Both handlers CAPTURE this connection's stable `connectionID`, so `spawnMuxChannel` /
    /// `removeMuxSession` only ever touch the OWNING connection's sessions in the composite-keyed
    /// `muxSessions` map. Without the capture, a `channelID`-only key let one connection's
    /// close-hook resolve (and shut) a DIFFERENT connection's live session, because every
    /// connection allocates `channelID` 1 for its first pane.
    private func handleNewMuxConnection(_ connection: MuxNWConnection) async {
        let connectionID = connection.connectionID
        // Tell MuxNWConnection whether a whole-link DROP should route to detach (skip the
        // per-channel hostCloseHandler kill loop and fire linkDownHandler for BOTH clean FIN and
        // hard error). When detach is disabled the connection keeps exact no-detach behaviour.
        await connection.setDetachShellsOnLinkDrop(detachEnabled)
        // RETAIN the connection so stop()/link-drop can close it (frees its 2 receive loops + 2
        // NWConnections). This map is also the strong ref the open handler resolves the connection from.
        retainMuxConnection(connectionID, connection)
        await connection.setHostOpenHandler { [weak self] open in
            // Hop the blocking PTY spawn OFF the mux actor's receive loop. `spawnMuxChannel` runs a
            // synchronous `openpty()` + `fork()` (+ reaper-thread spawn) that would otherwise stall the
            // receive loop — and thus input echo / resize / output for EVERY OTHER pane riding this
            // shared connection — for the spawn's duration. The channel's sub-channels are already
            // registered on `connection`, so any inbound frame arriving during the spawn is buffered on
            // them and nothing is lost; `sendOpenAck` already completes asynchronously.
            //
            // Resolve the connection from the retention map by id rather than CAPTURING it strongly — a
            // strong capture forms a connection → hostOpenHandler → connection retain cycle.
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self, let conn = muxConnection(for: connectionID) else { return }
                spawnMuxChannel(open, on: conn, connectionID: connectionID)
            }
        }
        // A clean peer `channelClose` means THIS client is done with the pane — a refcounted LEAVE.
        // With one subscriber that is today's hard kill, unchanged; with two it must not reap the
        // other client's running agent. The UNCONDITIONAL reap belongs to the document instead:
        // `closePane` / `closeTab` are topology deletes and are applied HOST-side, so a close is
        // driven by the layout rather than by whichever client's socket closed first.
        // A link DROP (peer crash / TCP reset) still triggers detach: the client MAY reconnect.
        await connection.setHostCloseHandler { [weak self] channelID in
            self?.leavePaneChannel(MuxSessionKey(connectionID: connectionID, channelID: channelID))
        }
        // When the whole physical link drops (peer crash / TCP reset), detach every live
        // session on this connection (if detach is enabled) so their shells survive for the client
        // to reconnect to, then reap the connection itself (frees sockets + receive tasks).
        await connection.setLinkDownHandler { [weak self] in
            self?.handleLinkDown(connectionID: connectionID)
        }
        onLog?("mux connection \(connectionID) accepted (shared)")
    }

    /// Handles an incoming `channelOpen` with three-path routing.
    ///
    /// - **PATH A — reattach**: the store holds a live detached session for `open.sessionID`
    ///   and the child is still alive. Rebind the relay to the new sub-channels, replay the
    ///   ReplayBuffer tail, rewire `onExit`, remove from the store, and ack accepted.
    /// - **PATH B — new shell**: no detached session found (first connect, or detach disabled).
    ///   Spawn a fresh shell exactly as before.
    /// - **PATH C — child-exited**: the store lookup auto-evicts a dead session; falls through
    ///   to PATH B (fresh shell). The client MUST reset its seq to 0 — the existing ack path
    ///   with `resumeFromSeq=0` (the `sendOpenAck` with `accepted: true` on a fresh shell)
    ///   signals this.
    private func spawnMuxChannel(_ open: MuxChannelOpen, on connection: MuxNWConnection, connectionID: UUID) {
        // FIRST line, and deliberately BEFORE the pane-routing critical section below: a workspace
        // channel carries no PTY, so it must never touch the JOIN / detached-claim reasoning that
        // keeps ONE shell per sessionID. Routing here leaves that invariant literally untouched
        // (docs/45 §5.1).
        if open.channelClass == MuxChannelClass.workspace.rawValue {
            openWorkspaceChannel(open, on: connection, connectionID: connectionID)
            return
        }
        // Anything this host does not route is DECLINED, never guessed at — and declined HERE, before
        // the exclusivity critical section, for the same reason the workspace route sits above it.
        // Falling through into the PTY spawn path instead would hand a peer one version ahead a login
        // shell it never asked for: a pty, a reaper thread and a scrollback journal addressed by
        // nobody.
        guard open.channelClass == MuxChannelClass.pane.rawValue else {
            onLog?(
                "mux channel \(open.channelID) (conn \(connectionID)): declined — "
                    + "channel class \(open.channelClass) is not served by this host",
            )
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        let key = MuxSessionKey(connectionID: connectionID, channelID: open.channelID)
        // (`hasRealSessionID` compares the ZERO sentinel `WireMessage.newSessionID` — a
        // first-connect preamble from a raw/old client. Our mux client replaces the sentinel
        // with a fresh real UUID before sending, so this is normally always true.)
        let hasRealSessionID = open.sessionID != WireMessage.newSessionID
        // ONE critical section decides the route: the composite-key idempotency guard, the stopping
        // gate, the "sessionID already attached elsewhere" refusal, and the exclusive detached-store
        // claim all happen under `lock` — paired with `detachMuxSession`'s synchronous insert, no two
        // channelOpens can ever route the same sessionID to two attachments. That double-attach alias
        // would let one client's later close kill the OTHER client's live PTY and delete its
        // scrollback journal.
        lock.lock()
        let isStopping = stopping
        // Idempotency guard (defense-in-depth with the `isNewChannel` gate in `MuxNWConnection.route`):
        // if a session already exists for this composite key, a duplicate/retransmitted `channelOpen`
        // must NOT spawn a SECOND PTY and overwrite the live session in `muxSessions` (orphaning the
        // first PTY + master fd + reaper thread). Re-ack idempotently and return.
        let alreadyLive = muxSessions[key] != nil
        // Same sessionID already LIVE under a DIFFERENT composite key (a second connection / window
        // presenting an id somebody is still holding): this is the JOIN, and it is what a host does
        // — a pane is shared, never handed over and never duplicated.
        //
        // The invariant the routing keeps is about the SHELL: exactly one `openpty()` + `fork()` per
        // sessionID, ever. `store.claim` only ever finds DETACHED sessions, so a live id that failed
        // to route here would fall through to `spawnFreshShell` and `claimJournal` would rotate the
        // live session's journal writer out — the incumbent's transcript stopping mid-session.
        let liveElsewhere: MuxChannelSession? = (!isStopping && !alreadyLive && hasRealSessionID)
            ? muxSessions.first { $0.key != key && $0.value.sessionID == open.sessionID }?.value
            : nil
        // PATH D — JOIN: take THAT session object (never a second one) and register this key against
        // it now, inside the same critical section, so a third concurrent open sees the pane as held
        // and routes here too. The subscriber itself is added OUTSIDE the lock — it composes a
        // snapshot and awaits sends.
        var joining: MuxChannelSession?
        var joiningSubscriber: MuxSubscriberID?
        if let live = liveElsewhere {
            joining = live
            joiningSubscriber = registerJoiningKeyLocked(live, key: key)
        }
        // PATH A claim: exclusively TAKE the detached session (removes the entry + cancels
        // its TTL task atomically — `claim` auto-evicts a child-exited entry and returns nil,
        // PATH C → falls to B). Registering the claimed session under its NEW key in this same
        // critical section makes the sessionID immediately visible as "attached" to every later
        // channelOpen — closing the two-concurrent-reattach and reattach-vs-TTL races.
        var claimed: MuxChannelSession?
        // A dead child reaped BY the claim (PATH C): the claim took over the entry, so the
        // reaped session's own detached-exit closure stands down (`remove` returns false) —
        // the per-id teardown it would have done is finished below, outside the lock.
        var reapedDeadChild: MuxChannelSession?
        // `joining == nil` rather than a lookup that happens to miss: a key that JOINED must never
        // also take the claim, because the `muxSessions[key] = session` below would overwrite the
        // registration `registerJoiningKeyLocked` just wrote — leaving the key naming the CLAIMED
        // session while `muxSubscriberIDs[key]` names a member of the JOINED one. A live session is
        // never simultaneously in the detached store, but that is a fact about the store; the
        // exclusion belongs here, where the two writes are.
        if !isStopping, !alreadyLive, joining == nil, hasRealSessionID, let store = detachedStore {
            switch store.claim(open.sessionID) {
            case let .claimed(session):
                claimed = session
                muxSessions[key] = session
            case let .reapedDeadChild(session):
                reapedDeadChild = session
            case .notFound:
                break
            }
        }
        lock.unlock()

        if let reapedDeadChild {
            // Prevent-sleep strict balance: the dead session may still carry a `.working`
            // status nobody will ever clear (its stale exit closure is gated off) — fan the
            // final `.none` here. Drop its hook-sink key BEFORE the fresh spawn below
            // re-registers the same sessionID (identity-guarded, so ordering is belt+braces).
            // The journal writer is deliberately NOT released: the same-UUID fresh spawn
            // rotates it via `claimJournal`, keeping the transcript file continuous.
            fanAgentTeardown(reapedDeadChild)
            unregisterHookSink(session: reapedDeadChild)
        }

        if isStopping {
            // Shutting down — refuse the channel so we never fork a PTY that would outlive the daemon
            // (a channelOpen racing stop() after the session map was drained).
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        if alreadyLive {
            Task { await connection.sendOpenAck(open.channelID, accepted: true) }
            return
        }
        if let session = joining, let subscriber = joiningSubscriber {
            // PATH D: the pane is LIVE and somebody else is already watching it — join them.
            Task { [weak self] in
                await self?.performJoin(
                    session: session,
                    subscriber: subscriber,
                    open: open,
                    connection: connection,
                    connectionID: connectionID,
                )
            }
        } else if let session = claimed {
            // PATH A: live detached session claimed — reattach.
            Task { [weak self] in
                await self?.performReattach(
                    session: session,
                    open: open,
                    connection: connection,
                    connectionID: connectionID,
                )
            }
        } else {
            // PATH B/C: no detached session (or child exited), detach disabled, or zero UUID
            // (first connect) — spawn fresh.
            spawnFreshShell(open: open, connection: connection, connectionID: connectionID, key: key)
        }
    }

    /// PATH D: add a SECOND (third, …) client to a pane somebody is already watching.
    ///
    /// `performReattach`'s ordering, reproduced against a drain that is LIVE: ack FIRST (the client
    /// awaits it before rendering a byte), then the state transfer, which
    /// ``MuxChannelSession/joinSubscriber(data:control:channelClass:sizePassive:)`` composes
    /// NON-destructively and hands over atomically w.r.t. the drain. The per-JOIN re-asserts
    /// (echo / blocks / activity, `.title` after `.commandStatus`) are addressed to the new member
    /// only, so the incumbent is not flooded with the truths it already holds.
    ///
    /// The session was registered under `key` — with `subscriber` RESERVED for it — inside
    /// `spawnMuxChannel`'s critical section, so a failure here must UNREGISTER it: leaving the key
    /// behind would make a later close of this connection reap a pane it never joined.
    ///
    /// The reservation is what makes the whole async window below attributable. `joinSubscriber`
    /// composes an O(retained history) screen and then ships it through this client's credit
    /// window; a link drop anywhere in there must retire THIS member, and a key that named no id
    /// would resolve to the pane's primary and retire the INCUMBENT instead.
    private func performJoin(
        session: MuxChannelSession,
        subscriber: MuxSubscriberID,
        open: MuxChannelOpen,
        connection: MuxNWConnection,
        connectionID: UUID,
    ) async {
        let key = MuxSessionKey(connectionID: connectionID, channelID: open.channelID)
        // Ack BEFORE the replay, exactly as the reattach does: the resume verdict rides the DATA
        // link FIFO-ahead of the state transfer, so the awaiting client learns the session resumed
        // before the first byte. A joiner is always current from here on, hence `resumeFromSeq` of
        // its own `lastReceivedSeq`.
        await connection.sendOpenAck(open.channelID, accepted: true, resumeFromSeq: open.lastReceivedSeq)
        let joined = await session.joinSubscriber(
            id: subscriber,
            data: open.data,
            control: open.control,
            sizePassive: sizePassiveForConnection(connectionID),
        )
        guard let subscriberID = joined else {
            // The pane emptied or the joining link died while we were composing. Unregister and
            // refuse; the client reconnects and takes whichever path is true then. The reserved id
            // may have been registered as a size contributor by a workspace `subscribe` that landed
            // mid-join, so it goes too — a phantom contributor would sit in the roster forever.
            unregisterJoinKey(key, ifStill: session)
            session.removeResizeContributor(subscriber)
            onLog?(
                "mux channel \(open.channelID) (conn \(connectionID)): refused — "
                    + "session \(open.sessionID) was not joinable (link died mid-join or pane emptied)",
            )
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        emitConnectionCount()
        noteWorkspaceFactChanged()
        onLog?(
            "mux channel \(open.channelID) (conn \(connectionID)): joined live session \(open.sessionID) "
                + "as subscriber \(subscriberID)",
        )
    }

    /// Registers a JOINING key against the session it is about to join AND reserves the member id
    /// that join will use — both under the caller's `lock`, so the pair is installed atomically.
    ///
    /// Recording the id only after the async join returned left a window in which `muxSessions` knew
    /// the key but `muxSubscriberIDs` did not: every per-client path (`handleLinkDown`,
    /// `leavePaneChannel`, `channelKey(for:subscriber:)`) falls back to
    /// ``MuxChannelSession/primarySubscriberID`` for an unknown key, so a joiner whose link died
    /// mid-state-transfer retired the INCUMBENT — and, if that was the pane's only member, parked a
    /// session whose client was still connected.
    ///
    /// - Precondition: the caller holds `lock`.
    private func registerJoiningKeyLocked(
        _ session: MuxChannelSession,
        key: MuxSessionKey,
    ) -> MuxSubscriberID {
        let id = session.reserveSubscriberID()
        muxSessions[key] = session
        muxSubscriberIDs[key] = id
        return id
    }

    /// Drops a join registration that never completed, iff the key still names `session`.
    private func unregisterJoinKey(_ key: MuxSessionKey, ifStill session: MuxChannelSession) {
        lock.lock()
        if muxSessions[key] === session { muxSessions[key] = nil }
        muxSubscriberIDs[key] = nil
        lock.unlock()
    }

    /// PATH A: reattach a returning client to its detached ``MuxChannelSession``.
    ///
    /// The session was already CLAIMED (removed from the store, TTL cancelled) and registered
    /// under `key` in ``spawnMuxChannel``'s single critical section — this method only rebinds
    /// the relay and acks. If `stop()` raced in after the claim, `drainMuxSessions()` finds the
    /// session in the map and shuts it down like any other live session.
    private func performReattach(
        session: MuxChannelSession,
        open: MuxChannelOpen,
        connection: MuxNWConnection,
        connectionID: UUID,
    ) async {
        let key = MuxSessionKey(connectionID: connectionID, channelID: open.channelID)
        // The returning client may be a DIFFERENT device from the one that detached — a Mac's pane
        // picked up on a phone. Re-resolve the fold's predicate for the connection this session now
        // rides, before any of its resize frames can land.
        session.addResizeContributor(sizePassive: sizePassiveForConnection(connectionID))
        // Ack FIRST — synchronously, before the replay: the host-authoritative resume verdict
        // (`resumeFromSeq = lastReceivedSeq`, docs/20 §8.2) rides the DATA link FIFO-ahead of
        // the replayed `output` frames, so the awaiting client learns "same session resumed"
        // before the first byte. If the rebind below then fails, the `accepted: false` refusal
        // supersedes this ack (the router rejects the channel; the client reconnects) — the
        // same outcome a mid-replay link death always had.
        await connection.sendOpenAck(open.channelID, accepted: true, resumeFromSeq: open.lastReceivedSeq)
        // Replay the buffered tail to the NEW data sub-channel BEFORE rebinding so live output
        // does not interleave with the replay (the rebind starts the live drain). The client
        // sent `lastReceivedSeq` so we can skip already-received messages. A `true` return
        // means the replay was a RENDERED snapshot (state-transfer) — see the jiggle gate below.
        let replayStart = ContinuousClock.now
        let snapshotComposed = await session.replayTail(after: open.lastReceivedSeq, on: open.data)
        let replayElapsed = ContinuousClock.now - replayStart
        // Rebind the relay: swap sub-channels, clear stale queues, restart relay tasks.
        // onExit is threaded INTO rebindRelay so it is assigned under taskLock, atomically with
        // the exitTask (re)start — closing the race where a shell that exits between rebindRelay
        // returning and a post-call `session.onExit =` assignment would fire the stale
        // detached-exit handler. (The TTL timer was already cancelled by `claim`.)
        let rebound = session.rebindRelay(
            data: open.data,
            control: open.control,
            onExit: { [weak self] _ in self?.removeMuxSession(key) },
            // COLD client (fresh surface): the detached-window out-FIFO backlog is replay-
            // transformed before the drain restarts, mirroring the ring/tail transform the
            // replayTail above already applied. A warm client needs the raw backlog.
            transformDetachedBacklog: open.lastReceivedSeq == 0,
        )
        guard rebound else {
            // The new link can die MID-REPLAY: `finishLink` parks the sub-channels and
            // `handleLinkDown` re-parks the session while `replayTail` is still iterating, and
            // `rebindRelay` then refuses the finished channels (it also refuses a session that
            // is not detached — the double-attach loser). Refuse the channel AND recover the
            // claimed session: re-park it (or reap an exited child) so it is never stranded
            // outside both the live map and the store.
            recoverFailedRebind(session: session, key: key)
            onLog?(
                "mux channel \(open.channelID) (conn \(connectionID)): refused — "
                    + "session \(open.sessionID) was claimed but not rebindable "
                    + "(link died mid-reattach or not detached); session recovered",
            )
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        emitConnectionCount()
        // Refresh the hook sink under the session's ORIGINAL (env-baked) pane id — never
        // the new connection's key (see `refreshHookSinkOnReattach`).
        refreshHookSinkOnReattach(session: session)
        // The replay duration IS the "empty pane" window the user stares at — log it so a
        // slow reattach is diagnosable from the daemon log alone.
        let replayMillis = Int64(replayElapsed / .milliseconds(1))
        onLog?(
            "mux channel \(open.channelID) (conn \(connectionID)): reattached session \(open.sessionID) "
                + "(\(snapshotComposed ? "snapshot" : "raw") replay in \(replayMillis) ms)",
        )
        // Nudge the PTY foreground process to repaint after reattach — the client terminal is
        // fresh (no buffered output) so without this the pane is blank until the user presses
        // a key. A brief delay lets the client's first `.resize` land and wires the sub-channels
        // before the nudge fires, so zsh/bash redraw with the correct terminal dimensions.
        //
        // COLD client (fresh surface) on the TRANSFORM-COLLAPSED replay: a full-screen TUI's
        // live frame arrives incomplete — and a differential renderer (Claude Code) ignores a
        // same-size SIGWINCH for the rows it believes are already painted, leaving the
        // collapsed rows (input dividers, status line) blank forever. Only a REAL size change
        // forces the full re-layout: shrink one row, hold long enough for the app's event loop
        // to observe the intermediate size (too short and both SIGWINCHes coalesce into
        // "unchanged"), then restore. A RENDERED-snapshot replay needs none of this — every
        // row the app believes painted IS painted — so it takes the plain nudge, like a warm
        // client whose grid survived.
        let nudgePTY = session.pty
        let coldClient = open.lastReceivedSeq == 0
        Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            if coldClient, !snapshotComposed, let jiggle = nudgePTY.beginRedrawJiggle() {
                try? await Task.sleep(for: .milliseconds(200))
                nudgePTY.endRedrawJiggle(jiggle)
            } else {
                nudgePTY.nudgeRedraw()
            }
        }
    }

    /// PATH B/C: spawn a fresh shell (the no-detach path).
    private func spawnFreshShell(
        open: MuxChannelOpen,
        connection: MuxNWConnection,
        connectionID: UUID,
        key: MuxSessionKey,
    ) {
        // Disk scrollback (journal + restore) applies only to a REAL client-owned session ID —
        // the zero sentinel (a raw/old client) can never be re-presented, so journaling it would
        // only produce an orphan file.
        let hasResumableID = open.sessionID != WireMessage.newSessionID
        // `claimJournal` FIRST (exclusive fresh-spawn ownership): it registers the live writer —
        // exempting the file from a concurrently-running `sweep()` — and ROTATES OUT a ghost
        // instance a same-UUID predecessor may still hold (the detach-window race / claim-reaped
        // dead child), flushing its tail so the restore below reads the complete transcript.
        // Sharing the ghost's instance instead would interleave two writers into one file and
        // let the ghost's late teardown close the live session's journaling forever.
        let journal = hasResumableID ? scrollbackJournals?.claimJournal(for: open.sessionID) : nil
        // Restore gate: a fresh spawn for a RETURNING id whose client is COLD (`lastReceivedSeq
        // == 0` — a brand-new terminal surface). A WARM client (non-zero seq: transport dropped
        // but the app kept running) still holds its rendered grid; replaying the transcript there
        // would double-print it. The read (≤ ring cap) + distill run once per fresh spawn.
        let restored: ScrollbackJournalStore.RestoredScrollback? =
            (hasResumableID && open.lastReceivedSeq == 0)
                ? scrollbackJournals?.restoredScrollback(for: open.sessionID)
                : nil
        if let restored {
            onLog?(
                "mux channel \(open.channelID) (conn \(connectionID)): restored "
                    + "\(restored.bytes.count) journaled bytes "
                    + "(\(restored.snapshotComposed ? "snapshot" : "distilled") replay)",
            )
        }

        let pty = PTYProcess()
        // The per-session ZDOTDIR shim dir (if the zsh shim is installed) — captured so the session can
        // delete it when the child exits, instead of leaking one temp dir per pane forever.
        var shimDir: URL?
        // The directory the child ACTUALLY lands in, which is not the requested one: `resolveCwd`
        // repairs an absent/stale/unusable request to HOME. Captured so the By-Project seed below
        // describes the pane's real cwd rather than skipping a pane that requested nothing.
        var spawnCwd: String?
        do {
            let argv0 = HostEnvironment.loginArgv0(forShell: shellPath)
            switch launchMode {
            case .shell:
                // Layer the zsh shell-integration shim (a generated ZDOTDIR) so the
                // interactive shell reprints its prompt after a resize. Opt-out via
                // SLOPDESK_SHELL_INTEGRATION=0; non-zsh shells are left untouched. The shim sources
                // the user's real startup files, so their env / prompt is preserved.
                //
                // Resolve the effective TERM against the host's terminfo DB. The plain-shell
                // default is `xterm-ghostty`, but on a host that cannot resolve that entry we
                // auto-fall back to `xterm-256color` (#54700) so vim/htop/less/tmux/top don't
                // degrade. No explicit override exists on the plain-shell path.
                let term = resolveEffectiveTerm(requested: .ghostty, explicitOverride: false)
                // When the opt-in hook listener is bound, export its socket path + this
                // pane's id so an installed Claude hook can POST status events for this pane.
                let paneID = Self.paneID(connectionID: connectionID, channelID: open.channelID)
                var env = HostEnvironment.curated(
                    term: term.rawValue,
                    agentSocketPath: agentHookListener != nil ? agentHookSocketPath : nil,
                    paneID: agentHookListener != nil ? paneID : nil,
                    controlSocketPath: agentControlSocketPath.isEmpty ? nil : agentControlSocketPath,
                )
                // Resolve ONCE and let `PWD`, the spawn and the By-Project seed all quote the same
                // answer. `PWD` must name where the child lands, not what it asked for: a shell that
                // trusts an inherited `PWD` would print a prompt for a directory it is not in.
                spawnCwd = PTYProcess.resolveCwd(open.initialCwd, home: env["HOME"])
                if let spawnCwd { env["PWD"] = spawnCwd }
                if let overrides = ShellIntegration.makeEnvironmentOverrides(
                    parent: ProcessInfo.processInfo.environment,
                    shellPath: shellPath,
                    warn: { [weak self] in self?.onLog?($0) },
                ) {
                    for (k, value) in overrides { env[k] = value }
                    // The shim's ZDOTDIR override IS the generated `slopdesk-zdotdir-*` dir — track it so the
                    // session deletes it on the child's exit.
                    shimDir = overrides["ZDOTDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                }
                try pty.spawn(shellPath, environment: env, argv0: argv0, cwd: spawnCwd)
            }
        } catch {
            onLog?("mux channel \(open.channelID) (conn \(connectionID)): shell spawn failed: \(error)")
            // The ZDOTDIR shim dir is written BEFORE the spawn, so a spawn failure (e.g. EMFILE / fork
            // failure — conditions that can REPEAT) would leak it: no MuxChannelSession is created on
            // this path to delete it later. Clean it up here so the "no leaked shim dir per pane"
            // guarantee holds on the failure path too.
            if let shimDir { try? FileManager.default.removeItem(at: shimDir) }
            // Release the just-claimed journal writer (fd + map entry; file kept) — no session
            // was created to own it, and a dangling live writer is also sweep-exempt forever.
            if let journal { scrollbackJournals?.release(sessionID: open.sessionID, instance: journal) }
            // Refuse the channel so the client's router marks it dead and never routes data to it.
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }

        let session = MuxChannelSession(
            channelID: open.channelID,
            pty: pty,
            data: open.data,
            control: open.control,
            sessionID: open.sessionID,
            // Read from the connection's workspace channel, if it has subscribed yet; the subscribe
            // itself re-resolves this for panes that opened first.
            isSizePassive: sizePassiveForConnection(connectionID),
            shimDir: shimDir,
            agentDetectEnabled: agentDetectEnabled,
            // Verb 13 reports the LIVE hook-listener bind state. Probed at request time (weak — the
            // listener outlives sessions anyway) so a bind failure reads honest-false, never a stale
            // construction-time snapshot.
            agentHookListenerActive: { [weak listener = agentHookListener] in listener?.isListening ?? false },
            blocksEnabled: blocksEnabled,
            scrollbackJournal: journal,
            restoredScrollback: restored?.bytes,
            snapshotReplay: MuxChannelSession.makeSnapshotReplayPolicy(),
        )
        // The shell-exit reaper closes over the SAME composite key so it only removes THIS
        // connection's session (idempotent with the peer-close `setHostCloseHandler` path).
        session.onExit = { [weak self] _ in self?.removeMuxSession(key) }
        wireAgentStatusFanOut(session)
        wireRepoWatch(session)
        wireSubscriberEviction(session)
        lock.lock()
        if stopping {
            // stop() set `stopping` AFTER our early check but BEFORE this insert (it raced the fork).
            // Do NOT register past the drain — tear the just-spawned shell down (its reaper is already
            // running from `pty.spawn`, so `shutdown()` reaps it cleanly) and refuse the channel.
            lock.unlock()
            session.shutdown()
            // The stopping path never reaches an end-of-life that would release the claimed
            // writer — drop it here (file kept; the restart's restore reads it).
            if let journal { scrollbackJournals?.release(sessionID: open.sessionID, instance: journal) }
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        muxSessions[key] = session
        lock.unlock()
        emitConnectionCount()
        session.startRelay()
        // Seed the By-Project truths from the RESOLVED spawn cwd (server-side, pre-shell): the sidebar
        // sections are right from the first frame, including for shells that never emit
        // OSC-133/OSC-7 — the warm-up gate would otherwise hold the key hostage to a prompt edge
        // that may never come. After startRelay so the enqueued control rides the live sender.
        //
        // The RESOLVED cwd, not `open.initialCwd`: a pane that requested nothing (the `home`
        // working-directory policy, and the very first pane of a fresh workspace) still lands in a
        // real directory, and skipping its seed left it stranded outside every project section until
        // an OSC-7 edge that an unshimmed shell never sends.
        if let spawnCwd, !spawnCwd.isEmpty {
            session.seedProjectTruthAtSpawn(cwd: spawnCwd)
        }
        // Register this pane's hook sink so an installed Claude hook POSTing to the host
        // socket (with this pane's id) routes into THIS channel's per-pane status handler.
        registerHookSink(session: session, connectionID: connectionID, channelID: open.channelID)
        Task { await connection.sendOpenAck(open.channelID, accepted: true) }
        // The PANE is named as well as the pid: both GUI gates assert on how many of these lines one
        // auto-connect produces, and a second line is only diagnosable if it says which pane asked.
        onLog?(
            "mux channel \(open.channelID) (conn \(connectionID)): shell \(shellPath) "
                + "(pid \(pty.pid)) attached for pane \(open.sessionID)",
        )
    }

    /// Feeds this session's By-Project key edges into the ``RepoStatusWatcher`` refcounts (and
    /// releases them on the session's one-shot teardown signal — every end-of-life funnels through
    /// `MuxChannelSession.shutdown()`). Owner identity is the session OBJECT (a same-UUID ghost from
    /// the detach-window race must never release the repo its live successor holds). A no-op wiring
    /// when ``gitWatchEnabled`` is off — no callback, no stream, wire silence.
    private func wireRepoWatch(_ session: MuxChannelSession) {
        guard gitWatchEnabled else { return }
        let owner = ObjectIdentifier(session)
        session.onProjectKeyResolved = { [weak self] key in
            self?.repoWatcher.noteProjectKey(key, owner: owner)
            self?.noteWorkspaceFactChanged()
        }
        session.onTeardown = { [weak self] in
            self?.repoWatcher.dropOwner(owner)
        }
    }

    /// Registers the per-pane hook sink on the coordinator listener so a Claude hook POST
    /// carrying this pane's id routes into the session's `ingestAgentHookRecord`.
    ///
    /// FRESH-SPAWN ONLY — `(connectionID, channelID)` here is the identity `spawnFreshShell`
    /// also bakes into the child env as `SLOPDESK_PANE_ID`, which is immutable for the shell's
    /// life. The key is therefore recorded in ``hookPaneIDsBySession`` as the session's ONE
    /// routing key: reattach refreshes it (``refreshHookSinkOnReattach(session:)``), never
    /// re-keys, and every end of life unregisters it (``unregisterHookSink(sessionID:)``).
    private func registerHookSink(session: MuxChannelSession, connectionID: UUID, channelID: UInt32) {
        registerHookSink(session: session, paneID: Self.paneID(connectionID: connectionID, channelID: channelID))
    }

    /// Registers `paneID` as `session`'s ONE hook routing key. The mux path derives it from
    /// `(connectionID, channelID)`; a ctl-spawned pane has no channel pair and uses its session
    /// uuid. Both bake the SAME string into the child env as `SLOPDESK_PANE_ID`, so the key is
    /// immutable for the shell's life either way.
    private func registerHookSink(session: MuxChannelSession, paneID: String) {
        guard let agentHookListener else { return }
        lock.lock()
        hookPaneIDsBySession[session.sessionID] =
            HookSinkRegistration(paneID: paneID, owner: ObjectIdentifier(session))
        lock.unlock()
        agentHookListener.register(paneID: paneID) { [weak session] bytes in
            session?.ingestAgentHookRecord(bytes)
        }
    }

    /// Reattach edge: re-registers the session's ORIGINAL hook key (a harmless refresh of
    /// the sink closure — same session object). It must NOT register the new connection's
    /// composite key: the agent's hook POSTs carry the env-baked ORIGINAL pane id, so a
    /// per-reattach key could never route AND would leak one dead sink per detach/reattach cycle
    /// (one String key + closure per wifi flap, for the daemon's lifetime).
    private func refreshHookSinkOnReattach(session: MuxChannelSession) {
        guard let agentHookListener else { return }
        lock.lock()
        // A reattach continues the SAME session object, so ownership transfers with it —
        // re-point the entry's owner (the registration is keyed by the immutable env-baked
        // paneID either way; only the teardown identity-guard reads `owner`).
        let registration = hookPaneIDsBySession[session.sessionID].map {
            HookSinkRegistration(paneID: $0.paneID, owner: ObjectIdentifier(session))
        }
        if let registration { hookPaneIDsBySession[session.sessionID] = registration }
        lock.unlock()
        guard let registration else { return } // hooks were off at spawn — nothing routes to this pane
        agentHookListener.register(paneID: registration.paneID) { [weak session] bytes in
            session?.ingestAgentHookRecord(bytes)
        }
    }

    /// Teardown: drops the session's ORIGINAL hook key + its bookkeeping entry. Called from
    /// EVERY end of life — deliberate close (``removeMuxSession``), detached exit, TTL/overflow
    /// eviction (via ``DetachedSessionStore/onEvicted``), and the failed-rebind dead-child reap
    /// — but NEVER on a mere detach: hook records must keep folding into the detector while the
    /// session is parked, or a detached window's status goes stale. Idempotent.
    /// IDENTITY-GUARDED: removes the entry only while it is still OWNED by `session` — a stale
    /// teardown for a same-UUID ghost stands down instead of dropping the key its live
    /// successor re-registered (see ``HookSinkRegistration``).
    private func unregisterHookSink(session: MuxChannelSession) {
        lock.lock()
        let sessionID = session.sessionID
        let registration = hookPaneIDsBySession[sessionID]
        let owned = registration?.owner == ObjectIdentifier(session)
        if owned { hookPaneIDsBySession.removeValue(forKey: sessionID) }
        lock.unlock()
        if owned, let registration { agentHookListener?.unregister(paneID: registration.paneID) }
    }

    /// Resolves the effective `TERM` for a new PTY against the host's terminfo database, logging
    /// the auto-fallback exactly when it fires.
    ///
    /// Delegates to ``TerminfoResolver``. When the host cannot resolve `xterm-ghostty` and no explicit
    /// `.xterm256` override is in effect, the resolver returns `.xterm256` with `fellBack == true`; we
    /// then emit ONE diagnostic via ``onLog`` (host stderr, NOT the PTY byte stream, so it never
    /// pollutes what the client renders). Gated on `fellBack`: nothing is logged when ghostty resolves
    /// or `.xterm256` was the explicit request. (The plain-shell path always passes `.ghostty` with no
    /// override, so the fallback only fires on a host lacking the ghostty terminfo.)
    private func resolveEffectiveTerm(
        requested: ClaudeCodeProfile.Term,
        explicitOverride: Bool,
    ) -> ClaudeCodeProfile.Term {
        // Cache by (requested, explicitOverride): the host terminfo state is stable for the session,
        // so resolve (and possibly spawn infocmp) at most once per key, not on every channel-open.
        let key = "\(requested.rawValue)|\(explicitOverride)"
        lock.lock()
        if let cached = resolvedTermCache[key] { lock.unlock()
            return cached
        }
        lock.unlock()

        let result = TerminfoResolver.resolve(
            requested: requested,
            explicitOverride: explicitOverride,
        )

        // Store under lock; the FIRST writer logs the fallback (a concurrent first-open that already
        // cached wins and we return its value without a duplicate log).
        lock.lock()
        if let cached = resolvedTermCache[key] { lock.unlock()
            return cached
        }
        resolvedTermCache[key] = result.term
        lock.unlock()

        if result.fellBack {
            onLog?(
                "TERM: host cannot resolve '\(requested.rawValue)' terminfo entry; "
                    + "falling back to '\(result.term.rawValue)' (#54700) so TUI apps work",
            )
        }
        return result.term
    }

    /// Handles a physical link drop — either detaches all live sessions on this connection
    /// (when detach is enabled) so their shells survive, or shuts them down.
    /// Then removes the connection from the retention map.
    private func handleLinkDown(connectionID: UUID) {
        if detachEnabled {
            // Snapshot the live sessions belonging to this connection, remove them from the
            // live map (so a racing channelOpen won't see them as "alreadyLive"), then leave.
            lock.lock()
            let keysToDetach = muxSessions.keys.filter { $0.connectionID == connectionID }
            var sessionsToDetach: [(MuxSessionKey, MuxSubscriberID, MuxChannelSession)] = []
            for k in keysToDetach {
                if let s = muxSessions.removeValue(forKey: k) {
                    let subscriber = muxSubscriberIDs.removeValue(forKey: k)
                        ?? MuxChannelSession.primarySubscriberID
                    sessionsToDetach.append((k, subscriber, s))
                }
            }
            lock.unlock()
            if !sessionsToDetach.isEmpty { emitConnectionCount() }
            // Retire each of THIS connection's members, and park the session only when its LAST one
            // is gone. Detaching per key would let one client closing its lid engage the 64 MiB
            // offline gate — which pauses the PTY drain — while the other client is still watching:
            // its pane goes dead-quiet while the shell keeps producing, and the drain's wake
            // continuation is nil'd, so not even a later chunk could re-wake it.
            for (key, subscriber, session) in sessionsToDetach {
                guard session.removeSubscriber(subscriber) else { continue }
                detachMuxSession(key: key, session: session)
            }
            // `attached` → `detached` is a visible fact: the remaining clients render the pane as
            // running with nobody watching, rather than as still held by the client that just died.
            if !sessionsToDetach.isEmpty { noteWorkspaceFactChanged() }
        }
        // Always reap the connection itself (frees sockets + receive tasks + retain cycle).
        removeMuxConnection(connectionID)
    }

    /// A peer `channelClose` on a PANE channel: a refcounted LEAVE.
    ///
    /// The last member leaving reaps the pane exactly as a close always has (`removeMuxSession` —
    /// kill the shell, delete the journal). An earlier one just stops watching: reaping there would
    /// take down the other client's running agent, which is the orphan/over-reap pair docs/45 §8.6
    /// rules out. Idempotent — a key already gone is a no-op.
    private func leavePaneChannel(_ key: MuxSessionKey) {
        lock.lock()
        let session = muxSessions[key]
        let subscriber = muxSubscriberIDs[key] ?? MuxChannelSession.primarySubscriberID
        lock.unlock()
        guard let session else { return }
        guard session.removeSubscriber(subscriber) else {
            // Somebody else is still holding the pane: drop only THIS client's registration.
            lock.lock()
            if muxSessions[key] === session { muxSessions[key] = nil }
            muxSubscriberIDs[key] = nil
            lock.unlock()
            emitConnectionCount()
            noteWorkspaceFactChanged()
            onLog?("mux channel \(key.channelID) (conn \(key.connectionID)): left shared pane")
            return
        }
        removeMuxSession(key)
    }

    /// Reaps every live pane the topology stopped naming: one `channelClose` to EVERY subscriber
    /// holding it, then the unconditional PTY teardown.
    ///
    /// This is the UNCONDITIONAL half of the close story, and it is driven by the DOCUMENT rather
    /// than by a socket: `closePane` / `closeTab` are topology deletes applied host-side, so
    /// "this pane is gone" is a layout fact, while a `channelClose` is only ever one client leaving.
    /// ``removeMuxSession(_:)`` drops every key that aliases the session, so the loop is idempotent
    /// — the first reap of a fanned-out pane takes all of its channels with it.
    func reapPanesRemovedFromTopology(_ removed: Set<UUID>) {
        guard !removed.isEmpty else { return }
        lock.lock()
        let doomed = muxSessions.filter { removed.contains($0.value.sessionID) }.map(\.key)
        lock.unlock()
        guard !doomed.isEmpty else { return }
        for key in doomed {
            guard let connection = muxConnection(for: key.connectionID) else { continue }
            // `.retired` (the default): the pane is leaving the layout, so the session id this
            // channel names is about to stop existing. A client that re-opens it gets a SPAWN.
            Task { await connection.closeChannel(key.channelID) }
        }
        for key in doomed { removeMuxSession(key) }
    }

    /// Resolves the channel key one SUBSCRIBER of `session` rides. A key with no explicit entry is
    /// the pane's original channel (``MuxChannelSession/primarySubscriberID``).
    private func channelKey(
        for session: MuxChannelSession,
        subscriber id: MuxSubscriberID,
    ) -> MuxSessionKey? {
        lock.lock()
        defer { lock.unlock() }
        return muxSessions.first {
            $0.value === session
                && (muxSubscriberIDs[$0.key] ?? MuxChannelSession.primarySubscriberID) == id
        }?.key
    }

    /// Wires a session's diagnostic sink and its LAGGARD-EVICTION seam.
    ///
    /// A session holds no reference to the ``MuxNWConnection`` its members ride and
    /// `MuxSubChannel.finish()` is internal to the transport, so the only way to wake a member
    /// parked on an exhausted credit window is from out here: retire it (which cancels its sender —
    /// the park is cancellation-aware and throws) and then close its channel on the wire.
    private func wireSubscriberEviction(_ session: MuxChannelSession) {
        session.onLog = { [weak self] line in self?.onLog?(line) }
        session.onEvictSubscriber = { [weak self, weak session] id in
            guard let self, let session,
                  let key = channelKey(for: session, subscriber: id) else { return }
            leavePaneChannel(key)
            guard let connection = muxConnection(for: key.connectionID) else { return }
            // `.subscriberEvicted`, and this is the ONE place the difference from the document's
            // reap survives: the pane, its shell and its other members are all still here, so the
            // evicted client is looking at something it may reattach to. The close frame is the only
            // thing it will ever be told — nothing removes the pane from its topology — so the
            // reason has to ride it.
            Task { await connection.closeChannel(key.channelID, reason: .subscriberEvicted) }
        }
    }

    /// Detaches `session` from its current transport and inserts it into the detached store.
    ///
    /// Called from ``handleLinkDown`` when the physical link drops. Unlike ``removeMuxSession``
    /// (which kills the shell), this keeps the shell alive so a returning client can reattach.
    ///
    /// The `onDetachedExit` closure wired into `detach()` removes the session from the store +
    /// calls `shutdownDetached()` if the shell exits while parked — so there is no zombie entry.
    private func detachMuxSession(key: MuxSessionKey, session: MuxChannelSession) {
        guard let store = detachedStore else {
            // Detach not available — fall back to hard shutdown.
            session.shutdownDetached()
            return
        }
        let sessionID = session.sessionID
        let ttl = detachTTL
        session.detach { [weak self, weak store, weak session] id in
            // Shell exited while in the store — remove the entry (TTL cancelled) and
            // close the master fd. The shell is already dead, so no kill needed.
            //
            // OWNERSHIP GATE: proceed only when THIS call removed the entry. `false` means
            // `claim()`/`evict()`/`drainAll()` already took it and owns the teardown — this
            // closure is then a STALE straggler (the exit task can fire seconds late, e.g. a
            // claim-reaped dead child unblocking `awaitExitSentOrTimeout`), and running the
            // per-id teardown anyway would release the journal writer + hook-sink key a
            // same-UUID successor session is already using. The fd close below stays (it acts
            // on THIS session object only, idempotent).
            let owned = store?.remove(id) ?? false
            guard owned else {
                session?.shutdownDetached()
                return
            }
            // Prevent-sleep strict balance: a parked shell that exits mid-turn never
            // delivered a non-working transition — fan a final `.none` so a `.working` observer clears it.
            if let session { self?.fanAgentTeardown(session) }
            // shutdownDetached is safe on an already-dead shell (idempotent fd close).
            session?.shutdownDetached()
            // Non-deliberate end of life (never reaches `removeMuxSession`): RELEASE the disk
            // journal — flush + close the fd, drop the map entry, KEEP the file (the restore
            // source for a returning cold client) — and drop the hook-sink key. Without these,
            // every parked death leaked one fd + one sink for the daemon's lifetime.
            if let session {
                self?.scrollbackJournals?.release(sessionID: id, instance: session.scrollbackJournal)
                self?.unregisterHookSink(session: session)
            }
            self?.onLog?("detached session \(id): shell exited while parked")
        }
        // SYNCHRONOUS insert: a fire-and-forget `Task { await store.insert }` could lose to a fast
        // reconnect, whose claim would then miss the store and spawn a SECOND shell under the same
        // sessionID (orphaned live PTY + two writers interleaving the one sessionID-keyed journal).
        // By the time this method returns, the session is claimable.
        store.insert(session, key: key, ttl: ttl)
        onLog?("mux channel \(key.channelID) (conn \(key.connectionID)): detached session \(sessionID)")
    }

    /// Removes a live session (clean close by the peer, or child self-exit). Kills the shell.
    /// Idempotent: if the key is not in the map, this is a no-op.
    private func removeMuxSession(_ key: MuxSessionKey) {
        lock.lock()
        let session = muxSessions.removeValue(forKey: key)
        muxSubscriberIDs[key] = nil
        // A reap takes EVERY key that names this session, not just the one that asked. Under a
        // fan-out N keys alias one session object, and leaving N−1 behind would keep a dead pane
        // reported by `listPanesForControl`, re-shut by `stop()`, and read as still-attached by
        // `recoverFailedRebind`'s live-map scan.
        if let session {
            for alias in muxSessions.filter({ $0.value === session }).map(\.key) {
                muxSessions[alias] = nil
                muxSubscriberIDs[alias] = nil
            }
        }
        let isStopping = stopping
        lock.unlock()
        // A pane that just went away is the one case where a client MUST hear promptly: the row is
        // still on screen. `reconcileWorkspaceDocument` reaps by "not captured", so this kick is
        // what turns a close into a delete rather than waiting out a tick.
        if session != nil { noteWorkspaceFactChanged() }
        // Disk-journal policy: a pane that ends DELIBERATELY (peer `channelClose` / attached
        // child exit — exactly this method's callers) takes its transcript with it. Link-drop
        // detach, TTL eviction, and daemon stop never come through here, and the `stopping`
        // guard keeps a child-exit RACING `stop()` from wiping a journal the restart is
        // supposed to restore.
        if let session, !isStopping {
            scrollbackJournals?.delete(sessionID: session.sessionID, instance: session.scrollbackJournal)
        }
        // Drop this pane's hook sink so a late hook POST for a closed pane is dropped.
        // Keyed by the session's ORIGINAL pane id (not this close's composite key — after a
        // reattach cycle they differ, and unregistering the current key leaked the original).
        if let session { unregisterHookSink(session: session) }
        // Only re-count when a session was actually removed (the path is idempotent with the
        // peer-close / child-exit race, so a second remove of the same key is a no-op and must
        // not re-emit an unchanged count).
        if session != nil { emitConnectionCount() }
        // Prevent-sleep strict balance: a pane closed WHILE its agent is working never
        // delivers a non-working transition on its own — fan a final `.none` so observers clear it.
        // Guarded by the map-removal idempotency above (a second remove sees `nil` → no double-fan).
        if let session { fanAgentTeardown(session) }
        // shutdownDetached() (NOT shutdown()): this method is reached SYNCHRONOUSLY from the mux
        // connection's receive loop for a peer `channelClose` / link drop (route/finishLink →
        // hostCloseHandler → here). `shutdown()` blocks the caller up to ~0.5s (SIGTERM → wait →
        // SIGKILL → wait → close; the full ~250ms escalation for an interactive shell that ignores
        // SIGTERM), which would stall every OTHER pane riding the same shared connection and park a
        // cooperative-pool thread. The map removal above is the cross-shut/double-shut guard, so the
        // blocking PTY kill + fd close run off the receive loop. (The `onExit` reaper path also lands
        // here with an already-dead child, where the detached shutdown is near-instant anyway.)
        session?.shutdownDetached()
    }

    // MARK: - Agent-control surface (used by AgentControlListener)

    /// Struct returned by ``listPanesForControl()``.
    public struct PaneInfo: Sendable {
        public let paneId: String // sessionID.uuidString
        public let title: String // last sniffed OSC title (empty if none)
        public let pid: Int32 // child PID (-1 if exited)
        public let isAlive: Bool // child still running
        /// Supervision state — the per-pane Claude agent state mapped to the ctl wire
        /// vocabulary (`idle`/`working`/`done`/`blocked`). A live pane with no detected
        /// `claude` reports `idle` (see ``AgentControlState``).
        public let state: String
        /// The detector's human label (the blocking question / last assistant line), `nil` when none.
        public let stateMessage: String?
        /// Host-observed cwd truth (OSC-7 sniff / prompt-edge probe), `nil` until observed.
        public let cwd: String?
        /// The pane's live foreground-process BASENAME (`zsh`/`claude`/`vim`), "" when unresolvable.
        public let command: String
        /// The freshest OSC-133-D exit code, `nil` until a command finished with a reported `$?`.
        public let lastExitCode: Int32?
        /// PTY grid size, 0×0 on a closed/unspawned master.
        public let rows: Int
        public let cols: Int
    }

    /// Returns a snapshot of all live panes (mux + standalone control panes + DETACHED panes).
    /// Called from the agent-control `list-panes` verb handler. O(N) over active panes
    /// (each pane costs one `TIOCGWINSZ` + one `proc_pidinfo` foreground probe — the same
    /// syscall class the input path already pays per keystroke batch).
    ///
    /// Detached sessions are included because they are LIVE — the shell keeps running with no
    /// client attached (`DetachedSessionStore`, tmux semantics). Omitting them made a pane that
    /// survived a client quit invisible to the one "describe all panes" API the product has, which
    /// is precisely the pane an orchestrator reattaching to a machine wants to find. The three
    /// sources are disjoint: `detachMuxSession` removes from `muxSessions` before inserting into
    /// the store, and `claim` removes before the reattach re-registers.
    public func listPanesForControl() -> [PaneInfo] {
        lock.lock()
        // DEDUPED: one PaneInfo per pane, not one per attached client.
        let mux = Self.distinct(muxSessions.values)
        let ctrl = Array(controlSessions.values)
        lock.unlock()
        // Outside `lock`: the store takes its OWN lock, and the nesting contract is one-way
        // (HostServer.lock → DetachedSessionStore.lock is allowed, never the reverse). `nil` when
        // `SLOPDESK_DETACH_ENABLED=0` — no store, nothing detached, nothing to add.
        let detached = detachedStore?.allSessions() ?? []
        return (mux + ctrl + detached).map { session in
            let agent = session.agentStatusAndMessageForControl
            let size = session.pty.currentWindowSize()
            return PaneInfo(
                paneId: session.sessionID.uuidString,
                title: session.currentTitle,
                pid: session.pty.pid,
                isAlive: !session.isChildExited(),
                state: AgentControlState.string(from: agent.status),
                stateMessage: agent.message,
                cwd: session.cwdForControl,
                command: PTYForegroundProbe.foregroundName(masterFD: session.pty.masterFD),
                lastExitCode: session.lastExitCodeForControl,
                rows: Int(size?.rows ?? 0),
                cols: Int(size?.cols ?? 0),
            )
        }
    }

    // MARK: - Cross-pane agent-status fan-out

    /// Registers a cross-pane `agent_status_changed` observer and returns its dedupe key. Called
    /// by the top-level (no-paneId) `subscribe` handler. The observer is invoked with
    /// `(paneId, state, agentPresent, title, ts)` on EVERY pane's status transition until
    /// ``removeAgentStatusObserver(id:)``. `agentPresent` is the bit the four-state supervision
    /// vocabulary cannot carry — see ``AgentControlState``.
    func registerAgentStatusObserver(
        id: UUID,
        _ observer: @escaping @Sendable (
            _ paneId: String, _ state: String, _ agentPresent: Bool, _ title: String, _ ts: Double,
        ) -> Void,
    ) {
        agentStatusObserversLock.lock()
        agentStatusObservers[id] = observer
        agentStatusObserversLock.unlock()
    }

    /// Removes a cross-pane observer (idempotent — a missing id is a no-op).
    func removeAgentStatusObserver(id: UUID) {
        agentStatusObserversLock.lock()
        agentStatusObservers[id] = nil
        agentStatusObserversLock.unlock()
    }

    /// Registers a PROCESS-LIFETIME observer of cross-pane agent-status transitions, the public
    /// seam `slopdesk-hostd` uses to drive the prevent-sleep `IOPMAssertion` off the `.working` aggregate.
    /// Reuses the existing fan-out (``registerAgentStatusObserver(id:_:)``); the observer receives
    /// `(paneId, state)` where `state` is the stable ctl supervision string (``AgentControlState`` — `"working"`
    /// while a turn runs). No deregistration is exposed: the daemon holds it for its whole lifetime.
    @preconcurrency
    public func observeAgentStatusForPreventSleep(
        _ observer: @escaping @Sendable (_ paneId: String, _ state: String) -> Void,
    ) {
        registerAgentStatusObserver(id: UUID()) { paneId, state, _, _, _ in observer(paneId, state) }
    }

    /// Fans one pane's status transition to every registered cross-pane observer. Snapshots the
    /// observer map under its lock, then calls each observer OUTSIDE the lock (an observer's NDJSON
    /// write must never serialise the next pane's transition). Maps the host ``ClaudeStatus`` to the
    /// ctl wire string here (the observers receive the stable supervision vocabulary, not the enum).
    func fanAgentStatusChanged(paneId: String, title: String, status: ClaudeStatus) {
        agentStatusObserversLock.lock()
        let observers = Array(agentStatusObservers.values)
        agentStatusObserversLock.unlock()
        guard !observers.isEmpty else { return }
        let state = AgentControlState.string(from: status)
        let present = AgentControlState.presence(from: status)
        let ts = Date().timeIntervalSince1970
        for observer in observers { observer(paneId, state, present, title, ts) }
    }

    /// Kicks a workspace reconcile from a fact-changing event, so the steady-state latency is one
    /// hop rather than half a reconciler period. Cheap and idempotent — an unchanged capture bumps
    /// nothing and sends nothing.
    func noteWorkspaceFactChanged() {
        kickWorkspaceReconcile()
    }

    /// Wires a freshly-created session's `onAgentStatusChanged` to the server fan-out. Called from
    /// EVERY session-creation site (mux + control spawn) so a transition on any pane reaches the
    /// top-level subscribers. `[weak self]` avoids retaining the server through the session.
    private func wireAgentStatusFanOut(_ session: MuxChannelSession) {
        let paneId = session.sessionID.uuidString
        session.onAgentStatusChanged = { [weak self, weak session] status in
            let title = session?.currentTitle ?? ""
            self?.fanAgentStatusChanged(paneId: paneId, title: title, status: status)
            // Kick HERE, not inside `fanAgentStatusChanged` — that funnel returns early when no ctl
            // observer is registered, which is the ordinary case, so a kick placed there would fire
            // only when an orchestrator happened to be watching.
            self?.noteWorkspaceFactChanged()
        }
    }

    /// Prevent-sleep STRICT BALANCE: fans a FINAL `.none` agent status for a pane torn down
    /// WHILE it still carries a non-`.none` status. A pane normally delivers its own `working → done/idle`
    /// transition (detector poll / hook), but one CLOSED mid-turn — tab close (`removeMuxSession`), child
    /// exit (`removeMuxSession`/`removeControlSession`), link drop, or ctl `kill` (`killPaneForControl`) —
    /// never does. Without this fan, a `.working`-tracking observer (the `slopdesk-hostd` prevent-sleep
    /// driver) keeps that dead paneId forever, `anyAgentWorking` stays true, and the `IOPMAssertion` is
    /// held for the daemon's whole lifetime — a leaked assertion keeping the Mac awake forever. Reuses the
    /// fan-out so EVERY observer (prevent-sleep + cross-pane subscribers) clears the pane uniformly.
    /// Gated on a non-`.none` prior status so a plain shell with no agent never emits a spurious teardown.
    private func fanAgentTeardown(_ session: MuxChannelSession) {
        guard session.agentStatusForControl != .none else { return }
        fanAgentStatusChanged(
            paneId: session.sessionID.uuidString,
            title: session.currentTitle,
            status: .none,
        )
    }

    /// Looks up a pane by its `sessionID.uuidString` across both live and control maps.
    /// Returns `nil` when no matching pane exists (caller emits an error response).
    /// Internal: `AgentControlListener` lives in the same module.
    func lookupPaneForControl(paneId: String) -> MuxChannelSession? {
        lock.lock()
        defer { lock.unlock() }
        // Search muxSessions first (the common case), then controlSessions.
        for session in muxSessions.values where session.sessionID.uuidString == paneId {
            return session
        }
        for session in controlSessions.values where session.sessionID.uuidString == paneId {
            return session
        }
        return nil
    }

    /// Kills the pane identified by `paneId` and removes it from the live maps.
    /// Returns `true` if a pane was found and killed, `false` if not found.
    @discardableResult
    public func killPaneForControl(paneId: String) -> Bool {
        lock.lock()
        // Check muxSessions. EVERY key naming the pane goes, not just the first match: under a
        // fan-out N keys alias one session, and a survivor keeps the killed pane in
        // `listPanesForControl`, re-shut by `stop()`, and read as attached by `recoverFailedRebind`.
        if let session = muxSessions.values.first(where: { $0.sessionID.uuidString == paneId }) {
            for key in muxSessions.filter({ $0.value === session }).map(\.key) {
                muxSessions[key] = nil
                muxSubscriberIDs[key] = nil
            }
            lock.unlock()
            // Prevent-sleep strict balance: clear a working pane killed mid-turn by ctl.
            fanAgentTeardown(session)
            session.shutdownDetached()
            return true
        }
        // Check controlSessions.
        for (id, session) in controlSessions where id.uuidString == paneId {
            controlSessions.removeValue(forKey: id)
            lock.unlock()
            // The exit callback will not find this session in the map any more, so its hook key is
            // retired here (identity-guarded + idempotent) rather than leaking one sink per kill.
            unregisterHookSink(session: session)
            // Prevent-sleep strict balance: clear a working pane killed mid-turn by ctl.
            fanAgentTeardown(session)
            session.shutdownDetached()
            return true
        }
        lock.unlock()
        return false
    }

    /// Spawns a standalone PTY pane (no client connection) and registers it in `controlSessions`.
    ///
    /// The pane's output goes into its `ReplayBuffer` (read via the `read` verb) and fires
    /// output observers (used by the `wait` verb). The `data`/`control` sub-channels are null
    /// stubs (infinite window, no-op sends, immediately-finished inbound) so the relay's receive
    /// loops exit at once and `setClientOnline(false)` engages the 64 MiB offline gate — PTY
    /// output flows into the replay ring rather than trying to send on a non-existent connection.
    ///
    /// - Parameters:
    ///   - cmd: command + argv to run. `nil` → the user's login shell.
    ///   - cwd: working directory for the child. `nil` → inherited from hostd.
    ///   - env: extra environment variables merged on top of ``HostEnvironment/curated()``.
    ///   - rows/cols: initial PTY dimensions.
    /// - Returns: the new session's `sessionID.uuidString`.
    /// - Throws: if `PTYProcess.spawn` fails (e.g. `EMFILE`, executable not found).
    public func spawnStandalonePane(
        cmd: [String]?,
        cwd: String?,
        env extraEnv: [String: String]?,
        rows: UInt16,
        cols: UInt16,
    ) async throws -> String {
        guard !stopping else {
            throw ControlError.serverStopping
        }
        let pty = PTYProcess()
        let sessionID = UUID()

        // Build the environment. Thread the control socket path so a spawned agent can reach the
        // ctl socket (curated sets SLOPDESK_CONTROL_SOCKET when non-empty), and — exactly like the
        // mux path — the HOOK socket + this pane's id, so an installed Claude hook can POST its
        // status here. Without them a ctl-spawned pane was the one place an agent ran completely
        // unobserved: no hook route in, and (below) no detector to fold anything into.
        var environ = HostEnvironment.curated(
            agentSocketPath: agentHookListener != nil ? agentHookSocketPath : nil,
            paneID: agentHookListener != nil ? sessionID.uuidString : nil,
            controlSocketPath: agentControlSocketPath.isEmpty ? nil : agentControlSocketPath,
        )
        // Interactive login-shell spawn (`cmd == nil`) layers the SAME shell-integration shim the
        // mux path does: the shim's OSC-133 marks are what feed the pane's block segmentation, and
        // a control pane without them answers `last-output` with nothing and never resolves a
        // `run --wait`. A `cmd` pane is `$SHELL -c …` (non-interactive, no prompt cycles) — the
        // shim is prompt machinery, so it is skipped there. Caller `env` still wins (merged after).
        var shimDir: URL?
        if cmd == nil || cmd?.isEmpty == true {
            if let overrides = ShellIntegration.makeEnvironmentOverrides(
                parent: ProcessInfo.processInfo.environment,
                shellPath: shellPath,
                warn: { [weak self] in self?.onLog?($0) },
            ) {
                for (k, value) in overrides { environ[k] = value }
                shimDir = overrides["ZDOTDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            }
        }
        if let extraEnv { for (k, v) in extraEnv { environ[k] = v } }
        // Inject the pane self-id (same contract as a mux-spawned pane).
        environ[HostEnvironment.agentPaneIDEnvKey] = sessionID.uuidString
        // Full self-orientation sentinel: an agent inside a spawned pane knows it is under
        // slopdesk control (SLOPDESK_CTL=1) and where the ctl binary is, with zero discovery.
        environ[HostEnvironment.ctlSentinelEnvKey] = "1"
        if !ctlBinaryPath.isEmpty { environ[HostEnvironment.ctlBinaryEnvKey] = ctlBinaryPath }
        // Inject the working directory via `PWD` if provided (the shell sources it).
        if let cwd { environ["PWD"] = cwd }

        // Build the executable path and argv.
        let executable: String
        let argv: [String]
        let argv0: String
        if let cmd, !cmd.isEmpty {
            executable = cmd[0]
            argv = Array(cmd.dropFirst())
            argv0 = URL(fileURLWithPath: cmd[0]).lastPathComponent
        } else {
            executable = shellPath
            argv = []
            argv0 = HostEnvironment.loginArgv0(forShell: shellPath)
        }

        // Spawn the child with the requested initial window size.
        do {
            try pty.spawn(
                executable,
                arguments: argv,
                environment: environ,
                argv0: argv0,
                cwd: cwd,
                cols: cols,
                rows: rows,
            )
        } catch {
            // The ZDOTDIR shim dir is written BEFORE the spawn (same as the mux path) — a spawn
            // failure would leak it since no session exists to delete it on exit.
            if let shimDir { try? FileManager.default.removeItem(at: shimDir) }
            throw error
        }

        // Build null sub-channels (no real connection).
        let nullData = await MuxSubChannel.makeNull(channel: .data)
        let nullControl = await MuxSubChannel.makeNull(channel: .control)

        // `channelID: 0` is the sentinel for control-spawned panes (protocol allocates from 1).
        let session = MuxChannelSession(
            channelID: 0,
            pty: pty,
            data: nullData,
            control: nullControl,
            sessionID: sessionID,
            shimDir: shimDir,
            // Agent detection follows the server flag, same as a mux pane. A ctl-spawned pane is
            // where an ORCHESTRATOR runs its agents, so it is the last place that should be blind
            // to them: without this the detector never polls, `list-panes` reports every such pane
            // idle forever, and the hook records routed above have nothing to fold into.
            agentDetectEnabled: agentDetectEnabled,
            agentHookListenerActive: { [weak listener = agentHookListener] in listener?.isListening ?? false },
            // Blocks tracking follows the server flag even with no GUI client: the ctl socket
            // itself consumes the segmentation (`last-output` reads the block ring, `run --wait`
            // resolves on block close) — a control-spawned pane without it answers every
            // block verb with "SLOPDESK_BLOCKS=0".
            blocksEnabled: blocksEnabled,
        )
        session.onExit = { [weak self] _ in self?.removeControlSession(sessionID) }
        wireAgentStatusFanOut(session)
        wireRepoWatch(session)

        // Synchronous helper: NSLock is unavailable from async context directly.
        guard insertControlSession(sessionID, session) else {
            session.shutdown()
            throw ControlError.serverStopping
        }
        // Route this pane's hook POSTs to it. The env above advertises `SLOPDESK_PANE_ID` as the
        // session uuid (a ctl pane's only identity — there is no `(connection, channel)` pair), so
        // the sink is keyed by exactly that string. Registered AFTER the insert succeeds: a refused
        // insert throws without any teardown path to retire the key.
        registerHookSink(session: session, paneID: sessionID.uuidString)

        session.startRelay()
        // Same spawn-cwd seed as the mux path: a ctl-spawned pane (often a raw command with no
        // shell integration at all) still gets a correct By-Project key for later reattach.
        if let cwd, !cwd.isEmpty { session.seedProjectTruthAtSpawn(cwd: cwd) }
        return sessionID.uuidString
    }

    /// Synchronously inserts a control session. Returns `false` if `stopping` is set
    /// (the session was NOT inserted and must be shut down by the caller).
    private func insertControlSession(_ id: UUID, _ session: MuxChannelSession) -> Bool {
        lock.lock()
        if stopping { lock.unlock()
            return false
        }
        controlSessions[id] = session
        lock.unlock()
        return true
    }

    /// Synchronously removes a control session (called from the exit callback).
    private func removeControlSession(_ id: UUID) {
        lock.lock()
        let session = controlSessions.removeValue(forKey: id)
        lock.unlock()
        // Retire the pane's hook routing key with the pane — the mux path does this from every end
        // of life, and a ctl pane must not leak one key + closure per spawn for the daemon's life.
        if let session { unregisterHookSink(session: session) }
        // Prevent-sleep strict balance: a standalone pane whose child exits mid-turn never
        // delivers a non-working transition — fan a final `.none` so a `.working` observer clears it.
        if let session { fanAgentTeardown(session) }
    }

    /// Errors thrown by the agent-control spawn path.
    public enum ControlError: Error, Sendable {
        case serverStopping
    }

    // MARK: - Test seams (reattach-orphan recovery)

    // These drive the REAL private detach/reattach state machine (`detachMuxSession`,
    // `handleLinkDown`, `recoverFailedRebind`, the store, and the live map) headlessly —
    // no NWListener, no connection, no spawned shell (hang-safety). `performReattach`
    // itself needs a live `MuxNWConnection` for its ack, so tests reproduce its exact step
    // sequence through these seams instead. Reached via `@testable import`; never used in
    // production.

    /// The detached-session store (testing only; `nil` when detach is disabled).
    var detachedStoreForTesting: DetachedSessionStore? { detachedStore }

    /// Registers `session` under `key` in the live map — the state `spawnMuxChannel`'s claim
    /// critical section leaves behind for `performReattach` (testing only).
    func registerMuxSessionForTesting(_ session: MuxChannelSession, key: MuxSessionKey) {
        lock.lock()
        muxSessions[key] = session
        lock.unlock()
    }

    /// The live-map entry for `key`, if any (testing only).
    func muxSessionForTesting(key: MuxSessionKey) -> MuxChannelSession? {
        lock.lock()
        defer { lock.unlock() }
        return muxSessions[key]
    }

    /// Registers `key` as an ADDITIONAL member of an already-live session — the state
    /// `performJoin` leaves behind (testing only). The fan-out's N-keys-one-session shape without
    /// a real second connection.
    ///
    /// The member is ENTERED, not just aliased: the refcounted teardowns read the subscriber set,
    /// so a key-only rig would put every one of them on
    /// ``MuxChannelSession/removeSubscriber(_:)``'s unknown-id branch and prove nothing about the
    /// count.
    @discardableResult
    func registerJoinedKeyForTesting(
        _ session: MuxChannelSession,
        key: MuxSessionKey,
    ) -> MuxSubscriberID {
        let id = session.enterBareSubscriberForTesting(
            data: MuxSubChannel(channelID: key.channelID, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: key.channelID, channel: .control) { _, _ in },
        )
        lock.lock()
        muxSessions[key] = session
        muxSubscriberIDs[key] = id
        lock.unlock()
        return id
    }

    /// Drives the REAL join REGISTRATION — the state `spawnMuxChannel`'s critical section leaves
    /// behind for `performJoin`, BEFORE the async state transfer has admitted anybody (testing
    /// only). The window in which a joiner's link can drop while its member does not yet exist.
    @discardableResult
    func registerJoiningKeyForTesting(
        _ session: MuxChannelSession,
        key: MuxSessionKey,
    ) -> MuxSubscriberID {
        lock.lock()
        defer { lock.unlock() }
        return registerJoiningKeyLocked(session, key: key)
    }

    /// How many live-map keys currently name a session (testing only) — the alias count a reap
    /// must take with it.
    var muxSessionKeyCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return muxSessions.count
    }

    /// Drives the REAL peer-`channelClose` route — a refcounted LEAVE (testing only).
    func leavePaneChannelForTesting(_ key: MuxSessionKey) {
        leavePaneChannel(key)
    }

    /// Drives the REAL document-driven reap — what an APPLIED `closePane` / `closeTab` runs
    /// (testing only).
    func reapPanesRemovedFromTopologyForTesting(_ removed: Set<UUID>) {
        reapPanesRemovedFromTopology(removed)
    }

    /// Installs the REAL laggard-eviction wiring on `session` against a retained `connection`, so a
    /// test can fire the seam `MuxChannelSession.evictLaggingSubscribers` fires and watch what
    /// reaches the far end (testing only). Reproducing the lag itself needs a real PTY and tens of
    /// megabytes — `scripts/soak-fanout-laggard.sh` — so this drives the closure directly.
    func armSubscriberEvictionForTesting(
        _ session: MuxChannelSession,
        on connection: MuxNWConnection,
        connectionID: UUID,
    ) {
        retainMuxConnection(connectionID, connection)
        wireSubscriberEviction(session)
    }

    /// Drives the REAL `detachMuxSession` — the handleLinkDown park path (testing only).
    func detachMuxSessionForTesting(key: MuxSessionKey, session: MuxChannelSession) {
        detachMuxSession(key: key, session: session)
    }

    /// Drives the REAL `handleLinkDown` — the whole-link-drop detach sweep (testing only).
    /// Drives the REAL `channelOpen` router (`spawnMuxChannel`) from a test.
    ///
    /// The seam exists so the `channelClass` routing can be exercised end-to-end over an in-memory
    /// mux, which is the only way to prove that a workspace open never reaches the PTY spawn path.
    /// Calling `openWorkspaceChannel` directly would test the handler while skipping the decision.
    func spawnMuxChannelForTesting(_ open: MuxChannelOpen, on connection: MuxNWConnection, connectionID: UUID) {
        spawnMuxChannel(open, on: connection, connectionID: connectionID)
    }

    func handleLinkDownForTesting(connectionID: UUID) {
        handleLinkDown(connectionID: connectionID)
    }

    /// Drives the REAL failed-rebind recovery path `performReattach` takes (testing only).
    func recoverFailedRebindForTesting(session: MuxChannelSession, key: MuxSessionKey) {
        recoverFailedRebind(session: session, key: key)
    }

    /// Drives the REAL `removeMuxSession` — the deliberate-close (peer `channelClose` / attached
    /// child exit) teardown path (testing only).
    func removeMuxSessionForTesting(_ key: MuxSessionKey) {
        removeMuxSession(key)
    }

    /// Drives the REAL hook-sink registration `spawnFreshShell` performs — the fresh-spawn edge,
    /// where the pane id is also baked into the child env as `SLOPDESK_PANE_ID` (testing only).
    func registerHookSinkForTesting(session: MuxChannelSession, connectionID: UUID, channelID: UInt32) {
        registerHookSink(session: session, connectionID: connectionID, channelID: channelID)
    }

    /// Drives the REAL hook-sink step `performReattach` performs after a successful rebind
    /// (testing only). Takes the NEW connection's identity — exactly what `performReattach`
    /// has in hand at that point — and deliberately IGNORES it: the routing key is the
    /// env-baked ORIGINAL pane id, stable for the session's life.
    func reattachHookSinkForTesting(session: MuxChannelSession, connectionID _: UUID, channelID _: UInt32) {
        refreshHookSinkOnReattach(session: session)
    }

    /// Count of tracked original hook pane ids (testing only — the bookkeeping-leak pin: every
    /// end of life must remove its entry).
    var hookPaneIDCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return hookPaneIDsBySession.count
    }
}

/// Composite key namespacing a host mux channel session by its owning connection AND its
/// channelID. The connectionID alone is insufficient (one connection has many channels) and the
/// channelID alone is insufficient (every connection allocates channelID 1 first) — only the pair
/// uniquely identifies one pane's session across multiple simultaneous client connections.
struct MuxSessionKey: Hashable {
    let connectionID: UUID
    let channelID: UInt32
}
