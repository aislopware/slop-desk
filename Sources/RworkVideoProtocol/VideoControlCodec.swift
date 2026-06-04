import Foundation

/// Session bring-up control messages for the GUI video path (PATH 2). These travel
/// on the **control** datagram type of the video session and establish a session
/// before any video/cursor/geometry/input datagram flows.
///
/// The PATH 2 session is plain UDP (doc 17 §3.6) — there is no TCP handshake like
/// PATH 1's `hello`/`helloAck` (doc 20 §8). Instead a tiny control exchange runs
/// over the same UDP path the media uses:
///
/// 1. Client → host `hello(protocolVersion, requestedWindowID, viewport)` —
///    announces the client, the window it wants to remote, and the client viewport
///    size (so the host can size capture/encode to the client surface).
/// 2. Host → client `helloAck(accepted, streamID, captureWidth, captureHeight,
///    windowBoundsCG)` — confirms (or rejects) and reports the negotiated capture
///    dimensions + the window's current CG-top-left bounds (the client maps input
///    against these until the geometry channel updates them).
/// 3. Either side may send `bye` to tear the session down cleanly.
///
/// `protocolVersion` MUST equal ``RworkVideoProtocol/version`` — the host accepts
/// only the exact version (no fallback, mirroring PATH 1's strict version check,
/// doc 20 §4).
///
/// In-session resize (the host-window-resize feature, additive after the original
/// hello/helloAck/bye trio): when the client surface settles to a new size, the client
/// sends `resizeRequest(desired, epoch)` on the control channel; the host clamps it to
/// the live window min/max and re-sizes capture/encode, then confirms the size it
/// actually adopted with `resizeAck(captureWidth, captureHeight, epoch)`. `epoch` is a
/// client-minted monotonic counter so a stale request (one whose epoch ≤ the
/// last-applied) is ignored — coalescing a burst to the settled size. `desired` is
/// Float64 w/h (the viewport precision); the ack reports UInt16 w/h (the same capture-
/// size wire `helloAck` uses).
///
/// Wire layout (big-endian), `[UInt8 type][body]`:
/// ```
/// type 1 hello:         UInt16 protocolVersion | UInt32 requestedWindowID
///                       | Float64 viewportW | Float64 viewportH
/// type 2 helloAck:      UInt8 accepted(0/1) | UInt32 streamID
///                       | UInt16 captureWidth | UInt16 captureHeight
///                       | Float64 boundsX | boundsY | boundsW | boundsH
/// type 3 bye:           (no body)
/// type 4 resizeRequest: Float64 desiredW | Float64 desiredH | UInt32 epoch
/// type 5 resizeAck:     UInt16 captureWidth | UInt16 captureHeight | UInt32 epoch
/// type 6 keepalive:     (no body)
/// ```
///
/// Liveness keepalive (additive after the resize pair — CONCURRENCY-HOST-1 crash-without-bye,
/// `RWORK_VIDEO_KEEPALIVE`): the client sends a zero-body `keepalive` on the control channel
/// every few seconds while streaming so the host's idle-timeout reaper can tell a live-but-quiet
/// client (still alive, just not interacting) from a crashed one (truly silent → reapable). It is
/// wire-safe in BOTH directions: a peer that does not recognise type 6 hits the decoder's `default`
/// arm, which THROWS `.malformed` — both consumers catch-and-DROP it (the host's `handleControl`,
/// the client's `ReceivedDatagramRouter`), never crash. A keepalive is meant to be inert to a peer
/// that doesn't speak it; only a NEW host stamps it as liveness.
public enum VideoControlMessage: Equatable, Sendable {
    /// Client → host: open a session for `requestedWindowID`, sized to `viewport`.
    case hello(protocolVersion: UInt16, requestedWindowID: UInt32, viewport: VideoSize)
    /// Host → client: accept/reject + negotiated capture size + the window's current
    /// CG-top-left bounds (the input-mapping origin until geometry updates arrive).
    case helloAck(accepted: Bool, streamID: UInt32, captureWidth: UInt16, captureHeight: UInt16, windowBoundsCG: VideoRect)
    /// Either side: clean session teardown.
    case bye
    /// Client → host: the client surface settled to `desired` (points); please re-size
    /// capture to it. `epoch` is a monotonic counter so the host can drop a stale request.
    case resizeRequest(desired: VideoSize, epoch: UInt32)
    /// Host → client: capture was re-sized to `captureWidth`×`captureHeight` for the
    /// request carrying `epoch` (the client re-bases its aspect-fit denominator on it).
    case resizeAck(captureWidth: UInt16, captureHeight: UInt16, epoch: UInt32)
    /// Client → host: a zero-body liveness heartbeat (`RWORK_VIDEO_KEEPALIVE`). Sent every few
    /// seconds while streaming so the host's idle-timeout reaper distinguishes a quiet-but-alive
    /// client from a crashed one. Inert to a peer that does not recognise type 6 (it drops it).
    case keepalive

    public var messageType: UInt8 {
        switch self {
        case .hello: return 1
        case .helloAck: return 2
        case .bye: return 3
        case .resizeRequest: return 4
        case .resizeAck: return 5
        case .keepalive: return 6
        }
    }

    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case .hello(let version, let windowID, let viewport):
            out.appendBE(version)
            out.appendBE(windowID)
            out.appendBE(viewport.width)
            out.appendBE(viewport.height)
        case .helloAck(let accepted, let streamID, let w, let h, let bounds):
            out.append(accepted ? 1 : 0)
            out.appendBE(streamID)
            out.appendBE(w)
            out.appendBE(h)
            out.appendBE(bounds.origin.x)
            out.appendBE(bounds.origin.y)
            out.appendBE(bounds.size.width)
            out.appendBE(bounds.size.height)
        case .bye:
            break
        case .resizeRequest(let desired, let epoch):
            out.appendBE(desired.width)
            out.appendBE(desired.height)
            out.appendBE(epoch)
        case .resizeAck(let w, let h, let epoch):
            out.appendBE(w)
            out.appendBE(h)
            out.appendBE(epoch)
        case .keepalive:
            break
        }
        return out
    }

    public static func decode(_ data: Data) throws -> VideoControlMessage {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            let version = try reader.readUInt16()
            let windowID = try reader.readUInt32()
            let w = try reader.readFiniteFloat64("hello.viewport.w")
            let h = try reader.readFiniteFloat64("hello.viewport.h")
            return .hello(protocolVersion: version, requestedWindowID: windowID, viewport: VideoSize(width: w, height: h))
        case 2:
            let accepted = try reader.readUInt8() != 0
            let streamID = try reader.readUInt32()
            let cw = try reader.readUInt16()
            let ch = try reader.readUInt16()
            let bx = try reader.readFiniteFloat64("helloAck.bounds.x")
            let by = try reader.readFiniteFloat64("helloAck.bounds.y")
            let bw = try reader.readFiniteFloat64("helloAck.bounds.w")
            let bh = try reader.readFiniteFloat64("helloAck.bounds.h")
            return .helloAck(accepted: accepted, streamID: streamID, captureWidth: cw, captureHeight: ch,
                             windowBoundsCG: VideoRect(x: bx, y: by, width: bw, height: bh))
        case 3:
            return .bye
        case 4:
            let w = try reader.readFiniteFloat64("resizeRequest.w")
            let h = try reader.readFiniteFloat64("resizeRequest.h")
            let epoch = try reader.readUInt32()
            return .resizeRequest(desired: VideoSize(width: w, height: h), epoch: epoch)
        case 5:
            let w = try reader.readUInt16()
            let h = try reader.readUInt16()
            let epoch = try reader.readUInt32()
            return .resizeAck(captureWidth: w, captureHeight: h, epoch: epoch)
        case 6:
            return .keepalive
        default:
            throw VideoProtocolError.malformed("unknown video control message type \(type)")
        }
    }
}
