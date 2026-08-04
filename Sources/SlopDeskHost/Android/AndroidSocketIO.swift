// AndroidSocketIO — blocking BSD-socket primitives for the Android bridge, and the one place that
// explains why this corner of hostd is not written in Network.framework like the rest of it.
//
// **Why not `NWListener`/`NWConnection` here.** Every other listener in hostd carries a MESSAGE
// protocol — the terminal wire, the inspector wire — where Network.framework's receive-a-complete-
// message callback is exactly the right shape. The Android bridge carries no message protocol after
// its first line: it is a byte pump between the client's socket and a socket `adb` forwarded from
// the device, and the two things it needs are the two things a callback chain makes awkward.
//
//  1. **Backpressure for free.** A blocking `write` that stalls stops the `read` above it, which
//     stops draining `adb`'s socket, which backs the pressure up into the device's encoder — the
//     same chain scrcpy itself relies on. An `NWConnection.send` completion chain buffers instead,
//     and a 2 Mbit/s stream to a client that has stopped reading grows without a bound until an
//     explicit credit scheme is written, which is more code than the pump.
//  2. **Connect-until-a-byte-arrives.** The `adb forward` tunnel accepts a TCP connection whether or
//     not anything is listening on the far side, so the only proof the device's server is up is a
//     byte read back from it (scrcpy's own `connect_and_read_byte`). That is a blocking retry loop
//     by nature.
//
// Everything here therefore runs on dedicated threads and blocks freely. Nothing on hostd's actors
// or queues calls into it.
//
// Hang-safety: unit tests never reach this file — the bridge's testable surface is its PARSERS
// (``AndroidDeviceCatalog``, ``AndroidBridgeRequest``).

import Foundation

/// A blocking TCP socket. Not `Sendable` by accident: a descriptor is handed to exactly one pump
/// thread, and ``close()`` is the only call the owning side makes from elsewhere.
final class AndroidSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    /// Latched so a double close cannot land on a descriptor the kernel has already reissued to
    /// something else — the classic way a byte pump starts writing into an unrelated file.
    private var isClosed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if !isClosed { Darwin.close(descriptor) }
    }

    /// Connects to `127.0.0.1:port`, or `nil` on failure. Loopback only — this dials the tunnel
    /// `adb` opened on this machine, never a remote address.
    static func connectLoopback(port: UInt16, timeout: TimeInterval = 2) -> AndroidSocket? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        var timeoutValue = timeval(
            tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000),
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return AndroidSocket(descriptor: fd)
    }

    /// Turns off Nagle. Set on the CONTROL leg: a 32-byte touch message that waits for a companion
    /// before leaving is a pointer that lags behind the finger, and coalescing buys nothing when the
    /// messages are already this small.
    func setNoDelay() {
        var enabled: Int32 = 1
        withDescriptor { setsockopt($0, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size)) }
    }

    /// Clears the receive timeout set at connect time. The dial needs one (a tunnel with nothing
    /// behind it must not park a thread forever); a live stream must NOT have one, or an idle device
    /// — measured at 547 B/s, with gaps of seconds between frames — reads as a dead socket.
    func clearReceiveTimeout() {
        var never = timeval(tv_sec: 0, tv_usec: 0)
        withDescriptor {
            setsockopt($0, SOL_SOCKET, SO_RCVTIMEO, &never, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    /// Reads exactly `count` bytes, or `nil` on EOF/error/timeout. Used only for the handshake,
    /// where the lengths are fixed and known.
    func readExactly(_ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer[filled...].withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return withDescriptor { Darwin.read($0, base, count - filled) }
            }
            if n <= 0 { return nil }
            filled += n
        }
        return Data(buffer)
    }

    /// Reads whatever is available, up to `capacity`. Empty result means end of stream.
    func read(upTo capacity: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let n = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return withDescriptor { Darwin.read($0, base, capacity) }
        }
        guard n > 0 else { return nil }
        return Data(buffer[0..<n])
    }

    /// Writes every byte, or returns `false`. A partial `write` is normal on a socket whose peer is
    /// slow; the loop is what makes this a pump rather than a lossy forwarder.
    @discardableResult
    func writeAll(_ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return false }
            while sent < data.count {
                let n = withDescriptor { write($0, base + sent, data.count - sent) }
                if n <= 0 {
                    // EINTR is a signal, not a failure — every other errno ends the pump.
                    if n < 0, errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }

    /// Shuts the socket down. Idempotent, and safe to call from a thread other than the pump's — a
    /// blocked `read` returns `0` as soon as the descriptor closes, which is how a session is
    /// torn down without a cancellation flag the pump would have to poll.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func withDescriptor<T>(_ body: (Int32) -> T) -> T {
        lock.lock()
        let fd = isClosed ? -1 : descriptor
        lock.unlock()
        return body(fd)
    }
}

/// A listening socket bound to `0.0.0.0`.
///
/// **No credential, by invariant** — every port hostd opens is protected by the WireGuard mesh and
/// nothing else (`docs/DECISIONS.md`: no app-layer crypto/auth). This one is no different, and it is
/// worth being explicit that the bridge behind it reaches `adb`: on a host whose mesh is configured
/// as documented that is the same trust boundary the terminal wire already sits behind.
final class AndroidListener: @unchecked Sendable {
    private let descriptor: Int32
    let port: UInt16

    /// Binds an ephemeral port (`0`) and starts listening, or returns `nil`.
    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            return nil
        }
        descriptor = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    /// Blocks until a client connects. `nil` once the listener is closed.
    func accept() -> AndroidSocket? {
        let fd = Darwin.accept(descriptor, nil, nil)
        guard fd >= 0 else { return nil }
        return AndroidSocket(descriptor: fd)
    }

    func close() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }
}
