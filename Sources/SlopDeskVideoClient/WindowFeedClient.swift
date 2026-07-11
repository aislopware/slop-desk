#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import SlopDeskVideoProtocol

/// One host answer to a `windowFeedSubscribe` renewal (docs/45): either "you're current" or a fully
/// assembled snapshot. `nil` at the call sites means the round timed out (old host / offline).
public enum WindowFeedAnswer: Equatable, Sendable {
    case current(generation: UInt32)
    case snapshot(generation: UInt32, records: [HostWindowRecord])
}

/// One client-side window-FEED subscribe round (docs/45 host-windows rail): the feed sibling of
/// ``VideoWindowDiscovery``. Acquires a transient lane on the SAME per-host shared UDP flow as
/// streaming, retransmits `windowFeedSubscribe(knownGeneration:)` until an answer resolves — the
/// 5-byte `windowFeedCurrent` ack, or a complete `windowFeedSnapshot` chunk sequence assembled by
/// the pure ``WindowFeedAssembler`` — then releases the lane. Never a `hello`, so the host never
/// mints a capture session. An old host (no feed support) never replies → `nil` → the rail shows
/// its unavailable state. Partial generations die with the round (`assembler` is round-local); the
/// NEXT renewal heals any loss from the host's cached chunks.
@preconcurrency
@MainActor
public enum WindowFeedRound {
    /// Runs one subscribe round. Returns `nil` on timeout / no registry / no host support.
    public static func subscribeOnce(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        knownGeneration: UInt32,
        retryInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(3),
    ) async -> WindowFeedAnswer? {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return nil }
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        defer { registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: acq.channelID) }

        let box = FeedAnswerBox()
        acq.flow.registerLane(
            channelID: acq.channelID,
            onMedia: { channel, payload in
                guard channel == .control, let msg = try? VideoControlMessage.decode(payload) else { return }
                switch msg {
                case let .windowFeedCurrent(generation):
                    box.deliver(.current(generation: generation))
                case let .windowFeedSnapshot(generation, chunkIndex, chunkCount, records):
                    box.fold(
                        generation: generation, chunkIndex: chunkIndex, chunkCount: chunkCount,
                        records: records,
                    )
                default:
                    return
                }
            },
            onCursor: { _ in },
        )

        let request = VideoControlMessage.windowFeedSubscribe(knownGeneration: knownGeneration).encode()
        let flow = acq.flow
        let channelID = acq.channelID
        // Retransmit until an answer resolves or the deadline passes (UDP — the request OR any reply
        // datagram can drop), then resolve the waiter so an unanswered round returns nil, not a hang.
        let sender = Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline, !box.hasAnswer, !Task.isCancelled {
                flow.send(request, on: .control, channelID: channelID)
                try? await Task.sleep(for: retryInterval)
            }
            box.finish()
        }
        let answer = await box.firstAnswer()
        sender.cancel()
        return answer
    }
}

/// Thread-safe one-shot box correlating the feed answer (delivered off the flow's receive queue)
/// with the awaiting round — ``VideoWindowDiscovery``'s `ReplyBox` shape, plus the chunk assembler
/// folded in under the same lock (chunks arrive on the receive queue; the assembler is not Sendable-
/// shared anywhere else). Resolved exactly once, by the first complete answer or by `finish()`.
private final class FeedAnswerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler = WindowFeedAssembler()
    private var answer: WindowFeedAnswer?
    private var cont: CheckedContinuation<WindowFeedAnswer?, Never>?
    private var resolved = false

    var hasAnswer: Bool { lock.withLock { answer != nil } }

    /// A complete answer arrived (`windowFeedCurrent`, or the fold below completing a generation).
    /// Only the first sticks (UDP duplication).
    func deliver(_ value: WindowFeedAnswer) {
        lock.lock()
        if answer == nil { answer = value }
        guard !resolved, let c = cont else { lock.unlock()
            return
        }
        resolved = true
        cont = nil
        let a = answer
        lock.unlock()
        c.resume(returning: a)
    }

    /// Folds one snapshot chunk; completing a generation resolves the round with that snapshot.
    func fold(generation: UInt32, chunkIndex: UInt8, chunkCount: UInt8, records: [HostWindowRecord]) {
        lock.lock()
        let complete = assembler.fold(
            generation: generation, chunkIndex: chunkIndex, chunkCount: chunkCount, records: records,
        )
        lock.unlock()
        if let complete {
            deliver(.snapshot(generation: complete.generation, records: complete.records))
        }
    }

    /// Timeout: resolve the waiter with whatever resolved earlier (possibly nothing). No-op once done.
    func finish() {
        lock.lock()
        guard !resolved, let c = cont else { lock.unlock()
            return
        }
        resolved = true
        cont = nil
        let a = answer
        lock.unlock()
        c.resume(returning: a)
    }

    /// Awaits the first answer (or `finish()`). Returns immediately if already resolved.
    func firstAnswer() async -> WindowFeedAnswer? {
        await withCheckedContinuation { (c: CheckedContinuation<WindowFeedAnswer?, Never>) in
            lock.lock()
            if resolved || answer != nil {
                resolved = true
                let a = answer
                lock.unlock()
                c.resume(returning: a)
                return
            }
            cont = c
            lock.unlock()
        }
    }
}
#endif
