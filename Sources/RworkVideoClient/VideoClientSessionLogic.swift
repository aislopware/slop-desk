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
        /// The host acked an in-session resize: it adopted `size` as the new capture size.
        /// The actor stages it as the PENDING capture size and adopts it as the aspect-fit
        /// denominator (`decodedSize`) only once a decoded `CVPixelBuffer` actually arrives at
        /// that size (in-flight old-size frames may still be in the queue after the ack).
        case updateCaptureSize(VideoSize)
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
        case .resizeAck(let cw, let ch, _):
            // The host adopted a new capture size for an in-session resize. Stage it as the
            // pending capture size; the actor adopts it as the aspect-fit denominator only when
            // a decoded CVPixelBuffer actually arrives at that size (frame-gated — in-flight
            // old-size frames may still be queued after the ack). Acted on ONLY while streaming
            // (a stray/late ack after teardown is inert). The epoch is the host's echo of the
            // request that won; the actor does not re-validate it (the host already dropped
            // stale epochs). On a fixed-size session (the host AX-refuses a resize) no resizeAck
            // is sent, so this branch is simply never reached.
            guard state == .streaming else { return [] }
            return [.updateCaptureSize(VideoSize(width: Double(cw), height: Double(ch)))]
        case .hello, .resizeRequest, .keepalive:
            // The client never receives a hello / resizeRequest / keepalive (all client→host) —
            // defensive no-op.
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

/// Pure frame-gated resize-adoption decision (the client mirror of the host's
/// ``SizeNegotiation``): after the host acks an in-session resize, the client must adopt the new
/// size as its aspect-fit denominator (``decodedSize``) ONLY when a decoded `CVPixelBuffer` at
/// the new size actually arrives — an in-flight OLD-size frame queued behind the ack must NOT
/// trip adoption early (it would briefly mis-scale the cursor / `videoScale`). Two gates, both
/// required; pure so the gating is unit-testable without a `VTDecompressionSession`.
public enum ResizeAdoption {
    /// Whether the just-decoded buffer is the genuinely-NEW size (adopt) rather than an
    /// in-flight old-size frame (reject).
    ///
    /// - `pending`: the acked target size (host window POINTS).
    /// - `decoded`: the just-decoded buffer dims (PIXELS = points × captureScale).
    /// - `previousDecoded`: the prior decoded buffer dims (`nil` ⇒ first frame).
    ///
    /// Gate 1 — ASPECT: the decoded aspect matches the acked aspect. Rejects an old frame when
    /// the resize CHANGED the aspect (the common freeform-drag case).
    /// Gate 2 — MAGNITUDE: the decoded pixel size actually CHANGED from the previous decoded
    /// frame. Rejects an old frame when the resize PRESERVED the aspect (a proportional resize),
    /// where the aspect gate alone would adopt on the first identical-aspect old frame. The
    /// client can't exact-match pixels↔points (no captureScale client-side), but the first
    /// genuinely-new-size frame is the first whose dims differ from the steady old size.
    ///
    /// ⚠️ Residual: a rapid double-resize WITHIN the in-flight window can adopt the latest
    /// `pending` on an intermediate-size frame (both gates pass: aspect matches + dims changed,
    /// but to the intermediate size, not the final one). Rare; self-heals on the next IDR.
    public static func shouldAdopt(pending: VideoSize, decoded: VideoSize, previousDecoded: VideoSize?) -> Bool {
        guard pending.width > 0, pending.height > 0, decoded.width > 0, decoded.height > 0 else { return false }
        let aspectMatches = abs(pending.width / pending.height - decoded.width / decoded.height) < 0.02
        let sizeChanged = previousDecoded.map { abs(decoded.width - $0.width) >= 1 || abs(decoded.height - $0.height) >= 1 } ?? true
        return aspectMatches && sizeChanged
    }
}

/// Pure client-side debounce for the in-session resize feature (the platform-free mirror
/// of ``LTREscalationTracker``'s pass-`now`-in discipline): the host view fires a layout
/// callback on EVERY frame of a live window-drag, but the host should re-size capture only
/// once per settled size — a flood of `resizeRequest`s mid-drag would thrash the
/// AX-resize + SCStream reconfigure and pump epochs needlessly. This coalesces a burst to
/// the size the surface SETTLES on: while the layer is still changing it `.hold`s; once it
/// has been QUIET for `settleInterval` (and differs from the last requested size by at
/// least `minDelta` on some axis) it emits `.request(settled)` exactly once. No timer / no
/// Network — the caller passes the layer size + elapsed-since-last-change in — so the
/// coalescing is unit-testable in isolation. The epoch counter is minted here so each
/// emitted request carries a monotonic, host-droppable epoch.
public struct ResizeDebounce: Sendable, Equatable {
    /// The size of the last request the client actually EMITTED (`nil` ⇒ none yet — the
    /// session is still at its hello-negotiated capture size). A new settled size is
    /// compared against this to drop sub-`minDelta` jitter.
    public private(set) var lastRequested: VideoSize?
    /// The monotonic epoch of the last emitted request (0 ⇒ none emitted yet). The next
    /// emitted request carries `lastEpoch + 1`.
    public private(set) var lastEpoch: UInt32 = 0

    /// Minimum per-axis change (points) below which a new settled size is treated as
    /// jitter and dropped (no request) — prevents a 1px layout wobble re-sizing capture.
    public let minDelta: Double
    /// How long the layer size must be UNCHANGED before the burst is considered settled
    /// and a request fires (seconds, elapsed-since-last-change passed in by the caller).
    public let settleInterval: TimeInterval

    public init(minDelta: Double = 8, settleInterval: TimeInterval = 0.2) {
        self.minDelta = minDelta
        self.settleInterval = settleInterval
    }

    /// The debounce decision for one layer-size sample.
    public enum Decision: Equatable, Sendable {
        /// The size has settled and differs enough — emit a `resizeRequest` for this size.
        case request(VideoSize)
        /// Still mid-burst (not yet quiet), or the settled size is within `minDelta` of the
        /// last request — do nothing.
        case hold
    }

    /// Decides whether `layerSize` should trigger a resize request, given how long the
    /// layer has been at this size (`elapsedSinceLastChange`, passed in by the caller —
    /// the actor measures it, exactly like ``LTREscalationTracker`` takes `now`). Pure
    /// query: it does NOT mutate — call ``noteRequested(_:)`` after acting on `.request`.
    public func decide(layerSize: VideoSize, elapsedSinceLastChange: TimeInterval) -> Decision {
        // Still settling: the layer changed too recently to be the final size — coalesce.
        guard elapsedSinceLastChange >= settleInterval else { return .hold }
        // Quiet long enough — is this a meaningful change vs the last request we emitted?
        guard changedEnough(from: lastRequested, to: layerSize) else { return .hold }
        return .request(layerSize)
    }

    /// Records that a request for `size` was emitted: stores it as the new baseline and
    /// advances the epoch. Returns the epoch the emitted request must carry. Call this
    /// ONLY after acting on a `.request(size)` decision (mirrors
    /// ``LTREscalationTracker/noteRequestSent(now:)`` being a separate mutator).
    @discardableResult
    public mutating func noteRequested(_ size: VideoSize) -> UInt32 {
        lastRequested = size
        lastEpoch &+= 1
        return lastEpoch
    }

    /// Whether `to` differs from `from` by at least `minDelta` on some axis. A `nil`
    /// baseline (no request yet) always counts as changed (the first settle always fires).
    private func changedEnough(from: VideoSize?, to: VideoSize) -> Bool {
        guard let from else { return true }
        return abs(to.width - from.width) >= minDelta || abs(to.height - from.height) >= minDelta
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

/// Pure decider for the cursor-shape SELF-HEAL (FIX B). A cursor shape bitmap is shipped over
/// the cursor socket ONCE per `shapeID`; a lost (or over-MTU, IP-fragment-lost) shape would
/// otherwise leave the overlay permanently wrong/invisible for the whole session — the host
/// strips the real cursor, so this overlay is the ONLY cursor the user sees.
///
/// When a cursor POSITION update references a `shapeID` the client has NOT cached, the client
/// re-requests that shape on the EXISTING recovery channel (mirroring `requestIDR`). This type
/// decides WHETHER to send such a request: only for an UNKNOWN id, and at most once per
/// `reRequestInterval` so a steady stream of position updates referencing a still-missing id
/// (the host's re-ship may itself be lost) does not flood the recovery channel. `noteShapeArrived`
/// marks an id cached (idempotent re-insert) so its position updates stop triggering requests.
///
/// Pure value type — no transport, no clock (the caller passes `now`) — so the decision is
/// headlessly unit-testable without a socket or a `CALayer`.
public struct CursorShapeRequestTracker: Sendable, Equatable {
    /// Shape ids the client has received the bitmap for (cached) — their position updates never
    /// re-request. A received shape is recorded here even if it arrived before any position update.
    private var knownShapeIDs: Set<UInt16> = []
    /// Host time (seconds) of the last re-request PER missing shapeID, so a still-missing id is
    /// re-requested at most once per ``reRequestInterval`` instead of on every ~120 Hz position
    /// update. Cleared for an id once its shape arrives.
    private var lastRequested: [UInt16: TimeInterval] = [:]

    /// Minimum spacing between re-requests for the SAME missing shapeID (seconds). A few × RTT:
    /// long enough that one re-ship has time to arrive, short enough to self-heal promptly.
    public let reRequestInterval: TimeInterval

    public init(reRequestInterval: TimeInterval = 0.5) {
        self.reRequestInterval = reRequestInterval
    }

    /// A cursor shape bitmap arrived for `shapeID` — mark it cached (idempotent) and stop
    /// re-requesting it.
    public mutating func noteShapeArrived(_ shapeID: UInt16) {
        knownShapeIDs.insert(shapeID)
        lastRequested[shapeID] = nil
    }

    /// Whether the id is already cached (no request needed). Test/diagnostics seam.
    public func isKnown(_ shapeID: UInt16) -> Bool { knownShapeIDs.contains(shapeID) }

    /// A cursor POSITION update referenced `shapeID` at host time `now`. Returns `true` iff the
    /// client should SEND a `requestCursorShape(shapeID)` now: the id is unknown AND no request
    /// for it was sent within ``reRequestInterval``. Records the request time when it returns
    /// `true` (so it is the query+mutator the caller acts on), so the next ~120 Hz update for the
    /// same still-missing id does not immediately re-fire.
    public mutating func shouldRequest(shapeID: UInt16, now: TimeInterval) -> Bool {
        guard !knownShapeIDs.contains(shapeID) else { return false }
        if let last = lastRequested[shapeID], now - last < reRequestInterval {
            return false
        }
        lastRequested[shapeID] = now
        return true
    }
}
