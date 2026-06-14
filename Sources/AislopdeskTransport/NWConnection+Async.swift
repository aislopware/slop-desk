import AislopdeskProtocol
import Foundation
import Network

/// Async bridges over the raw `NWConnection` callback API, used only during the
/// pre-framing association/handshake phase (reading the fixed-size preamble and
/// writing raw preamble bytes). Once the preamble is consumed, the connection is
/// handed to ``NWMuxByteLink`` which owns all further I/O.
extension NWConnection {
    /// Starts the connection on `queue` and suspends until it reaches `.ready`.
    /// Throws ``AislopdeskTransportError/connectionFailed(_:)`` if it fails/cancels first.
    ///
    /// Cancellation-aware: an unreachable/refused endpoint parks `NWConnection` in
    /// `.waiting` indefinitely (waitForConnectivity), which is NOT a terminal state, so
    /// without this the readiness continuation would never resume. If the awaiting task
    /// is cancelled (e.g. a handshake-timeout fires), we cancel the underlying connection —
    /// which drives it to `.cancelled` — and resume the continuation, so the continuation
    /// is never leaked and the socket is torn down.
    func startAndWaitReady(on queue: DispatchQueue) async throws {
        // A small box so the state handler and the continuation share completion state
        // without racing: only the first terminal transition resumes.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var resumed = false
            func tryResume(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                body()
            }
        }
        let box = Box()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        box.tryResume { continuation.resume() }
                    case let .failed(error):
                        box.tryResume {
                            continuation
                                .resume(throwing: AislopdeskTransportError.connectionFailed(String(describing: error)))
                        }
                    case .cancelled:
                        box.tryResume {
                            continuation.resume(throwing: AislopdeskTransportError.connectionFailed("cancelled"))
                        }
                    default:
                        break
                    }
                }
                if Task.isCancelled {
                    // Cancelled before we even installed the handler / started: bail out
                    // and let the cancellation handler cancel the connection.
                    box.tryResume { continuation.resume(throwing: CancellationError()) }
                    return
                }
                start(queue: queue)
            }
        } onCancel: {
            // Cancelling drives the connection to `.cancelled`, which the state handler
            // turns into a thrown error (if it hasn't already resumed).
            cancel()
        }
        // Detach the temporary handler; NWMuxByteLink installs its own.
        stateUpdateHandler = nil
    }

    /// Writes raw bytes (used for the association preamble) and suspends until the OS
    /// accepts them.
    func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AislopdeskTransportError.sendFailed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads **exactly** `count` bytes (used for the fixed-size association preamble),
    /// suspending until they arrive. Throws if the peer closes first or on I/O error.
    ///
    /// `NWConnection.receive(minimumIncompleteLength:maximumLength:)` with both set to
    /// `count` returns exactly `count` bytes in one shot once they are available, so a
    /// single call suffices for the small fixed preambles.
    func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: AislopdeskTransportError.receiveFailed(String(describing: error)))
                    return
                }
                if let data, data.count == count {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation
                        .resume(throwing: AislopdeskTransportError.connectionFailed("peer closed during preamble"))
                    return
                }
                // Short read without completion shouldn't happen given min==count, but be safe.
                continuation.resume(throwing: AislopdeskTransportError.receiveFailed("short preamble read"))
            }
        }
    }
}
