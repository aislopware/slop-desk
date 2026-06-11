import Foundation
import AislopdeskProtocol
import AislopdeskTransport

/// The host daemon: owns the ``HostTransport`` (`NWListener`), accepts shared-mux connections, and
/// spawns a fresh login shell + per-channel relay for every channel a client opens on them.
///
/// ## Lifecycle
/// `start()` brings up the listener and starts consuming newly-accepted shared mux connections; for
/// each ``MuxNWConnection`` yielded on `HostTransport.muxConnections_` it installs a
/// per-channel-open handler. Every `channelOpen` the client sends mints a PTY + per-channel relay
/// (``MuxChannelSession``) and acks. `stop()` cancels the listener and shuts every channel down.
///
/// ## Session survival & reconnect
/// MANY panes ride ONE shared connection, each as a logical channel. A channel's PTY + relay stay
/// bound to the channel; a clean `bye` keeps the shell alive (keep-alive), while a peer
/// `channelClose` or a link drop reaps the channel's shell (no per-channel reconnect/resume at this
/// stage). The daemon never kills a shell on a transient client disconnect.
///
/// `@unchecked Sendable`: mutable state (`muxSessions`, `acceptTasks`) is guarded by `lock`.
public final class HostServer: @unchecked Sendable {
    /// Requested TCP port (`0` lets the OS pick; read the result from ``boundPort()``).
    public let port: UInt16

    /// Absolute path to the shell to spawn (defaults to the user's login shell).
    public let shellPath: String

    /// What every new channel spawns: a plain login shell (default) or `claude` under
    /// the curated Claude Code profile. The plain-shell path is unchanged; this is an
    /// additional option, selected at construction. The daemon CLI selects it via the
    /// `--claude [--xterm256]` flags (see `aislopdesk-hostd/main.swift`).
    public enum LaunchMode: Sendable, Equatable {
        /// Plain login shell (the WF-3 path): `[shell] argv0=-shell`, curated generic env.
        case shell
        /// Launch `claude` via `[shell, -lc, command]` with the Claude Code profile env.
        case claudeCode(ClaudeCodeProfile)
    }

    /// The launch mode for new channels.
    public let launchMode: LaunchMode

    private let transport: HostTransport
    private let lock = NSLock()
    private var muxAcceptTask: Task<Void, Never>?

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
    /// cancelling its 2 receive loops + 2 `NWConnection`s/sockets — on ``stop()`` or when its physical
    /// link drops. Before this map existed, `stop()` closed nothing and the host open-handler captured
    /// the connection strongly (a retain cycle), so every Start→Stop cycle on the long-lived menu-bar
    /// host abandoned one live connection + 2 sockets + 2 tasks, accumulating toward EMFILE. The map is
    /// also the strong-ref the open handler looks the connection up from (instead of capturing it).
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
    /// shared TCP mux connection per client, regardless of how many panes/channels ride it —
    /// the same semantics as ``liveSessionIDs()``). Fired whenever a channel is added or
    /// removed (so the count rises on the first channel of a new connection and falls to 0
    /// when the last channel of the last connection goes away), and reset to 0 on ``stop()``.
    ///
    /// Purely observational and ADDITIVE: it defaults to `nil`, so the headless `aislopdesk-hostd`
    /// daemon (which never sets it) is byte-identical. It exists for the menu-bar host app,
    /// which surfaces a live "N client(s) connected" line without polling. The closure is
    /// `@Sendable` and may be invoked off the main actor (from the lock-guarded spawn/remove
    /// paths) — the app hops to its actor before touching UI state.
    public var onConnectionCountChanged: (@Sendable (Int) -> Void)?

    /// Fired when the listener fails AFTER it became ready (R15 #2) — a post-bind interface drop /
    /// socket error that the one-shot `start()` result cannot report. Purely observational and
    /// ADDITIVE (defaults `nil`, so the headless `aislopdesk-hostd` daemon is byte-identical): the
    /// menu-bar host app sets it to re-classify its "running" badge to "failed" when the listener
    /// silently dies. May be invoked off the main actor; the app hops to its actor.
    public var onListenerFailed: (@Sendable (AislopdeskTransportError) -> Void)?

    public init(
        port: UInt16,
        shellPath: String? = nil,
        launchMode: LaunchMode = .shell
    ) {
        self.port = port
        self.shellPath = shellPath ?? HostEnvironment.loginShell()
        self.launchMode = launchMode
        self.transport = HostTransport()
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
        // Pre-warm the terminfo resolution OFF any connection's receive loop. The resolution can run a
        // directory probe and (on a host lacking the ghostty terminfo) spawn `infocmp` — doing that
        // lazily inside `spawnMuxChannel` blocks the MuxNWConnection actor's receive loop on the first
        // channel-open (review #5). Resolving the common key (.ghostty, false) here in a detached task
        // populates `resolvedTermCache`, so `spawnMuxChannel` reads a warm cache with no probe/IO on the
        // connection's actor. (The .xterm256-explicit path short-circuits the probe entirely.)
        Task.detached(priority: .utility) { [weak self] in
            _ = self?.resolveEffectiveTerm(requested: .ghostty, explicitOverride: false)
        }
        let muxStream = transport.muxConnections_
        muxAcceptTask = Task { [weak self] in
            for await muxConnection in muxStream {
                await self?.handleNewMuxConnection(muxConnection)
            }
        }
    }

    /// Stops the listener and shuts down every live channel.
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
        // fds closed before `aislopdesk-hostd` calls `exit(0)`).
        let liveMux = drainMuxSessions()
        await withTaskGroup(of: Void.self) { group in
            for session in liveMux {
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        session.shutdownDetached { c.resume() }
                    }
                }
            }
            await group.waitForAll()
        }
        // R5 rank 3: close every accepted connection so its 2 receive loops + 2 NWConnections/sockets
        // are torn down (and its handler retain cycle broken). Without this each Start→Stop cycle on the
        // long-lived menu-bar host abandoned one live connection → accumulation toward EMFILE.
        let liveConns = drainMuxConnections()
        for conn in liveConns { await conn.close() }
    }

    /// Synchronously sets the `stopping` flag (NSLock is unavailable from the async `stop()` directly).
    private func markStopping() {
        lock.lock(); stopping = true; lock.unlock()
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
        lock.lock(); muxConnections[id] = connection; lock.unlock()
    }

    /// Looks up a retained accepted connection by id — the open handler resolves the connection HERE
    /// (the map's strong ref) instead of capturing it strongly, which would form a retain cycle.
    private func muxConnection(for id: UUID) -> MuxNWConnection? {
        lock.lock(); defer { lock.unlock() }
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

    /// Snapshot of the live connection ids carrying channels (diagnostics / tests).
    public func liveSessionIDs() -> [UUID] {
        lock.lock(); defer { lock.unlock() }
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
                guard let self, let conn = self.muxConnection(for: connectionID) else { return }
                self.spawnMuxChannel(open, on: conn, connectionID: connectionID)
            }
        }
        // FIX #2: a clean peer `channelClose` must tear the channel's PTY + master fd down. There is
        // NO per-channel reconnect/resume, so a closed channel's shell must NOT be kept alive — the
        // keep-alive `.bye` no-op in `MuxChannelSession` is for the link-survives case, not channel
        // close. Without this, every cleanly-closed pane leaked its shell. `removeMuxSession` is
        // idempotent with the `onExit` path, so a close that races the child's own exit is harmless.
        await connection.setHostCloseHandler { [weak self] channelID in
            self?.removeMuxSession(MuxSessionKey(connectionID: connectionID, channelID: channelID))
        }
        // R5 rank 3: when the whole physical link drops (peer crash / TCP reset), reap the connection —
        // drop it from the retention map + close it (frees sockets + receive tasks). Captures only the
        // connectionID (never the connection), so it forms no retain cycle.
        await connection.setLinkDownHandler { [weak self] in
            self?.removeMuxConnection(connectionID)
        }
        onLog?("mux connection \(connectionID) accepted (shared)")
    }

    /// Spawns a shell + per-channel relay for one peer-initiated channel, registers it, and acks the
    /// open.
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
                // AISLOPDESK_SHELL_INTEGRATION=0; non-zsh shells are left untouched. The shim sources
                // the user's real startup files, so their env / prompt is preserved.
                //
                // Audit #17: resolve the effective TERM against the host's terminfo DB. The
                // plain-shell default is `xterm-ghostty`, but on a host that cannot resolve
                // that entry we auto-fall back to `xterm-256color` (#54700) so vim/htop/less/
                // tmux/top don't degrade. No explicit override exists on the plain-shell path.
                let term = self.resolveEffectiveTerm(requested: .ghostty, explicitOverride: false)
                var env = HostEnvironment.curated(term: term.rawValue)
                if let overrides = ShellIntegration.makeEnvironmentOverrides(
                    parent: ProcessInfo.processInfo.environment,
                    shellPath: shellPath
                ) {
                    for (key, value) in overrides { env[key] = value }
                    // The shim's ZDOTDIR override IS the generated `aislopdesk-zdotdir-*` dir — track it so the
                    // session deletes it on the child's exit (R8 #3).
                    shimDir = overrides["ZDOTDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                }
                try pty.spawn(shellPath, environment: env, argv0: argv0)
            case .claudeCode(let profile):
                // Audit #17: same terminfo bootstrap for the Claude path. An explicit
                // `--xterm256` (`profile.term == .xterm256`) is an operator override and WINS —
                // the resolver keeps it untouched; only a `.ghostty` request that the host
                // cannot resolve auto-falls back.
                let term = self.resolveEffectiveTerm(
                    requested: profile.term,
                    explicitOverride: profile.term == .xterm256
                )
                var resolvedProfile = profile
                resolvedProfile.term = term
                try pty.spawn(
                    shellPath,
                    arguments: resolvedProfile.loginShellArguments(),
                    environment: resolvedProfile.environment(),
                    argv0: argv0
                )
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
            shimDir: shimDir
        )
        // The shell-exit reaper closes over the SAME composite key so it only removes THIS
        // connection's session (idempotent with the peer-close `setHostCloseHandler` path).
        session.onExit = { [weak self] _ in self?.removeMuxSession(key) }
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
        Task { await connection.sendOpenAck(open.channelID, accepted: true) }
        onLog?("mux channel \(open.channelID) (conn \(connectionID)): shell \(shellPath) (pid \(pty.pid)) attached")
    }

    /// Resolves the effective `TERM` for a new PTY against the host's terminfo database
    /// (audit #17), logging the auto-fallback exactly when it fires.
    ///
    /// Delegates the decision to ``TerminfoResolver`` (pure logic + the live terminfo probe).
    /// When the host cannot resolve `xterm-ghostty` and no explicit `--xterm256` override is in
    /// effect, the resolver returns `.xterm256` with `fellBack == true`; we then emit ONE
    /// diagnostic line via ``onLog`` (host stderr — the same out-of-band channel as every other
    /// session-lifecycle log, NOT the PTY byte stream, so it never pollutes what the client
    /// renders). The log is gated on `fellBack`: when ghostty resolves, or the operator
    /// explicitly chose `xterm-256color`, nothing is logged.
    private func resolveEffectiveTerm(
        requested: ClaudeCodeProfile.Term,
        explicitOverride: Bool
    ) -> ClaudeCodeProfile.Term {
        // Cache by (requested, explicitOverride): the host terminfo state is stable for the session,
        // so resolve (and possibly spawn infocmp) at most once per key, not on every channel-open.
        let key = "\(requested.rawValue)|\(explicitOverride)"
        lock.lock()
        if let cached = resolvedTermCache[key] { lock.unlock(); return cached }
        lock.unlock()

        let result = TerminfoResolver.resolve(
            requested: requested,
            explicitOverride: explicitOverride
        )

        // Store under lock; the FIRST writer logs the fallback (a concurrent first-open that already
        // cached wins and we return its value without a duplicate log).
        lock.lock()
        if let cached = resolvedTermCache[key] { lock.unlock(); return cached }
        resolvedTermCache[key] = result.term
        lock.unlock()

        if result.fellBack {
            onLog?(
                "TERM: host cannot resolve '\(requested.rawValue)' terminfo entry; "
                    + "falling back to '\(result.term.rawValue)' (#54700) so TUI apps work"
            )
        }
        return result.term
    }

    private func removeMuxSession(_ key: MuxSessionKey) {
        lock.lock()
        let session = muxSessions.removeValue(forKey: key)
        lock.unlock()
        // Only re-count when a session was actually removed (the path is idempotent with the
        // peer-close / child-exit race, so a second remove of the same key is a no-op and must
        // not re-emit an unchanged count).
        if session != nil { emitConnectionCount() }
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
}

/// Composite key namespacing a host mux channel session by its owning connection AND its
/// channelID. The connectionID alone is insufficient (one connection has many channels) and the
/// channelID alone is insufficient (every connection allocates channelID 1 first) — only the pair
/// uniquely identifies one pane's session across multiple simultaneous client connections.
struct MuxSessionKey: Hashable {
    let connectionID: UUID
    let channelID: UInt32
}
