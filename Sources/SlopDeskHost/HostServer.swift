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
    /// + hook listener (W11, Decision #5/#9). The curated env is a client-side launch preset, not a
    /// host launch mode.
    public enum LaunchMode: Sendable, Equatable {
        /// Plain login shell (the WF-3 path): `[shell] argv0=-shell`, curated generic env.
        case shell
    }

    /// The launch mode for new channels.
    public let launchMode: LaunchMode

    /// W10 — whether new channels run the host-side foreground-process watch (the PRIMARY,
    /// zero-config Claude-Code detection signal, Decision #5). Resolved by the daemon from
    /// `SLOPDESK_AGENT_DETECT` (default-ON; only `"0"` disables). When false, the channel's byte
    /// pipeline is byte-identical to pre-W10.
    public let agentDetectEnabled: Bool

    /// W10 — the OPT-IN Claude-hook listener (the `AF_UNIX` socket), or `nil` when hooks are
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

    /// P1 supervision — server-level cross-pane `agent_status_changed` observers, keyed by a
    /// per-subscription `UUID`, guarded by `agentStatusObserversLock`. Each ``MuxChannelSession``
    /// (mux OR control) is wired with an `onAgentStatusChanged` closure that calls
    /// ``fanAgentStatusChanged(paneId:title:status:)``, which snapshots this map and invokes every
    /// observer with `(paneId, state, title, ts)`. A top-level `subscribe` (no paneId) registers
    /// one here and deregisters on disconnect. Separate lock from `lock` so a status fan-out never
    /// contends with the session maps (the closure may run on the foreground-poll task thread).
    private let agentStatusObserversLock = NSLock()
    private var agentStatusObservers: [UUID: @Sendable (
        _ paneId: String,
        _ state: String,
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

    /// Accepted shared mux connections, keyed by their stable `connectionID`, guarded by `lock`
    /// (R5 rank 3). The host must RETAIN every accepted ``MuxNWConnection`` so it can `close()` it —
    /// cancelling its 2 receive loops + 2 `NWConnection`s/sockets — on ``stop()`` or link drop.
    /// Without this map, `stop()` closed nothing and the open-handler captured the connection strongly
    /// (a retain cycle), so every Start→Stop cycle on the long-lived menu-bar host abandoned one live
    /// connection + 2 sockets + 2 tasks, accumulating toward EMFILE. The map is also the strong ref the
    /// open handler resolves the connection from (instead of capturing it).
    private var muxConnections: [UUID: MuxNWConnection] = [:]

    /// Set true by ``stop()`` (under `lock`) before draining sessions. The accepted connections' receive
    /// loops keep running after `stop()` (the listener cancel does not cancel them), so a `channelOpen`
    /// already buffered / in flight can still reach ``spawnMuxChannel`` AFTER the session map is drained
    /// — which would fork a login shell that is never reaped and OUTLIVES the daemon (SIGINT during an
    /// active channel-open). `spawnMuxChannel` checks this flag (early, and again at the insert) and
    /// REFUSES the channel once stopping, so no orphan PTY is minted past shutdown. Monotonic; guarded
    /// by `lock`.
    private var stopping = false

    /// Cache of the resolved effective TERM keyed by `requested|explicitOverride`, guarded by `lock`.
    /// The host's terminfo state doesn't change during a session, so the (possibly `infocmp`-spawning)
    /// probe runs at most ~once per key instead of on EVERY channel-open (new pane/tab), and the
    /// fallback diagnostic is logged exactly once. (Review #5/#6: avoid per-open re-probe + unbounded
    /// synchronous infocmp on the channel-open path.)
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

    /// Fired when the listener fails AFTER it became ready (R15 #2) — a post-bind interface drop /
    /// socket error that the one-shot `start()` result cannot report. Purely observational and
    /// ADDITIVE (defaults `nil`, so the headless `slopdesk-hostd` daemon is byte-identical): the
    /// menu-bar host app sets it to re-classify its "running" badge to "failed" when the listener
    /// silently dies. May be invoked off the main actor; the app hops to its actor.
    public var onListenerFailed: (@Sendable (SlopDeskTransportError) -> Void)?

    /// WB1 — whether new channels run the additive "Blocks" tap (the ``CommandBlockSegmenter`` +
    /// the type-28/29 wire). Resolved from `SLOPDESK_BLOCKS` (default-ON; only `"0"` disables) by
    /// the daemon and passed in. When false, a channel's byte pipeline is byte-identical to pre-WB1.
    public let blocksEnabled: Bool

    /// S3 — whether detach/reattach is enabled (env `SLOPDESK_DETACH_ENABLED`). Default-ON idiom:
    /// when the env var equals `"0"`, detach is off and a disconnect routes to the existing immediate
    /// shutdown (S1 behavior). Any other value (or absence) enables detach. Resolved once at init so
    /// every handler reads a single immutable Bool.
    public let detachEnabled: Bool

    /// S3 — the TTL (seconds) for a detached session before the shell is killed (env
    /// `SLOPDESK_DETACH_TTL_SECS`, default 3600 = 1 hour). Resolved once at init.
    public let detachTTL: Duration

    /// E13 WI-3 (ES-E13-6) — the "Resume Session on Recovery" host policy (client toggle
    /// ``AgentPreferences/resumeOnRecovery`` → `SLOPDESK_AGENT_RESUME_ON_RECOVERY`, default-ON `!= "0"`).
    /// Maps onto ``DetachedSessionStore`` (spec `getting-started__first-launch` §"Resume Session on
    /// Recovery"): ON → a recovered terminal reattaches to the still-running detached session; OFF →
    /// the host neither keeps nor reattaches, so recovery yields a FRESH shell. Resolved once at init
    /// and AND-ed into ``detachEnabled`` (the single reattach gate) so this flag actuates.
    public let resumeOnRecovery: Bool

    /// S3 — the store for detached sessions. `nil` when `detachEnabled == false`.
    private let detachedStore: DetachedSessionStore?

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
        resumeOnRecovery: Bool? = nil,
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
        transport = HostTransport()

        // S3: resolve detach from env (default-ON: only "0" disables) unless overridden by the caller.
        let envDetach = ProcessInfo.processInfo.environment["SLOPDESK_DETACH_ENABLED"]
        // E13 WI-3 (ES-E13-6): "Resume on Recovery" gates the SAME reattach machinery. AND it into the
        // detach gate — when OFF, detached sessions are neither kept (handleLinkDown hard-shuts down) nor
        // reattached (spawnMuxChannel sees a nil store), so recovery yields a fresh shell.
        let effectiveResume = resumeOnRecovery ?? HostEnvironment.agentResumeOnRecoveryEnabled()
        self.resumeOnRecovery = effectiveResume
        let effectiveDetach = (detachEnabled ?? (envDetach != "0")) && effectiveResume
        self.detachEnabled = effectiveDetach

        let envTTL = ProcessInfo.processInfo.environment["SLOPDESK_DETACH_TTL_SECS"]
            .flatMap { Int($0) }
        let ttlSecs = detachTTLSecs ?? envTTL ?? 3600
        detachTTL = .seconds(ttlSecs)

        detachedStore = effectiveDetach ? DetachedSessionStore() : nil
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
        // Forward a POST-ready listener failure (R15 #2) to this server's hook. Read the hook lazily
        // at failure time (`self?.onListenerFailed`) so the app's assignment after init is honoured;
        // `[weak self]` avoids retaining the server through the transport's listener handler.
        try await transport.start(port: port, onListenerFailed: { [weak self] err in
            self?.onListenerFailed?(err)
        })
        // Pre-warm the terminfo resolution OFF any connection's receive loop: the resolution can run a
        // directory probe and (on a host lacking the ghostty terminfo) spawn `infocmp`, which done lazily
        // inside `spawnMuxChannel` would block the MuxNWConnection actor's receive loop on the first
        // channel-open (review #5). Resolving the common key (.ghostty, false) here in a detached task
        // warms `resolvedTermCache`, so `spawnMuxChannel` reads it with no probe/IO on the connection's
        // actor. (The .xterm256-explicit path short-circuits the probe entirely.)
        Task.detached(priority: .utility) { [weak self] in
            _ = self?.resolveEffectiveTerm(requested: .ghostty, explicitOverride: false)
        }
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
        await transport.stop()
        // R5 rank 8: tear the channels down in PARALLEL on the concurrent teardown queue instead of
        // serially (each `shutdown()` blocks up to ~0.25s for an interactive shell that ignores SIGTERM,
        // so N panes took ~N×0.25s serially while parking a cooperative-pool thread). `shutdownDetached`
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
        // S3: kill every detached session — shells that were kept alive across a client disconnect.
        await detachedStore?.drainAll()
        // R5 rank 3: close every accepted connection so its 2 receive loops + 2 NWConnections/sockets
        // are torn down (and its handler retain cycle broken). Without this each Start→Stop cycle on the
        // long-lived menu-bar host abandoned one live connection → accumulation toward EMFILE.
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
        let live = Array(muxSessions.values)
        muxSessions.removeAll()
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

    /// Synchronously removes and returns every retained accepted connection (R5 rank 3). The caller
    /// `close()`s them outside the lock (cancelling receive loops + sockets + breaking the handler cycle).
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
        lock.unlock()
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

    /// Registers a reattached session in the live map under `lock`, exactly mirroring the
    /// fresh-shell path in ``spawnFreshShell``. Returns `true` if the session was registered,
    /// or `false` if `stopping` was set (the caller must then shut the session down and refuse
    /// the channel). NSLock is unavailable from the async ``performReattach`` directly — same
    /// discipline as ``markStopping()`` / ``drainMuxSessions()``.
    @discardableResult
    private func registerReattachedSession(_ session: MuxChannelSession, key: MuxSessionKey) -> Bool {
        lock.lock()
        if stopping {
            lock.unlock()
            return false
        }
        muxSessions[key] = session
        lock.unlock()
        return true
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
        // S3: tell MuxNWConnection whether a whole-link DROP should route to detach (skip the S1
        // per-channel hostCloseHandler kill loop and fire linkDownHandler for BOTH clean FIN and
        // hard error). When detach is disabled the connection keeps exact S1 behaviour.
        await connection.setDetachShellsOnLinkDrop(detachEnabled)
        // R5 rank 3: RETAIN the connection so stop()/link-drop can close it (frees its 2 receive loops +
        // 2 NWConnections). This map is also the strong ref the open handler resolves the connection from.
        retainMuxConnection(connectionID, connection)
        await connection.setHostOpenHandler { [weak self] open in
            // R5 rank 6: hop the blocking PTY spawn OFF the mux actor's receive loop. `spawnMuxChannel`
            // runs a synchronous `openpty()` + `fork()` (+ reaper-thread spawn) that would otherwise
            // stall the receive loop — and thus input echo / resize / output for EVERY OTHER pane riding
            // this shared connection — for the spawn's duration. The channel's sub-channels are already
            // registered on `connection`, so any inbound frame that arrives during the spawn is buffered
            // on them and lost nothing; `sendOpenAck` already completes asynchronously.
            //
            // Resolve the connection from the retention map by id rather than CAPTURING it strongly — a
            // strong capture forms a connection → hostOpenHandler → connection retain cycle (R5 rank 3).
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self, let conn = muxConnection(for: connectionID) else { return }
                spawnMuxChannel(open, on: conn, connectionID: connectionID)
            }
        }
        // S3: a clean peer `channelClose` means the client is done with the pane — no detach, just shut
        // it down (S1 behavior). A link DROP (peer crash / TCP reset) triggers detach: the client MAY
        // reconnect. So: channelClose = hard kill; link-down = soft detach (if enabled) or kill.
        await connection.setHostCloseHandler { [weak self] channelID in
            self?.removeMuxSession(MuxSessionKey(connectionID: connectionID, channelID: channelID))
        }
        // R5 rank 3: when the whole physical link drops (peer crash / TCP reset), detach every live
        // session on this connection (if detach is enabled) so their shells survive for the client
        // to reconnect to, then reap the connection itself (frees sockets + receive tasks).
        await connection.setLinkDownHandler { [weak self] in
            self?.handleLinkDown(connectionID: connectionID)
        }
        onLog?("mux connection \(connectionID) accepted (shared)")
    }

    /// Handles an incoming `channelOpen` with three-path routing (S3).
    ///
    /// - **PATH A — reattach**: the store holds a live detached session for `open.sessionID`
    ///   and the child is still alive. Rebind the relay to the new sub-channels, replay the
    ///   ReplayBuffer tail (C4), rewire `onExit`, remove from the store, and ack accepted.
    /// - **PATH B — new shell**: no detached session found (first connect, or detach disabled).
    ///   Spawn a fresh shell exactly as before.
    /// - **PATH C — child-exited**: the store lookup auto-evicts a dead session; falls through
    ///   to PATH B (fresh shell). The client MUST reset its seq to 0 — the existing ack path
    ///   with `resumeFromSeq=0` (the `sendOpenAck` with `accepted: true` on a fresh shell)
    ///   signals this (C4: client resets its seq to 0 on a fresh-shell ack).
    private func spawnMuxChannel(_ open: MuxChannelOpen, on connection: MuxNWConnection, connectionID: UUID) {
        let key = MuxSessionKey(connectionID: connectionID, channelID: open.channelID)
        // Idempotency guard (defense-in-depth with the `isNewChannel` gate in `MuxNWConnection.route`):
        // if a session already exists for this composite key, a duplicate/retransmitted `channelOpen`
        // must NOT spawn a SECOND PTY and overwrite the live session in `muxSessions` (orphaning the
        // first PTY + master fd + reaper thread). Re-ack idempotently and return.
        lock.lock()
        let alreadyLive = muxSessions[key] != nil
        let isStopping = stopping
        lock.unlock()
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

        // S3 PATH A: reattach to an existing detached session.
        // `lookup` auto-evicts a child-exited entry and returns nil (PATH C → falls to B).
        if let store = detachedStore, open.sessionID != UUID() {
            Task { [weak self] in
                guard let self else { return }
                if let session = await store.lookup(open.sessionID) {
                    // PATH A: live detached session found — reattach.
                    await performReattach(
                        session: session,
                        open: open,
                        connection: connection,
                        connectionID: connectionID,
                        store: store,
                    )
                } else {
                    // PATH B/C: no detached session (or child exited) — spawn fresh.
                    spawnFreshShell(open: open, connection: connection, connectionID: connectionID, key: key)
                }
            }
        } else {
            // S3 disabled or zero UUID (first connect) — always PATH B.
            spawnFreshShell(open: open, connection: connection, connectionID: connectionID, key: key)
        }
    }

    /// PATH A: reattach a returning client to its detached ``MuxChannelSession``.
    private func performReattach(
        session: MuxChannelSession,
        open: MuxChannelOpen,
        connection: MuxNWConnection,
        connectionID: UUID,
        store: DetachedSessionStore,
    ) async {
        let key = MuxSessionKey(connectionID: connectionID, channelID: open.channelID)
        // Replay the buffered tail to the NEW data sub-channel BEFORE rebinding so live output
        // does not interleave with the replay (the rebind starts the live drain). C4: the client
        // sent `lastReceivedSeq` so we can skip already-received messages.
        await session.replayTail(after: open.lastReceivedSeq, on: open.data)
        // Rebind the relay: swap sub-channels, clear stale queues, restart relay tasks (C3).
        // onExit is threaded INTO rebindRelay so it is assigned under taskLock, atomically with
        // the exitTask (re)start — closing the race where a shell that exits between rebindRelay
        // returning and a post-call `session.onExit =` assignment would fire the stale
        // detached-exit handler. C2: store.remove cancels the TTL timer.
        session.rebindRelay(
            data: open.data,
            control: open.control,
            onExit: { [weak self] _ in self?.removeMuxSession(key) },
        )
        await store.remove(open.sessionID)
        // Register in the live map (synchronous helper — NSLock is unavailable from async directly).
        guard registerReattachedSession(session, key: key) else {
            session.shutdown()
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        emitConnectionCount()
        // W10: re-register the hook sink for this pane under the new connection's pane ID.
        if let agentHookListener {
            let paneID = Self.paneID(connectionID: connectionID, channelID: open.channelID)
            agentHookListener.register(paneID: paneID) { [weak session] bytes in
                session?.ingestAgentHookRecord(bytes)
            }
        }
        Task { await connection.sendOpenAck(open.channelID, accepted: true) }
        onLog?("mux channel \(open.channelID) (conn \(connectionID)): reattached session \(open.sessionID)")
        // Nudge the PTY foreground process to repaint after reattach — the client terminal is
        // fresh (no buffered output) so without this the pane is blank until the user presses
        // a key. A brief delay lets the client's first `.resize` land and wires the sub-channels
        // before SIGWINCH fires, so zsh/bash redraw with the correct terminal dimensions.
        let nudgePTY = session.pty
        Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            nudgePTY.nudgeRedraw()
        }
    }

    /// PATH B/C: spawn a fresh shell (original S1 logic).
    private func spawnFreshShell(
        open: MuxChannelOpen,
        connection: MuxNWConnection,
        connectionID: UUID,
        key: MuxSessionKey,
    ) {
        let pty = PTYProcess()
        // R8 #3: the per-session ZDOTDIR shim dir (if the zsh shim is installed) — captured so the
        // session can delete it when the child exits, instead of leaking one temp dir per pane forever.
        var shimDir: URL?
        do {
            let argv0 = HostEnvironment.loginArgv0(forShell: shellPath)
            switch launchMode {
            case .shell:
                // WF4: layer the zsh shell-integration shim (a generated ZDOTDIR) so the
                // interactive shell reprints its prompt after a resize. Opt-out via
                // SLOPDESK_SHELL_INTEGRATION=0; non-zsh shells are left untouched. The shim sources
                // the user's real startup files, so their env / prompt is preserved.
                //
                // Audit #17: resolve the effective TERM against the host's terminfo DB. The
                // plain-shell default is `xterm-ghostty`, but on a host that cannot resolve
                // that entry we auto-fall back to `xterm-256color` (#54700) so vim/htop/less/
                // tmux/top don't degrade. No explicit override exists on the plain-shell path.
                let term = resolveEffectiveTerm(requested: .ghostty, explicitOverride: false)
                // W10: when the opt-in hook listener is bound, export its socket path + this
                // pane's id so an installed Claude hook can POST status events for this pane.
                let paneID = Self.paneID(connectionID: connectionID, channelID: open.channelID)
                var env = HostEnvironment.curated(
                    term: term.rawValue,
                    agentSocketPath: agentHookListener != nil ? agentHookSocketPath : nil,
                    paneID: agentHookListener != nil ? paneID : nil,
                    controlSocketPath: agentControlSocketPath.isEmpty ? nil : agentControlSocketPath,
                )
                if let initialCwd = open.initialCwd { env["PWD"] = initialCwd }
                if let overrides = ShellIntegration.makeEnvironmentOverrides(
                    parent: ProcessInfo.processInfo.environment,
                    shellPath: shellPath,
                ) {
                    for (k, value) in overrides { env[k] = value }
                    // The shim's ZDOTDIR override IS the generated `slopdesk-zdotdir-*` dir — track it so the
                    // session deletes it on the child's exit (R8 #3).
                    shimDir = overrides["ZDOTDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                }
                try pty.spawn(shellPath, environment: env, argv0: argv0, cwd: open.initialCwd)
            }
        } catch {
            onLog?("mux channel \(open.channelID) (conn \(connectionID)): shell spawn failed: \(error)")
            // R9 self-audit: the ZDOTDIR shim dir is written BEFORE the spawn, so a spawn failure (e.g.
            // EMFILE / fork failure — conditions that can REPEAT) would leak it (no MuxChannelSession is
            // created on this path to delete it later). Clean it up here so R8 #3's "no leaked shim dir
            // per pane" guarantee holds on the failure path too.
            if let shimDir { try? FileManager.default.removeItem(at: shimDir) }
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
            shimDir: shimDir,
            agentDetectEnabled: agentDetectEnabled,
            // Queue-safety cluster (2026-07-02): verb 13 reports the LIVE hook-listener bind state.
            // Probed at request time (weak — the listener outlives sessions anyway) so a bind failure
            // reads honest-false, never a stale construction-time snapshot.
            agentHookListenerActive: { [weak listener = agentHookListener] in listener?.isListening ?? false },
            blocksEnabled: blocksEnabled,
        )
        // The shell-exit reaper closes over the SAME composite key so it only removes THIS
        // connection's session (idempotent with the peer-close `setHostCloseHandler` path).
        session.onExit = { [weak self] _ in self?.removeMuxSession(key) }
        wireAgentStatusFanOut(session)
        lock.lock()
        if stopping {
            // stop() set `stopping` AFTER our early check but BEFORE this insert (it raced the fork).
            // Do NOT register past the drain — tear the just-spawned shell down (its reaper is already
            // running from `pty.spawn`, so `shutdown()` reaps it cleanly) and refuse the channel.
            lock.unlock()
            session.shutdown()
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }
        muxSessions[key] = session
        lock.unlock()
        emitConnectionCount()
        session.startRelay()
        // W10: register this pane's hook sink so an installed Claude hook POSTing to the host
        // socket (with this pane's id) routes into THIS channel's per-pane status handler.
        if let agentHookListener {
            let paneID = Self.paneID(connectionID: connectionID, channelID: open.channelID)
            agentHookListener.register(paneID: paneID) { [weak session] bytes in
                session?.ingestAgentHookRecord(bytes)
            }
        }
        Task { await connection.sendOpenAck(open.channelID, accepted: true) }
        onLog?("mux channel \(open.channelID) (conn \(connectionID)): shell \(shellPath) (pid \(pty.pid)) attached")
    }

    /// Resolves the effective `TERM` for a new PTY against the host's terminfo database
    /// (audit #17), logging the auto-fallback exactly when it fires.
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

    /// S3: handles a physical link drop — either detaches all live sessions on this connection
    /// (when detach is enabled) so their shells survive, or shuts them down (S1 behavior).
    /// Then removes the connection from the retention map.
    private func handleLinkDown(connectionID: UUID) {
        if detachEnabled {
            // Snapshot the live sessions belonging to this connection, remove them from the
            // live map (so a racing channelOpen won't see them as "alreadyLive"), then detach.
            lock.lock()
            let keysToDetach = muxSessions.keys.filter { $0.connectionID == connectionID }
            var sessionsToDetach: [(MuxSessionKey, MuxChannelSession)] = []
            for k in keysToDetach {
                if let s = muxSessions.removeValue(forKey: k) {
                    sessionsToDetach.append((k, s))
                }
            }
            lock.unlock()
            if !sessionsToDetach.isEmpty { emitConnectionCount() }
            // Detach each session: the shell stays alive in DetachedSessionStore.
            for (key, session) in sessionsToDetach {
                detachMuxSession(key: key, session: session)
            }
        }
        // Always reap the connection itself (frees sockets + receive tasks + retain cycle).
        removeMuxConnection(connectionID)
    }

    /// S3: detaches `session` from its current transport and inserts it into the detached store.
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
            // C2: shell exited while in the store — remove the entry (TTL cancelled) and
            // close the master fd. The shell is already dead, so no kill needed.
            Task {
                await store?.remove(id)
                // E13 WI-3 (prevent-sleep strict balance): a parked shell that exits mid-turn never
                // delivered a non-working transition — fan a final `.none` so a `.working` observer clears it.
                if let session { self?.fanAgentTeardown(session) }
                // shutdownDetached is safe on an already-dead shell (idempotent fd close).
                session?.shutdownDetached()
            }
            self?.onLog?("detached session \(id): shell exited while parked")
        }
        Task { await store.insert(session, key: key, ttl: ttl) }
        onLog?("mux channel \(key.channelID) (conn \(key.connectionID)): detached session \(sessionID)")
    }

    /// Removes a live session (clean close by the peer, or child self-exit). Kills the shell.
    /// Idempotent: if the key is not in the map, this is a no-op.
    private func removeMuxSession(_ key: MuxSessionKey) {
        lock.lock()
        let session = muxSessions.removeValue(forKey: key)
        lock.unlock()
        // W10: drop this pane's hook sink so a late hook POST for a closed pane is dropped.
        if session != nil, let agentHookListener {
            agentHookListener.unregister(paneID: Self.paneID(connectionID: key.connectionID, channelID: key.channelID))
        }
        // Only re-count when a session was actually removed (the path is idempotent with the
        // peer-close / child-exit race, so a second remove of the same key is a no-op and must
        // not re-emit an unchanged count).
        if session != nil { emitConnectionCount() }
        // E13 WI-3 (prevent-sleep strict balance): a pane closed WHILE its agent is working never
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
        /// P1 supervision state — the per-pane Claude agent state mapped to the ctl wire
        /// vocabulary (`idle`/`working`/`done`/`blocked`). A live pane with no detected
        /// `claude` reports `idle` (see ``AgentControlState``).
        public let state: String
    }

    /// Returns a snapshot of all live panes (mux + standalone control panes).
    /// Called from the agent-control `list-panes` verb handler. O(N) over active panes.
    public func listPanesForControl() -> [PaneInfo] {
        lock.lock()
        let mux = Array(muxSessions.values)
        let ctrl = Array(controlSessions.values)
        lock.unlock()
        return (mux + ctrl).map { session in
            PaneInfo(
                paneId: session.sessionID.uuidString,
                title: session.currentTitle,
                pid: session.pty.pid,
                isAlive: !session.isChildExited(),
                state: AgentControlState.string(from: session.agentStatusForControl),
            )
        }
    }

    // MARK: - P1 cross-pane agent-status fan-out

    /// Registers a cross-pane `agent_status_changed` observer and returns its dedupe key. Called
    /// by the top-level (no-paneId) `subscribe` handler. The observer is invoked with
    /// `(paneId, state, title, ts)` on EVERY pane's status transition until ``removeAgentStatusObserver(id:)``.
    func registerAgentStatusObserver(
        id: UUID,
        _ observer: @escaping @Sendable (_ paneId: String, _ state: String, _ title: String, _ ts: Double) -> Void,
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

    /// E13 WI-3 — registers a PROCESS-LIFETIME observer of cross-pane agent-status transitions, the public
    /// seam `slopdesk-hostd` uses to drive the prevent-sleep `IOPMAssertion` off the `.working` aggregate.
    /// Reuses the existing P1 fan-out (``registerAgentStatusObserver(id:_:)``); the observer receives
    /// `(paneId, state)` where `state` is the stable ctl supervision string (``AgentControlState`` — `"working"`
    /// while a turn runs). No deregistration is exposed: the daemon holds it for its whole lifetime.
    @preconcurrency
    public func observeAgentStatusForPreventSleep(
        _ observer: @escaping @Sendable (_ paneId: String, _ state: String) -> Void,
    ) {
        registerAgentStatusObserver(id: UUID()) { paneId, state, _, _ in observer(paneId, state) }
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
        let ts = Date().timeIntervalSince1970
        for observer in observers { observer(paneId, state, title, ts) }
    }

    /// Wires a freshly-created session's `onAgentStatusChanged` to the server fan-out. Called from
    /// EVERY session-creation site (mux + control spawn) so a transition on any pane reaches the
    /// top-level subscribers. `[weak self]` avoids retaining the server through the session.
    private func wireAgentStatusFanOut(_ session: MuxChannelSession) {
        let paneId = session.sessionID.uuidString
        session.onAgentStatusChanged = { [weak self, weak session] status in
            let title = session?.currentTitle ?? ""
            self?.fanAgentStatusChanged(paneId: paneId, title: title, status: status)
        }
    }

    /// E13 WI-3 (prevent-sleep STRICT BALANCE): fans a FINAL `.none` agent status for a pane torn down
    /// WHILE it still carries a non-`.none` status. A pane normally delivers its own `working → done/idle`
    /// transition (detector poll / hook), but one CLOSED mid-turn — tab close (`removeMuxSession`), child
    /// exit (`removeMuxSession`/`removeControlSession`), link drop, or ctl `kill` (`killPaneForControl`) —
    /// never does. Without this fan, a `.working`-tracking observer (the `slopdesk-hostd` prevent-sleep
    /// driver) keeps that dead paneId forever, `anyAgentWorking` stays true, and the `IOPMAssertion` is
    /// held for the daemon's whole lifetime — a leaked assertion keeping the Mac awake forever. Reuses the
    /// P1 fan-out so EVERY observer (prevent-sleep + cross-pane subscribers) clears the pane uniformly.
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
        // Check muxSessions.
        for (key, session) in muxSessions where session.sessionID.uuidString == paneId {
            muxSessions.removeValue(forKey: key)
            lock.unlock()
            // E13 WI-3 (prevent-sleep strict balance): clear a working pane killed mid-turn by ctl.
            fanAgentTeardown(session)
            session.shutdownDetached()
            return true
        }
        // Check controlSessions.
        for (id, session) in controlSessions where id.uuidString == paneId {
            controlSessions.removeValue(forKey: id)
            lock.unlock()
            // E13 WI-3 (prevent-sleep strict balance): clear a working pane killed mid-turn by ctl.
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
    /// loops exit at once and `setClientOnline(false)` engages the 4 MiB offline gate — PTY
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
        // ctl socket (curated sets SLOPDESK_CONTROL_SOCKET when non-empty).
        var environ = HostEnvironment.curated(
            controlSocketPath: agentControlSocketPath.isEmpty ? nil : agentControlSocketPath,
        )
        if let extraEnv { for (k, v) in extraEnv { environ[k] = v } }
        // Inject the pane self-id (same contract as a mux-spawned pane).
        environ[HostEnvironment.agentPaneIDEnvKey] = sessionID.uuidString
        // P1 full self-orientation sentinel: an agent inside a spawned pane knows it is under
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
        try pty.spawn(
            executable,
            arguments: argv,
            environment: environ,
            argv0: argv0,
            cwd: cwd,
            cols: cols,
            rows: rows,
        )

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
            agentHookListenerActive: { [weak listener = agentHookListener] in listener?.isListening ?? false },
            blocksEnabled: false, // no client → blocks metadata would be dropped anyway
        )
        session.onExit = { [weak self] _ in self?.removeControlSession(sessionID) }
        wireAgentStatusFanOut(session)

        // Synchronous helper: NSLock is unavailable from async context directly.
        guard insertControlSession(sessionID, session) else {
            session.shutdown()
            throw ControlError.serverStopping
        }

        session.startRelay()
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
        // E13 WI-3 (prevent-sleep strict balance): a standalone pane whose child exits mid-turn never
        // delivers a non-working transition — fan a final `.none` so a `.working` observer clears it.
        if let session { fanAgentTeardown(session) }
    }

    /// Errors thrown by the agent-control spawn path.
    public enum ControlError: Error, Sendable {
        case serverStopping
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
