import Foundation
import RworkVideoProtocol

// Pure, platform-free client-session logic for the GUI video path (PATH 2 / Phase 4).
// NO VideoToolbox / Metal / Network — exactly the discipline of RworkVideoProtocol
// and the host's `VideoSessionLogic`, so every decision here is unit-testable in
// isolation. The actor in `RworkVideoClientSession.swift` owns the live components
// (decoder / pacer / renderer / sockets) and delegates each decision to these types.

/// Lifecycle state of a client video session (the mirror of the host's
/// ``VideoSessionState``).
public enum VideoClientState: Equatable, Sendable {
    /// Not yet started.
    case idle
    /// `hello` sent; awaiting the host's `helloAck`.
    case connecting
    /// `helloAck(accepted: true)` received; video/cursor flowing.
    case streaming
    /// The host rejected the hello (version mismatch / wrong window).
    case rejected
    /// `stop()` (or a received `bye`) ran; terminal.
    case stopped
}

/// The pure state machine driving a client video session. It emits the `hello`,
/// consumes the host's `helloAck`, and gates whether received media should be
/// processed — with NO live component. The actor advances it and acts on the
/// returned ``Effect``s.
public struct VideoClientStateMachine: Sendable {
    public private(set) var state: VideoClientState = .idle

    /// The window this client asked the host to remote.
    public let requestedWindowID: UInt32
    /// The client viewport size sent in the hello (host sizes capture against it).
    public let viewport: VideoSize

    /// Negotiated values, populated on an accepted `helloAck`.
    public private(set) var streamID: UInt32 = 0
    public private(set) var captureSize: VideoSize = VideoSize(width: 0, height: 0)
    /// The window's CG-top-left bounds reported in the ack (the initial geometry,
    /// updated thereafter by the geometry channel).
    public private(set) var windowBoundsCG: VideoRect = VideoRect(x: 0, y: 0, width: 0, height: 0)

    public init(requestedWindowID: UInt32, viewport: VideoSize) {
        self.requestedWindowID = requestedWindowID
        self.viewport = viewport
    }

    /// Side effects the actor performs after a transition.
    public enum Effect: Equatable, Sendable {
        /// Send this control message to the host (on the control channel).
        case sendControl(VideoControlMessage)
        /// The session is up at the negotiated capture size: bring up the decoder /
        /// pacer / renderer (the actor's GUI-only step).
        case startDecodePipeline(captureSize: VideoSize, windowBoundsCG: VideoRect)
        /// Tear the decode pipeline down.
        case stopDecodePipeline
    }

    /// `start()` was called: send the hello, move to `.connecting`.
    public mutating func start() -> [Effect] {
        guard state == .idle else { return [] }
        state = .connecting
        return [.sendControl(.hello(protocolVersion: RworkVideoProtocol.version, requestedWindowID: requestedWindowID, viewport: viewport))]
    }

    /// A control datagram arrived from the host. The only message the client acts on
    /// is `helloAck` (accept → start pipeline; reject → `.rejected`) and `bye` (host
    /// tore down → stop). A duplicate accepted ack while already streaming is ignored
    /// (idempotent — UDP may deliver the ack more than once).
    public mutating func handleControl(_ message: VideoControlMessage) -> [Effect] {
        switch message {
        case .helloAck(let accepted, let streamID, let cw, let ch, let bounds):
            guard state == .connecting else {
                // Already resolved: ignore a duplicate / late ack.
                return []
            }
            guard accepted else {
                state = .rejected
                return []
            }
            self.streamID = streamID
            self.captureSize = VideoSize(width: Double(cw), height: Double(ch))
            self.windowBoundsCG = bounds
            state = .streaming
            return [.startDecodePipeline(captureSize: captureSize, windowBoundsCG: bounds)]
        case .bye:
            guard state == .streaming || state == .connecting else { return [] }
            state = .stopped
            return [.stopDecodePipeline]
        case .hello:
            // The client never receives a hello.
            return []
        }
    }

    /// `stop()` was called locally: tell the host (best-effort `bye`) and tear down.
    public mutating func stop() -> [Effect] {
        guard state != .stopped else { return [] }
        let wasStreaming = state == .streaming
        state = .stopped
        var effects: [Effect] = [.sendControl(.bye)]
        if wasStreaming { effects.append(.stopDecodePipeline) }
        return effects
    }

    /// Whether received media (video/geometry/cursor) should be processed right now.
    public var mediaFlowing: Bool { state == .streaming }
}

/// Display-scale + cursor-placement math for the client (doc 17 §3.3).
///
/// The decoded frame is `decodedSize` pixels (the host's capture size). The Metal
/// layer occupies `layerSize` points on screen. `videoScale` is **client-view-points
/// per host-window-point** — the factor the ``ClientCursorCompositor`` multiplies a
/// host-space cursor position by so the overlaid pointer lands on the same pixel the
/// video shows. Pure so the layout math is testable without a layer.
public enum VideoScaleMath {
    /// The single uniform scale relating the host window (capture) to the on-screen
    /// layer. The renderer draws the decoded frame to fill the whole layer (the quad
    /// is full-screen), so the effective scale on each axis is `layer / decoded`.
    ///
    /// The cursor is reported in host-WINDOW-space POINTS and the capture size is in
    /// the SAME points (the host clamps the viewport to the window's point size), so a
    /// single ratio maps host-window-points → client-view-points. We use the WIDTH
    /// ratio (capture preserves the window aspect, so width and height ratios match;
    /// width is the stable axis to key on). Returns `1.0` for a degenerate
    /// (zero-width) decoded frame so the cursor is still placed sensibly.
    public static func videoScale(layerSize: VideoSize, decodedSize: VideoSize) -> Double {
        guard decodedSize.width > 0 else { return 1.0 }
        return layerSize.width / decodedSize.width
    }
}

/// Routes a datagram received on the MEDIA socket (control / video / geometry) by the
/// channel it arrived on, decoding it into a typed value for the actor to act on.
/// Pure decision logic — no decoder / reassembler instance — so routing is testable
/// without a `VTDecompressionSession`. (The cursor socket is single-purpose and
/// handled separately via ``CursorChannelMessage``.)
public struct ReceivedDatagramRouter: Sendable {
    public init() {}

    /// The typed outcome of a received media datagram.
    public enum Routed: Equatable, Sendable {
        /// A control message (the client acts on `helloAck` / `bye`).
        case control(VideoControlMessage)
        /// A parsed video fragment (feed the ``FrameReassembler``).
        case videoFragment(FrameFragment)
        /// A window-geometry update (move/resize/title).
        case geometry(WindowGeometryMessage)
        /// Drop a malformed / undecodable datagram (a corrupt single packet must never
        /// crash the receiver — same contract as the reassembler).
        case drop(reason: String)
        /// Ignore: a channel the client does not receive on (e.g. `.input`), or media
        /// while not streaming.
        case ignore
    }

    /// Routes one media-socket datagram.
    ///
    /// - Parameters:
    ///   - channel: the channel the transport demultiplexed from the 1-byte tag.
    ///   - data: the channel payload (tag already stripped by the transport).
    ///   - mediaFlowing: whether the session is `.streaming`. Control is ALWAYS
    ///     processed (the `helloAck` that starts streaming, and `bye`, arrive on it);
    ///     video/geometry are ignored until streaming.
    public func route(channel: VideoChannel, data: Data, mediaFlowing: Bool) -> Routed {
        switch channel {
        case .control:
            do { return .control(try VideoControlMessage.decode(data)) }
            catch { return .drop(reason: "undecodable control datagram") }
        case .video:
            guard mediaFlowing else { return .ignore }
            do { return .videoFragment(try FrameFragment.decode(data)) }
            catch { return .drop(reason: "undecodable video fragment") }
        case .geometry:
            guard mediaFlowing else { return .ignore }
            do { return .geometry(try WindowGeometryMessage.decode(data)) }
            catch { return .drop(reason: "undecodable geometry datagram") }
        case .cursor, .input, .recovery:
            // Cursor arrives on its own socket; input + recovery are client→host only.
            return .ignore
        }
    }
}

/// Builds client→host ``InputEvent`` datagrams from view-space pointer/key input,
/// normalising pointer positions into the 0..1 window space the host expects (doc 05
/// §2 — the client NEVER sends raw pixels; normalised coords remove pixel-vs-point
/// ambiguity). Pure so the normalisation is testable.
///
/// `tag` is the self-inject filter value the host stamps on `eventSourceUserData` so
/// its own `CursorSampler`/`WindowGeometryWatcher` can drop the events this client
/// injected (doc 18 §A). The client hands out a monotonic tag per event.
public struct InputEventEncoder: Sendable {
    private var nextTag: UInt32

    public init(initialTag: UInt32 = 1) {
        self.nextTag = initialTag
    }

    /// Normalises a point in the layer's view space (origin top-left, +Y down, the
    /// same orientation the host's window space uses) to 0..1, clamped to the window so
    /// an out-of-bounds drag does not send coordinates the host would reject.
    ///
    /// This is the EXACT INVERSE of the render transform (doc 17 §3.7), so a click lands
    /// on the host pixel that is under the cursor on screen:
    ///   1. The renderer ASPECT-FITS the video into a centred sub-rect of the layer
    ///      (``AspectFit/displayedVideoRect(viewSize:videoNativeSize:)``) — letterbox /
    ///      pillarbox. We first map the view point into that displayed rect's 0..1 span.
    ///   2. The renderer then CROPS for zoom/pan (fragment shader
    ///      `uv = (uv-0.5)*invZoom + 0.5 + pan`). We apply the same crop forward so the
    ///      source coordinate matches what the user sees. On macOS `zoom==1`, `pan==.zero`
    ///      so this term is inert and the result is just the letterbox-corrected `u/v`.
    /// The pan is clamped IDENTICALLY to the renderer (`panLimit = 0.5·(1-invZoom)`) so
    /// the inverse can never diverge from the forward transform.
    public static func normalize(
        viewPoint: VideoPoint,
        layerSize: VideoSize,
        videoNativeSize: VideoSize,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit
    ) -> VideoPoint {
        let r = AspectFit.displayedVideoRect(viewSize: layerSize, videoNativeSize: videoNativeSize, mode: mode)
        // 0..1 over the DISPLAYED (un-zoomed) video rect; degenerate rect → 0.
        let u = r.size.width > 0 ? (viewPoint.x - r.origin.x) / r.size.width : 0
        let v = r.size.height > 0 ? (viewPoint.y - r.origin.y) / r.size.height : 0
        // Apply the renderer's zoom/pan crop forward (inert when zoom == 1).
        let invZoom = 1 / max(1, zoom)
        let panLimit = 0.5 * (1 - invZoom)
        let px = min(max(pan.x, -panLimit), panLimit)
        let py = min(max(pan.y, -panLimit), panLimit)
        let sx = (u - 0.5) * invZoom + 0.5 + px
        let sy = (v - 0.5) * invZoom + 0.5 + py
        return VideoPoint(x: min(max(sx, 0), 1), y: min(max(sy, 0), 1))
    }

    /// The tag the next emitted event will carry (for tests).
    public var peekNextTag: UInt32 { nextTag }

    private mutating func takeTag() -> UInt32 {
        let tag = nextTag
        nextTag &+= 1
        return tag
    }

    public mutating func mouseMove(viewPoint: VideoPoint, layerSize: VideoSize, videoNativeSize: VideoSize, zoom: Double = 1, pan: VideoPoint = VideoPoint(x: 0, y: 0), mode: VideoContentMode = .fit) -> InputEvent {
        .mouseMove(normalized: Self.normalize(viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: videoNativeSize, zoom: zoom, pan: pan, mode: mode), tag: takeTag())
    }

    public mutating func mouseDown(button: MouseButton, viewPoint: VideoPoint, layerSize: VideoSize, videoNativeSize: VideoSize, clickCount: UInt8, modifiers: InputModifiers, zoom: Double = 1, pan: VideoPoint = VideoPoint(x: 0, y: 0), mode: VideoContentMode = .fit) -> InputEvent {
        .mouseDown(button: button, normalized: Self.normalize(viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: videoNativeSize, zoom: zoom, pan: pan, mode: mode), clickCount: clickCount, modifiers: modifiers, tag: takeTag())
    }

    public mutating func mouseUp(button: MouseButton, viewPoint: VideoPoint, layerSize: VideoSize, videoNativeSize: VideoSize, clickCount: UInt8, modifiers: InputModifiers, zoom: Double = 1, pan: VideoPoint = VideoPoint(x: 0, y: 0), mode: VideoContentMode = .fit) -> InputEvent {
        .mouseUp(button: button, normalized: Self.normalize(viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: videoNativeSize, zoom: zoom, pan: pan, mode: mode), clickCount: clickCount, modifiers: modifiers, tag: takeTag())
    }

    /// A drag move (a button is held). Emitted from the view's `mouseDragged`/`rightMouseDragged`
    /// — distinct from a hover `mouseMove` — so the host posts a `*MouseDragged` statelessly.
    public mutating func mouseDrag(button: MouseButton, viewPoint: VideoPoint, layerSize: VideoSize, videoNativeSize: VideoSize, clickCount: UInt8, modifiers: InputModifiers, zoom: Double = 1, pan: VideoPoint = VideoPoint(x: 0, y: 0), mode: VideoContentMode = .fit) -> InputEvent {
        .mouseDrag(button: button, normalized: Self.normalize(viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: videoNativeSize, zoom: zoom, pan: pan, mode: mode), clickCount: clickCount, modifiers: modifiers, tag: takeTag())
    }

    public mutating func scroll(dx: Double, dy: Double, viewPoint: VideoPoint, layerSize: VideoSize, videoNativeSize: VideoSize, zoom: Double = 1, pan: VideoPoint = VideoPoint(x: 0, y: 0), mode: VideoContentMode = .fit) -> InputEvent {
        .scroll(dx: dx, dy: dy, normalized: Self.normalize(viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: videoNativeSize, zoom: zoom, pan: pan, mode: mode), tag: takeTag())
    }

    public mutating func key(keyCode: UInt16, down: Bool, modifiers: InputModifiers) -> InputEvent {
        .key(keyCode: keyCode, down: down, modifiers: modifiers, tag: takeTag())
    }

    public mutating func text(_ string: String) -> InputEvent {
        .text(string, tag: takeTag())
    }
}
