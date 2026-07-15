import Foundation
import SlopDeskVideoProtocol

// Pure, platform-free client-session logic for the GUI video path (PATH 2 / Phase 4).
// NO VideoToolbox / Metal / Network (same discipline as SlopDeskVideoProtocol and the
// host's `VideoSessionLogic`) so every decision is unit-testable in isolation. The actor
// in `SlopDeskVideoClientSession.swift` owns the live components (decoder / pacer /
// renderer / sockets) and delegates each decision to these types.

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

/// What a client video session asks the host to stream: one WINDOW (the classic per-window
/// session, wire `hello`) or a whole DISPLAY (the full-desktop pane, wire `helloDisplay` —
/// `0` = the host's main display). Everything downstream of the hello (ack, decode, input
/// mapping) is target-agnostic.
public enum VideoStreamTarget: Equatable, Sendable {
    case window(UInt32)
    case display(UInt32)
}

/// The pure state machine driving a client video session: emits the `hello` (or the display
/// sibling `helloDisplay`), consumes the host's `helloAck`, and gates whether received media is
/// processed. No live component — the actor advances it and acts on the returned ``Effect``s.
public struct VideoClientStateMachine: Sendable {
    public private(set) var state: VideoClientState = .idle

    /// What this client asked the host to stream (window or whole display).
    public let target: VideoStreamTarget
    /// The window this client asked the host to remote (`0` for a display target — kept for the
    /// window-specific call sites; prefer ``target``).
    public var requestedWindowID: UInt32 {
        if case let .window(id) = target { return id }
        return 0
    }

    /// The client viewport size sent in the hello (host sizes capture against it).
    public let viewport: VideoSize

    /// Negotiated values, populated on an accepted `helloAck`.
    public private(set) var streamID: UInt32 = 0
    public private(set) var captureSize: VideoSize = .init(width: 0, height: 0)
    /// The TARGET's CG-top-left bounds reported in the ack (the initial geometry — a window's
    /// frame, updated thereafter by the geometry channel; a display's fixed CG bounds).
    public private(set) var windowBoundsCG: VideoRect = .init(x: 0, y: 0, width: 0, height: 0)

    public init(requestedWindowID: UInt32, viewport: VideoSize) {
        self.init(target: .window(requestedWindowID), viewport: viewport)
    }

    public init(target: VideoStreamTarget, viewport: VideoSize) {
        self.target = target
        self.viewport = viewport
    }

    /// The wire hello for this session's target — `hello` for a window, `helloDisplay` for a
    /// display. One derivation shared by ``start()`` and ``resendHello()``.
    private var helloMessage: VideoControlMessage {
        switch target {
        case let .window(id):
            .hello(
                protocolVersion: SlopDeskVideoProtocol.version,
                requestedWindowID: id,
                viewport: viewport,
            )
        case let .display(id):
            .helloDisplay(
                protocolVersion: SlopDeskVideoProtocol.version,
                requestedDisplayID: id,
                viewport: viewport,
            )
        }
    }

    /// Side effects the actor performs after a transition.
    public enum Effect: Equatable, Sendable {
        /// Send this control message to the host (on the control channel).
        case sendControl(VideoControlMessage)
        /// (Re-)send the cursor side-channel prime so the host (re-)learns this lane's cursor
        /// reply flow. The cursor socket is host→client only after the prime — there is NO ongoing
        /// client→host traffic on it — so unlike the media flow (re-stamped by every routed inbound
        /// datagram) a lost stamp NEVER self-heals: a host daemon restart between the one-shot lane
        /// prime and the (re)hello leaves video+input working while every cursor update is silently
        /// dropped (the pointer shape freezes on the default arrow). Emitting the prime with EVERY
        /// hello closes that hole.
        case primeCursorFlow
        /// Session up at the negotiated capture size: bring up decoder / pacer / renderer
        /// (the actor's GUI-only step). `fullRange` is the stream's negotiated
        /// luma range off the `helloAck`; the actor sets the decoder's output pixel-format
        /// + the renderer's shader coefficients from it to follow the host's actual encoded
        /// range. `false` ⇒ video-range.
        case startDecodePipeline(captureSize: VideoSize, windowBoundsCG: VideoRect, fullRange: Bool)
        /// Tear the decode pipeline down.
        case stopDecodePipeline
        /// The host acked an in-session resize, adopting `size` as the new capture size.
        /// The actor stages it as the PENDING capture size and adopts it as the aspect-fit
        /// denominator (`decodedSize`) only once a decoded `CVPixelBuffer` actually arrives at
        /// that size (in-flight old-size frames may still be queued after the ack).
        case updateCaptureSize(VideoSize)
        /// FPS-governor announcement of the stream's CONTENT cadence — at session start and on
        /// every governed step. The actor forwards it to the GUI layer (the pacer rebases its
        /// deadline-mode interval + adaptive-jitter seconds→frames conversion). Duplicate
        /// deliveries (the host dup-sends ×2 for loss tolerance) are idempotent.
        case applyStreamCadence(UInt16)
        /// Apply a host-measured scroll offset to the scroll reprojector (warp the last frame
        /// between codec frames). `(dx, dy)` are signed NORMALIZED shifts in ten-thousandths of
        /// the frame extent (±10000 ≈ ±1.0); `(0, 0)` arms the reprojector's decay (scroll
        /// stopped). `bandTop`/`bandBottom` are the moving-content vertical band (ten-thousandths
        /// of height); the renderer warps ONLY that band so static chrome doesn't slide
        /// (`bandBottom <= bandTop` ⇒ whole-frame warp fallback).
        case applyScrollOffset(Int16, Int16, UInt16, UInt16)
        /// Apply the opaque-content rect set (capture PIXELS) the host sent after a capture-region
        /// change: the renderer masks everything OUTSIDE these rects to transparent (so a popup
        /// overhanging the window floats over the canvas instead of a black bar). An EMPTY list
        /// clears the mask (whole frame opaque — the contracted/default state).
        case applyContentMask([MaskRect])
        /// Adopt the host's reported MAXIMUM resizable POINT size (the bounds of the display the
        /// captured window sits on). Stored + forwarded to the view → the "Resize…" popover caps
        /// its width/height fields at it. Purely informational — no capture/decode effect.
        case applyDisplayMax(VideoSize)
        /// The HOST ended this session (a received `bye` — daemon shutdown, VD termination, or the
        /// restarted daemon answering an unbound lane). The actor surfaces it to the GUI layer,
        /// which rebuilds the WHOLE pipeline (fresh lane + hello + renderer/pacer/decoder) — the
        /// reconnect-wedge fix. Distinct from a LOCAL ``stop()`` (pane closed), which must NOT rebuild.
        case sessionEndedByHost
        /// The host REFUSED this session (`helloAck(accepted: false)` — version mismatch, or the
        /// requested window is gone: the mux mint-failure refusal). TERMINAL and NON-RETRYING —
        /// deliberately distinct from ``sessionEndedByHost``, whose pipeline handler REBUILDS and
        /// re-hellos: rebuilding on a refusal would re-send the same doomed hello forever (the
        /// mint-failure retry wedge, one layer up). The GUI layer tears the pane down and falls
        /// back to the picker/error state instead.
        case sessionRejectedByHost
    }

    /// `start()` was called: prime the cursor flow + send the hello, move to `.connecting`.
    public mutating func start() -> [Effect] {
        guard state == .idle else { return [] }
        state = .connecting
        return [.primeCursorFlow, .sendControl(helloMessage)]
    }

    /// A control datagram arrived from the host. The client acts only on `helloAck`
    /// (accept → start pipeline; reject → `.rejected`) and `bye` (host tore down → stop).
    /// A duplicate accepted ack while already streaming is ignored (idempotent — UDP may
    /// deliver the ack more than once).
    public mutating func handleControl(_ message: VideoControlMessage) -> [Effect] {
        switch message {
        case let .helloAck(accepted, streamID, cw, ch, bounds, fullRange):
            guard state == .connecting else {
                // Already resolved: ignore a duplicate / late ack.
                return []
            }
            guard accepted else {
                // TERMINAL REFUSAL (window gone on the host — the mux mint-failure refusal — or a
                // version mismatch). Surface `.sessionRejectedByHost` so the pane tears down and
                // falls back to the picker; the `.connecting` guard above makes a duplicate refusal
                // (UDP re-delivery / a re-refused retried hello) inert. Deliberately NOT
                // `.sessionEndedByHost`: that path REBUILDS + re-hellos, which would re-send the
                // same doomed request forever.
                state = .rejected
                return [.sessionRejectedByHost]
            }
            self.streamID = streamID
            captureSize = VideoSize(width: Double(cw), height: Double(ch))
            windowBoundsCG = bounds
            state = .streaming
            return [.startDecodePipeline(captureSize: captureSize, windowBoundsCG: bounds, fullRange: fullRange)]
        case .bye:
            guard state == .streaming || state == .connecting else { return [] }
            state = .stopped
            // `.sessionEndedByHost` (reconnect-wedge fix): the GUI layer rebuilds the whole
            // pipeline + re-hellos on a fresh lane. Emitted ONLY here (host-initiated end) —
            // a local `stop()` must not trigger a rebuild.
            return [.stopDecodePipeline, .sessionEndedByHost]
        case let .resizeAck(cw, ch, _):
            // Host adopted a new capture size. Stage it as pending; adoption as the aspect-fit
            // denominator is frame-gated to the first decoded buffer at that size (in-flight
            // old-size frames may still be queued after the ack). Acted on ONLY while streaming
            // (a stray/late ack after teardown is inert). The echoed epoch is not re-validated
            // (the host already dropped stale epochs). Fixed-size sessions (host AX-refuses
            // resize) send no resizeAck, so this branch is never reached there.
            guard state == .streaming else { return [] }
            return [.updateCaptureSize(VideoSize(width: Double(cw), height: Double(ch)))]
        case let .streamCadence(fps):
            // FPS governor (host→client): rebase content-cadence assumptions. Streaming only.
            // fps 0 is nonsense — dropped (host never sends it; defensive against a corrupt body
            // that still parsed).
            guard state == .streaming, fps >= 1 else { return [] }
            return [.applyStreamCadence(fps)]
        case let .scrollOffset(dx, dy, bandTop, bandBottom):
            // Host→client scroll-reprojection hint + moving-content band. Streaming only. (0,0,…)
            // still flows — it arms the reprojector's decay when scroll stops.
            guard state == .streaming else { return [] }
            return [.applyScrollOffset(dx, dy, bandTop, bandBottom)]
        case let .contentMask(rects):
            // Host→client transparency mask after a DIALOG-EXPAND region change. Streaming only;
            // an empty list clears the mask.
            guard state == .streaming else { return [] }
            return [.applyContentMask(rects)]
        case let .displayMax(w, h):
            // Host→client max resizable point size (the window's display bounds). Streaming only.
            // Zero/degenerate dimensions are dropped (popover stays uncapped) rather than pinning
            // the field max to 0.
            guard state == .streaming, w >= 1, h >= 1 else { return [] }
            return [.applyDisplayMax(VideoSize(width: Double(w), height: Double(h)))]
        case .hello,
             .helloDisplay,
             .resizeRequest,
             .keepalive,
             .listWindows,
             .windowList,
             .focusWindow,
             .listSystemDialogs,
             .systemDialogList,
             .listDisplays,
             .displayList,
             .windowFeedSubscribe,
             .windowFeedSnapshot,
             .windowFeedCurrent,
             .appIconRequest,
             .blobChunk,
             .windowPreviewRequest:
            // hello / resizeRequest / keepalive / listWindows / focusWindow / listSystemDialogs /
            // windowFeedSubscribe / appIconRequest are all client→host. `windowList` +
            // `systemDialogList` + `windowFeedSnapshot` + `windowFeedCurrent` + `blobChunk` ARE
            // host→client but handled out-of-band by the discovery / system-dialog-monitor /
            // window-feed / blob queries (their own lanes), NOT by a streaming session's FSM —
            // defensive no-op here.
            return []
        }
    }

    /// Re-emits the `hello` while STILL `.connecting` (hello-retry path — the second half of the
    /// reconnect-wedge fix). Over plain UDP the one-shot hello or its ack can be lost, and after a
    /// pipeline rebuild the restarted host may not be listening yet — either way, without a retry the
    /// session would wedge in `.connecting` forever. Driven on the ``HelloRetryPolicy`` cadence; any resolved state
    /// (streaming / rejected / stopped) returns `[]`, ending the retry loop. Idempotent on the host
    /// (a duplicate hello re-acks without restarting capture).
    public mutating func resendHello() -> [Effect] {
        guard state == .connecting else { return [] }
        // The prime rides every retry, not just the first hello: a session that sat `.connecting`
        // across a host daemon restart reconnects THROUGH this path on the restarted daemon, which
        // never saw the lane's original one-shot prime — without a re-prime its cursor channel
        // stays dead (pointer shape frozen on the default arrow) while video and input recover.
        return [.primeCursorFlow, .sendControl(helloMessage)]
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

/// PURE hello-retry cadence (reconnect-wedge fix): how long to wait before re-sending the `hello`
/// while still `.connecting`. Exponential from `initialDelay`, capped at `maxDelay` — fast enough
/// that a lost ack costs half a second, slow enough that a pane pointed at a downed host settles to
/// one ~20-byte datagram per `maxDelay` (same order as the window dock's discovery poll). No clock,
/// no timer (the actor sleeps the returned delay) — headlessly unit-testable.
public enum HelloRetryPolicy {
    /// First retry fires this long after the initial hello (seconds).
    public static let initialDelay: TimeInterval = 0.5
    /// Ceiling for the backoff (seconds).
    public static let maxDelay: TimeInterval = 5.0

    /// The delay before retry number `attempt` (0-based: `attempt == 0` is the FIRST retry after
    /// the initial hello). `initialDelay × 2^attempt`, capped at `maxDelay`; a negative attempt is
    /// clamped to 0 (defensive — the caller counts up from 0).
    public static func delay(attempt: Int) -> TimeInterval {
        let n = max(0, attempt)
        // 2^4 already exceeds the cap (0.5 × 16 = 8 > 5) — short-circuit so a long retry loop
        // can never overflow the shift.
        guard n < 4 else { return maxDelay }
        return Double.minimum(maxDelay, initialDelay * Double(1 << n))
    }
}

/// The STICKY show/hide reducer behind the remote-GUI pane's "Reconnecting…" scrim — the
/// presentational counterpart of the reconnect-wedge fix. The stall monitor
/// folds each ``StreamStallPolicy/Verdict`` through this and notifies the view ONLY on a flip.
///
/// Why sticky: once shown, the recovery path itself makes the verdict leave `.stalled` — a
/// host-ended rebuild drops the FSM to `.connecting` (verdict `.notConnected`), and the fresh
/// session starts with no liveness signal (verdict `.unknown`). Clearing on either would flash the
/// pane "healthy" while it still shows a stale frozen frame mid-recovery, so the scrim clears ONLY
/// on a real `.live` verdict (traffic actually flowing again). Pure value type — no timer/clock (the
/// monitor owns the cadence), headlessly unit-testable.
public struct StallScrimLatch: Sendable, Equatable {
    /// Whether the scrim is currently shown.
    public private(set) var visible = false

    public init() {}

    /// A HOST-ENDED rebuild started (a received `bye` — daemon shutdown / restarted-daemon answer):
    /// show the scrim NOW. The bye path never produces a `.stalled` verdict (the FSM leaves
    /// `.streaming` before the monitor can see a gap, so verdicts run `.notConnected`) — without
    /// this, a gracefully-shut-down host that never returns would leave the pane frozen in
    /// hello-retry limbo with no scrim (the HW-found bye-path gap). Returns `true` when this SHOWED
    /// the scrim (caller notifies the view), `nil` when already up (duplicate byes are quiet).
    public mutating func noteReconnecting() -> Bool? {
        guard !visible else { return nil }
        visible = true
        return true
    }

    /// Folds one verdict. Returns the NEW visibility when it flipped (the caller notifies the view),
    /// `nil` when unchanged (quiet — no per-tick re-notify). `.notConnected`/`.unknown` hold the
    /// current state (see the type doc: sticky through the rebuild).
    public mutating func apply(_ verdict: StreamStallPolicy.Verdict) -> Bool? {
        switch verdict {
        case .stalled:
            guard !visible else { return nil }
            visible = true
            return true
        case .live:
            guard visible else { return nil }
            visible = false
            return false
        case .notConnected,
             .unknown:
            return nil
        }
    }
}

/// Pure edge-pan reachability + clamp math for the ACTUAL-SIZE viewport. The pane shows
/// the remote window inside a fixed viewport; the DISPLAYED window size is the native POINT size ×
/// the client zoom (a compositor scale of the sublayer), and edge-pan is the only in-pane way to
/// reach content beyond the pane. Both the navigability GATE and the per-axis pan CLAMP must key off
/// the DISPLAYED (zoomed) size, or a zoomed-in window's overflow is unreachable (gate false) / only
/// half-reachable (clamp stops at the un-zoomed size). Pure Double math — no `CALayer`.
public enum ViewportPan {
    /// Whether displayed window content extends beyond the pane on some axis (±1 pt slack). Keys off
    /// `window × zoom` (the DISPLAYED size), matching the layer frame the compositor lays out.
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

/// Tracks which modifier KEYS the view forwarded to the host as "down" but whose release
/// `flagsChanged` it may never see because focus moved away (⌘-Tab, pane blur, first-responder
/// resign). The host injects modifiers through a shared `CGEventSource(.hidSystemState)` that
/// LATCHES flag state, so a swallowed key-up leaves the modifier stuck — and later scroll /
/// mouse-move events (which carry no explicit flags) inherit it, turning a plain two-finger scroll
/// into ⌘-scroll (the remote page zooms). This lets the view synthesize the missing key-ups on
/// focus loss. Pure value type — headlessly unit-testable.
public struct ModifierLatchTracker: Sendable, Equatable {
    private var downKeyCodes: Set<UInt16> = []

    public init() {}

    /// Whether no modifier is currently latched down.
    public var isEmpty: Bool { downKeyCodes.isEmpty }

    /// Whether `keyCode` is currently latched down.
    public func isDown(_ keyCode: UInt16) -> Bool { downKeyCodes.contains(keyCode) }

    /// Record one modifier `flagsChanged` edge (idempotent — a repeated same-edge is absorbed).
    /// Caps Lock (keyCode 57) is NEVER latched: it is a TOGGLE, not a held key, so the
    /// blur-time synthesized "release" (a bare key-up CGEvent on virtualKey 57) would FLIP the host's
    /// Caps state — focus/blur of a GUI pane with local Caps on toggled remote Caps every time. Its
    /// genuine `flagsChanged` edges still forward to the host 1:1; they just bypass the latch.
    public mutating func note(keyCode: UInt16, down: Bool) {
        guard keyCode != InputModifierKeys.capsLockKeyCode else { return }
        if down { downKeyCodes.insert(keyCode) } else { downKeyCodes.remove(keyCode) }
    }

    /// Returns every latched keyCode (ascending, deterministic emit order) and CLEARS the tracker —
    /// the caller synthesizes a host key-up for each so no modifier stays latched after focus loss.
    public mutating func drainForRelease() -> [UInt16] {
        let all = downKeyCodes.sorted()
        downKeyCodes.removeAll()
        return all
    }
}

/// Display-scale + cursor-placement math for the client (doc 17 §3.3).
///
/// The decoded frame is `decodedSize` pixels (the host's capture size); the Metal layer occupies
/// `layerSize` points on screen. `videoScale` is **client-view-points per host-window-point** — the
/// factor the ``ClientCursorCompositor`` multiplies a host-space cursor position by so the overlaid
/// pointer lands on the same pixel the video shows. Pure so the layout math is testable without a layer.
public enum VideoScaleMath {
    /// The single uniform scale relating the host window (capture) to the on-screen layer. The
    /// renderer draws the decoded frame to fill the whole layer (full-screen quad), so the effective
    /// scale on each axis is `layer / decoded`.
    ///
    /// The cursor is reported in host-WINDOW-space POINTS and the capture size is in the SAME points
    /// (the host clamps the viewport to the window's point size), so a single ratio maps
    /// host-window-points → client-view-points. We key on the WIDTH ratio (capture preserves aspect,
    /// so width and height ratios match; width is the stable axis). Returns `1.0` for a degenerate
    /// (zero-width) decoded frame so the cursor is still placed sensibly.
    public static func videoScale(layerSize: VideoSize, decodedSize: VideoSize) -> Double {
        guard decodedSize.width > 0 else { return 1.0 }
        return layerSize.width / decodedSize.width
    }
}

/// Pre-decode triage for a reassembled frame. A ZERO-byte frame must never reach
/// `VTDecompressionSessionDecodeFrame` as a zero-length sample buffer: the decode fails and the
/// session's hard-failure recovery tears the live `VTDecompressionSession` down + forces a full IDR
/// round-trip (a visible stall) — needless churn for what is really a corrupt/empty fragment (a
/// hostile UDP payloadLength that decoded to 0, or a host bug emitting an empty frame). Classify up
/// front instead. Pure (Int + Bool only) — unit-testable with ZERO VideoToolbox dependency.
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

/// Pure frame-gated resize-adoption decision (client mirror of the host's ``SizeNegotiation``):
/// after the host acks an in-session resize, the client adopts the new size as its aspect-fit
/// denominator (``decodedSize``) ONLY when a decoded `CVPixelBuffer` at the new size actually
/// arrives — an in-flight OLD-size frame queued behind the ack must NOT trip adoption early (it
/// would briefly mis-scale the cursor / `videoScale`). Two gates, both required; pure so the gating
/// is unit-testable without a `VTDecompressionSession`.
public enum ResizeAdoption {
    /// Whether the just-decoded buffer is the genuinely-NEW size (adopt) rather than an
    /// in-flight old-size frame (reject).
    ///
    /// - `pending`: the acked target size (host window POINTS).
    /// - `decoded`: the just-decoded buffer dims (PIXELS = points × captureScale).
    /// - `previousDecoded`: the prior decoded buffer dims (`nil` ⇒ first frame).
    ///
    /// Gate 1 — ASPECT: decoded aspect matches the acked aspect. Rejects an old frame when the
    /// resize CHANGED the aspect (the common freeform-drag case).
    /// Gate 2 — MAGNITUDE: the decoded pixel size actually CHANGED from the previous decoded frame.
    /// Rejects an old frame when the resize PRESERVED the aspect (proportional resize), where the
    /// aspect gate alone would adopt on the first identical-aspect old frame. The client can't
    /// exact-match pixels↔points (no captureScale client-side), but the first genuinely-new-size
    /// frame is the first whose dims differ from the steady old size.
    ///
    /// ⚠️ Residual: a rapid double-resize WITHIN the in-flight window can adopt the latest `pending`
    /// on an intermediate-size frame (both gates pass, but to the intermediate size, not the final).
    /// Rare; self-heals on the next IDR.
    public static func shouldAdopt(pending: VideoSize, decoded: VideoSize, previousDecoded: VideoSize?) -> Bool {
        guard pending.width > 0, pending.height > 0, decoded.width > 0, decoded.height > 0 else { return false }
        let aspectMatches = abs(pending.width / pending.height - decoded.width / decoded.height) < 0.02
        let sizeChanged = previousDecoded
            .map { abs(decoded.width - $0.width) >= 1 || abs(decoded.height - $0.height) >= 1 } ?? true
        return aspectMatches && sizeChanged
    }
}

/// Pure client-side debounce for in-session resize (platform-free mirror of
/// ``LTREscalationTracker``'s pass-`now`-in discipline): the view fires a layout callback on EVERY
/// frame of a live window-drag, but capture should re-size only once per settled size — a flood of
/// `resizeRequest`s mid-drag would thrash the AX-resize + SCStream reconfigure and pump epochs
/// needlessly. Coalesces a burst to the size the surface SETTLES on: while the layer is still
/// changing it `.hold`s; once QUIET for `settleInterval` (and differing from the last requested size
/// by ≥ `minDelta` on some axis) it emits `.request(settled)` once. No timer / no Network (the
/// caller passes layer size + elapsed-since-last-change) — unit-testable in isolation. The epoch
/// counter is minted here so each emitted request carries a monotonic, host-droppable epoch.
public struct ResizeDebounce: Sendable, Equatable {
    /// Size of the last request actually EMITTED (`nil` ⇒ none yet — still at the hello-negotiated
    /// capture size). A new settled size is compared against this to drop sub-`minDelta` jitter.
    public private(set) var lastRequested: VideoSize?
    /// Monotonic epoch of the last emitted request (0 ⇒ none emitted yet). The next emitted request
    /// carries `lastEpoch + 1`.
    public private(set) var lastEpoch: UInt32 = 0

    /// Minimum per-axis change (points) below which a new settled size is jitter, dropped (no
    /// request) — prevents a 1px layout wobble re-sizing capture.
    public let minDelta: Double
    /// How long the layer size must be UNCHANGED before the burst is settled and a request fires
    /// (seconds, elapsed-since-last-change passed in by the caller).
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

    /// Decides whether `layerSize` should trigger a resize request, given how long the layer has
    /// been at this size (`elapsedSinceLastChange`, passed in by the caller — the actor measures it,
    /// like ``LTREscalationTracker`` takes `now`). Pure query: does NOT mutate — call
    /// ``noteRequested(_:)`` after acting on `.request`.
    public func decide(layerSize: VideoSize, elapsedSinceLastChange: TimeInterval) -> Decision {
        // Still settling: changed too recently to be the final size — coalesce.
        guard elapsedSinceLastChange >= settleInterval else { return .hold }
        // Quiet long enough — meaningful change vs the last emitted request?
        guard changedEnough(from: lastRequested, to: layerSize) else { return .hold }
        return .request(layerSize)
    }

    /// Records that a request for `size` was emitted: stores it as the new baseline and advances the
    /// epoch. Returns the epoch the emitted request must carry. Call ONLY after acting on a
    /// `.request(size)` decision (mirrors ``LTREscalationTracker/noteRequestSent(now:)`` being a
    /// separate mutator).
    @discardableResult
    public mutating func noteRequested(_ size: VideoSize) -> UInt32 {
        lastRequested = size
        lastEpoch &+= 1
        return lastEpoch
    }

    /// Rebases the jitter baseline on a size the CLIENT adopted by itself (the 1:1 pane snap — pane
    /// resized to the stream, nothing sent to the host), WITHOUT minting an epoch. The snap-induced
    /// layout pass then decides `.hold` (zero delta vs this baseline), so a client-side snap never
    /// echoes a `resizeRequest` back — which would AX-resize the host window and re-trigger the snap
    /// (a feedback loop). A LATER user drag still differs ≥ `minDelta` and requests normally.
    public mutating func noteAdopted(_ size: VideoSize) {
        lastRequested = size
    }

    /// Whether `to` differs from `from` by ≥ `minDelta` on some axis. A `nil` baseline (no request
    /// yet) always counts as changed (the first settle always fires).
    private func changedEnough(from: VideoSize?, to: VideoSize) -> Bool {
        guard let from else { return true }
        return abs(to.width - from.width) >= minDelta || abs(to.height - from.height) >= minDelta
    }
}

/// 1:1 PANE SNAP: a remote-GUI canvas pane adopts the STREAM's natural size so its video renders
/// without a fractional resample. The snap target is the HOST WINDOW's own POINT size — `decoded
/// pixels / the HOST captureScale` — which the resizeRequest/resizeAck round-trip carries in POINTS,
/// so the resize feedback loop has gain 1 and a user drag converges to the size dragged to.
///
/// ⚠️ The target must be `decoded pixels / the HOST captureScale`, NOT `decoded pixels / the CLIENT
/// contentsScale`: the latter is only correct when the host captures at the client's scale (2× VD on
/// a 2× Retina client). With NO virtual display the host captures at 1× while the client is 2×
/// Retina, so `pixels / 2` would HALVE the pane every resize cycle (loop gain 0.5) — the panes would
/// keep shrinking on every resize. The host captureScale is not on the wire but is CONSTANT for the
/// session and inferable from the first decoded frame: `decoded pixels / the acked window points`
/// (see ``inferredCaptureScale``). Pure math — unit-testable headlessly.
public enum StreamSizeSnap {
    /// The video-layer point size at which the decoded stream renders 1:1: `pixels / captureScale`,
    /// where `captureScale` is the HOST's capture scale (NOT the client contentsScale — see the type
    /// doc). Equals the host window's point size, so it round-trips cleanly through the point-valued
    /// resizeRequest/resizeAck. A non-positive scale falls back to 1 (defensive).
    public static func targetPoints(pixelSize: VideoSize, captureScale: Double) -> VideoSize {
        let s = captureScale > 0 ? captureScale : 1
        return VideoSize(width: pixelSize.width / s, height: pixelSize.height / s)
    }

    /// The HOST capture scale inferred from the first decoded frame: decoded PIXELS per negotiated
    /// window POINT (the helloAck `captureWidth/Height` are points). CONSTANT for the session (host
    /// captures at a fixed scale; only window points change on resize) — so the client infers it once
    /// and reuses it for every later in-session resize. A non-positive `windowPoints` width falls
    /// back to 1 (defensive: the helloAck always carries a real size before any frame).
    public static func inferredCaptureScale(decodedPixels: VideoSize, windowPoints: VideoSize) -> Double {
        guard windowPoints.width > 0, decodedPixels.width > 0 else { return 1 }
        return decodedPixels.width / windowPoints.width
    }

    /// Whether the pane should snap: the 1:1 target differs from the current layer size by ≥
    /// `epsilon` points on some axis. Sub-epsilon deltas are layout noise — snapping on them would
    /// churn the canvas frame + persistence for an invisible change.
    public static func shouldSnap(target: VideoSize, current: VideoSize, epsilon: Double = 0.5) -> Bool {
        abs(target.width - current.width) >= epsilon || abs(target.height - current.height) >= epsilon
    }
}

/// Routes a MEDIA-socket datagram (control / video / geometry) by its channel, decoding it into a
/// typed value for the actor. Pure decision logic — no decoder / reassembler instance — so routing
/// is testable without a `VTDecompressionSession`. (The cursor socket is single-purpose, handled
/// separately via ``CursorChannelMessage``.)
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
    ///   - mediaFlowing: whether the session is `.streaming`. Control is ALWAYS processed (the
    ///     `helloAck` that starts streaming, and `bye`, arrive on it); video/geometry are ignored
    ///     until streaming.
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

/// Builds client→host ``InputEvent`` datagrams from view-space pointer/key input, normalising
/// pointer positions into the 0..1 window space the host expects (doc 05 §2 — the client NEVER sends
/// raw pixels; normalised coords remove pixel-vs-point ambiguity). Pure so the normalisation is testable.
///
/// `tag` is the self-inject filter value the host stamps on `eventSourceUserData` so its own
/// `CursorSampler`/`WindowGeometryWatcher` can drop the events this client injected (doc 18 §A). The
/// client hands out a monotonic tag per event.
public struct InputEventEncoder: Sendable {
    private var nextTag: UInt32

    public init(initialTag: UInt32 = 1) {
        nextTag = initialTag
    }

    /// Normalises a point in the layer's view space (origin top-left, +Y down, same orientation as
    /// the host's window space) to 0..1, clamped to the window so an out-of-bounds drag does not send
    /// coordinates the host would reject.
    ///
    /// EXACT INVERSE of the render transform (doc 17 §3.7), so a click lands on the host pixel under
    /// the cursor on screen:
    ///   1. The renderer ASPECT-FITS the video into a centred sub-rect of the layer
    ///      (``AspectFit/displayedVideoRect(viewSize:videoNativeSize:)``) — letterbox / pillarbox.
    ///      Map the view point into that displayed rect's 0..1 span.
    ///   2. The renderer then CROPS for zoom/pan (fragment shader `uv = (uv-0.5)*invZoom + 0.5 +
    ///      pan`). Apply the same crop forward so the source coordinate matches what the user sees.
    ///      On macOS `zoom==1`, `pan==.zero` so this term is inert (just letterbox-corrected `u/v`).
    /// The pan is clamped IDENTICALLY to the renderer (`panLimit = 0.5·(1-invZoom)`) so the inverse
    /// can never diverge from the forward transform.
    public static func normalize(
        viewPoint: VideoPoint,
        layerSize: VideoSize,
        videoNativeSize: VideoSize,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit,
        viewportCrop: VideoRect? = nil,
    ) -> VideoPoint {
        // ACTUAL-SIZE VIEWPORT (per-axis 1:1 crop): with the pane at the window's actual
        // point size, the renderer maps a texture sub-rect `viewportCrop` (UV origin + size, per-axis)
        // onto the WHOLE drawable (fit = (1,1), no letterbox / scalar-zoom). The inverse is a plain
        // per-axis affine — view fraction → UV — matching the renderer's `crop.xy + uv·crop.zw`
        // exactly, so a click lands on the right host pixel even with independent H/V scales. Additive
        // + default-nil ⇒ the fit/zoom/pan path below (golden-pinned, byte-identical) is untouched.
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

/// Pure decider for the cursor-shape SELF-HEAL. A cursor shape bitmap is shipped over the
/// cursor socket ONCE per `shapeID`; a lost (or over-MTU, IP-fragment-lost) shape would otherwise
/// leave the overlay permanently wrong/invisible for the whole session — the host strips the real
/// cursor, so this overlay is the ONLY cursor the user sees.
///
/// When a cursor POSITION update references a `shapeID` the client has NOT cached, the client
/// re-requests it on the EXISTING recovery channel (mirroring `requestIDR`). This type decides
/// WHETHER to send such a request: only for an UNKNOWN id, and at most once per `reRequestInterval`
/// so a steady stream of position updates referencing a still-missing id (the host's re-ship may
/// itself be lost) does not flood the recovery channel. `noteShapeArrived` marks an id cached
/// (idempotent re-insert) so its position updates stop triggering requests.
///
/// Pure value type — no transport, no clock (the caller passes `now`) — headlessly unit-testable
/// without a socket or a `CALayer`.
public struct CursorShapeRequestTracker: Sendable, Equatable {
    /// Shape ids the client has cached the bitmap for — their position updates never re-request.
    /// Recorded even if the shape arrived before any position update.
    private var knownShapeIDs: Set<UInt16> = []
    /// Host time (seconds) of the last re-request PER missing shapeID, capping re-requests at once
    /// per ``reRequestInterval`` instead of every ~120 Hz position update. Cleared once the shape arrives.
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
    /// client should SEND a `requestCursorShape(shapeID)` now: the id is unknown AND no request for
    /// it was sent within ``reRequestInterval``. Records the request time on `true` (query+mutator),
    /// so the next ~120 Hz update for the same still-missing id does not immediately re-fire.
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
/// SECOND-ORDER differences of arrival intervals. Using only the client's relative deltas (never the
/// host's send timestamp), the constant clock offset cancels and even modest rate skew is negligible
/// — fully clock-skew-immune. The caller passes each frame's arrival time in (client monotonic
/// seconds), so no wall-clock / no I/O — deterministic + headlessly unit-testable.
///
/// ⚠️ Do NOT feed the host `hostSendTsMillis` into this — that re-introduces cross-machine clock
/// skew. Jitter is a purely client-local arrival-cadence measure.
public struct OWDJitterEstimator: Sendable, Equatable {
    /// Client-monotonic time (seconds) of the previous arrival (`nil` ⇒ no sample yet).
    private var lastArrival: Double?
    /// The previous inter-arrival interval (seconds), for the 2nd-difference (`nil` ⇒ <2 samples).
    private var lastInterArrival: Double?
    /// Smoothed jitter (seconds), RFC3550 `J += (|D| − J)/16`.
    public private(set) var jitterSeconds: Double = 0

    public init() {}

    /// Folds one frame arrival (client monotonic seconds). Sample 1 seeds `lastArrival` (no interval
    /// yet); sample 2 seeds the first interval (no 2nd-difference yet); from sample 3 on it updates
    /// the smoothed jitter — so an initial burst never emits a spurious spike.
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

/// PURE adaptive jitter-buffer depth controller (client). Recommends a presentation buffer depth (in
/// FRAMES) from the measured inter-arrival jitter, sized so the slack ≈ `jitterSafety` × jitter (NOT
/// 1×, so a marginal link keeps headroom). Asymmetric BY DESIGN — anti-judder hysteresis:
///   • GROW FAST — a higher recommendation (jitter rose) OR an underrun applies in the same step, so
///     the buffer re-inflates the instant a real dip occurs.
///   • SHRINK SLOW — a lower recommendation steps depth DOWN by at most ONE, and only after
///     `shrinkCooldownFrames` CONSECUTIVE low-jitter frames, so a freshly grown buffer "sticks" for
///     ~cooldown frames and a near-boundary link cannot thrash. `depthForJitter` uses `ceil`, so
///     small jitter wobble does not flip the integer recommendation.
/// Clock-free + deterministic (the caller folds each decoded-frame's smoothed jitter) — headlessly
/// unit-testable. The recommendation is always clamped to `[minDepth, maxDepth]`.
///
/// On a perfectly steady link `jitter == 0` ⇒ recommendation `minDepth` (the latency floor) — the
/// whole point: reclaim the fixed-depth buffer's ~targetDepth/fps of added latency on a clean LAN
/// while still re-inflating on a real spike.
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
    /// Consecutive low-jitter frames required before a single one-step shrink (the slow, hysteretic
    /// path). ~3s at 60fps by default.
    public let shrinkCooldownFrames: Int

    /// The live recommendation (frames). Initialised to the configured/initial depth.
    public private(set) var targetDepth: Int
    /// Consecutive frames the recommendation has been BELOW `targetDepth`; a one-step shrink fires
    /// (and resets this) at `shrinkCooldownFrames`. Reset to 0 by any grow or steady step.
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
        // Clamp the Double BEFORE the Int conversion: a non-finite (NaN/Inf) or out-of-range product
        // would TRAP `Int(_:)`. The result is bounded by maxDepth anyway, so capping `raw` at
        // maxDepth is behaviour-preserving for every reachable value while making the conversion
        // total (trap-class hardening, codebase invariant).
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
