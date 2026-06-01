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
/// `@unchecked Sendable`: mutable state (`sessions`, `acceptTask`) is guarded by `lock`.
public final class HostServer: @unchecked Sendable {
    /// Requested TCP port (`0` lets the OS pick; read the result from ``boundPort()``).
    public let port: UInt16

    /// Absolute path to the shell to spawn (defaults to the user's login shell).
    public let shellPath: String

    /// Optional idle TTL for abandoned sessions. `nil` = keep-alive (default).
    public let idleTTL: TimeInterval?

    private let transport = HostTransport()
    private let lock = NSLock()
    private var sessions: [UUID: HostSession] = [:]
    private var acceptTask: Task<Void, Never>?

    /// A hook the daemon can set to log session lifecycle to stderr.
    public var onLog: (@Sendable (String) -> Void)?

    public init(port: UInt16, shellPath: String? = nil, idleTTL: TimeInterval? = nil) {
        self.port = port
        self.shellPath = shellPath ?? HostEnvironment.loginShell()
        self.idleTTL = idleTTL
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
    }

    /// Stops the listener and shuts down every live session.
    public func stop() async {
        acceptTask?.cancel()
        await transport.stop()
        let live = drainSessions()
        for session in live { session.shutdown() }
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

    // MARK: New session

    private func handleNewSession(_ sessionTransport: HostSessionTransport) {
        let id = sessionTransport.sessionID
        let pty = PTYProcess()
        do {
            let argv0 = HostEnvironment.loginArgv0(forShell: shellPath)
            try pty.spawn(
                shellPath,
                environment: HostEnvironment.curated(),
                argv0: argv0
            )
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
        lock.unlock()
        session?.shutdown()
    }
}
