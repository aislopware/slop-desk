import Darwin
import Foundation

/// hostd's end of one `AF_UNIX` stream socket, framed.
///
/// Only hostd's end: superd's is `rust/slopdesk-superd/src/server.rs`. Writes are serialised by a
/// lock (two interleaved frames would desynchronise the stream permanently); reads are done by the
/// client's single read loop, one frame at a time.
///
/// `@unchecked Sendable`: `fd` is immutable after init and every mutation is under `writeLock` or
/// `stateLock`.
public final class SupervisorConnection: @unchecked Sendable {
    public let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
    }

    public var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    /// Writes one frame. Safe to call from several threads.
    ///
    /// No descriptor parameter: hostd receives PTY masters, it never has one to give. The sending
    /// half lives once, in `rust/slopdesk-superd/src/frame.rs`.
    public func send(body: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try SupervisorFrame.write(socket: fd, body: body)
    }

    /// Reads one frame. Single-reader only — the owner's read loop.
    ///
    /// The tag comes back with the body because the two body kinds are not interchangeable: JSON
    /// control traffic and a pane's raw output share this socket, and only the tag says which
    /// arrived (``SupervisorFrame/tagOutput``).
    public func receive() throws -> (tag: UInt8, body: [UInt8], descriptor: Int32?) {
        try SupervisorFrame.read(socket: fd)
    }

    /// Idempotent. `shutdown` before `close` so a peer blocked in `recvmsg` wakes immediately
    /// instead of waiting for a timeout that does not exist.
    public func close() {
        stateLock.lock()
        let wasClosed = closed
        closed = true
        stateLock.unlock()
        guard !wasClosed else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

/// `connect(2)`, and nothing else.
///
/// There is no `listen` here. superd binds, in `rust/slopdesk-superd/src/server.rs`, and a Swift
/// listener would only ever have been a test fake — a second superd, written in the language the
/// real one deliberately is not, drifting from it silently. The client end is tested against the
/// real daemon instead (`scripts/check-supervisor.sh`), which is the only test that can be wrong
/// in a way that matters.
public enum SupervisorSocket {
    public enum SocketError: Error, Sendable {
        case socketFailed(errno: Int32)
        case connectFailed(errno: Int32, path: String)
    }

    public static func connect(to path: String) throws -> Int32 {
        var address = try UnixSocketPath.address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socketFailed(errno: errno) }
        // A `write` or `sendmsg` on a socket whose peer has gone raises SIGPIPE, and the default
        // disposition kills the process — so superd dying, or this client being disconnected while
        // another thread still holds it, would take hostd down with it. That is the exact opposite
        // of what this daemon is for. With `SO_NOSIGPIPE` the same write returns `EPIPE`, which
        // `SupervisorFrame.writeAll` already turns into a thrown `ioFailed` the caller reports and
        // reconnects from. macOS has no `MSG_NOSIGNAL`, so it has to be set on the socket.
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // AF_UNIX defaults to an 8 KB buffer on macOS, against TCP's 128 KB, and this socket now
        // carries the BULK path: one pane-output frame is up to `READ_CHUNK_BYTES` = 32 KiB, so a
        // single frame does not fit and superd's writer parks mid-frame the moment hostd is a beat
        // behind (`DECISIONS.md` 2026-08-10 warned about exactly this before the byte path moved
        // here). Both directions, because both directions matter: superd writes output, hostd
        // writes pauses and verbs. Best-effort — a kernel that refuses the size just keeps its own.
        var bufferBytes = Int32(256 * 1024)
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferBytes, optionSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferBytes, optionSize)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw SocketError.connectFailed(errno: code, path: path)
        }
        return fd
    }
}

// The single-instance `flock` lives in Rust, in `slopdesk-superd` — it is what makes "one superd
// per user" true, and only the daemon ever takes it. There is deliberately no Swift copy: a second
// implementation of that lock is a second way to strand every pane.
