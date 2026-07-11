#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import SlopDeskVideoProtocol

/// One host answer on the window-feed lane (docs/45): either "you're current" or a fully assembled
/// snapshot. Arrives in response to a renewal AND — Phase 2 — as an unsolicited push on a
/// generation bump.
public enum WindowFeedAnswer: Equatable, Sendable {
    case current(generation: UInt32)
    case snapshot(generation: UInt32, records: [HostWindowRecord])
}

/// The client's PERSISTENT window-feed lane (docs/45): ONE collision-safe channelID held for the
/// feed's whole active lifetime, so Phase-2 pushes between renewals always have a registered
/// handler to land on. Rides the SAME per-host shared UDP flow as streaming
/// (``VideoConnectionRegistry``); sends `windowFeedSubscribe(knownGeneration:)` renewals — never a
/// `hello`, so the host never mints a capture session. Chunks assemble in the pure
/// ``WindowFeedAssembler`` (bounded partials; a generation lost to UDP weather heals at the next
/// renewal from the host's cached chunks). `close()` releases the lane; the host's subscriber TTL
/// (3 missed renewals) retires it server-side.
@preconcurrency
@MainActor
public final class WindowFeedChannel {
    private let registry: VideoConnectionRegistry
    private let host: String
    private let mediaPort: UInt16
    private let cursorPort: UInt16
    private let channelID: UInt32
    private let flow: any VideoMuxClientFlowing
    private let box: WindowFeedPushBox
    private var closed = false

    /// Opens the lane and registers the answer handler. Returns `nil` when no registry is installed
    /// (headless / no video module) — the feature is then inert.
    @preconcurrency
    public init?(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        onAnswer: @escaping @MainActor (WindowFeedAnswer) -> Void,
    ) {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return nil }
        self.registry = registry
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        channelID = acq.channelID
        flow = acq.flow
        box = WindowFeedPushBox(onAnswer: onAnswer)
        let box = box
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
    }

    /// Fires one `windowFeedSubscribe` renewal (the poll + subscription renewal + resync anchor).
    public func send(knownGeneration: UInt32) {
        guard !closed else { return }
        flow.send(
            VideoControlMessage.windowFeedSubscribe(knownGeneration: knownGeneration).encode(),
            on: .control,
            channelID: channelID,
        )
    }

    /// Releases the lane (idempotent). The host reaps the subscription after 3 missed renewals.
    public func close() {
        guard !closed else { return }
        closed = true
        box.invalidate()
        registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: channelID)
    }
}

/// Thread-safe fold-and-forward box: chunks arrive on the flow's receive queue, assemble under the
/// lock, and complete answers hop to the MainActor callback. Long-lived (unlike the one-shot
/// discovery `ReplyBox`) — pushes keep arriving for the lane's whole lifetime; `invalidate()` stops
/// forwarding after `close()` so a late datagram can't call into a torn-down feed.
private final class WindowFeedPushBox: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler = WindowFeedAssembler()
    private var onAnswer: (@MainActor (WindowFeedAnswer) -> Void)?

    init(onAnswer: @escaping @MainActor (WindowFeedAnswer) -> Void) {
        self.onAnswer = onAnswer
    }

    func deliver(_ answer: WindowFeedAnswer) {
        lock.lock()
        let sink = onAnswer
        lock.unlock()
        guard let sink else { return }
        Task { @MainActor in sink(answer) }
    }

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

    func invalidate() {
        lock.lock()
        onAnswer = nil
        lock.unlock()
    }
}
#endif
