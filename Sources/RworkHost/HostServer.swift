import Foundation
import RworkProtocol
import RworkTransport

/// The host daemon: owns the ``HostTransport`` (`NWListener`), maps `sessionID` →
/// ``HostSession``, spawns a fresh login shell + relay for every NEW client, and lets
/// the transport reattach a RETURNING_CLIENT in place.
///
/// ## Lifecycle
/// `start()` brings up the listener and starts consuming newly-accepted sessions; for
/// each NEW `HostSessionTransport` yielded on `HostTransport.sessions_` it spawns a
/// login shell, builds a ``HostSession``, and starts the relay. `stop()` cancels the
/// listener and shuts every session down.
///
/// ## Session survival & reconnect ([12] §6 / [18] §H)
/// A RETURNING_CLIENT reconnect is handled **entirely inside** `HostTransport`: it
/// rebinds the new channels onto the existing `HostSessionTransport` and replays the
/// un-acked tail via that object's `resume()`. Such a reconnect is deliberately **not**
/// re-yielded on `sessions_`, so the server does nothing — the already-running
/// `HostSession` (its PTY + relay tasks) stays bound to the same transport object, and
/// output that was buffered while the client was offline replays automatically. This
/// is what makes reconnect real without tmux: the daemon never kills the shell on a
/// client disconnect.
///
/// ## Idle / abandoned-session policy
/// **Default: keep-alive** (personal-use). A session whose client has gone away keeps
/// its shell running so the user can reconnect and resume the exact byte stream. An
/// optional `idleTTL` may be set to reap sessions whose client has been offline longer
/// than the TTL; when `nil` (default) sessions live until the shell exits or `stop()`.
///
/// When `idleTTL != nil` a background reaper polls each live session's
/// ``HostSessionTransport/clientOnline``. The first time a session is seen offline its
/// offline-since instant is recorded; once `now - offlineSince > idleTTL` the session is
/// fully torn down — ``HostSession/shutdown()`` (stop forwarders, terminate the child,
/// close the master fd) plus dropping its transport (release the channels/forwarders).
/// A session that comes back online (reconnect) clears its offline mark, so it is never
/// reaped while a client is attached. The reaper is deterministically testable:
/// ``reapIdleSessions(now:)`` is the reap-now entry point a test drives with a
/// synthesized `now` (no wall-clock sleeps).
///
/// `@unchecked Sendable`: mutable state (`sessions`, `acceptTask`, `offlineSince`,
/// `reaperTask`) is guarded by `lock`.
public final class HostServer: @unchecked Sendable {
    /// Requested TCP port (`0` lets the OS pick; read the result from ``boundPort()``).
    public let port: UInt16

    /// Absolute path to the shell to spawn (defaults to the user's login shell).
    public let shellPath: String

    /// Optional idle TTL for abandoned sessions. `nil` = keep-alive (default).
    public let idleTTL: TimeInterval?

    /// What every new session spawns: a plain login shell (default) or `claude` under
    /// the curated Claude Code profile. The plain-shell path is unchanged; this is an
    /// additional option, selected at construction. The daemon CLI selects it via the
    /// `--claude [--xterm256]` flags (see `rwork-hostd/main.swift`).
    public enum LaunchMode: Sendable, Equatable {
        /// Plain login shell (the WF-3 path): `[shell] argv0=-shell`, curated generic env.
        case shell
        /// Launch `claude` via `[shell, -lc, command]` with the Claude Code profile env.
        case claudeCode(ClaudeCodeProfile)
    }

    /// The launch mode for new sessions.
    public let launchMode: LaunchMode

    /// How often the idle reaper polls session liveness when `idleTTL != nil`. Injectable
    /// so a daemon can tune it (and the background-timer cost stays bounded); tests drive
    /// ``reapIdleSessions(now:)`` directly instead of waiting on this. Defaults to a
    /// fraction of the TTL at ``start()``-time if not overridden.
    private let reapInterval: TimeInterval?

    /// Clock for the idle reaper. Injectable point is ``reapIdleSessions(now:)``; the
    /// background timer reads ``clockNow()``.
    private let clock = ContinuousClock()

    private let transport: HostTransport
    private let lock = NSLock()
    private var sessions: [UUID: HostSession] = [:]
    /// For each session currently observed offline, the instant it was FIRST seen
    /// offline. Cleared when the session is seen online again. Guarded by `lock`.
    private var offlineSince: [UUID: ContinuousClock.Instant] = [:]
    private var acceptTask: Task<Void, Never>?
    private var reaperTask: Task<Void, Never>?

    /// TCP-mux (RWORK_TCP_MUX) relay: consumes shared mux connections and spawns a PTY per channel.
    /// `nil`/idle when the gate is OFF — the OFF path never constructs or touches it.
    private var muxAcceptTask: Task<Void, Never>?
    /// Live per-channel mux sessions, keyed by `(connectionID, channelID)`, guarded by `lock`.
    /// Empty when OFF.
    ///
    /// ⚠️ The key is the COMPOSITE, not `channelID` alone: every distinct client connection
    /// allocates `channelID` 1 for its first pane (``ChannelTable/allocate()`` starts at 1 per
    /// connection), so a channelID-only key made connection B's `channelOpen(1)` silently
    /// OVERWRITE connection A's live session at `1` (orphaning A's PTY/master-fd), and made A's
    /// close-hook `removeMuxSession(1)` shut DOWN B's live pane — cross-shutting a different
    /// client. Namespacing by the per-connection identity gives each connection its own keyspace.
    private var muxSessions: [MuxSessionKey: MuxChannelSession] = [:]

    /// Whether per-channel credit flow control (`RWORK_TCP_MUX_FLOW`, S2) is ON. Resolved ONCE at
    /// construction (alongside the `RWORK_TCP_MUX` gate the transport reads), and threaded into each
    /// ``MuxChannelSession`` so its output queue is BOUNDED + the PTY read pauses under a flood. OFF
    /// → unbounded queue, no pausing (byte-identical to S1).
    private let flowControlEnabled: Bool

    /// A hook the daemon can set to log session lifecycle to stderr.
    public var onLog: (@Sendable (String) -> Void)?

    public init(
        port: UInt16,
        shellPath: String? = nil,
        idleTTL: TimeInterval? = nil,
        launchMode: LaunchMode = .shell,
        reapInterval: TimeInterval? = nil,
        flowControlEnabled: Bool = MuxFlowControl.flowEnabledFromEnvironment()
    ) {
        self.port = port
        self.shellPath = shellPath ?? HostEnvironment.loginShell()
        self.idleTTL = idleTTL
        self.launchMode = launchMode
        self.reapInterval = reapInterval
        self.flowControlEnabled = flowControlEnabled
        self.transport = HostTransport()
    }

    /// The port the listener actually bound to (resolved after ``start()``).
    public func boundPort() async -> UInt16? {
        await transport.boundPort
    }

    /// Starts the listener and begins accepting sessions. Returns once the listener is
    /// ready (so the caller can read ``boundPort()``).
    public func start() async throws {
        try await transport.start(port: port)
        let stream = transport.sessions_
        acceptTask = Task { [weak self] in
            for await sessionTransport in stream {
                self?.handleNewSession(sessionTransport)
            }
        }
        // TCP-mux gate (RWORK_TCP_MUX): only consume shared mux connections when the host
        // transport's gate is ON. With it OFF, `muxConnections_` never yields (the handshake
        // rejects mux preambles), so this loop idles forever harmlessly — the OFF path spawns
        // PTYs exclusively through the unchanged `handleNewSession` above.
        let muxStream = transport.muxConnections_
        muxAcceptTask = Task { [weak self] in
            for await muxConnection in muxStream {
                await self?.handleNewMuxConnection(muxConnection)
            }
        }
        startIdleReaperIfNeeded()
    }

    /// Stops the listener and shuts down every live session.
    public func stop() async {
        acceptTask?.cancel()
        muxAcceptTask?.cancel()
        cancelReaperTask()
        await transport.stop()
        let live = drainSessions()
        for session in live { session.shutdown() }
        let liveMux = drainMuxSessions()
        for session in liveMux { session.shutdown() }
    }

    /// Synchronously removes and returns every live mux channel session (no `await` across the lock).
    private func drainMuxSessions() -> [MuxChannelSession] {
        lock.lock(); defer { lock.unlock() }
        let live = Array(muxSessions.values)
        muxSessions.removeAll()
        return live
    }

    /// Cancels the idle-reaper task under the lock (sync helper — keeps `NSLock` out of
    /// the async ``stop()``).
    private func cancelReaperTask() {
        lock.lock(); defer { lock.unlock() }
        reaperTask?.cancel()
        reaperTask = nil
    }

    // MARK: Idle reaper (idleTTL)

    /// Launches the background idle reaper when `idleTTL` is set. The reaper polls each
    /// live session's online state on an interval and tears down any session whose client
    /// has been offline longer than `idleTTL`. No-op when `idleTTL == nil` (keep-alive).
    private func startIdleReaperIfNeeded() {
        guard let idleTTL else { return }
        // Poll fast relative to the TTL so reap latency is bounded; clamp to a small floor.
        let interval = reapInterval ?? max(idleTTL / 4, 0.05)
        let nanos = UInt64((interval * 1_000_000_000).rounded())
        lock.lock()
        reaperTask?.cancel()
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    return // cancelled
                }
                guard let self else { return }
                await self.reapIdleSessions(now: self.clock.now)
            }
        }
        lock.unlock()
    }

    /// Reap-now entry point: tears down every live session whose client has been offline
    /// longer than `idleTTL`, measured against `now`. Updates the per-session
    /// offline-since marks (recording a fresh offline, clearing one that came back
    /// online). No-op when `idleTTL == nil`.
    ///
    /// Deterministically testable: a test passes a synthesized `now` (e.g. the offline
    /// mark + TTL + ε) so the reap fires WITHOUT any wall-clock sleep. Returns the ids it
    /// reaped (for assertions / logging).
    @discardableResult
    public func reapIdleSessions(now: ContinuousClock.Instant) async -> [UUID] {
        guard let idleTTL else { return [] }
        let ttl: Duration = .seconds(idleTTL)

        // Snapshot the live sessions (sync helper — no NSLock across an await).
        let live = snapshotSessions()

        // Probe each session's online state off-lock (actor hop), then decide.
        var reaped: [UUID] = []
        for (id, session) in live {
            let online = await session.transport.clientOnline
            if markOnlineOrAgeOffline(id: id, online: online, now: now) > ttl {
                reaped.append(id)
            }
        }

        // Tear the expired sessions down: remove from the map + offline marks, shut the
        // session (stop forwarders, terminate child, close master fd), and drop the
        // transport (release its channels/forwarder tasks).
        var actuallyReaped: [UUID] = []
        for id in reaped {
            // TOCTOU guard: re-probe liveness immediately before teardown. A
            // RETURNING_CLIENT reconnect is handled entirely inside the `HostTransport`
            // actor (`associateData` → `resume` → `setClientOnline(true)`), which does NOT
            // touch `HostServer.sessions`/`offlineSince` — the two maps share no lock. So a
            // client can come back online in the window between the probe loop above and
            // this teardown; without re-checking, the reaper would kill the
            // freshly-reconnected session. If it is back online, clear the stale offline
            // mark and skip the kill.
            if let session = live[id], await session.transport.clientOnline {
                _ = markOnlineOrAgeOffline(id: id, online: true, now: now)  // clears offlineSince[id]
                continue
            }
            let session = removeSessionForReap(id)
            session?.shutdown()
            await transport.dropSession(id)
            onLog?("session \(id): reaped (client offline > \(idleTTL)s idleTTL)")
            actuallyReaped.append(id)
        }
        return actuallyReaped
    }

    /// Sync snapshot of the live sessions (keeps `NSLock` out of the async reaper).
    private func snapshotSessions() -> [UUID: HostSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions
    }

    /// Sync lock-guarded offline bookkeeping for one session. If `online`, clears any
    /// offline mark and returns `.zero` (never reapable). Otherwise records the
    /// first-seen-offline instant (`now`) if new and returns the offline age (`now -
    /// since`), which the caller compares against the TTL.
    private func markOnlineOrAgeOffline(id: UUID, online: Bool, now: ContinuousClock.Instant) -> Duration {
        lock.lock(); defer { lock.unlock() }
        if online {
            offlineSince[id] = nil
            return .zero
        }
        let since: ContinuousClock.Instant
        if let existing = offlineSince[id] {
            since = existing
        } else {
            offlineSince[id] = now
            since = now
        }
        return now - since
    }

    /// Sync lock-guarded removal of a session being reaped (drops its offline mark too).
    private func removeSessionForReap(_ id: UUID) -> HostSession? {
        lock.lock(); defer { lock.unlock() }
        offlineSince[id] = nil
        return sessions.removeValue(forKey: id)
    }

    /// Synchronously removes and returns every live session (no `await` across the
    /// lock — keeps `NSLock` out of the async context).
    private func drainSessions() -> [HostSession] {
        lock.lock(); defer { lock.unlock() }
        let live = Array(sessions.values)
        sessions.removeAll()
        return live
    }

    /// Snapshot of the live session ids (diagnostics / tests).
    public func liveSessionIDs() -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.keys)
    }

    /// Test seam: inserts an already-built ``HostSession`` into the live map without a
    /// real client connection, so the idle reaper can be exercised deterministically
    /// (the production path goes through ``start()`` + a live `HostTransport`). `internal`
    /// — not part of the daemon API.
    func _insertSessionForTest(_ session: HostSession) {
        lock.lock(); sessions[session.sessionID] = session; lock.unlock()
    }

    // MARK: New session

    private func handleNewSession(_ sessionTransport: HostSessionTransport) {
        let id = sessionTransport.sessionID
        let pty = PTYProcess()
        do {
            let argv0 = HostEnvironment.loginArgv0(forShell: shellPath)
            switch launchMode {
            case .shell:
                // WF-3 plain-shell path, unchanged.
                try pty.spawn(
                    shellPath,
                    environment: HostEnvironment.curated(),
                    argv0: argv0
                )
            case .claudeCode(let profile):
                // Launch `claude` via `[shell, -lc, command]` with the curated profile
                // env (TERM=xterm-ghostty, NO_FLICKER, ENTRYPOINT=remote_mobile, ...).
                try pty.spawn(
                    shellPath,
                    arguments: profile.loginShellArguments(),
                    environment: profile.environment(),
                    argv0: argv0
                )
            }
        } catch {
            onLog?("session \(id): shell spawn failed: \(error)")
            // The transport already bound + published this session (live forwarders + open
            // data/control connections). With no shell behind it, drop it so we don't leak
            // the channels and forwarder tasks. (spawn() already closed its local master fd
            // on the failure path, so there is no PTY fd to release here.)
            Task { await self.transport.dropSession(id) }
            return
        }

        let session = HostSession(sessionID: id, pty: pty, transport: sessionTransport)
        lock.lock()
        sessions[id] = session
        lock.unlock()
        session.startRelay()
        onLog?("session \(id): shell \(shellPath) (pid \(pty.pid)) attached")

        // Reap the session map entry when the shell finally exits (keep-alive otherwise).
        Task { [weak self] in
            let code = await pty.waitForExit()
            self?.onLog?("session \(id): shell exited code \(code)")
            self?.removeSession(id)
        }
    }

    private func removeSession(_ id: UUID) {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        offlineSince[id] = nil // drop any idle-reaper bookkeeping for the gone session.
        lock.unlock()
        session?.shutdown()
    }

    // MARK: New mux connection / channel (TCP-mux S1 — gated, never reached when OFF)

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
        // FIX #2: a clean peer `channelClose` must tear the channel's PTY + master fd down. S1 has
        // NO per-channel reconnect/resume, so a closed channel's shell must NOT be kept alive — the
        // keep-alive `.bye` no-op in `MuxChannelSession` is for the link-survives case, not channel
        // close. Without this, every cleanly-closed pane leaked its shell (the reaper covers only
        // `sessions`, never `muxSessions`). `removeMuxSession` is idempotent with the `onExit` path,
        // so a close that races the child's own exit is harmless (whichever runs first wins).
        await connection.setHostCloseHandler { [weak self] channelID in
            self?.removeMuxSession(MuxSessionKey(connectionID: connectionID, channelID: channelID))
        }
        onLog?("mux connection \(connectionID) accepted (shared)")
    }

    /// Spawns a shell + per-channel relay for one peer-initiated channel, registers it, and acks the
    /// open. Mirrors ``handleNewSession``'s spawn logic exactly (same launch mode / env / argv0).
    private func spawnMuxChannel(_ open: MuxChannelOpen, on connection: MuxNWConnection, connectionID: UUID) {
        let key = MuxSessionKey(connectionID: connectionID, channelID: open.channelID)
        let pty = PTYProcess()
        do {
            let argv0 = HostEnvironment.loginArgv0(forShell: shellPath)
            switch launchMode {
            case .shell:
                try pty.spawn(shellPath, environment: HostEnvironment.curated(), argv0: argv0)
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
            control: open.control,
            flowControl: flowControlEnabled
        )
        // The shell-exit reaper closes over the SAME composite key so it only removes THIS
        // connection's session (idempotent with the peer-close `setHostCloseHandler` path).
        session.onExit = { [weak self] _ in self?.removeMuxSession(key) }
        lock.lock()
        muxSessions[key] = session
        lock.unlock()
        session.startRelay()
        Task { await connection.sendOpenAck(open.channelID, accepted: true) }
        onLog?("mux channel \(open.channelID) (conn \(connectionID)): shell \(shellPath) (pid \(pty.pid)) attached")
    }

    private func removeMuxSession(_ key: MuxSessionKey) {
        lock.lock()
        let session = muxSessions.removeValue(forKey: key)
        lock.unlock()
        session?.shutdown()
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
