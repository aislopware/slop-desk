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
/// `protocolVersion` MUST equal ``AislopdeskVideoProtocol/version`` — the host accepts
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
///                       | UInt8 fullRange(0/1)
///                       | Float64 boundsX | boundsY | boundsW | boundsH
/// type 3 bye:           (no body)
/// type 4 resizeRequest: Float64 desiredW | Float64 desiredH | UInt32 epoch
/// type 5 resizeAck:     UInt16 captureWidth | UInt16 captureHeight | UInt32 epoch
/// type 6 keepalive:     (no body)
/// type 7 listWindows:   (no body)
/// type 8 windowList:    UInt16 count | per record: UInt32 id | UInt16 w | UInt16 h | lp app | lp title
/// type 9 focusWindow:   (no body)
/// type 10 streamCadence: UInt16 fps
/// type 11 listSystemDialogs: (no body)
/// type 12 systemDialogList:  UInt16 count | per record: UInt32 id | UInt16 w | UInt16 h
///                            | UInt8 isSecure | lp owner | lp title
/// ```
///
/// Liveness keepalive (additive after the resize pair — CONCURRENCY-HOST-1 crash-without-bye):
/// the client sends a zero-body `keepalive` on the control channel
/// every few seconds while streaming so the host's idle-timeout reaper can tell a live-but-quiet
/// client (still alive, just not interacting) from a crashed one (truly silent → reapable). It is
/// wire-safe in BOTH directions: a peer that does not recognise type 6 hits the decoder's `default`
/// arm, which THROWS `.malformed` — both consumers catch-and-DROP it (the host's `handleControl`,
/// the client's `ReceivedDatagramRouter`), never crash. A keepalive is meant to be inert to a peer
/// that doesn't speak it; only a NEW host stamps it as liveness.
/// One host-side shareable window in a ``VideoControlMessage/windowList(_:)`` response — the data the
/// client's Remote-Window PICKER renders (replacing manual window-id entry). Mirrors what
/// `aislopdesk-videohostd --list` prints, but delivered over the wire.
public struct WindowSummary: Equatable, Sendable {
    /// The host CGWindowID to put in a `hello`'s `requestedWindowID` to stream this window.
    public var windowID: UInt32
    /// The owning application name (e.g. "Google Chrome").
    public var appName: String
    /// The window title (may be empty).
    public var title: String
    /// Window size in points (for display in the picker; clamped to UInt16 on the wire).
    public var width: UInt16
    public var height: UInt16

    public init(windowID: UInt32, appName: String, title: String, width: UInt16, height: UInt16) {
        self.windowID = windowID
        self.appName = appName
        self.title = title
        self.width = width
        self.height = height
    }
}

/// One host-side SYSTEM dialog/prompt in a ``VideoControlMessage/systemDialogList(_:)`` response —
/// a cross-process modal window NOT attached to any app the client is already streaming (the prime
/// case: a `SecurityAgent` password / admin prompt, but also save/open panels and system alerts).
/// The client POLLS `listSystemDialogs`, diffs the answer, and AUTO-SPAWNS an ephemeral pane that
/// streams each dialog by its `windowID` — closing it again when the dialog leaves the list. This is
/// the "show system popups in their own pane" feature (mirror of ``WindowSummary`` + the picker).
public struct SystemDialogSummary: Equatable, Sendable {
    /// Host CGWindowID — the client puts this in a `hello`'s `requestedWindowID` to stream the dialog.
    public var windowID: UInt32
    /// The owning process name (e.g. "SecurityAgent", "Open and Save Panel Service").
    public var owner: String
    /// The dialog title (often empty / "Untitled" for SecurityAgent — owner is the useful label).
    public var title: String
    public var width: UInt16
    public var height: UInt16
    /// HW-proven (probe 2026-06-12): a `SecurityAgent`-class dialog raises system Secure Event Input —
    /// the host can CAPTURE it (pixels stream fine) but synthetic keystrokes are OS-dropped, so the
    /// password can't be TYPED from the client. The pane shows a "view-only — type on the host" hint.
    public var isSecure: Bool

    public init(windowID: UInt32, owner: String, title: String, width: UInt16, height: UInt16, isSecure: Bool) {
        self.windowID = windowID
        self.owner = owner
        self.title = title
        self.width = width
        self.height = height
        self.isSecure = isSecure
    }
}

public enum VideoControlMessage: Equatable, Sendable {
    /// Client → host: open a session for `requestedWindowID`, sized to `viewport`.
    case hello(protocolVersion: UInt16, requestedWindowID: UInt32, viewport: VideoSize)
    /// Host → client: accept/reject + negotiated capture size + the window's current
    /// CG-top-left bounds (the input-mapping origin until geometry updates arrive).
    /// `fullRange` (WF-6 #8) tells the client the encoded stream's luma swing so it picks
    /// the matching decoder pixel-format + YCbCr→RGB shader coefficients FROM THE STREAM
    /// (no separate client env flag). `false` ⇒ today's video-range (the default).
    case helloAck(
        accepted: Bool,
        streamID: UInt32,
        captureWidth: UInt16,
        captureHeight: UInt16,
        windowBoundsCG: VideoRect,
        fullRange: Bool,
    )
    /// Either side: clean session teardown.
    case bye
    /// Client → host: the client surface settled to `desired` (points); please re-size
    /// capture to it. `epoch` is a monotonic counter so the host can drop a stale request.
    case resizeRequest(desired: VideoSize, epoch: UInt32)
    /// Host → client: capture was re-sized to `captureWidth`×`captureHeight` for the
    /// request carrying `epoch` (the client re-bases its aspect-fit denominator on it).
    case resizeAck(captureWidth: UInt16, captureHeight: UInt16, epoch: UInt32)
    /// Client → host: a zero-body liveness heartbeat. Sent every few
    /// seconds while streaming so the host's idle-timeout reaper distinguishes a quiet-but-alive
    /// client from a crashed one. Inert to a peer that does not recognise type 6 (it drops it).
    case keepalive
    /// Client → host: "what windows can I stream?" — a session-LESS discovery request (the host answers
    /// with ``windowList(_:)`` WITHOUT minting a capture session). Zero body. Carries the remote-window
    /// PICKER (replaces manual window-id entry). An old host drops it (unknown type) → the client times
    /// out + falls back to the manual id field.
    case listWindows
    /// Host → client: the shareable windows, in response to ``listWindows``. The client renders these in
    /// the picker; choosing one sends a normal `hello` with that window's id.
    case windowList([WindowSummary])
    /// Client → host: the remote-window pane was focused on the client (hover / first-responder). Asks the
    /// host to RAISE the captured window to frontmost ONCE, proactively — so the user's first click lands
    /// instantly instead of paying the per-interaction activate-then-control raise stall. Zero body,
    /// idempotent on the host (the raise short-circuits when the window is already frontmost). Inert to an
    /// old host (unknown type → dropped). This is the "raise the focused pane's window" model that
    /// replaced the abandoned no-raise background-injection approach.
    case focusWindow
    /// Host → client: the stream's CONTENT cadence changed (FPS governor, 2026-06-11). Sent once at
    /// session start and on every governed fps step (duplicated ×2, ~25 ms apart, for loss
    /// tolerance — the client's application is idempotent). The client rebases its deadline-pacer
    /// content interval + adaptive-jitter seconds→frames conversion on it. Inert to an old peer
    /// (unknown type → dropped).
    case streamCadence(fps: UInt16)
    /// Client → host: "what SYSTEM dialogs/prompts are open right now?" — a session-LESS poll (the host
    /// answers with ``systemDialogList(_:)`` WITHOUT minting a session), mirroring ``listWindows``. The
    /// client polls this on a slow cadence and diffs the result to auto-spawn/close ephemeral dialog
    /// panes. Zero body. An old host drops it (unknown type) → the feature is simply inert.
    case listSystemDialogs
    /// Host → client: the currently-open system dialogs, in response to ``listSystemDialogs``. The client
    /// streams each by sending a normal `hello` for its `windowID`.
    case systemDialogList([SystemDialogSummary])

    public var messageType: UInt8 {
        switch self {
        case .hello: 1
        case .helloAck: 2
        case .bye: 3
        case .resizeRequest: 4
        case .resizeAck: 5
        case .keepalive: 6
        case .listWindows: 7
        case .windowList: 8
        case .focusWindow: 9
        case .streamCadence: 10
        case .listSystemDialogs: 11
        case .systemDialogList: 12
        }
    }

    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case let .hello(version, windowID, viewport):
            out.appendBE(version)
            out.appendBE(windowID)
            out.appendBE(viewport.width)
            out.appendBE(viewport.height)
        case let .helloAck(accepted, streamID, w, h, bounds, fullRange):
            out.append(accepted ? 1 : 0)
            out.appendBE(streamID)
            out.appendBE(w)
            out.appendBE(h)
            out.append(fullRange ? 1 : 0) // WF-6 (#8): negotiated luma range (after captureHeight)
            out.appendBE(bounds.origin.x)
            out.appendBE(bounds.origin.y)
            out.appendBE(bounds.size.width)
            out.appendBE(bounds.size.height)
        case .bye:
            break
        case let .resizeRequest(desired, epoch):
            out.appendBE(desired.width)
            out.appendBE(desired.height)
            out.appendBE(epoch)
        case let .resizeAck(w, h, epoch):
            out.appendBE(w)
            out.appendBE(h)
            out.appendBE(epoch)
        case .keepalive:
            break
        case .listWindows:
            break
        case let .windowList(windows):
            // `UInt16 count` then per record: UInt32 id | UInt16 w | UInt16 h | len-prefixed app | len-prefixed title.
            // The CALLER (host) must cap the list to fit one UDP datagram (control is not packetized).
            out.appendBE(UInt16(truncatingIfNeeded: windows.count))
            for w in windows {
                out.appendBE(w.windowID)
                out.appendBE(w.width)
                out.appendBE(w.height)
                out.appendLengthPrefixed(w.appName)
                out.appendLengthPrefixed(w.title)
            }
        case .focusWindow:
            break
        case let .streamCadence(fps):
            out.appendBE(fps)
        case .listSystemDialogs:
            break
        case let .systemDialogList(dialogs):
            // Mirrors windowList; CALLER caps the list to fit one UDP datagram (control is not packetized).
            out.appendBE(UInt16(truncatingIfNeeded: dialogs.count))
            for d in dialogs {
                out.appendBE(d.windowID)
                out.appendBE(d.width)
                out.appendBE(d.height)
                out.append(d.isSecure ? 1 : 0)
                out.appendLengthPrefixed(d.owner)
                out.appendLengthPrefixed(d.title)
            }
        }
        return out
    }

    public static func decode(_ data: Data) throws -> Self {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            let version = try reader.readUInt16()
            let windowID = try reader.readUInt32()
            let w = try reader.readFiniteFloat64("hello.viewport.w")
            let h = try reader.readFiniteFloat64("hello.viewport.h")
            return .hello(
                protocolVersion: version,
                requestedWindowID: windowID,
                viewport: VideoSize(width: w, height: h),
            )
        case 2:
            let accepted = try reader.readUInt8() != 0
            let streamID = try reader.readUInt32()
            let cw = try reader.readUInt16()
            let ch = try reader.readUInt16()
            let fr = try reader.readUInt8() != 0 // WF-6 (#8): negotiated luma range (after captureHeight)
            let bx = try reader.readFiniteFloat64("helloAck.bounds.x")
            let by = try reader.readFiniteFloat64("helloAck.bounds.y")
            let bw = try reader.readFiniteFloat64("helloAck.bounds.w")
            let bh = try reader.readFiniteFloat64("helloAck.bounds.h")
            return .helloAck(
                accepted: accepted,
                streamID: streamID,
                captureWidth: cw,
                captureHeight: ch,
                windowBoundsCG: VideoRect(x: bx, y: by, width: bw, height: bh),
                fullRange: fr,
            )
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
        case 7:
            return .listWindows
        case 8:
            let count = try Int(reader.readUInt16())
            var windows: [WindowSummary] = []
            // Do NOT reserveCapacity(count) — count is untrusted. Each record read throws `.truncated`
            // the instant the datagram runs short, so a bogus huge count cannot over-allocate or
            // over-read (it bails on the first missing byte).
            for _ in 0..<count {
                let id = try reader.readUInt32()
                let w = try reader.readUInt16()
                let h = try reader.readUInt16()
                let app = try reader.readLengthPrefixed()
                let title = try reader.readLengthPrefixed()
                windows.append(WindowSummary(windowID: id, appName: app, title: title, width: w, height: h))
            }
            return .windowList(windows)
        case 9:
            return .focusWindow
        case 10:
            return try .streamCadence(fps: reader.readUInt16())
        case 11:
            return .listSystemDialogs
        case 12:
            let count = try Int(reader.readUInt16())
            var dialogs: [SystemDialogSummary] = []
            // Same untrusted-count discipline as windowList: no reserveCapacity; each record read throws
            // `.truncated` the instant the datagram runs short, so a bogus huge count can't over-read.
            for _ in 0..<count {
                let id = try reader.readUInt32()
                let w = try reader.readUInt16()
                let h = try reader.readUInt16()
                let isSecure = try reader.readUInt8() != 0
                let owner = try reader.readLengthPrefixed()
                let title = try reader.readLengthPrefixed()
                dialogs.append(SystemDialogSummary(
                    windowID: id,
                    owner: owner,
                    title: title,
                    width: w,
                    height: h,
                    isSecure: isSecure,
                ))
            }
            return .systemDialogList(dialogs)
        default:
            throw VideoProtocolError.malformed("unknown video control message type \(type)")
        }
    }
}
