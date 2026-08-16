import Darwin

/// `SCM_RIGHTS` file-descriptor **receiving** over `AF_UNIX`, in pure Swift.
///
/// ## Receiving only
/// hostd never sends an fd — it is the end that gets handed PTY masters, never the end that has
/// one to give. The sender lives in `rust/slopdesk-superd/src/frame.rs`, and there is deliberately
/// no Swift twin of it: two implementations of `SCM_RIGHTS` arithmetic is two chances to get the
/// Darwin alignment rule wrong, and only one of them would be under test.
///
/// ## Why this is hand-rolled
/// The `CMSG_FIRSTHDR` / `CMSG_SPACE` / `CMSG_LEN` / `CMSG_DATA` accessors are C **macros**, so the
/// Darwin overlay does not surface them to Swift. Their arithmetic is stable ABI, though, so it is
/// spelled out here rather than pulling in a second C target — which keeps the repo's "the only C
/// is `CSlopDeskSIMD`" invariant intact (`CLAUDE.md`). `docs/51` §2.1 records that this was
/// verified against a live PTY master (read / `TIOCSWINSZ` / `tcgetpgrp` all intact in the
/// receiver) before the design depended on it.
///
/// ## The alignment rule
/// Darwin aligns control-message headers and payloads to `sizeof(uint32_t)`, NOT to the platform
/// word — this is the one place where copying the Linux formula silently produces a buffer that
/// the kernel reads past on a 64-bit build. `ALIGN` in `<sys/socket.h>` is
/// `(n + sizeof(uint32_t) - 1) &~ (sizeof(uint32_t) - 1)`.
public enum FileDescriptorPassing {
    /// `ALIGN(n)` from Darwin's `<sys/socket.h>` — round up to a `uint32_t` boundary.
    @inline(__always)
    static func align(_ n: Int) -> Int {
        let unit = MemoryLayout<UInt32>.size
        return (n + unit - 1) & ~(unit - 1)
    }

    /// `CMSG_SPACE(payload)` — the buffer bytes one control message occupies, header included.
    @inline(__always)
    static func space(payload: Int) -> Int {
        align(MemoryLayout<cmsghdr>.size) + align(payload)
    }

    /// `CMSG_LEN(payload)` — the value the kernel wants in `cmsg_len` (header + payload, the
    /// payload NOT rounded up; only the trailing pad is, which is why this differs from `space`).
    @inline(__always)
    static func length(payload: Int) -> Int {
        align(MemoryLayout<cmsghdr>.size) + payload
    }

    /// The byte offset of `CMSG_DATA` from the start of the control buffer.
    @inline(__always)
    static func dataOffset() -> Int {
        align(MemoryLayout<cmsghdr>.size)
    }

    public enum PassError: Error, Sendable {
        case sendFailed(errno: Int32)
        case shortSend(sent: Int, expected: Int)
        case receiveFailed(errno: Int32)
        /// The peer closed the connection (`recvmsg` returned 0).
        case peerClosed
        /// A frame that must carry an fd arrived without one — the caller decides whether that is
        /// fatal. Never trap on it: an untrusted or version-skewed peer can produce it.
        case missingDescriptor
        /// The control message was truncated (`MSG_CTRUNC`) — the receiver's buffer was too small,
        /// which for a single fd means the kernel and this arithmetic disagree. Any fds the kernel
        /// did install would leak, so this is reported rather than swallowed.
        case controlTruncated
    }

    /// Sends `bytes` on `socket`. No ancillary data — see the type's note on receiving only.
    public static func send(socket: Int32, bytes: [UInt8]) throws {
        var payload = bytes
        let sent: Int = try payload.withUnsafeMutableBufferPointer { buffer in
            var vector = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            return try withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr()
                message.msg_iov = vectorPointer
                message.msg_iovlen = 1
                // EINTR is retried: a signal must not look like a transport failure to the caller.
                while true {
                    let n = sendmsg(socket, &message, 0)
                    if n >= 0 { return n }
                    if errno == EINTR { continue }
                    throw PassError.sendFailed(errno: errno)
                }
            }
        }
        guard sent == bytes.count else {
            throw PassError.shortSend(sent: sent, expected: bytes.count)
        }
    }

    /// Receives up to `capacity` bytes from `socket`, collecting an `SCM_RIGHTS` descriptor when
    /// the sender attached one.
    ///
    /// - Returns: the bytes actually read and the adopted descriptor (already owned by this
    ///   process — the caller must `close` it).
    public static func receive(
        socket: Int32,
        capacity: Int,
    ) throws -> (bytes: [UInt8], descriptor: Int32?) {
        var payload = [UInt8](repeating: 0, count: capacity)
        let controlSpace = space(payload: MemoryLayout<Int32>.size)
        let control = UnsafeMutableRawPointer.allocate(
            byteCount: controlSpace,
            alignment: MemoryLayout<cmsghdr>.alignment,
        )
        defer { control.deallocate() }
        memset(control, 0, controlSpace)

        var received = 0
        var truncated = false
        var descriptor: Int32?

        try payload.withUnsafeMutableBufferPointer { buffer in
            var vector = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            try withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr()
                message.msg_iov = vectorPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(controlSpace)

                var n = 0
                while true {
                    n = recvmsg(socket, &message, 0)
                    if n >= 0 { break }
                    if errno == EINTR { continue }
                    throw PassError.receiveFailed(errno: errno)
                }
                guard n > 0 else { throw PassError.peerClosed }
                received = n

                if message.msg_flags & MSG_CTRUNC != 0 {
                    truncated = true
                    return
                }
                // A control buffer shorter than one header means "no ancillary data", not an
                // error: the vast majority of frames carry no fd.
                guard message.msg_controllen >= socklen_t(length(payload: MemoryLayout<Int32>.size))
                else { return }
                let header = control.bindMemory(to: cmsghdr.self, capacity: 1)
                guard header.pointee.cmsg_level == SOL_SOCKET,
                      header.pointee.cmsg_type == SCM_RIGHTS
                else { return }
                descriptor = control.advanced(by: dataOffset())
                    .bindMemory(to: Int32.self, capacity: 1).pointee
            }
        }

        if truncated { throw PassError.controlTruncated }
        return (Array(payload.prefix(received)), descriptor)
    }
}
