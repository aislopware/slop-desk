import CSlopDeskFFI
import Foundation
import SlopDeskTTY

/// The framing for the `slopdesk-superd` ↔ `slopdesk-hostd` control socket.
///
/// ```text
/// <1 byte tag> <4 bytes big-endian length> <length bytes body>
/// ```
///
/// ## Why the layout is not spelled here any more
/// It was, and superd spelled it too: this file's doc comment and
/// `rust/slopdesk-superd/src/frame.rs`'s module comment each opened by describing the other as a
/// mirror. Two hand-written spellings of one byte layout, agreeing by inspection, in the one place
/// where a disagreement shows up as a DESYNCHRONISED SOCKET rather than as a wrong value.
///
/// `slopdesk-superwire` is the one spelling now. What stays here is this side's I/O lane —
/// `recvmsg` with `SCM_RIGHTS`, the write-until-gone loop, the read-exactly loop — because the
/// descriptor has to land in THIS process, and because that lane already has a contract of its own.
///
/// ## Why the tag byte exists
/// `SCM_RIGHTS` ancillary data is delivered to the **first `recvmsg` that reads any byte of the
/// matching `sendmsg`**. On a `SOCK_STREAM` socket a multi-byte header can come up short, which
/// would leave the fd already adopted while the header is still half-read — a state with no
/// correct recovery. A one-byte read cannot be short, so the fd rides the tag and the rest of the
/// frame is plain stream bytes. This is the whole reason the header is not simply a length.
public enum SupervisorFrame {
    /// Frame carries no file descriptor.
    static let tagPlain = slopdesk_supervisor_tag(UInt32(SLOPDESK_SUPERVISOR_TAG_PLAIN))
    /// Frame carries exactly one `SCM_RIGHTS` file descriptor.
    static let tagWithDescriptor =
        slopdesk_supervisor_tag(UInt32(SLOPDESK_SUPERVISOR_TAG_WITH_DESCRIPTOR))
    /// Frame carries a pane's raw output bytes rather than JSON — see ``decodeOutput(_:)``.
    ///
    /// superd only ever sends one of these to a client that asked, with `subscribe`. That is what
    /// keeps a new tag inside the append-only rule: an older hostd has no such verb, so it can
    /// never be handed a tag it would reject.
    public static let tagOutput = slopdesk_supervisor_tag(UInt32(SLOPDESK_SUPERVISOR_TAG_OUTPUT))
    /// Frame carries what the shell said OUT OF BAND in the chunk just sent — see ``decodeSniff(_:)``.
    ///
    /// It always arrives BEFORE the ``tagOutput`` frame carrying the bytes the events were found
    /// in, on the same connection under the same write lock. superd sends one only when a chunk
    /// actually contained something, so a receiver cannot wait to see whether one is coming — it
    /// can only hold what it has already been given. Events first is what lets the receiver hand
    /// them on WITH their chunk.
    public static let tagSniff = slopdesk_supervisor_tag(UInt32(SLOPDESK_SUPERVISOR_TAG_SNIFF))
    /// Frame carries the command-block changes the chunk just sent produced — see
    /// ``decodeSniff(_:)``, which decodes it too (the two share a body shape).
    ///
    /// Same placement and the same reason as ``tagSniff``, and a gate of its own: superd segments a
    /// pane only when the `spawn` that made it carried a `blocks` request. A tag rather than
    /// another kind inside the `0x04` batch, because the property that keeps a new tag safe — never
    /// sent to a peer that did not ask — only holds while each tag has exactly one thing to ask for.
    public static let tagBlocks = slopdesk_supervisor_tag(UInt32(SLOPDESK_SUPERVISOR_TAG_BLOCKS))

    /// The largest body this side will send or accept. Above `ARG_MAX`, far below trouble.
    public static let maximumBodyBytes = slopdesk_supervisor_max_body()

    public enum FrameError: Error, Sendable {
        case bodyTooLarge(Int)
        case unknownTag(UInt8)
        case peerClosed
        case ioFailed(errno: Int32)
    }

    /// Writes one frame. Always ``tagPlain`` — only superd ever attaches a descriptor, and its
    /// writer is `rust/slopdesk-superd/src/frame.rs`.
    ///
    /// Not internally synchronised — a socket shared by several senders needs a lock around this
    /// call, or two frames interleave. ``SupervisorConnection`` owns that lock.
    public static func write(socket: Int32, body: [UInt8]) throws {
        var header = [UInt8](repeating: 0, count: 4)
        let sized = header.withUnsafeMutableBufferPointer { room in
            slopdesk_supervisor_header(body.count, room.baseAddress, room.count)
        }
        // The door refuses a length past the cap rather than truncating it, because a truncated
        // length loses the frame boundary and a socket with a lost boundary never resynchronises.
        guard sized else { throw FrameError.bodyTooLarge(body.count) }
        try FileDescriptorPassing.send(socket: socket, bytes: [tagPlain])
        try writeAll(socket: socket, bytes: header + body)
    }

    /// Reads one frame. Blocks until a whole frame arrives, the peer closes, or the socket errors.
    ///
    /// - Returns: the body bytes and the adopted descriptor, if the sender attached one. The
    ///   caller owns the descriptor.
    public static func read(socket: Int32) throws -> (tag: UInt8, body: [UInt8], descriptor: Int32?) {
        let (tagBytes, descriptor) = try FileDescriptorPassing.receive(socket: socket, capacity: 1)
        guard let tag = tagBytes.first else { throw FrameError.peerClosed }
        guard slopdesk_supervisor_is_known_tag(tag) else {
            // A descriptor may already have been installed in this process by the kernel before we
            // decided the tag was nonsense — close it rather than leak an fd per bad frame.
            if let descriptor { close(descriptor) }
            throw FrameError.unknownTag(tag)
        }

        let header = try readExactly(socket: socket, count: 4, onFailureClose: descriptor)
        let count = header.withUnsafeBufferPointer { bytes in
            slopdesk_supervisor_body_length(bytes.baseAddress, bytes.count)
        }
        // `usize::MAX` is the door's refusal for a length past the cap. A real body can never reach
        // it — but this guard cannot be spelled `count != .max`, and it was, which meant it never
        // fired. Swift imports `size_t` as the SIGNED `Int`, so the door's all-ones refusal arrives
        // as `-1` while `.max` infers `Int.max`; the two never met, and an over-cap header fell
        // through to `readExactly(count: -1)`. Measured with a scratch C target on 2026-08-22, not
        // reasoned about: `probe_max()` returning `(size_t)-1` types as `Int`, prints `-1`, and
        // `== .max` is `false`.
        guard count >= 0 else {
            if let descriptor { close(descriptor) }
            throw FrameError.bodyTooLarge(count)
        }
        let body = count == 0
            ? []
            : try readExactly(socket: socket, count: count, onFailureClose: descriptor)
        return (tag, body, descriptor)
    }

    /// One pane-output body:
    ///
    /// ```text
    /// <2B be pane-id length> <pane id> <8B be offset> <payload>
    /// ```
    ///
    /// The offset is the absolute position of the FIRST payload byte in that pane's output since it
    /// was born (`rust/slopdesk-superd/src/ring.rs`). It rides every frame rather than being counted
    /// by the receiver so that a gap is DETECTABLE: a stream spliced across an unannounced hole
    /// renders a terminal that is wrong, not merely short.
    ///
    /// - Returns: `nil` for a body too short to hold its own header, or a pane id that is not UTF-8.
    ///   Validate-then-drop, the rule every untrusted decode in this repo follows — and this one is
    ///   only as trusted as the daemon on the other end of the socket, which may be an older build.
    public static func decodeOutput(
        _ body: [UInt8],
    ) -> (paneID: String, offset: UInt64, payload: Data)? {
        guard let record = parse(body, through: slopdesk_supervisor_parse_output) else { return nil }
        return (name(body, record), record.offset, Data(payload(body, record)))
    }

    /// One out-of-band body, for either ``tagSniff`` or ``tagBlocks``:
    ///
    /// ```text
    /// <2B be pane-id length> <pane id> <JSON>
    /// ```
    ///
    /// The JSON is a `{"events": [...]}` object of ``SniffedEvent``, or a `{"blocks": [...]}` object
    /// of ``BlockEvent``. It is left undecoded here for the same reason the payload above is: this
    /// type owns the FRAME, and what rides inside one is the caller's vocabulary. The two tags share
    /// a decode because they share a body.
    ///
    /// - Returns: `nil` for a body too short to hold its own header, or a pane id that is not UTF-8.
    public static func decodeSniff(_ body: [UInt8]) -> (paneID: String, json: Data)? {
        guard let record = parse(body, through: slopdesk_supervisor_parse_pane_json)
        else { return nil }
        return (name(body, record), Data(payload(body, record)))
    }

    // MARK: The crossing

    /// The measure-nothing, copy-nothing call both decodes share. `nil` is the door's refusal, which
    /// is validate-then-drop rather than a half-filled record.
    private static func parse(
        _ body: [UInt8],
        through door: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<SlopDeskSupervisorBody>?)
            -> Bool,
    ) -> SlopDeskSupervisorBody? {
        var record = SlopDeskSupervisorBody()
        let parsed = body.withUnsafeBufferPointer { bytes in
            door(bytes.baseAddress, bytes.count, &record)
        }
        return parsed ? record : nil
    }

    /// The pane id, cut out of the body at the offset the door named.
    ///
    /// `slopdesk_supervisor_parse_output` refuses a body whose id is not UTF-8, so by the time these
    /// bytes are here they have already been validated and the lossy decode cannot substitute
    /// anything. The rule's failable alternative would buy an optional that can never be `nil`, paid
    /// for with a `??` fallback naming no pane at all.
    private static func name(_ body: [UInt8], _ record: SlopDeskSupervisorBody) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: slice(body, record.pane_offset, record.pane_len), as: UTF8.self)
    }

    private static func payload(
        _ body: [UInt8], _ record: SlopDeskSupervisorBody,
    ) -> ArraySlice<UInt8> {
        slice(body, record.payload_offset, record.payload_len)
    }

    /// A span the door named, clamped to the buffer it was measured against.
    ///
    /// Clamped rather than trusted: the offsets cross a C ABI, and a range past the end would be a
    /// trap in this process rather than a dropped frame. The Rust suite pins that every span the
    /// door answers is already inside the body.
    private static func slice(
        _ body: [UInt8], _ offset: UInt32, _ length: UInt32,
    ) -> ArraySlice<UInt8> {
        let start = Swift.min(Int(offset), body.count)
        let end = Swift.min(start + Int(length), body.count)
        return body[start..<end]
    }

    /// `write(2)` until every byte is gone, retrying `EINTR` and short writes.
    /// A frame that cannot be delivered MUST be reported — half a frame on a socket is a lost
    /// boundary, not a dropped message. The loop is ``FileDescriptorWrite``; what stays here is the
    /// reaction, which is this lane's own.
    static func writeAll(socket: Int32, bytes: [UInt8]) throws {
        switch FileDescriptorWrite.all(fd: socket, bytes) {
        case .complete: return
        case .peerClosed: throw FrameError.peerClosed
        case let .failed(errno, _): throw FrameError.ioFailed(errno: errno)
        }
    }

    /// `read(2)` until exactly `count` bytes have arrived.
    ///
    /// - Parameter onFailureClose: a descriptor already adopted from this frame's tag. If the body
    ///   never completes, that descriptor has no owner — close it here instead of leaking it.
    static func readExactly(
        socket: Int32,
        count: Int,
        onFailureClose descriptor: Int32?,
    ) throws -> [UInt8] {
        let (buffer, outcome) = FileDescriptorRead.exactly(fd: socket, count: count)
        switch outcome {
        case .complete: return buffer
        case .peerClosed:
            if let descriptor { close(descriptor) }
            throw FrameError.peerClosed
        case let .failed(errno, _):
            if let descriptor { close(descriptor) }
            throw FrameError.ioFailed(errno: errno)
        }
    }
}
