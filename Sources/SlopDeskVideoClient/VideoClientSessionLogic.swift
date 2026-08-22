import CSlopDeskFFI
import Foundation
import SlopDeskArena
import SlopDeskVideoProtocol

// Pure, platform-free client-session logic for the GUI video path (PATH 2 / Phase 4).
// NO VideoToolbox / Metal / Network (same discipline as SlopDeskVideoProtocol and the
// host's `VideoSessionLogic`) so every decision is unit-testable in isolation. The actor
// in `SlopDeskVideoClientSession.swift` owns the live components (decoder / pacer /
// renderer / sockets) and delegates each decision to these types.
//
// The lifecycle half — the state machine, the hello-retry cadence, the reconnecting-scrim latch —
// is the Swift FACE of `rust/slopdesk-video`'s `client_session`. It holds no decision of its own:
// the machine crosses BY VALUE (every field is read here, so there is nothing for a handle to own —
// docs/55 §4b) and each transition answers a list of effects through lent buffers.

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

    /// The state behind one of the door's codes. An unrecognised code reads as ``idle`` — the only
    /// state from which nothing has happened yet.
    init(code: UInt32) {
        switch code {
        case SLOPDESK_VIDEO_CLIENT_CONNECTING: self = .connecting
        case SLOPDESK_VIDEO_CLIENT_STREAMING: self = .streaming
        case SLOPDESK_VIDEO_CLIENT_REJECTED: self = .rejected
        case SLOPDESK_VIDEO_CLIENT_STOPPED: self = .stopped
        default: self = .idle
        }
    }
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
    /// The whole machine as it crosses: six scalars and two rectangles, all of them read here, so
    /// there is nothing for a handle to own (docs/55 §4b) and value semantics survive the port.
    private var machine: SlopDeskVideoClientMachine

    public var state: VideoClientState { VideoClientState(code: machine.state) }

    /// What this client asked the host to stream (window or whole display).
    public var target: VideoStreamTarget {
        machine.target_kind == SLOPDESK_VIDEO_TARGET_DISPLAY
            ? .display(machine.target_id)
            : .window(machine.target_id)
    }

    /// The window this client asked the host to remote (`0` for a display target — kept for the
    /// window-specific call sites; prefer ``target``).
    public var requestedWindowID: UInt32 { slopdesk_video_client_requested_window_id(machine) }

    /// The client viewport size sent in the hello (host sizes capture against it).
    public var viewport: VideoSize { Self.size(machine.viewport) }

    /// Negotiated values, populated on an accepted `helloAck`.
    public var streamID: UInt32 { machine.stream_id }
    public var captureSize: VideoSize { Self.size(machine.capture_size) }
    /// The TARGET's CG-top-left bounds reported in the ack (the initial geometry — a window's
    /// frame, updated thereafter by the geometry channel; a display's fixed CG bounds).
    public var windowBoundsCG: VideoRect { Self.rect(machine.window_bounds_cg) }

    public init(requestedWindowID: UInt32, viewport: VideoSize) {
        self.init(target: .window(requestedWindowID), viewport: viewport)
    }

    public init(target: VideoStreamTarget, viewport: VideoSize) {
        let (kind, id): (UInt32, UInt32) =
            switch target {
            case let .window(id): (SLOPDESK_VIDEO_TARGET_WINDOW, id)
            case let .display(id): (SLOPDESK_VIDEO_TARGET_DISPLAY, id)
            }
        machine = slopdesk_video_client_new(
            kind, id, SlopDeskVideoSize(width: viewport.width, height: viewport.height),
        )
    }

    /// Side effects the actor performs after a transition.
    public enum Effect: Equatable, Sendable {
        /// Send these bytes to the host on the control channel. Already ENCODED — the hello that
        /// opens every session is minted by the same crate the host parses it back with, so there is
        /// no second encoder for the runtime to disagree with.
        case sendControl([UInt8])
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
        /// Adopt the host's ~2 Hz stats-HUD reading (smoothed RTT + encode-wall EWMA, tenths of a
        /// millisecond; 0 = no reading yet). The actor stores the latest pair and folds it into the
        /// client-local network-stats mirror. Purely informational — no capture/decode effect.
        case applyHostStats(rttTenthsMillis: UInt16, encodeTenthsMillis: UInt16)
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
    public mutating func start() -> [Effect] { drain(slopdesk_video_client_start) }

    /// Re-emits the `hello` while STILL `.connecting` (hello-retry path — the second half of the
    /// reconnect-wedge fix). Over plain UDP the one-shot hello or its ack can be lost, and after a
    /// pipeline rebuild the restarted host may not be listening yet — either way, without a retry the
    /// session would wedge in `.connecting` forever. Driven on the ``HelloRetryPolicy`` cadence; any resolved state
    /// (streaming / rejected / stopped) returns `[]`, ending the retry loop. Idempotent on the host
    /// (a duplicate hello re-acks without restarting capture).
    public mutating func resendHello() -> [Effect] { drain(slopdesk_video_client_resend_hello) }

    /// `stop()` was called locally: tell the host (best-effort `bye`) and tear down.
    public mutating func stop() -> [Effect] { drain(slopdesk_video_client_stop) }

    /// A control datagram arrived from the host. The client acts only on `helloAck`
    /// (accept → start pipeline; reject → `.rejected`) and `bye` (host tore down → stop).
    /// A duplicate accepted ack while already streaming is ignored (idempotent — UDP may
    /// deliver the ack more than once).
    /// ⚠️ A ZERO-LOGIC WRAPPER, and deliberately kept. Its only callers are the state-machine tests,
    /// which construct `VideoControlMessage` values because that is the level they are testing at —
    /// but it decides NOTHING: it encodes and hands over, so there is no rule here that could drift
    /// from the one below. Do not delete it as dead, and do not grow it: the moment it does anything
    /// the datagram overload does not, the transition has two homes, and only one of them is on the
    /// live path where a disagreement would show.
    public mutating func handleControl(_ message: VideoControlMessage) -> [Effect] {
        handleControl(datagram: message.encode())
    }

    /// The same, from the datagram the transport handed over — the shape the door takes, so a caller
    /// that already holds the bytes does not re-encode what it just decoded. An undecodable datagram
    /// is inert: no effects, no transition.
    ///
    /// This is the entry the LIVE path takes. It existed and went uncalled: the session held the
    /// transport's `Data`, routed it, and then handed the DECODED message to the overload above,
    /// which encoded it back into bytes for the door to decode a second time. Measured at the
    /// operating point (a `scrollOffset`, which the host sends per frame while the picture scrolls):
    /// `[UInt8](message.encode())` is **148–155 ns** against **0.7 ns** for lending the datagram the
    /// caller already has, over two agreeing runs. Nine microseconds a second of scroll is not why
    /// this changed — a door written for exactly this call and left unreached is (`docs/55` §8).
    public mutating func handleControl(datagram: some ContiguousBytes) -> [Effect] {
        func step(
            _ seat: UnsafeMutablePointer<SlopDeskVideoClientMachine>?,
            _ out: UnsafeMutablePointer<SlopDeskVideoClientEffect>?,
            _ room: Int,
            _ masks: UnsafeMutablePointer<SlopDeskVideoMaskRect>?,
            _ maskRoom: Int,
            _ arena: UnsafeMutablePointer<UInt8>?,
            _ arenaRoom: Int,
        ) -> SlopDeskVideoClientShape {
            datagram.withUnsafeBytes { bytes in
                slopdesk_video_client_handle_control(
                    seat, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                    out, room, masks, maskRoom, arena, arenaRoom,
                )
            }
        }
        return drain(step)
    }

    /// Whether received media (video/geometry/cursor) should be processed right now.
    public var mediaFlowing: Bool { slopdesk_video_client_media_flowing(machine) }

    // MARK: - Crossing

    /// One transition, as the door takes it: the machine to step, and the three buffers its answer
    /// is written into.
    private typealias Step = (
        UnsafeMutablePointer<SlopDeskVideoClientMachine>?,
        UnsafeMutablePointer<SlopDeskVideoClientEffect>?,
        Int,
        UnsafeMutablePointer<SlopDeskVideoMaskRect>?,
        Int,
        UnsafeMutablePointer<UInt8>?,
        Int,
    ) -> SlopDeskVideoClientShape

    /// Runs one transition and reads its effects back.
    ///
    /// Two calls, and the first one is free of consequence: a transition that does not fit the lent
    /// buffers is NOT applied, so the measuring pass leaves the machine exactly where it was and the
    /// filling pass is the same transition rather than a second one.
    private mutating func drain(_ step: Step) -> [Effect] {
        let shape = withUnsafeMutablePointer(to: &machine) { seat in step(seat, nil, 0, nil, 0, nil, 0) }
        guard shape.effects > 0 else { return [] }
        let records = UnsafeMutableBufferPointer<SlopDeskVideoClientEffect>.allocate(capacity: shape.effects)
        defer { records.deallocate() }
        records.initialize(repeating: SlopDeskVideoClientEffect())
        let rects = UnsafeMutableBufferPointer<SlopDeskVideoMaskRect>.allocate(capacity: shape.masks)
        defer { rects.deallocate() }
        rects.initialize(repeating: SlopDeskVideoMaskRect())
        let arena = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: shape.arena)
        defer { arena.deallocate() }
        arena.initialize(repeating: 0)
        let filled = withUnsafeMutablePointer(to: &machine) { seat in
            step(
                seat, records.baseAddress, records.count, rects.baseAddress, rects.count,
                arena.baseAddress, arena.count,
            )
        }
        guard filled.effects == shape.effects else { return [] }
        return records.compactMap { record in Self.effect(record, rects, arena) }
    }

    /// One effect record, with its variable parts read out of the two arrays it points into.
    private static func effect(
        _ record: SlopDeskVideoClientEffect,
        _ rects: UnsafeMutableBufferPointer<SlopDeskVideoMaskRect>,
        _ arena: UnsafeMutableBufferPointer<UInt8>,
    ) -> Effect? {
        switch record.kind {
        case SLOPDESK_CLIENT_EFFECT_SEND_CONTROL:
            .sendControl(run(record.control, arena))
        case SLOPDESK_CLIENT_EFFECT_PRIME_CURSOR_FLOW:
            .primeCursorFlow
        case SLOPDESK_CLIENT_EFFECT_START_DECODE_PIPELINE:
            .startDecodePipeline(
                captureSize: size(record.size),
                windowBoundsCG: rect(record.bounds),
                fullRange: record.full_range,
            )
        case SLOPDESK_CLIENT_EFFECT_STOP_DECODE_PIPELINE:
            .stopDecodePipeline
        case SLOPDESK_CLIENT_EFFECT_UPDATE_CAPTURE_SIZE:
            .updateCaptureSize(size(record.size))
        case SLOPDESK_CLIENT_EFFECT_APPLY_STREAM_CADENCE:
            .applyStreamCadence(UInt16(truncatingIfNeeded: record.first))
        case SLOPDESK_CLIENT_EFFECT_APPLY_SCROLL_OFFSET:
            .applyScrollOffset(
                Int16(truncatingIfNeeded: record.dx),
                Int16(truncatingIfNeeded: record.dy),
                UInt16(truncatingIfNeeded: record.first),
                UInt16(truncatingIfNeeded: record.second),
            )
        case SLOPDESK_CLIENT_EFFECT_APPLY_CONTENT_MASK:
            .applyContentMask(mask(record, rects))
        case SLOPDESK_CLIENT_EFFECT_APPLY_DISPLAY_MAX:
            .applyDisplayMax(size(record.size))
        case SLOPDESK_CLIENT_EFFECT_APPLY_HOST_STATS:
            .applyHostStats(
                rttTenthsMillis: UInt16(truncatingIfNeeded: record.first),
                encodeTenthsMillis: UInt16(truncatingIfNeeded: record.second),
            )
        case SLOPDESK_CLIENT_EFFECT_SESSION_ENDED_BY_HOST:
            .sessionEndedByHost
        case SLOPDESK_CLIENT_EFFECT_SESSION_REJECTED_BY_HOST:
            .sessionRejectedByHost
        default:
            nil
        }
    }

    /// The run of the answer arena a span names.
    private static func run(_ span: SlopDeskByteSpan, _ arena: UnsafeMutableBufferPointer<UInt8>) -> [UInt8] {
        ArenaText.bytes(arena, offset: Int(span.offset), length: Int(span.length))
    }

    /// The run of the lent rectangles an effect names.
    private static func mask(
        _ record: SlopDeskVideoClientEffect,
        _ rects: UnsafeMutableBufferPointer<SlopDeskVideoMaskRect>,
    ) -> [MaskRect] {
        let start = Int(record.mask_offset)
        let end = start + Int(record.mask_count)
        guard start >= 0, end <= rects.count, start <= end else { return [] }
        return rects[start..<end].map { rect in
            MaskRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        }
    }

    private static func size(_ value: SlopDeskVideoSize) -> VideoSize {
        VideoSize(width: value.width, height: value.height)
    }

    private static func rect(_ value: SlopDeskVideoRect) -> VideoRect {
        VideoRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }
}

/// PURE hello-retry cadence (reconnect-wedge fix): how long to wait before re-sending the `hello`
/// while still `.connecting`. Exponential from `initialDelay`, capped at `maxDelay` — fast enough
/// that a lost ack costs half a second, slow enough that a pane pointed at a downed host settles to
/// one ~20-byte datagram per `maxDelay` (same order as the window dock's discovery poll). No clock,
/// no timer (the actor sleeps the returned delay) — headlessly unit-testable.
public enum HelloRetryPolicy {
    /// First retry fires this long after the initial hello (seconds) — which IS the delay before
    /// retry 0, so the number is asked for rather than restated.
    public static let initialDelay: TimeInterval = delay(attempt: 0)
    /// Ceiling for the backoff (seconds) — the delay at an attempt the backoff can never reach.
    public static let maxDelay: TimeInterval = delay(attempt: .max)

    /// The delay before retry number `attempt` (0-based: `attempt == 0` is the FIRST retry after
    /// the initial hello). `initialDelay × 2^attempt`, capped at `maxDelay`; a negative attempt is
    /// clamped to 0 (defensive — the caller counts up from 0).
    public static func delay(attempt: Int) -> TimeInterval {
        slopdesk_video_client_hello_retry_delay(UInt32(clamping: attempt))
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
        flipped { seat in slopdesk_stall_scrim_note_reconnecting(seat) }
    }

    /// Folds one verdict. Returns the NEW visibility when it flipped (the caller notifies the view),
    /// `nil` when unchanged (quiet — no per-tick re-notify). `.notConnected`/`.unknown` hold the
    /// current state (see the type doc: sticky through the rebuild).
    public mutating func apply(_ verdict: StreamStallPolicy.Verdict) -> Bool? {
        flipped { seat in slopdesk_stall_scrim_apply(seat, verdict.code) }
    }

    /// Runs one latch operation over the single bit this type is, and reads back what flipped.
    private mutating func flipped(_ fold: (UnsafeMutablePointer<Bool>) -> Int32) -> Bool? {
        let answer = withUnsafeMutablePointer(to: &visible) { seat in fold(seat) }
        switch answer {
        case SLOPDESK_SCRIM_SHOWN: return true
        case SLOPDESK_SCRIM_HIDDEN: return false
        default: return nil
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
        slopdesk_client_is_navigable(size(window), size(pane), zoom)
    }

    /// The maximum pan offset per axis (DISPLAY points, top-left basis): `displayed − pane`, floored at 0.
    /// Identical basis to ``isNavigable`` and to `layoutVideoLayer`'s frame clamp, so the gate, the edge-pan
    /// step clamp, and the layer position never disagree.
    public static func maxPanOffset(window: VideoSize, pane: VideoSize, zoom: Double) -> VideoPoint {
        let offset = slopdesk_client_max_pan_offset(size(window), size(pane), zoom)
        return VideoPoint(x: offset.x, y: offset.y)
    }

    private static func size(_ value: VideoSize) -> SlopDeskVideoSize {
        SlopDeskVideoSize(width: value.width, height: value.height)
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
    /// The whole tracker: one bit per held-modifier keycode, and every keycode that can be latched
    /// fits — the vocabulary is 54 through 63 (``InputModifierKeys/heldModifierKeyCodes``). A `Set`
    /// here was an allocation per pane to hold at most nine small integers, and it accepted keycodes
    /// that are not modifiers at all — latching them, then synthesising a key-up for them on the
    /// next focus loss. The crate refuses those now, so this cannot.
    private var latched = slopdesk_modifier_latch_new()

    public init() {}

    /// Whether no modifier is currently latched down.
    public var isEmpty: Bool { slopdesk_modifier_latch_is_empty(latched) }

    /// Whether `keyCode` is currently latched down.
    public func isDown(_ keyCode: UInt16) -> Bool { slopdesk_modifier_latch_is_down(latched, keyCode) }

    /// Record one modifier `flagsChanged` edge (idempotent — a repeated same-edge is absorbed).
    /// Caps Lock (57) is never latched, and neither is anything else outside the held-modifier
    /// vocabulary: it is a TOGGLE, not a held key, so the blur-time synthesized "release" (a bare
    /// key-up CGEvent on virtualKey 57) would FLIP the host's Caps state — focus/blur of a GUI pane
    /// with local Caps on toggled remote Caps every time. Its genuine `flagsChanged` edges still
    /// forward to the host 1:1; they just bypass the latch.
    public mutating func note(keyCode: UInt16, down: Bool) {
        latched = slopdesk_modifier_latch_note(latched, keyCode, down)
    }

    /// Returns every latched keyCode (ascending, deterministic emit order) and CLEARS the tracker —
    /// the caller synthesizes a host key-up for each so no modifier stays latched after focus loss.
    ///
    /// The buffer is lent at the crate's own capacity, which is the VOCABULARY rather than a number
    /// picked here: at that size the drain cannot come up short, so there is no measure pass and no
    /// half-drained latch to reason about.
    public mutating func drainForRelease() -> [UInt16] {
        let capacity = slopdesk_modifier_latch_capacity()
        var released = [UInt16](repeating: 0, count: capacity)
        let count = released.withUnsafeMutableBufferPointer { seats in
            withUnsafeMutablePointer(to: &latched) { mask in
                slopdesk_modifier_latch_drain(mask, seats.baseAddress, capacity)
            }
        }
        return Array(released.prefix(count))
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
        slopdesk_client_video_scale(
            SlopDeskVideoSize(width: layerSize.width, height: layerSize.height),
            SlopDeskVideoSize(width: decodedSize.width, height: decodedSize.height),
        )
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
        switch slopdesk_frame_decodability(keyframe, Swift.max(0, byteCount)) {
        case SLOPDESK_FRAME_REQUEST_KEYFRAME: .requestKeyframe
        case SLOPDESK_FRAME_DROP_SILENTLY: .dropSilently
        default: .decodable
        }
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
        // The absent previous frame crosses as a flag, not a sentinel size: "no frame yet" and "a
        // frame of zero by zero" are different states and only one of them means adopt.
        let previous = previousDecoded ?? VideoSize(width: 0, height: 0)
        return slopdesk_resize_should_adopt(
            box(pending), box(decoded), box(previous), previousDecoded != nil,
        )
    }

    private static func box(_ value: VideoSize) -> SlopDeskVideoSize {
        SlopDeskVideoSize(width: value.width, height: value.height)
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
    /// The whole debounce as it crosses: four fields, all of them read here, so there is nothing
    /// for a handle to own (docs/55 §4b) and value semantics survive the port.
    private var debounce: SlopDeskResizeDebounce

    /// Size of the last request actually EMITTED (`nil` ⇒ none yet — still at the hello-negotiated
    /// capture size). A new settled size is compared against this to drop sub-`minDelta` jitter.
    public var lastRequested: VideoSize? {
        guard debounce.has_last_requested else { return nil }
        return VideoSize(width: debounce.last_requested.width, height: debounce.last_requested.height)
    }

    /// Monotonic epoch of the last emitted request (0 ⇒ none emitted yet). The next emitted request
    /// carries `lastEpoch + 1`.
    public var lastEpoch: UInt32 { debounce.last_epoch }

    /// Minimum per-axis change (points) below which a new settled size is jitter, dropped (no
    /// request) — prevents a 1px layout wobble re-sizing capture.
    public var minDelta: Double { debounce.min_delta }
    /// How long the layer size must be UNCHANGED before the burst is settled and a request fires
    /// (seconds, elapsed-since-last-change passed in by the caller).
    public var settleInterval: TimeInterval { debounce.settle_interval }

    /// The band and the interval the client uses when nothing was configured — the crate's own, so
    /// the two languages cannot disagree about what "settled" means.
    public init() { debounce = slopdesk_resize_debounce_default() }

    public init(minDelta: Double, settleInterval: TimeInterval) {
        debounce = slopdesk_resize_debounce_new(minDelta, settleInterval)
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
        var settled = SlopDeskVideoSize(width: 0, height: 0)
        let verdict = withUnsafeMutablePointer(to: &settled) { out in
            slopdesk_resize_debounce_decide(
                debounce,
                SlopDeskVideoSize(width: layerSize.width, height: layerSize.height),
                elapsedSinceLastChange,
                out,
            )
        }
        guard verdict == SLOPDESK_RESIZE_REQUEST else { return .hold }
        return .request(VideoSize(width: settled.width, height: settled.height))
    }

    /// Records that a request for `size` was emitted: stores it as the new baseline and advances the
    /// epoch. Returns the epoch the emitted request must carry. Call ONLY after acting on a
    /// `.request(size)` decision (mirrors ``LTREscalationTracker/noteRequestSent(now:)`` being a
    /// separate mutator).
    @discardableResult
    public mutating func noteRequested(_ size: VideoSize) -> UInt32 {
        withUnsafeMutablePointer(to: &debounce) { seat in
            slopdesk_resize_debounce_note_requested(
                seat, SlopDeskVideoSize(width: size.width, height: size.height),
            )
        }
    }

    /// Rebases the jitter baseline on a size the CLIENT adopted by itself (the 1:1 pane snap — pane
    /// resized to the stream, nothing sent to the host), WITHOUT minting an epoch. The snap-induced
    /// layout pass then decides `.hold` (zero delta vs this baseline), so a client-side snap never
    /// echoes a `resizeRequest` back — which would AX-resize the host window and re-trigger the snap
    /// (a feedback loop). A LATER user drag still differs ≥ `minDelta` and requests normally.
    public mutating func noteAdopted(_ size: VideoSize) {
        withUnsafeMutablePointer(to: &debounce) { seat in
            slopdesk_resize_debounce_note_adopted(
                seat, SlopDeskVideoSize(width: size.width, height: size.height),
            )
        }
    }

    /// Spelled out because the crossed record is a C struct, which carries no `Equatable` of its
    /// own: two debounces are equal when the four things they answer are.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lastRequested == rhs.lastRequested
            && lhs.lastEpoch == rhs.lastEpoch
            && lhs.minDelta == rhs.minDelta
            && lhs.settleInterval == rhs.settleInterval
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
        let target = slopdesk_snap_target_points(box(pixelSize), captureScale)
        return VideoSize(width: target.width, height: target.height)
    }

    /// The HOST capture scale inferred from the first decoded frame: decoded PIXELS per negotiated
    /// window POINT (the helloAck `captureWidth/Height` are points). CONSTANT for the session (host
    /// captures at a fixed scale; only window points change on resize) — so the client infers it once
    /// and reuses it for every later in-session resize. A non-positive `windowPoints` width falls
    /// back to 1 (defensive: the helloAck always carries a real size before any frame).
    public static func inferredCaptureScale(decodedPixels: VideoSize, windowPoints: VideoSize) -> Double {
        slopdesk_snap_inferred_capture_scale(box(decodedPixels), box(windowPoints))
    }

    /// Whether the pane should snap: the 1:1 target differs from the current layer size by ≥
    /// `epsilon` points on some axis. Sub-epsilon deltas are layout noise — snapping on them would
    /// churn the canvas frame + persistence for an invisible change.
    public static func shouldSnap(target: VideoSize, current: VideoSize, epsilon: Double = epsilon) -> Bool {
        slopdesk_snap_should_snap(box(target), box(current), epsilon)
    }

    /// The slack below which a snap is layout noise rather than a real difference.
    public static let epsilon: Double = slopdesk_snap_epsilon()

    private static func box(_ value: VideoSize) -> SlopDeskVideoSize {
        SlopDeskVideoSize(width: value.width, height: value.height)
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
        /// A parsed app-audio datagram (config or one ~10 ms encoded frame — feed the
        /// audio decode path).
        case audio(AudioChannelMessage)
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
        case .audio:
            guard mediaFlowing else { return .ignore }
            do { return try .audio(AudioChannelMessage.decode(data)) } catch {
                return .drop(reason: "undecodable audio datagram")
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
        // The mapping crosses FLAT with a presence flag, because C has no two-variant enum — and
        // because a zero crop is a degenerate ACTUAL-SIZE viewport, which is a different answer from
        // "there is no crop". Only one of the two takes the aspect-fit path the golden vectors pin.
        let mapping = SlopDeskPointerMapping(
            video_native_size: SlopDeskVideoSize(
                width: videoNativeSize.width, height: videoNativeSize.height,
            ),
            zoom: zoom,
            pan: SlopDeskVideoPoint(x: pan.x, y: pan.y),
            mode: mode.code,
            crop: SlopDeskVideoRect(
                x: viewportCrop?.origin.x ?? 0, y: viewportCrop?.origin.y ?? 0,
                width: viewportCrop?.size.width ?? 0, height: viewportCrop?.size.height ?? 0,
            ),
            has_crop: viewportCrop != nil,
        )
        let normalized = slopdesk_input_normalize(
            SlopDeskVideoPoint(x: viewPoint.x, y: viewPoint.y),
            SlopDeskVideoSize(width: layerSize.width, height: layerSize.height),
            mapping,
        )
        return VideoPoint(x: normalized.x, y: normalized.y)
    }

    /// The tag the next emitted event will carry (for tests).
    public var peekNextTag: UInt32 { nextTag }

    private mutating func takeTag() -> UInt32 {
        let tag = nextTag
        nextTag = slopdesk_input_next_tag(nextTag)
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
    /// Ascending, because that is the order the crate keeps them in and the order it hands them back.
    private var known: [UInt16] = []
    /// The ids with an ask still outstanding, and the host time each was sent — two parallel lists
    /// rather than a dictionary because that is the shape a lent buffer can carry. Ascending by id.
    private var pendingIDs: [UInt16] = []
    private var pendingAt: [TimeInterval] = []

    /// Minimum spacing between re-requests for the SAME missing shapeID (seconds). A few × RTT:
    /// long enough that one re-ship has time to arrive, short enough to self-heal promptly.
    public let reRequestInterval: TimeInterval

    public init(reRequestInterval: TimeInterval = slopdesk_cursor_shape_default_interval()) {
        self.reRequestInterval = reRequestInterval
    }

    /// A cursor shape bitmap arrived for `shapeID` — mark it cached (idempotent) and stop
    /// re-requesting it.
    public mutating func noteShapeArrived(_ shapeID: UInt16) {
        _ = step { held, outKnown, knownCap, outIDs, outAt, pendingCap in
            slopdesk_cursor_shape_note_arrived(
                held.known, held.known.count, held.ids, held.at, held.ids.count, shapeID,
                outKnown, knownCap, outIDs, outAt, pendingCap,
            )
        }
    }

    /// Whether the id is already cached (no request needed). Test/diagnostics seam.
    public func isKnown(_ shapeID: UInt16) -> Bool {
        known.withUnsafeBufferPointer { slopdesk_cursor_shape_is_known($0.baseAddress, $0.count, shapeID) }
    }

    /// A cursor POSITION update referenced `shapeID` at host time `now`. Returns `true` iff the
    /// client should SEND a `requestCursorShape(shapeID)` now: the id is unknown AND no request for
    /// it was sent within ``reRequestInterval``. Records the request time on `true` (query+mutator),
    /// so the next ~120 Hz update for the same still-missing id does not immediately re-fire.
    public mutating func shouldRequest(shapeID: UInt16, now: TimeInterval) -> Bool {
        // The cached id is the STEADY STATE — the host samples the cursor at ~120 Hz and the shape
        // changes only when the pointer crosses a control — and it is the one case the crate answers
        // without touching its state, so asking through the door that reads nothing is the same
        // question, not a second copy of the rule. It matters because the general step lends three
        // buffers and adopts three prefixes: 6 allocations to be told "no". Measured against the
        // shipped xcframework, two agreeing runs: 488.0/509.1 ns per call with 4 cached shapes and
        // 1249.3/1122.3 ns with 12, against 68.5/68.6 ns and 252.2/258.6 ns through this guard.
        if isKnown(shapeID) { return false }
        // Read out before the step, which takes `self` exclusively: a closure reaching back for a
        // property of the value it is mutating is the same access twice.
        let interval = reRequestInterval
        return step { held, outKnown, knownCap, outIDs, outAt, pendingCap in
            slopdesk_cursor_shape_should_request(
                held.known, held.known.count, held.ids, held.at, held.ids.count, shapeID, now,
                interval, outKnown, knownCap, outIDs, outAt, pendingCap,
            )
        }
    }

    /// The three lists as one argument, so a step names its inputs once.
    private struct Held {
        let known: [UInt16]
        let ids: [UInt16]
        let at: [TimeInterval]
    }

    /// Runs one transition and adopts what it wrote.
    ///
    /// The buffers are lent one longer than what is held, which is the most any step can add — an
    /// arrival caches one id, an ask records one stamp — so the write always fits and there is no
    /// measure pass. The answer is adopted ONLY when it did fit: a step that could not write is not
    /// a decision, and acting on its `send` would put an ask on the wire the tracker has no record
    /// of, which is the flood the interval exists to prevent.
    private mutating func step(
        _ transition: (
            Held, UnsafeMutablePointer<UInt16>?, Int,
            UnsafeMutablePointer<UInt16>?, UnsafeMutablePointer<Double>?, Int,
        ) -> SlopDeskCursorShapeAnswer,
    ) -> Bool {
        var outKnown = [UInt16](repeating: 0, count: known.count + 1)
        var outIDs = [UInt16](repeating: 0, count: pendingIDs.count + 1)
        var outAt = [TimeInterval](repeating: 0, count: pendingAt.count + 1)
        let held = Held(known: known, ids: pendingIDs, at: pendingAt)
        let answer = outKnown.withUnsafeMutableBufferPointer { knownSeats in
            outIDs.withUnsafeMutableBufferPointer { idSeats in
                outAt.withUnsafeMutableBufferPointer { atSeats in
                    transition(
                        held, knownSeats.baseAddress, knownSeats.count,
                        idSeats.baseAddress, atSeats.baseAddress, idSeats.count,
                    )
                }
            }
        }
        guard answer.known <= outKnown.count, answer.pending <= outIDs.count else { return false }
        known = Array(outKnown.prefix(answer.known))
        pendingIDs = Array(outIDs.prefix(answer.pending))
        pendingAt = Array(outAt.prefix(answer.pending))
        return answer.send
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
    /// The whole estimate as it crosses: two optional stamps and the smoothed value, all of them
    /// read here, so there is nothing for a handle to own (docs/55 §4b).
    private var estimator = slopdesk_owd_jitter_new()

    /// Smoothed jitter (seconds), RFC3550 `J += (|D| − J)/16`.
    public var jitterSeconds: Double { estimator.jitter_seconds }

    public init() {}

    /// Folds one frame arrival (client monotonic seconds). Sample 1 seeds the arrival (no interval
    /// yet); sample 2 seeds the first interval (no 2nd-difference yet); from sample 3 on it updates
    /// the smoothed jitter — so an initial burst never emits a spurious spike.
    public mutating func note(arrival: Double) {
        withUnsafeMutablePointer(to: &estimator) { seat in slopdesk_owd_jitter_note(seat, arrival) }
    }

    /// The smoothed jitter as microseconds, clamped to the `UInt32` wire field (never traps the
    /// `UInt32(Double)` initializer: negatives floor to 0, an absurd value saturates at `UInt32.max`).
    public func jitterMicros() -> UInt32 { slopdesk_owd_jitter_micros(estimator) }

    /// Spelled out because the crossed record is a C struct, which carries no `Equatable` of its
    /// own: two estimators are equal when they would fold the next arrival the same way.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.estimator.has_last_arrival == rhs.estimator.has_last_arrival
            && lhs.estimator.last_arrival == rhs.estimator.last_arrival
            && lhs.estimator.has_last_inter_arrival == rhs.estimator.has_last_inter_arrival
            && lhs.estimator.last_inter_arrival == rhs.estimator.last_inter_arrival
            && lhs.jitterSeconds == rhs.jitterSeconds
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
    /// The whole controller as it crosses: seven numbers, all of them read here (docs/55 §4b).
    private var controller: SlopDeskAdaptiveJitter

    /// Floor — never recommend fewer than this many frames (1 ⇒ present as soon as decoded).
    public var minDepth: Int { Int(controller.min_depth) }
    /// Ceiling — the pacer's hard cap; the recommendation never exceeds it.
    public var maxDepth: Int { Int(controller.max_depth) }
    /// Presentation cadence (frames/s) — converts jitter SECONDS into a FRAME count.
    public var fps: Double { controller.fps }
    /// Buffer-sizing multiple: depth ≈ ceil(jitter × fps × safety). >1 gives a marginal link
    /// headroom so ordinary wobble does not underrun.
    public var jitterSafety: Double { controller.jitter_safety }
    /// Consecutive low-jitter frames required before a single one-step shrink (the slow, hysteretic
    /// path).
    public var shrinkCooldownFrames: Int { Int(controller.shrink_cooldown_frames) }
    /// The live recommendation (frames).
    public var targetDepth: Int { Int(controller.target_depth) }

    public init(
        minDepth: Int = 1,
        maxDepth: Int,
        fps: Double,
        initialDepth: Int,
        jitterSafety: Double = slopdesk_adaptive_jitter_default_safety(),
        shrinkCooldownFrames: Int = Int(slopdesk_adaptive_jitter_default_cooldown()),
    ) {
        controller = slopdesk_adaptive_jitter_new(
            UInt32(clamping: minDepth),
            UInt32(clamping: maxDepth),
            fps,
            UInt32(clamping: initialDepth),
            jitterSafety,
            UInt32(clamping: shrinkCooldownFrames),
        )
    }

    /// Folds one decoded-frame's smoothed jitter and returns the (possibly updated) depth.
    /// GROW FAST when the recommendation rises; SHRINK SLOW (one step per cooldown) when it
    /// falls; reset the cooldown when steady.
    @discardableResult
    public mutating func noteFrame(jitterSeconds: Double) -> Int {
        let depth = withUnsafeMutablePointer(to: &controller) { seat in
            slopdesk_adaptive_jitter_note_frame(seat, jitterSeconds)
        }
        return Int(depth)
    }

    /// A real starvation occurred — GROW one step immediately (capped) and restart the shrink
    /// cooldown so the bump is not undone by the next low-jitter frame.
    @discardableResult
    public mutating func noteUnderrun() -> Int {
        let depth = withUnsafeMutablePointer(to: &controller) { seat in
            slopdesk_adaptive_jitter_note_underrun(seat)
        }
        return Int(depth)
    }

    /// Spelled out because the crossed record is a C struct, which carries no `Equatable` of its
    /// own: two controllers are equal when they would fold the next frame the same way.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.controller.min_depth == rhs.controller.min_depth
            && lhs.controller.max_depth == rhs.controller.max_depth
            && lhs.controller.fps == rhs.controller.fps
            && lhs.controller.jitter_safety == rhs.controller.jitter_safety
            && lhs.controller.shrink_cooldown_frames == rhs.controller.shrink_cooldown_frames
            && lhs.controller.target_depth == rhs.controller.target_depth
            && lhs.controller.shrink_run == rhs.controller.shrink_run
    }
}
