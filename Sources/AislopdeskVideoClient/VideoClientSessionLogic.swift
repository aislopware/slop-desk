import AislopdeskVideoProtocol
import Foundation

// Pure, platform-free client-session logic for the GUI video path (PATH 2 / Phase 4).
// NO VideoToolbox / Metal / Network — exactly the discipline of AislopdeskVideoProtocol
// and the host's `VideoSessionLogic`, so every decision here is unit-testable in
// isolation. The actor in `AislopdeskVideoClientSession.swift` owns the live components
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
    public private(set) var captureSize: VideoSize = .init(width: 0, height: 0)
    /// The window's CG-top-left bounds reported in the ack (the initial geometry,
    /// updated thereafter by the geometry channel).
    public private(set) var windowBoundsCG: VideoRect = .init(x: 0, y: 0, width: 0, height: 0)

    public init(requestedWindowID: UInt32, viewport: VideoSize) {
        self.requestedWindowID = requestedWindowID
        self.viewport = viewport
    }

    /// Side effects the actor performs after a transition.
    public enum Effect: Equatable, Sendable {
        /// Send this control message to the host (on the control channel).
        case sendControl(VideoControlMessage)
        /// The session is up at the negotiated capture size: bring up the decoder /
        /// pacer / renderer (the actor's GUI-only step). `fullRange` (WF-6 #8) is the
        /// stream's negotiated luma range, taken straight off the `helloAck`; the actor
        /// sets the decoder's output pixel-format + the renderer's shader coefficients
        /// from it so both follow the host's actual encoded range. `false` ⇒ video-range.
        case startDecodePipeline(captureSize: VideoSize, windowBoundsCG: VideoRect, fullRange: Bool)
        /// Tear the decode pipeline down.
        case stopDecodePipeline
        /// The host acked an in-session resize: it adopted `size` as the new capture size.
        /// The actor stages it as the PENDING capture size and adopts it as the aspect-fit
        /// denominator (`decodedSize`) only once a decoded `CVPixelBuffer` actually arrives at
        /// that size (in-flight old-size frames may still be in the queue after the ack).
        case updateCaptureSize(VideoSize)
        /// The host announced (FPS governor) the stream's CONTENT cadence — at session start and
        /// on every governed step. The actor forwards it to the GUI layer (the pacer rebases its
        /// deadline-mode interval + adaptive-jitter seconds→frames conversion). Duplicate
        /// deliveries (the host dup-sends ×2 for loss tolerance) are idempotent.
        case applyStreamCadence(UInt16)
        /// Apply a host-measured scroll offset to the client's scroll reprojector (warp the last frame
        /// between codec frames). `(dx, dy)` are signed NORMALIZED shifts in ten-thousandths of the
        /// frame extent (±10000 ≈ ±1.0); `(0, 0)` arms the reprojector's decay (scroll stopped).
        /// `bandTop`/`bandBottom` are the moving-content vertical band (ten-thousandths of height); the
        /// renderer warps ONLY that band so the static chrome doesn't slide (`bandBottom <= bandTop` ⇒
        /// whole-frame warp fallback).
        case applyScrollOffset(Int16, Int16, UInt16, UInt16)
        /// Apply the opaque-content rect set (capture PIXELS) the host sent after a capture-region
        /// change: the renderer masks everything OUTSIDE these rects to transparent (so a popup
        /// overhanging the window floats over the canvas instead of a black bar). An EMPTY list
        /// clears the mask (whole frame opaque — the contracted/default state).
        case applyContentMask([MaskRect])
        /// Adopt the host's reported MAXIMUM resizable POINT size (the bounds of the display the captured
        /// window sits on). The session stores it and forwards it to the view → the "Resize…" popover caps
        /// its width/height fields at it. Purely informational — no capture/decode effect.
        case applyDisplayMax(VideoSize)
    }

    /// `start()` was called: send the hello, move to `.connecting`.
    public mutating func start() -> [Effect] {
        guard state == .idle else { return [] }
        state = .connecting
        return [.sendControl(.hello(
            protocolVersion: AislopdeskVideoProtocol.version,
            requestedWindowID: requestedWindowID,
            viewport: viewport,
        ))]
    }

    /// A control datagram arrived from the host. The only message the client acts on
    /// is `helloAck` (accept → start pipeline; reject → `.rejected`) and `bye` (host
    /// tore down → stop). A duplicate accepted ack while already streaming is ignored
    /// (idempotent — UDP may deliver the ack more than once).
    public mutating func handleControl(_ message: VideoControlMessage) -> [Effect] {
        switch message {
        case let .helloAck(accepted, streamID, cw, ch, bounds, fullRange):
            guard state == .connecting else {
                // Already resolved: ignore a duplicate / late ack.
                return []
            }
            guard accepted else {
                state = .rejected
                return []
            }
            self.streamID = streamID
            captureSize = VideoSize(width: Double(cw), height: Double(ch))
            windowBoundsCG = bounds
            state = .streaming
            return [.startDecodePipeline(captureSize: captureSize, windowBoundsCG: bounds, fullRange: fullRange)]
        case .bye:
            guard state == .streaming || state == .connecting else { return [] }
            state = .stopped
            return [.stopDecodePipeline]
        case let .resizeAck(cw, ch, _):
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
        case let .streamCadence(fps):
            // FPS governor (host→client): rebase the content-cadence assumptions. Only meaningful
            // while streaming (a stray/late cadence after teardown is inert); fps 0 is nonsense —
            // dropped (the host never sends it; defensive against a corrupt body that still parsed).
            guard state == .streaming, fps >= 1 else { return [] }
            return [.applyStreamCadence(fps)]
        case let .scrollOffset(dx, dy, bandTop, bandBottom):
            // Host→client scroll-reprojection hint + the moving-content band. Only meaningful while
            // streaming; (0,0,…) still flows (it arms the reprojector's decay when scroll stops). A
            // stray/late hint after teardown is inert.
            guard state == .streaming else { return [] }
            return [.applyScrollOffset(dx, dy, bandTop, bandBottom)]
        case let .contentMask(rects):
            // Host→client transparency mask after a DIALOG-EXPAND region change. Only meaningful
            // while streaming; an empty list clears the mask. A stray/late mask after teardown is
            // inert.
            guard state == .streaming else { return [] }
            return [.applyContentMask(rects)]
        case let .displayMax(w, h):
            // Host→client max resizable point size (the window's display bounds). Only meaningful while
            // streaming; a stray/late report after teardown is inert. Zero/degenerate dimensions are
            // dropped (the popover then stays uncapped) rather than pinning the field max to 0.
            guard state == .streaming, w >= 1, h >= 1 else { return [] }
            return [.applyDisplayMax(VideoSize(width: Double(w), height: Double(h)))]
        case .hello,
             .resizeRequest,
             .keepalive,
             .listWindows,
             .windowList,
             .focusWindow,
             .listSystemDialogs,
             .systemDialogList:
            // The client never receives a hello / resizeRequest / keepalive / listWindows / focusWindow /
            // listSystemDialogs (all client→host). `windowList` and `systemDialogList` ARE host→client but
            // are handled out-of-band by the discovery / system-dialog-monitor queries (transient lanes),
            // NOT by a streaming session's FSM — defensive no-op here.
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

/// Pure edge-pan reachability + clamp math for the ACTUAL-SIZE viewport (2026-07-02). The macOS pane shows
/// the remote window inside a fixed viewport; the DISPLAYED window size is the native POINT size × the client
/// zoom (a compositor scale of the sublayer), and edge-pan is the only in-pane way to reach content beyond the
/// pane. Both the navigability GATE and the per-axis pan CLAMP must key off the DISPLAYED (zoomed) size, or a
/// zoomed-in window's overflow is unreachable (gate false) / only half-reachable (clamp stops at the un-zoomed
/// size). Pure Double math — headlessly unit-testable, no `CALayer`.
public enum ViewportPan {
    /// Whether there is displayed window content beyond the pane to pan to on some axis (±1 pt slack). Keys
    /// off `window × zoom` (the DISPLAYED size), matching the layer frame the compositor lays out.
    public static func isNavigable(window: VideoSize, pane: VideoSize, zoom: Double) -> Bool {
        window.width * zoom > pane.width + 1 || window.height * zoom > pane.height + 1
    }

    /// The maximum pan offset per axis (DISPLAY points, top-left basis): `displayed − pane`, floored at 0.
    /// Identical basis to ``isNavigable`` and to `layoutVideoLayer`'s frame clamp, so the gate, the edge-pan
    /// step clamp, and the layer position never disagree.
    public static func maxPanOffset(window: VideoSize, pane: VideoSize, zoom: Double) -> VideoPoint {
        VideoPoint(
            x: Swift.max(0, window.width * zoom - pane.width),
            y: Swift.max(0, window.height * zoom - pane.height),
        )
    }
}

/// Tracks which modifier KEYS the view has forwarded to the host as "down" but whose release `flagsChanged`
/// it may never see because focus moved away (⌘-Tab to another app, pane blur, first-responder resign). Since
/// the host injects modifiers through a shared `CGEventSource(.hidSystemState)` that LATCHES flag state, a
/// swallowed key-up leaves the modifier stuck — and later scroll / mouse-move events (which carry no explicit
/// flags) inherit it, so a plain two-finger scroll becomes ⌘-scroll (the remote page zooms). This lets the
/// view synthesize the missing key-ups on focus loss. Pure value type — headlessly unit-testable.
public struct ModifierLatchTracker: Sendable, Equatable {
    private var downKeyCodes: Set<UInt16> = []

    public init() {}

    /// Whether no modifier is currently latched down.
    public var isEmpty: Bool { downKeyCodes.isEmpty }

    /// Whether `keyCode` is currently latched down.
    public func isDown(_ keyCode: UInt16) -> Bool { downKeyCodes.contains(keyCode) }

    /// Record one modifier `flagsChanged` edge (idempotent — a repeated same-edge is absorbed).
    /// Caps Lock (keyCode 57) is NEVER latched (C5 BUG A): it is a TOGGLE, not a held key, so the
    /// blur-time synthesized "release" (a bare key-up CGEvent on virtualKey 57) would FLIP the host's
    /// Caps state — focusing/blurring a GUI pane with local Caps on toggled remote Caps every time.
    /// Its genuine `flagsChanged` edges still forward to the host 1:1; they just bypass the latch.
    public mutating func note(keyCode: UInt16, down: Bool) {
        guard keyCode != InputModifierKeys.capsLockKeyCode else { return }
        if down { downKeyCodes.insert(keyCode) } else { downKeyCodes.remove(keyCode) }
    }

    /// Returns every latched keyCode (ascending, for a deterministic emit order) and CLEARS the tracker —
    /// the caller synthesizes a host key-up for each so no modifier stays latched after focus loss.
    public mutating func drainForRelease() -> [UInt16] {
        let all = downKeyCodes.sorted()
        downKeyCodes.removeAll()
        return all
    }
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

/// Pre-decode triage for a reassembled frame (R15 #9). A ZERO-byte frame must never reach
/// `VTDecompressionSessionDecodeFrame` as a zero-length sample buffer: the decode fails and the
/// session's hard-failure recovery tears the live `VTDecompressionSession` down + forces a full IDR
/// round-trip (a visible stall) — needless churn for what is really a corrupt/empty fragment (a
/// hostile UDP payloadLength that decoded to 0, or a host bug emitting an empty frame). Classify it
/// up front instead. Pure (Int + Bool only) so it is unit-testable with ZERO VideoToolbox dependency.
public enum FrameDecodability: Equatable, Sendable {
    /// Non-empty — submit to the decoder as usual.
    case decodable
    /// An empty DELTA — drop it without touching the decoder. A single empty/lost delta does not
    /// warrant a re-anchor; the reassembler's loss recovery covers a genuine gap.
    case dropSilently
    /// An empty KEYFRAME — the IDR itself was empty, so ask the host for a fresh one, but do NOT
    /// invalidate the (otherwise-healthy) session. The decoder throws ``VideoDecoderError/awaitingKeyframe``
    /// for this case, whose caller path requests an IDR WITHOUT a session rebuild.
    case requestKeyframe

    /// Triage a frame by its keyframe flag and reassembled byte count.
    public static func classify(keyframe: Bool, byteCount: Int) -> Self {
        if byteCount > 0 { return .decodable }
        return keyframe ? .requestKeyframe : .dropSilently
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
        let sizeChanged = previousDecoded
            .map { abs(decoded.width - $0.width) >= 1 || abs(decoded.height - $0.height) >= 1 } ?? true
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

    /// Rebases the jitter baseline on a size the CLIENT adopted by itself (the 1:1 pane
    /// snap — the pane resized to the stream, nothing was sent to the host), WITHOUT
    /// minting an epoch. The snap-induced layout pass then decides `.hold` (zero delta vs
    /// this baseline), so a client-side snap never echoes a `resizeRequest` back to the
    /// host — which would AX-resize the host window and re-trigger the snap (a feedback
    /// loop). A LATER user drag still differs ≥ `minDelta` and requests normally.
    public mutating func noteAdopted(_ size: VideoSize) {
        lastRequested = size
    }

    /// Whether `to` differs from `from` by at least `minDelta` on some axis. A `nil`
    /// baseline (no request yet) always counts as changed (the first settle always fires).
    private func changedEnough(from: VideoSize?, to: VideoSize) -> Bool {
        guard let from else { return true }
        return abs(to.width - from.width) >= minDelta || abs(to.height - from.height) >= minDelta
    }
}

/// 1:1 PANE SNAP (2026-06-11 "match the virtual display"; corrected 2026-06-16). A remote-GUI
/// canvas pane adopts the STREAM's natural size so its video renders without a fractional
/// resample. The snap target is the HOST WINDOW's own POINT size — `decoded pixels / the HOST
/// captureScale` — which the resizeRequest/resizeAck round-trip carries in POINTS, so the resize
/// feedback loop has gain 1 and a user drag converges to the size dragged to.
///
/// ⚠️ The bug it fixes (2026-06-16): the target was computed as `decoded pixels / the CLIENT
/// contentsScale`. That is only correct when the host captures at the client's scale (the 2× VD
/// on a 2× Retina client). With NO virtual display the host captures at 1× while the client is a
/// 2× Retina, so `pixels / 2` HALVED the pane every resize cycle (loop gain 0.5) — "khi resize
/// thì pane cứ bị co nhỏ". The host captureScale is not on the wire, but it is CONSTANT for the
/// session and inferable from the first decoded frame: `decoded pixels / the acked window points`
/// (see ``inferredCaptureScale``). Pure math — unit-testable headlessly.
public enum StreamSizeSnap {
    /// The video-layer point size at which the decoded stream renders 1:1: `pixels /
    /// captureScale`, where `captureScale` is the HOST's capture scale (NOT the client
    /// contentsScale — see the type doc). Equals the host window's point size, so it round-trips
    /// cleanly through the point-valued resizeRequest/resizeAck. A non-positive scale falls back
    /// to 1 (defensive).
    public static func targetPoints(pixelSize: VideoSize, captureScale: Double) -> VideoSize {
        let s = captureScale > 0 ? captureScale : 1
        return VideoSize(width: pixelSize.width / s, height: pixelSize.height / s)
    }

    /// The HOST capture scale inferred from the first decoded frame: decoded PIXELS per negotiated
    /// window POINT (the helloAck `captureWidth/Height` are points). CONSTANT for the session — the
    /// host captures at a fixed scale and only the window points change on resize — so the client
    /// infers it once and reuses it for every later in-session resize. A non-positive `windowPoints`
    /// width falls back to 1 (defensive: the helloAck always carries a real size before any frame).
    public static func inferredCaptureScale(decodedPixels: VideoSize, windowPoints: VideoSize) -> Double {
        guard windowPoints.width > 0, decodedPixels.width > 0 else { return 1 }
        return decodedPixels.width / windowPoints.width
    }

    /// Whether the pane should actually snap: the 1:1 target differs from the current layer
    /// size by at least `epsilon` points on some axis. Sub-epsilon deltas are layout noise —
    /// snapping on them would churn the canvas frame + persistence for an invisible change.
    public static func shouldSnap(target: VideoSize, current: VideoSize, epsilon: Double = 0.5) -> Bool {
        abs(target.width - current.width) >= epsilon || abs(target.height - current.height) >= epsilon
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
            do { return try .control(VideoControlMessage.decode(data)) } catch {
                return .drop(reason: "undecodable control datagram")
            }
        case .video:
            guard mediaFlowing else { return .ignore }
            do { return try .videoFragment(FrameFragment.decode(data)) } catch {
                return .drop(reason: "undecodable video fragment")
            }
        case .geometry:
            guard mediaFlowing else { return .ignore }
            do { return try .geometry(WindowGeometryMessage.decode(data)) } catch {
                return .drop(reason: "undecodable geometry datagram")
            }
        case .cursor,
             .input,
             .recovery:
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
        nextTag = initialTag
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
        mode: VideoContentMode = .fit,
        viewportCrop: VideoRect? = nil,
    ) -> VideoPoint {
        // ACTUAL-SIZE VIEWPORT (per-axis 1:1 crop, 2026-06-30): when the macOS pane shows the remote window
        // at its actual point size, the renderer maps a texture sub-rect `viewportCrop` (UV origin + size,
        // per-axis) onto the WHOLE drawable (fit = (1,1), no letterbox / scalar-zoom). The inverse is a
        // plain per-axis affine — view fraction → UV — that matches the renderer's `crop.xy + uv·crop.zw`
        // exactly, so a click lands on the right host pixel even with independent H/V scales. Additive +
        // default-nil ⇒ the fit/zoom/pan path below (golden-pinned, byte-identical) is untouched.
        if let crop = viewportCrop {
            let u = layerSize.width > 0 ? viewPoint.x / layerSize.width : 0
            let v = layerSize.height > 0 ? viewPoint.y / layerSize.height : 0
            // keep mul+add separate — FMA breaks bit-exact parity
            let sx = crop.origin.x + u * crop.size.width
            let sy = crop.origin.y + v * crop.size.height
            return VideoPoint(x: min(max(sx, 0), 1), y: min(max(sy, 0), 1))
        }
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

    public mutating func mouseMove(
        viewPoint: VideoPoint,
        layerSize: VideoSize,
        videoNativeSize: VideoSize,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit,
        viewportCrop: VideoRect? = nil,
    ) -> InputEvent {
        .mouseMove(
            normalized: Self
                .normalize(
                    viewPoint: viewPoint,
                    layerSize: layerSize,
                    videoNativeSize: videoNativeSize,
                    zoom: zoom,
                    pan: pan,
                    mode: mode,
                    viewportCrop: viewportCrop,
                ),
            tag: takeTag(),
        )
    }

    public mutating func mouseDown(
        button: MouseButton,
        viewPoint: VideoPoint,
        layerSize: VideoSize,
        videoNativeSize: VideoSize,
        clickCount: UInt8,
        modifiers: InputModifiers,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit,
        viewportCrop: VideoRect? = nil,
    ) -> InputEvent {
        .mouseDown(
            button: button,
            normalized: Self
                .normalize(
                    viewPoint: viewPoint,
                    layerSize: layerSize,
                    videoNativeSize: videoNativeSize,
                    zoom: zoom,
                    pan: pan,
                    mode: mode,
                    viewportCrop: viewportCrop,
                ),
            clickCount: clickCount,
            modifiers: modifiers,
            tag: takeTag(),
        )
    }

    public mutating func mouseUp(
        button: MouseButton,
        viewPoint: VideoPoint,
        layerSize: VideoSize,
        videoNativeSize: VideoSize,
        clickCount: UInt8,
        modifiers: InputModifiers,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit,
        viewportCrop: VideoRect? = nil,
    ) -> InputEvent {
        .mouseUp(
            button: button,
            normalized: Self
                .normalize(
                    viewPoint: viewPoint,
                    layerSize: layerSize,
                    videoNativeSize: videoNativeSize,
                    zoom: zoom,
                    pan: pan,
                    mode: mode,
                    viewportCrop: viewportCrop,
                ),
            clickCount: clickCount,
            modifiers: modifiers,
            tag: takeTag(),
        )
    }

    /// A drag move (a button is held). Emitted from the view's `mouseDragged`/`rightMouseDragged`
    /// — distinct from a hover `mouseMove` — so the host posts a `*MouseDragged` statelessly.
    public mutating func mouseDrag(
        button: MouseButton,
        viewPoint: VideoPoint,
        layerSize: VideoSize,
        videoNativeSize: VideoSize,
        clickCount: UInt8,
        modifiers: InputModifiers,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit,
        viewportCrop: VideoRect? = nil,
    ) -> InputEvent {
        .mouseDrag(
            button: button,
            normalized: Self
                .normalize(
                    viewPoint: viewPoint,
                    layerSize: layerSize,
                    videoNativeSize: videoNativeSize,
                    zoom: zoom,
                    pan: pan,
                    mode: mode,
                    viewportCrop: viewportCrop,
                ),
            clickCount: clickCount,
            modifiers: modifiers,
            tag: takeTag(),
        )
    }

    public mutating func scroll(
        dx: Double,
        dy: Double,
        viewPoint: VideoPoint,
        layerSize: VideoSize,
        videoNativeSize: VideoSize,
        scrollPhase: UInt8 = 0,
        momentumPhase: UInt8 = 0,
        continuous: Bool = false,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit,
        viewportCrop: VideoRect? = nil,
    ) -> InputEvent {
        .scroll(
            dx: dx,
            dy: dy,
            normalized: Self
                .normalize(
                    viewPoint: viewPoint,
                    layerSize: layerSize,
                    videoNativeSize: videoNativeSize,
                    zoom: zoom,
                    pan: pan,
                    mode: mode,
                    viewportCrop: viewportCrop,
                ),
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
            continuous: continuous,
            tag: takeTag(),
        )
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

    public init(reRequestInterval: TimeInterval = 0.25) {
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

/// Pure one-way-delay (OWD) jitter estimator for the network-feedback channel — the RFC3550
/// inter-arrival-jitter form, computed ENTIRELY in the CLIENT's own monotonic clock from
/// SECOND-ORDER differences of arrival intervals. Because it uses only the client's relative
/// deltas (never the host's send timestamp), the constant clock offset cancels and even modest
/// rate skew is negligible — it is fully clock-skew-immune. The caller passes each frame's arrival
/// time in (client monotonic seconds), so there is no wall-clock / no I/O and the math is
/// deterministic + headlessly unit-testable.
///
/// ⚠️ Do NOT feed the host `hostSendTsMillis` into this — that would re-introduce cross-machine
/// clock skew. Jitter is a purely client-local arrival-cadence measure.
public struct OWDJitterEstimator: Sendable, Equatable {
    /// Client-monotonic time (seconds) of the previous arrival (`nil` ⇒ no sample yet).
    private var lastArrival: Double?
    /// The previous inter-arrival interval (seconds), for the 2nd-difference (`nil` ⇒ <2 samples).
    private var lastInterArrival: Double?
    /// Smoothed jitter (seconds), RFC3550 `J += (|D| − J)/16`.
    public private(set) var jitterSeconds: Double = 0

    public init() {}

    /// Folds one frame arrival (client monotonic seconds). The first sample only seeds `lastArrival`
    /// (no interval yet); the second seeds the first interval (no 2nd-difference yet); from the third
    /// on it updates the smoothed jitter — so an initial burst never emits a spurious spike.
    public mutating func note(arrival: Double) {
        guard let prevArrival = lastArrival else { lastArrival = arrival
            return
        }
        let inter = arrival - prevArrival
        lastArrival = arrival
        guard let prevInter = lastInterArrival else { lastInterArrival = inter
            return
        }
        let d = abs(inter - prevInter)
        jitterSeconds += (d - jitterSeconds) / 16
        lastInterArrival = inter
    }

    /// The smoothed jitter as microseconds, clamped to the `UInt32` wire field (never traps the
    /// `UInt32(Double)` initializer: negatives floor to 0, an absurd value saturates at `UInt32.max`).
    public func jitterMicros() -> UInt32 {
        let micros = jitterSeconds * 1_000_000
        return UInt32(min(Double(UInt32.max), max(0, micros)))
    }
}

/// PURE adaptive jitter-buffer depth controller (client). Recommends a presentation buffer
/// depth (in FRAMES) from the measured inter-arrival jitter, sized so the slack ≈
/// `jitterSafety` × jitter (NOT 1×, so a marginal link keeps headroom). The response is
/// asymmetric BY DESIGN — anti-judder hysteresis:
///   • GROW FAST — a higher recommendation (jitter rose) OR an underrun is applied in the
///     same step, so the buffer re-inflates the instant a real dip occurs.
///   • SHRINK SLOW — a lower recommendation steps the depth DOWN by at most ONE, and only
///     after `shrinkCooldownFrames` CONSECUTIVE low-jitter frames, so a freshly grown buffer
///     "sticks" for ~cooldown frames and a near-boundary link cannot thrash. `depthForJitter`
///     uses `ceil`, so small jitter wobble does not flip the integer recommendation.
/// Clock-free + deterministic (the caller folds each decoded-frame's smoothed jitter), so it
/// is headlessly unit-testable. The recommendation is always clamped to `[minDepth, maxDepth]`.
///
/// On a perfectly steady link `jitter == 0` ⇒ recommendation `minDepth` (the latency floor),
/// which is the whole point: reclaim the fixed-depth buffer's ~targetDepth/fps of added
/// latency on a clean LAN while still re-inflating on a real spike.
public struct AdaptiveJitterController: Sendable, Equatable {
    /// Floor — never recommend fewer than this many frames (1 ⇒ present as soon as decoded).
    public let minDepth: Int
    /// Ceiling — the pacer's hard cap; the recommendation never exceeds it.
    public let maxDepth: Int
    /// Presentation cadence (frames/s) — converts jitter SECONDS into a FRAME count.
    public let fps: Double
    /// Buffer-sizing multiple: depth ≈ ceil(jitter × fps × safety). >1 gives a marginal link
    /// headroom so ordinary wobble does not underrun.
    public let jitterSafety: Double
    /// Consecutive low-jitter frames required before a single one-step shrink (the slow,
    /// hysteretic shrink path). ~3s at 60fps by default.
    public let shrinkCooldownFrames: Int

    /// The live recommendation (frames). Initialised to the configured/initial depth.
    public private(set) var targetDepth: Int
    /// Consecutive frames the recommendation has been BELOW `targetDepth`; a one-step shrink
    /// fires (and resets this) at `shrinkCooldownFrames`. Reset to 0 by any grow or steady step.
    private var shrinkRun: Int = 0

    public init(
        minDepth: Int = 1,
        maxDepth: Int,
        fps: Double,
        initialDepth: Int,
        jitterSafety: Double = 2.5,
        shrinkCooldownFrames: Int = 180,
    ) {
        let lo = max(1, minDepth)
        self.minDepth = lo
        self.maxDepth = max(lo, maxDepth)
        self.fps = fps
        self.jitterSafety = jitterSafety
        self.shrinkCooldownFrames = max(1, shrinkCooldownFrames)
        targetDepth = min(self.maxDepth, max(lo, initialDepth))
    }

    /// Depth that would absorb jitter `j` (seconds): `1 + ceil(j × fps × safety)`, clamped to
    /// `[minDepth, maxDepth]`. `j == 0` ⇒ `minDepth`. The `max(0, …)` guards a (theoretical)
    /// negative jitter so the +1 base never underflows the floor.
    private func depthForJitter(_ j: Double) -> Int {
        // Clamp the Double BEFORE the Int conversion: a non-finite (NaN/Inf) or out-of-range
        // product would TRAP the `Int(_:)` initialiser. The result is bounded by maxDepth anyway,
        // so capping `raw` at maxDepth is behaviour-preserving for every reachable value while
        // making the conversion total (trap-class hardening, codebase invariant).
        let raw = (j * fps * jitterSafety).rounded(.up)
        let extra = raw.isFinite ? max(0, Int(min(raw, Double(maxDepth)))) : 0
        return min(maxDepth, max(minDepth, 1 + extra))
    }

    /// Folds one decoded-frame's smoothed jitter and returns the (possibly updated) depth.
    /// GROW FAST when the recommendation rises; SHRINK SLOW (one step per cooldown) when it
    /// falls; reset the cooldown when steady.
    @discardableResult
    public mutating func noteFrame(jitterSeconds: Double) -> Int {
        let desired = depthForJitter(jitterSeconds)
        if desired > targetDepth {
            targetDepth = min(maxDepth, desired)
            shrinkRun = 0
        } else if desired < targetDepth {
            shrinkRun += 1
            if shrinkRun >= shrinkCooldownFrames {
                targetDepth = max(minDepth, targetDepth - 1)
                shrinkRun = 0
            }
        } else {
            shrinkRun = 0
        }
        return targetDepth
    }

    /// A real starvation occurred — GROW one step immediately (capped) and restart the shrink
    /// cooldown so the bump is not undone by the next low-jitter frame.
    @discardableResult
    public mutating func noteUnderrun() -> Int {
        targetDepth = min(maxDepth, targetDepth + 1)
        shrinkRun = 0
        return targetDepth
    }
}
