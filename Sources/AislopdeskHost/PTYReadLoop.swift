import Darwin
import Foundation

/// The host **output path**: a tight blocking `read()` loop on the PTY master fd,
/// running at `QOS_CLASS_USER_INTERACTIVE`, that hands each chunk **immediately** to a
/// sink — no intermediate ring buffer (`DECISIONS.md` "No-buffer relay"; the only
/// buffer in the system is the transport's `ReplayBuffer`).
///
/// ## Backpressure / drain-pause gate (the load-bearing contract)
/// The relay asserts a pause when the per-channel output queue crosses the bounded-queue
/// high-water mark (`MuxChannelSession`'s ``PausableQueueGate`` / `BoundedQueuePolicy`).
/// When paused, this loop **stops issuing `read()`** on the master fd. Because nothing
/// drains the master, the kernel PTY buffer fills and **backpressures the shell** — no
/// output is produced that we would have to drop (the never-drop invariant). When the
/// pause deasserts (client returns / acks drain the backlog) the loop resumes reading.
///
/// The gate is implemented with an `NSCondition`: ``setPaused(_:)`` is called from the
/// transport-driven side; the read loop blocks on the condition *before* each `read()`
/// while paused, so a paused loop performs zero syscalls on the master and the kernel
/// does the backpressuring. ``stop()`` also wakes the loop so a terminating session
/// does not hang on the gate.
///
/// `@unchecked Sendable`: all mutable state (`paused`, `stopped`) is guarded by the
/// `NSCondition`'s lock; `fd` is immutable.
public final class PTYReadLoop: @unchecked Sendable {
    /// The chunk size for each `read()`. 32 KiB: HALF the (latency-sized) bounded-queue
    /// capacity (`MuxFlowControl.hostQueueCapacityBytes`, 64 KiB), so the gate's worst
    /// overshoot is capacity + one read (~96 KiB) instead of capacity + 128 KiB — a
    /// 128 KiB read against a 64 KiB bound would pause the loop on EVERY flood chunk and
    /// half-defeat the latency sizing. Floods drain at the same throughput (the syscall
    /// count rises, but the wire — not read(2) — is the bottleneck).
    public static let readChunkSize = 32 * 1024

    private let fd: Int32
    private let onChunk: @Sendable (Data) -> Void
    private let onEOF: @Sendable () -> Void
    private let queue: DispatchQueue

    private let gate = NSCondition()
    private var paused = false
    private var stopped = false
    private var started = false

    /// - Parameters:
    ///   - fd: the PTY master fd (must have `O_NONBLOCK` cleared — see
    ///     ``PTYProcess/setBlocking(_:)``).
    ///   - onChunk: called on the read-loop queue with each non-empty chunk. The
    ///     callback must hand the bytes to the transport without retaining a copy past
    ///     its return (no-buffer relay). Bridging into an actor is the caller's job.
    ///   - onEOF: called once when the master reaches EOF / errors (the child closed
    ///     its tty — typically it has exited).
    @preconcurrency
    public init(
        fd: Int32,
        onChunk: @escaping @Sendable (Data) -> Void,
        onEOF: @escaping @Sendable () -> Void,
    ) {
        self.fd = fd
        self.onChunk = onChunk
        self.onEOF = onEOF
        queue = DispatchQueue(label: "aislopdesk.host.pty.read", qos: .userInteractive)
    }

    /// Starts the read loop on the user-interactive queue. Idempotent.
    public func start() {
        gate.lock()
        guard !started, !stopped else { gate.unlock()
            return
        }
        started = true
        gate.unlock()
        queue.async { [weak self] in self?.runLoop() }
    }

    /// Pauses (`true`) or resumes (`false`) the read loop. Driven by `MuxChannelSession`'s
    /// ``PausableQueueGate``. Resuming wakes a blocked loop.
    public func setPaused(_ value: Bool) {
        gate.lock()
        paused = value
        gate.signal()
        gate.unlock()
    }

    /// Stops the loop permanently and wakes it if it is parked on the gate.
    public func stop() {
        gate.lock()
        stopped = true
        gate.signal()
        gate.unlock()
    }

    // MARK: Loop

    private func runLoop() {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Self.readChunkSize, alignment: MemoryLayout<UInt8>.alignment,
        )
        defer { buffer.deallocate() }

        while true {
            // Gate: park (zero master syscalls) while paused so the kernel PTY buffer
            // fills and backpressures the shell. Wake on resume or stop.
            gate.lock()
            while paused, !stopped {
                gate.wait()
            }
            if stopped {
                gate.unlock()
                return
            }
            gate.unlock()

            let n = read(fd, buffer, Self.readChunkSize)

            if n > 0 {
                // Copy out of the reusable buffer into a Data the sink owns. This is the
                // only copy; there is no ring buffer between here and sendOutput.
                let chunk = Data(bytes: buffer, count: n)
                onChunk(chunk)
                continue
            }

            if n == 0 {
                // EOF: child closed the slave (exited).
                onEOF()
                return
            }

            // n < 0
            if errno == EINTR { continue }
            // EIO is the normal "slave side hung up" result on macOS when the child
            // exits — treat any other error as EOF too.
            onEOF()
            return
        }
    }
}
