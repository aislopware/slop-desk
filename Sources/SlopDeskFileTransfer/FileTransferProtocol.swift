import CSlopDeskFFI
import Foundation

/// PATH 4 — the dedicated file-transfer channel's wire vocabulary, **client end**.
///
/// A drag-and-drop upload onto the desktop window rides its OWN reliable TCP connection, never the
/// terminal mux (a bulk body sharing the PTY data channel would stall keystrokes/resizes) and never
/// the lossy UDP video path (FEC recovers frames, not files). This is a genuinely 4th path — it
/// shares no `WireMessage`/`FrameDecoder`/`Channel` with the other three, per the "do not merge"
/// convention. Frame shape on the wire is the house style: `[UInt32 BE length][UInt8 type][body]`.
///
/// Version 1 only, no negotiation: the client opens with `hello(version:)` and the host answers
/// `helloAck(accepted:)` — a mismatch is rejected outright, never renegotiated.
///
/// ## Two enums, because this is one END of the protocol
/// The receiving end is `slopdesk-dropd` (`rust/slopdesk-dropd`, `docs/53`), which decodes
/// ``FileTransferRequest`` and encodes ``FileTransferReply``. This side does the mirror and nothing
/// else: there is no Swift encoder for a reply and no Swift decoder for a request, because that
/// would be dropd's job written a second time in a second language. A protocol's two ENDS are what
/// the one-implementation rule allows; the same capability twice is not.
public enum FileTransferRequest: Equatable, Sendable {
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
}

/// The host→client half of PATH 4: what `slopdesk-dropd` says back.
public enum FileTransferReply: Equatable, Sendable {
    /// Answer to `hello`: `accepted == false` on a version mismatch (the client then closes).
    case helloAck(accepted: Bool)
    /// The host opened a destination for `transferId` and is ready for chunks.
    case accept(transferId: UInt32)
    /// The host wrote the whole body and moved the file into place.
    case complete(transferId: UInt32)
    /// The transfer failed; `reason` is a short human string for a toast (never a path).
    case failed(transferId: UInt32, reason: String)
}

/// The four numbers PATH 4 is pinned to, READ from the crate that enforces them.
///
/// None of them is respelled here. A cap the client believes and a cap the host enforces that drift
/// apart is a class of bug that no test on either side alone can see, so there is one spelling and
/// this is a window onto it: `rust/slopdesk-dropd`'s `VERSION`, `MAX_FRAME_PAYLOAD`,
/// `CHUNK_BYTE_COUNT` and `MAX_TRANSFER_BYTES`.
public enum FileTransferProtocolConstants {
    /// The only supported version (no negotiation, per the house rule).
    public static let version = UInt8(truncatingIfNeeded: slopdesk_drop_constant(0))

    /// Body-payload cap per frame, matching the other paths' 16 MiB ceiling. A length prefix over
    /// this is rejected before any allocation (never trust an attacker-chosen size).
    public static let maxFramePayloadLength = Int(slopdesk_drop_constant(1))

    /// Upload body chunk size the client sends (well under ``maxFramePayloadLength``). 256 KiB keeps
    /// per-chunk latency low while amortizing framing overhead.
    public static let chunkByteCount = Int(slopdesk_drop_constant(2))

    /// Hard ceiling on a single offered file. The HOST enforces it; this window exists so the client
    /// can report a hopeless file without a round trip.
    public static let maxTransferBytes = UInt64(slopdesk_drop_constant(3))
}

/// The one supported version constant, re-exported at the module root for call sites.
public let fileTransferVersion = FileTransferProtocolConstants.version
