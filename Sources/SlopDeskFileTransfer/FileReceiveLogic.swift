import Foundation

/// The pure, headless-testable host-side receive state machine for one PATH-4 connection.
///
/// It owns NO sockets and NO filesystem — it consumes decoded ``FileTransferMessage`` values and
/// emits ``FileReceiveEffect`` values the server executes (open a sink, write bytes, finalize, abort,
/// or send a reply). All the protocol correctness and byte accounting lives here so it can be driven
/// deterministically in a unit test; the impure edges (NWListener, disk) are the server's job.
///
/// Validate-then-drop throughout: a chunk before its offer, a body overrun past the offered size, an
/// over-cap offer, a duplicate/unknown transferId, or an unsanitizable name each produce a `failed`
/// reply + an abort of any partial state — never a trap, never an unbounded allocation.
public struct FileReceiveLogic {
    /// The per-transfer bookkeeping between an accepted offer and its finish.
    private struct Transfer {
        let sanitizedName: String
        let expectedSize: UInt64
        var receivedBytes: UInt64
    }

    /// Whether the client has completed the version handshake. Chunks/offers before `hello` are
    /// ignored except to fail — but in practice the client always sends `hello` first.
    private var didHello = false
    private var transfers: [UInt32: Transfer] = [:]

    public init() {}

    /// Advances the machine for one inbound message, returning the effects to execute in order.
    public mutating func handle(_ message: FileTransferMessage) -> [FileReceiveEffect] {
        switch message {
        case let .hello(version):
            let accepted = version == FileTransferProtocolConstants.version
            didHello = accepted
            return [.reply(.helloAck(accepted: accepted))]

        case let .offer(transferId, fileSize, name):
            return handleOffer(transferId: transferId, fileSize: fileSize, name: name)

        case let .chunk(transferId, data):
            return handleChunk(transferId: transferId, data: data)

        case let .finish(transferId):
            return handleFinish(transferId: transferId)

        case let .cancel(transferId):
            guard transfers.removeValue(forKey: transferId) != nil else { return [] }
            return [.abort(transferId: transferId)]

        // Host→client messages never arrive on the host receive path — ignore inertly.
        case .helloAck,
             .accept,
             .complete,
             .failed:
            return []
        }
    }

    // MARK: - Handlers

    private mutating func handleOffer(transferId: UInt32, fileSize: UInt64, name: String) -> [FileReceiveEffect] {
        guard didHello else {
            return [.reply(.failed(transferId: transferId, reason: "no handshake"))]
        }
        guard transfers[transferId] == nil else {
            return [.reply(.failed(transferId: transferId, reason: "duplicate transfer id"))]
        }
        guard fileSize <= FileTransferProtocolConstants.maxTransferBytes else {
            return [.reply(.failed(transferId: transferId, reason: "file too large"))]
        }
        guard let safeName = FileNameSanitizer.sanitize(name) else {
            return [.reply(.failed(transferId: transferId, reason: "invalid file name"))]
        }
        transfers[transferId] = Transfer(sanitizedName: safeName, expectedSize: fileSize, receivedBytes: 0)
        return [
            .open(transferId: transferId, name: safeName, size: fileSize),
            .reply(.accept(transferId: transferId)),
        ]
    }

    private mutating func handleChunk(transferId: UInt32, data: Data) -> [FileReceiveEffect] {
        guard var transfer = transfers[transferId] else {
            // A chunk with no live offer: nothing to abort, just refuse it.
            return [.reply(.failed(transferId: transferId, reason: "no such transfer"))]
        }
        let newTotal = transfer.receivedBytes + UInt64(data.count)
        guard newTotal <= transfer.expectedSize else {
            transfers.removeValue(forKey: transferId)
            return [
                .abort(transferId: transferId),
                .reply(.failed(transferId: transferId, reason: "body exceeds offered size")),
            ]
        }
        transfer.receivedBytes = newTotal
        transfers[transferId] = transfer
        return [.write(transferId: transferId, data: data)]
    }

    private mutating func handleFinish(transferId: UInt32) -> [FileReceiveEffect] {
        guard let transfer = transfers[transferId] else {
            return [.reply(.failed(transferId: transferId, reason: "no such transfer"))]
        }
        guard transfer.receivedBytes == transfer.expectedSize else {
            transfers.removeValue(forKey: transferId)
            return [
                .abort(transferId: transferId),
                .reply(.failed(transferId: transferId, reason: "incomplete body")),
            ]
        }
        transfers.removeValue(forKey: transferId)
        return [
            .finalize(transferId: transferId),
            .reply(.complete(transferId: transferId)),
        ]
    }
}

/// Side effects the ``FileReceiveLogic`` asks the server to perform, in emission order.
public enum FileReceiveEffect: Equatable, Sendable {
    /// Open a destination sink for `transferId` (create the temp file).
    case open(transferId: UInt32, name: String, size: UInt64)
    /// Append `data` to the sink for `transferId`.
    case write(transferId: UInt32, data: Data)
    /// The body is complete — move the temp file into place.
    case finalize(transferId: UInt32)
    /// Discard any partial sink for `transferId` (delete the temp file).
    case abort(transferId: UInt32)
    /// Send this message back to the client.
    case reply(FileTransferMessage)
}
