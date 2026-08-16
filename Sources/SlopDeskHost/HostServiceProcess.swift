// HostServiceProcess — the shared plumbing behind every LAZILY SPAWNED host-side HTTP service the
// right panel's surfaces run on: the code panel's `code-server` (verb 18) and the simulator
// panel's `baguette serve` (verb 21).
//
// Both managers follow the same shape, and it is the shape rather than the binary that carries the
// hard-won details: spawn with port `0` and LEARN the bound port from the child's own log line (no
// pre-bind allocation race), merge stdout+stderr into one pipe (a future build moving its announce
// line cannot silently break the parse), probe readiness with a BOUNDED loopback connect (the
// metadata queue must never hang), and locate the binary through `PATH` PLUS the Homebrew prefixes
// a hostd launched outside a login shell never sees.
//
// Hang-safety: everything here creates real processes and sockets — a unit test drives its manager
// through the injected seams instead, and never reaches this file.

import Foundation
import SlopDeskSupervisor

/// One live (or launching) supervised child. A protocol seam so unit tests drive a manager with a
/// fake — the hang-safety rule extends here: a unit test must NEVER spawn a real service (a
/// multi-second boot, a network listener, a Homebrew dependency).
protocol HostServiceProcessHandle: AnyObject, Sendable {
    /// Whether the child is still alive. `false` (crash, idle-timeout self-exit) makes the next
    /// `ensure` respawn.
    var isRunning: Bool { get }
    /// Ends the service for good. Idempotent.
    ///
    /// The counterpart to ``relinquish()``, and the same line `docs/51` §5.5 draws for panes: this
    /// one means "this service is over", not "hostd is going away". Only a deliberate stop may call
    /// it — a daemon shutdown must not.
    func terminate()
    /// Lets the service GO: hostd stops listening to it and superd keeps the child running.
    ///
    /// What `HostServer.stop()` calls. Before superd held these, hostd's stop terminated them, so
    /// every host edit cost the user a Node reboot in the code panel and a dead simulator server.
    func relinquish()
}

enum HostServiceProcess {
    /// Finds the service's executable, or `nil` when the host has none (→ `.unavailable`).
    typealias BinaryLocator = @Sendable () -> String?

    /// Spawns the child; `onLogLine` receives each line of its merged stdout/stderr (the port
    /// parse). Throws when the exec itself fails, or when superd is unreachable.
    typealias Spawner = @Sendable (
        _ binary: String, _ arguments: [String], _ onLogLine: @escaping @Sendable (String) -> Void,
    ) throws -> any HostServiceProcessHandle

    /// Whether a TCP connect to `127.0.0.1:port` succeeds (bounded, never hangs).
    typealias ReadinessProbe = @Sendable (_ port: UInt16) -> Bool

    /// Reads a child's own announce line for the port it bound, or `nil` for every other line.
    typealias PortParser = @Sendable (_ logLine: String) -> UInt16?

    /// Locates `name` on the host: `overrideVariable` wins when it names an executable, else the
    /// ``searchDirectories`` walk. `nil` ⇒ the service is not installed (the panel renders its
    /// install hint rather than failing).
    ///
    /// An override that is SET but not executable resolves to `nil` rather than falling through to
    /// the search: an operator who named a binary meant that one, and silently running a different
    /// one is worse than reporting unavailable.
    static func locate(
        _ name: String, overrideVariable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        vendoredBinDirectory: String? = VendoredTools.binDirectory,
    ) -> String? {
        if let override = environment[overrideVariable], !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        for directory in searchDirectories(
            environment: environment, vendoredBinDirectory: vendoredBinDirectory,
        ) {
            let candidate = directory + "/" + name
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The full search order, most authoritative first.
    ///
    /// **The vendored prefix leads**, ahead of even `PATH`. That inverts the usual "the operator's
    /// `PATH` wins" instinct on purpose: the version in `ThirdParty/tools/tools.lock` is the one
    /// this checkout's panel code was written and measured against, and it is the one whose bump is
    /// a reviewed change with a documented tail (the code panel's clip height and settings seed both
    /// key off the workbench version). A stale Homebrew copy silently winning is the exact failure
    /// this layer exists to end. `SLOPDESK_*_BIN` is still the escape hatch, and it is checked
    /// before any of this.
    ///
    /// Then `PATH`, then ``fallbackBinDirectories``: hostd is launched by `nohup`/launchd, not a
    /// login shell, so its inherited `PATH` routinely misses all of them.
    static func searchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        vendoredBinDirectory: String? = VendoredTools.binDirectory,
    ) -> [String] {
        var directories: [String] = []
        if let vendoredBinDirectory { directories.append(vendoredBinDirectory) }
        directories.append(contentsOf: (environment["PATH"] ?? "").split(separator: ":").map(String.init))
        directories.append(contentsOf: fallbackBinDirectories)
        return directories
    }

    /// The bin directories appended after the `PATH` walk, for a host with no provisioned prefix.
    /// `~/.local/bin` comes FIRST and Homebrew after: a service installed there is the hand-managed
    /// copy, so when both exist that is the one the operator meant. Apple-silicon prefix leads the
    /// Homebrew pair.
    static let fallbackBinDirectories = [
        NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
    ]

    /// Starts `service` — or takes back the one that survived the last hostd — and streams each
    /// line of its merged stdout/stderr to `onLogLine` (the port parse).
    ///
    /// **hostd does not fork this.** superd does, and superd keeps it, which is why editing a host
    /// file no longer reboots the embedded workbench. See ``SupervisedServiceProcess`` for the whole
    /// argument; the shape of this call is unchanged so that the managers above it did not have to
    /// learn anything new.
    ///
    /// Throws when superd is unreachable or the exec itself fails (missing/broken binary → the
    /// caller reports unavailable).
    static func spawn(
        service: String, binary: String, arguments: [String], environment: [String: String],
        onLogLine: @escaping @Sendable (String) -> Void,
    ) throws -> any HostServiceProcessHandle {
        try SupervisedServiceProcess.spawnOrAdopt(
            service: service,
            binary: binary,
            arguments: arguments,
            environment: environment,
            supervisor: HostServiceSupervisor.shared.connected(),
            onLogLine: onLogLine,
            onLog: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) },
        )
    }

    /// Bounded TCP connect to `127.0.0.1:port` (~250 ms): listening ⇒ `true`. Non-blocking socket +
    /// `poll(2)` — a filtered/blackholed port times out instead of hanging the metadata queue.
    static func isListening(onLoopbackPort port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFD, 1, 250) == 1 else { return false }
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0 else { return false }
        return soError == 0
    }
}

/// The one superd connection every panel service is spawned through.
///
/// Process-wide, because the managers above it are (`HostCodeServerPerformer.sharedManager` and
/// friends): one host runs one code-server and one `baguette serve`, and they outlive any single
/// ``HostServer``. Separate from `HostServer.supervisor` for the same reason — a service must not
/// be held by a connection whose lifetime is a listener's.
///
/// The client is built on FIRST USE, never eagerly, because `SupervisorClient` resolves its socket
/// path at construction: a `static let` would latch whichever `SLOPDESK_SUPERD_SOCKET` happened to
/// be set when this file's globals initialised, which in a test process is somebody else's private
/// daemon.
final class HostServiceSupervisor: @unchecked Sendable {
    static let shared = HostServiceSupervisor()

    private let lock = NSLock()
    private var cached: SupervisorClient?

    /// A connected client.
    ///
    /// - Throws: ``SupervisorClient/ClientError`` or a socket error when superd is not reachable.
    ///   That is a real failure and the caller reports the panel unavailable — hostd does not fork,
    ///   so there is no fallback to have.
    func connected() throws -> SupervisorClient {
        lock.lock()
        if let cached, cached.isConnected {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let client = SupervisorClient()
        try client.connect(clientName: "slopdesk-hostd-services")
        lock.lock()
        // A racing caller may have connected one first; keep whichever landed and drop the spare,
        // so two services never end up on two connections.
        if let winner = cached, winner.isConnected {
            lock.unlock()
            client.disconnect()
            return winner
        }
        cached = client
        lock.unlock()
        return client
    }

    /// Drops the connection without touching a single service. superd keeps every one of them.
    func relinquish() {
        lock.lock()
        let client = cached
        cached = nil
        lock.unlock()
        client?.disconnect()
    }
}
