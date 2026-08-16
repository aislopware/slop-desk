import Foundation

/// How a loop that must move EVERY byte ended — the same three answers for `write(2)` and for
/// `read(2)`, which is why the type is named for neither.
///
/// The cases are what the thirteen copies of those loops each needed some subset of: the six that
/// dropped their failure needed only `.complete`, and the ones that report needed to tell a peer
/// that closed from a descriptor that failed. The distinction comes back; the REACTION stays with
/// the caller, because dropping a control reply and dropping a frame are different contracts.
public enum FileDescriptorOutcome: Sendable, Equatable {
    /// Every byte moved.
    case complete
    /// The syscall returned 0 with bytes still owed — the peer is gone. `transferred` is what moved
    /// before that.
    case peerClosed(transferred: Int)
    /// The syscall failed with `errno`, after `transferred` bytes.
    case failed(errno: Int32, transferred: Int)
}

/// `write(2)` until the whole buffer is out, folding in the two things every caller of `write` has
/// to fold in and half of them forget: EINTR is a retry, not a failure, and a short write is normal.
///
/// ELEVEN copies of this loop, not the six the first sweep found: four were named `writeAll`, two
/// more were inline closures inside the agent control listener, and the rest were spelled out at
/// the call site returning `Bool`, setting an `ok` flag, or calling `die`.
///
/// It lives in this leaf because this is where the Swift side's raw descriptors already live — raw
/// mode, termios, `TIOCSWINSZ` — and it had SIX copies before it had one: the agent control
/// listener, the client control server, the mux channel session, `slopdesk-client`'s stdout path,
/// the supervisor's frame writer and the screend client. Four returned silently on failure and two
/// threw; the difference is a real contract (a control response that cannot be delivered is dropped;
/// a supervisor frame that cannot be delivered must be reported), so it survives as the OUTCOME the
/// caller reads rather than as six loops.
///
/// Not a Rust port, and this is the one place that argument does not carry: the loop has no policy
/// in it, every caller already owns the descriptor, and routing each control-response write through
/// the boundary would add marshalling to a call whose entire cost is the syscall.
public enum FileDescriptorWrite {
    /// Writes every byte of `buffer` to `fd`.
    @discardableResult
    public static func all(fd: Int32, _ buffer: UnsafeRawBufferPointer) -> FileDescriptorOutcome {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return .complete }
        var offset = 0
        while offset < buffer.count {
            let n = write(fd, base + offset, buffer.count - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n < 0 {
                if errno == EINTR { continue }
                return .failed(errno: errno, transferred: offset)
            }
            return .peerClosed(transferred: offset)
        }
        return .complete
    }

    /// Writes every byte of `data` to `fd`.
    @discardableResult
    public static func all(fd: Int32, _ data: Data) -> FileDescriptorOutcome {
        data.withUnsafeBytes { all(fd: fd, $0) }
    }

    /// Writes every byte of `bytes` to `fd`.
    @discardableResult
    public static func all(fd: Int32, _ bytes: [UInt8]) -> FileDescriptorOutcome {
        bytes.withUnsafeBytes { all(fd: fd, $0) }
    }
}

/// `read(2)` until exactly `count` bytes have arrived — the mirror of ``FileDescriptorWrite``, and
/// duplicated for the same reason: the supervisor's frame reader and the screend client each spelled
/// it, folding in the same EINTR retry and the same "a short read is normal, an EOF mid-frame is
/// not". Both must REPORT — a frame half-read is a lost boundary, not a dropped message — and they
/// spell that report with different error types, so the outcome comes back and the reaction stays
/// with the lane.
public enum FileDescriptorRead {
    /// Fills `count` bytes, or says why it could not.
    ///
    /// `.peerClosed` is `read` returning 0 with bytes still owed: the peer died holding the rest of
    /// a frame, which is a different fact from an idle socket and is why this is not a plain
    /// `Optional`.
    public static func exactly(fd: Int32, count: Int) -> (bytes: [UInt8], outcome: FileDescriptorOutcome) {
        var buffer = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return (buffer, .complete) }
        var outcome = FileDescriptorOutcome.complete
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < count {
                let n = read(fd, base + offset, count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    outcome = .failed(errno: errno, transferred: offset)
                    return
                }
                outcome = .peerClosed(transferred: offset)
                return
            }
        }
        return (buffer, outcome)
    }
}
