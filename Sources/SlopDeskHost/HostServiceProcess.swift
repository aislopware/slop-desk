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

/// One live (or launching) supervised child. A protocol seam so unit tests drive a manager with a
/// fake — the hang-safety rule extends here: a unit test must NEVER spawn a real service (a
/// multi-second boot, a network listener, a Homebrew dependency).
protocol HostServiceProcessHandle: AnyObject, Sendable {
    /// Whether the child is still alive. `false` (crash, idle-timeout self-exit) makes the next
    /// `ensure` respawn.
    var isRunning: Bool { get }
    /// Asks the child to exit (SIGTERM). Idempotent.
    func terminate()
}

enum HostServiceProcess {
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

    /// Spawns `binary` and streams each line of its MERGED stdout/stderr to `onLogLine` (the port
    /// parse). Throws when the exec itself fails (missing/broken binary → the caller reports
    /// unavailable).
    static func spawn(
        binary: String, arguments: [String], environment: [String: String],
        onLogLine: @escaping @Sendable (String) -> Void,
    ) throws -> any HostServiceProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lines = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in lines.append(chunk) {
                onLogLine(line)
            }
        }
        try process.run()
        return ProcessHandleAdapter(process: process)
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

    /// Accumulates pipe chunks and yields complete lines (lock-guarded — the readability handler
    /// runs on a FileHandle-owned queue, and Sendable closures may not mutate captured vars).
    private final class LineSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ chunk: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
            var complete: [String] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineBytes = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(bytes: lineBytes, encoding: .utf8) {
                    complete.append(line)
                }
            }
            return complete
        }
    }

    /// The production ``HostServiceProcessHandle``.
    private final class ProcessHandleAdapter: HostServiceProcessHandle, @unchecked Sendable {
        private let process: Process

        init(process: Process) {
            self.process = process
        }

        var isRunning: Bool { process.isRunning }

        func terminate() {
            guard process.isRunning else { return }
            process.terminate()
        }
    }
}
