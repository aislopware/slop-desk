import Foundation

/// PATH 4 — the dedicated file-transfer channel's wire vocabulary.
///
/// A drag-and-drop upload onto the desktop window rides its OWN reliable TCP connection, never the
/// terminal mux (a bulk body sharing the PTY data channel would stall keystrokes/resizes) and never
/// the lossy UDP video path (FEC recovers frames, not files). This is a genuinely 4th path — it
/// shares no `WireMessage`/`FrameDecoder`/`Channel` with the other three, per the "do not merge"
/// convention. Frame shape on the wire is the house style: `[UInt32 BE length][UInt8 type][body]`.
///
/// Version 1 only, no negotiation: the client opens with `hello(version:)` and the host answers
/// `helloAck(accepted:)` — a mismatch is rejected outright, never renegotiated.
public enum FileTransferMessage: Equatable, Sendable {
    // MARK: Client → host

    /// Version pin, first frame the client sends. `version` must equal ``fileTransferVersion``.
    case hello(version: UInt8)
    /// Announces a file: a client-scoped `transferId`, the total `fileSize`, and the display `name`
    /// (untrusted — the host sanitizes it before it touches the filesystem).
    case offer(transferId: UInt32, fileSize: UInt64, name: String)
    /// A body chunk for `transferId`. TCP already orders bytes; there is no per-chunk sequence.
    case chunk(transferId: UInt32, data: Data)
    /// The client has sent the whole body for `transferId`.
    case finish(transferId: UInt32)
    /// The client abandons `transferId` (e.g. a read error on its side).
    case cancel(transferId: UInt32)

    // MARK: Host → client

    /// Answer to `hello`: `accepted == false` on a version mismatch (the client then closes).
    case helloAck(accepted: Bool)
    /// The host opened a destination for `transferId` and is ready for chunks.
    case accept(transferId: UInt32)
    /// The host wrote the whole body and moved the file into place.
    case complete(transferId: UInt32)
    /// The transfer failed; `reason` is a short human string for a toast (never a path).
    case failed(transferId: UInt32, reason: String)
}

public enum FileTransferProtocolConstants {
    /// The only supported version (no negotiation, per the house rule).
    public static let version: UInt8 = 1

    /// Body-payload cap per frame, matching the other paths' 16 MiB ceiling. A length prefix over
    /// this is rejected before any allocation (never trust an attacker-chosen size).
    public static let maxFramePayloadLength = 16 * 1024 * 1024

    /// Upload body chunk size the client sends (well under ``maxFramePayloadLength``). 256 KiB keeps
    /// per-chunk latency low while amortizing framing overhead.
    public static let chunkByteCount = 256 * 1024

    /// Hard ceiling on a single offered file. An offer larger than this is rejected outright — a
    /// guard against a hostile or fat-fingered size, not a real limit anyone hits (20 GiB).
    public static let maxTransferBytes: UInt64 = 20 * 1024 * 1024 * 1024
}

/// The one supported version constant, re-exported at the module root for call sites.
public let fileTransferVersion = FileTransferProtocolConstants.version
