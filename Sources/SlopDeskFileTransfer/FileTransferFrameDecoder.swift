import Foundation

/// Incremental splitter that turns arbitrary TCP chunks into whole ``FileTransferMessage`` values —
/// the PATH-4 analogue of `MuxFrameDecoder`, deliberately its own type (the three-paths-share
/// -nothing rule) though it follows the identical `[UInt32 BE length][payload]` streaming shape:
/// buffer-append + advancing read cursor + lazy head compaction + poison-on-fault.
///
/// A partial frame is NOT an error — ``nextMessage()`` returns `nil` and waits for more bytes. A
/// decode fault (oversize length, malformed payload) POISONS the decoder: the byte boundary for the
/// whole stream is lost, so every later byte is untrustworthy — further ``append(_:)`` is dropped and
/// ``nextMessage()`` rethrows the original fault (fail-stop, never resync onto attacker bytes).
///
/// Value type, intentionally NOT `Sendable`: it holds mutable buffer state for a single per-connection
/// receive loop. One decoder per physical connection.
public struct FileTransferFrameDecoder {
    private static let prefixLength = 4
    private static let compactionThreshold = 64 * 1024

    private var buffer = Data()
    private var readOffset = 0
    private var fault: Error?

    public init() {}

    /// Appends a freshly received chunk. A no-op once poisoned (the buffer was cleared at the fault,
    /// so a peer holding the socket open cannot grow it without bound).
    public mutating func append(_ data: Data) {
        guard fault == nil else { return }
        buffer.append(data)
    }

    /// Test-only: buffered byte count — asserts a poisoned decoder cannot be grown further.
    var bufferedByteCountForTesting: Int { buffer.count }

    /// Returns the next complete message, or `nil` if a full frame is not yet buffered.
    ///
    /// - Throws: ``FileTransferFrameDecoderError/frameTooLarge(_:)`` if a length prefix exceeds
    ///   ``FileTransferProtocolConstants/maxFramePayloadLength``, or any ``FileTransferCodec/DecodeError``
    ///   from a malformed payload.
    public mutating func nextMessage() throws -> FileTransferMessage? {
        if let fault { throw fault }

        let available = buffer.count - readOffset
        guard available >= Self.prefixLength else {
            compactConsumed()
            return nil
        }

        let payloadLength = Int(readPrefix())
        guard payloadLength <= FileTransferProtocolConstants.maxFramePayloadLength else {
            throw poison(FileTransferFrameDecoderError.frameTooLarge(payloadLength))
        }

        let frameLength = Self.prefixLength + payloadLength
        guard available >= frameLength else {
            compactConsumed()
            return nil
        }

        let base = buffer.startIndex + readOffset
        let payloadStart = base + Self.prefixLength
        let payload = Data(buffer[payloadStart..<base + frameLength])
        readOffset += frameLength
        if readOffset >= Self.compactionThreshold { compactConsumed() }

        do {
            return try FileTransferCodec.decodePayload(payload)
        } catch {
            throw poison(error)
        }
    }

    private mutating func poison(_ error: Error) -> Error {
        fault = error
        buffer.removeAll(keepingCapacity: false)
        readOffset = 0
        return error
    }

    private mutating func compactConsumed() {
        guard readOffset > 0 else { return }
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + readOffset)
        readOffset = 0
    }

    private func readPrefix() -> UInt32 {
        let base = buffer.startIndex + readOffset
        var value: UInt32 = 0
        for i in 0..<Self.prefixLength {
            value = (value << 8) | UInt32(buffer[base + i])
        }
        return value
    }
}

public enum FileTransferFrameDecoderError: Error, Equatable, Sendable {
    /// A length prefix exceeded the frame-payload cap — rejected before allocating or waiting.
    case frameTooLarge(Int)
}
