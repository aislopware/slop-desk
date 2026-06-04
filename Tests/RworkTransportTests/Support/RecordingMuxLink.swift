import Foundation
import RworkProtocol
@testable import RworkTransport

/// A spy ``MuxByteLink`` that wraps an underlying link and CLASSIFIES every frame written through
/// it, so a test can assert WHICH link a given mux frame (e.g. a `windowAdjust` grant) was emitted
/// on — the exact, bounded, deadlock-free assertion FIX #2 needs.
///
/// The mux owner writes one whole `MuxEnvelopeCodec`-encoded frame per `send` (it calls
/// `link.send(MuxEnvelopeCodec.encode(frame))`), so feeding each `send`'s bytes into a
/// ``MuxFrameDecoder`` recovers the frame type. We only need to COUNT `windowAdjust` frames, but the
/// decoder is robust to chunk boundaries anyway. Receive + close are pure pass-throughs.
final class RecordingMuxLink: MuxByteLink, @unchecked Sendable {
    private let underlying: any MuxByteLink
    private let lock = NSLock()
    private var decoder = MuxFrameDecoder()
    private var windowAdjusts = 0

    init(wrapping underlying: any MuxByteLink) {
        self.underlying = underlying
    }

    /// Number of `windowAdjust` frames written through this link so far.
    var windowAdjustCount: Int { lock.lock(); defer { lock.unlock() }; return windowAdjusts }

    var receiveChunks: AsyncThrowingStream<Data, Error> { underlying.receiveChunks }

    func send(_ data: Data) async throws {
        classify(data) // synchronous critical section (no lock held across the await below)
        try await underlying.send(data)
    }

    /// Feeds `data` into the per-link frame decoder and counts `windowAdjust` frames. A malformed
    /// sequence (shouldn't happen — the owner writes whole frames) just stops counting; never fails.
    private func classify(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        decoder.append(data)
        while let frame = (try? decoder.nextFrame()) ?? nil {
            if case .windowAdjust = frame { windowAdjusts += 1 }
        }
    }

    func close() async {
        await underlying.close()
    }
}
