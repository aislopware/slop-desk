import Foundation
import RworkProtocol
import RworkTransport

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
    /// `--claude [--xterm256]` flags (see `rwork-hostd/main.swift`).
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

    /// A hook the daemon can set to log session lifecycle to stderr.
    public var onLog: (@Sendable (String) -> Void)?

    /// An optional hook called with the current count of distinct client *connections* (one
    /// shared TCP mux connection per client, regardless of how many panes/channels ride it —
    /// the same semantics as ``liveSessionIDs()``). Fired whenever a channel is added or
    /// removed (so the count rises on the first channel of a new connection and falls to 0
    /// when the last channel of the last connection goes away), and reset to 0 on ``stop()``.
    ///
    /// Purely observational and ADDITIVE: it defaults to `nil`, so the headless `rwork-hostd`
    /// daemon (which never sets it) is byte-identical. It exists for the menu-bar host app,
    /// which surfaces a live "N client(s) connected" line without polling. The closure is
    /// `@Sendable` and may be invoked off the main actor (from the lock-guarded spawn/remove
    /// paths) — the app hops to its actor before touching UI state.
    public var onConnectionCountChanged: (@Sendable (Int) -> Void)?

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
        try await transport.start(port: port)
        let muxStream = transport.muxConnections_
        muxAcceptTask = Task { [weak self] in
            for await muxConnection in muxStream {
                await self?.handleNewMuxConnection(muxConnection)
            }
        }
    }

    /// Stops the listener and shuts down every live channel.
    public func stop() async {
        muxAcceptTask?.cancel()
        await transport.stop()
        let liveMux = drainMuxSessions()
        for session in liveMux { session.shutdown() }
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
        await connection.setHostOpenHandler { [weak self] open in
            // Hop off the mux actor's executor: spawning a PTY + locking the session map is the
            // owner's (HostServer) job. The sub-channels are already registered on `connection`.
            guard let self else { return }
            self.spawnMuxChannel(open, on: connection, connectionID: connectionID)
        }
        // FIX #2: a clean peer `channelClose` must tear the channel's PTY + master fd down. There is
        // NO per-channel reconnect/resume, so a closed channel's shell must NOT be kept alive — the
        // keep-alive `.bye` no-op in `MuxChannelSession` is for the link-survives case, not channel
        // close. Without this, every cleanly-closed pane leaked its shell. `removeMuxSession` is
        // idempotent with the `onExit` path, so a close that races the child's own exit is harmless.
        await connection.setHostCloseHandler { [weak self] channelID in
            self?.removeMuxSession(MuxSessionKey(connectionID: connectionID, channelID: channelID))
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
        lock.unlock()
        if alreadyLive {
            Task { await connection.sendOpenAck(open.channelID, accepted: true) }
            return
        }
        let pty = PTYProcess()
        do {
            let argv0 = HostEnvironment.loginArgv0(forShell: shellPath)
            switch launchMode {
            case .shell:
                // WF4: layer the zsh shell-integration shim (a generated ZDOTDIR) so the
                // interactive shell reprints its prompt after a resize. Opt-out via
                // RWORK_SHELL_INTEGRATION=0; non-zsh shells are left untouched. The shim sources
                // the user's real startup files, so their env / prompt is preserved.
                var env = HostEnvironment.curated()
                if let overrides = ShellIntegration.makeEnvironmentOverrides(
                    parent: ProcessInfo.processInfo.environment,
                    shellPath: shellPath
                ) {
                    for (key, value) in overrides { env[key] = value }
                }
                try pty.spawn(shellPath, environment: env, argv0: argv0)
            case .claudeCode(let profile):
                try pty.spawn(
                    shellPath,
                    arguments: profile.loginShellArguments(),
                    environment: profile.environment(),
                    argv0: argv0
                )
            }
        } catch {
            onLog?("mux channel \(open.channelID) (conn \(connectionID)): shell spawn failed: \(error)")
            // Refuse the channel so the client's router marks it dead and never routes data to it.
            Task { await connection.sendOpenAck(open.channelID, accepted: false) }
            return
        }

        let session = MuxChannelSession(
            channelID: open.channelID,
            pty: pty,
            data: open.data,
            control: open.control
        )
        // The shell-exit reaper closes over the SAME composite key so it only removes THIS
        // connection's session (idempotent with the peer-close `setHostCloseHandler` path).
        session.onExit = { [weak self] _ in self?.removeMuxSession(key) }
        lock.lock()
        muxSessions[key] = session
        lock.unlock()
        emitConnectionCount()
        session.startRelay()
        Task { await connection.sendOpenAck(open.channelID, accepted: true) }
        onLog?("mux channel \(open.channelID) (conn \(connectionID)): shell \(shellPath) (pid \(pty.pid)) attached")
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
