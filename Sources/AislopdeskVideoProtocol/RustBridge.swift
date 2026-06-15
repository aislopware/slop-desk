import CAislopdeskFFI
import Foundation

/// Public entry to the Rust-core adaptive-playout law (the deadline pacer sizes its jitter buffer
/// through this). PUBLIC so the client's `FramePacer` (in `AislopdeskVideoClient`) can call it; the
/// rest of the C ABI stays encapsulated in the internal ``RustVideoFFI``.
public enum AdaptivePlayoutPolicy {
    /// One hysteretic step of the playout delay (milliseconds): maps live `jitterSeconds` to the
    /// target `clamp(k·jitter + base, [floor, ceil])` and steps `prevPlayoutMs` toward it — grow-fast,
    /// shrink-slow (≤ `shrinkStepMs` down per call). Wraps `aisd_adaptive_playout_step_ms`.
    public static func stepMs(
        jitterSeconds: Double,
        prevPlayoutMs: Double,
        shrinkStepMs: Double,
        k: Double,
        baseMs: Double,
        floorMs: Double,
        ceilMs: Double,
    ) -> Double {
        aisd_adaptive_playout_step_ms(jitterSeconds, prevPlayoutMs, shrinkStepMs, k, baseMs, floorMs, ceilMs)
    }
}

/// Swift-side bridge from `AislopdeskVideoProtocol` to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` for the video wire codecs is contained here; the codec types
/// call these typed wrappers so their public Swift APIs stay stable. The Rust core is the SINGLE
/// SOURCE OF TRUTH for the video wire codecs (there is no native Swift codec); its byte-exact
/// output is pinned by golden vectors, and the Swift marshaling here is pinned to the wire format
/// by `RustCodecWireVectorTests` (round-trips by `CodecTests`). The same core is the basis for the
/// Android client over the same C ABI.
///
/// Memory contract (mirrors `aislopdesk_ffi.h`): buffers passed *in* are borrowed for the
/// call only; any `AisdBytes` the library returns owns a Rust allocation and is released with
/// `aisd_bytes_free` before the wrapper returns.
enum RustVideoFFI {
    /// Encodes a cursor update (fixed 36 bytes) through the Rust core — the single source of
    /// truth. Encoding a valid update cannot fail (the only failure modes are a null `out` or a
    /// zero-length result, neither reachable here), so the guard traps rather than masking memory
    /// corruption with a second implementation.
    static func encode(_ update: CursorUpdate) -> Data {
        var out = AisdBytes()
        let status = aisd_cursor_update_encode(
            update.shapeID,
            update.visible ? 1 : 0,
            update.position.x,
            update.position.y,
            update.hotspot.x,
            update.hotspot.y,
            &out,
        )
        guard status == AISD_OK, let ptr = out.ptr, out.len > 0 else {
            preconditionFailure("aisd_cursor_update_encode failed for a valid update (status \(status))")
        }
        defer { aisd_bytes_free(out) }
        return Data(bytes: ptr, count: out.len)
    }

    /// Decodes a cursor update through the Rust core, throwing the ``VideoProtocolError`` cases
    /// that ``CursorUpdate`` decoding defines (`.malformed` for wrong type / non-finite,
    /// `.truncated` for a short body).
    static func decodeCursor(_ data: Data) throws -> CursorUpdate {
        var out = AisdCursorUpdate(shape_id: 0, visible: 0, x: 0, y: 0, hotspot_x: 0, hotspot_y: 0)
        let status: AisdStatus = data.withUnsafeBytes { raw in
            aisd_cursor_update_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        switch status {
        case AISD_OK:
            return CursorUpdate(
                position: VideoPoint(x: out.x, y: out.y),
                shapeID: out.shape_id,
                hotspot: VideoPoint(x: out.hotspot_x, y: out.hotspot_y),
                visible: out.visible != 0,
            )
        case AISD_ERR_MALFORMED:
            throw VideoProtocolError.malformed("rust: malformed cursor update")
        default:
            throw VideoProtocolError.truncated
        }
    }

    // MARK: - window_geometry (move/resize/bounds/title; one owned title buffer)

    /// Encodes a window-geometry message through the Rust core — the single source of truth.
    /// `move`/`resize`/`bounds` cross as scalars; a `title` is borrowed in (Rust copies it, never
    /// frees). Encoding a valid message cannot fail (the kind is always valid and a Swift `String`
    /// is always UTF-8), so the guard traps rather than masking corruption with a second codec.
    static func encode(_ message: WindowGeometryMessage) -> Data {
        func emit(_ c: inout AisdWindowGeometry) -> Data {
            var out = AisdBytes()
            let status = aisd_window_geometry_encode(&c, &out)
            guard status == AISD_OK, let ptr = out.ptr, out.len > 0 else {
                preconditionFailure("aisd_window_geometry_encode failed for a valid message (status \(status))")
            }
            defer { aisd_bytes_free(out) }
            return Data(bytes: ptr, count: out.len)
        }
        var c = AisdWindowGeometry()
        c.kind = message.messageType
        switch message {
        case let .move(p):
            c.x = p.x
            c.y = p.y
            return emit(&c)
        case let .resize(s):
            c.width = s.width
            c.height = s.height
            return emit(&c)
        case let .bounds(r):
            c.x = r.origin.x
            c.y = r.origin.y
            c.width = r.size.width
            c.height = r.size.height
            return emit(&c)
        case let .title(title):
            var bytes = Array(title.utf8)
            return bytes.withUnsafeMutableBufferPointer { buf in
                c.title = AisdBytes(ptr: buf.baseAddress, len: buf.count, cap: 0)
                return emit(&c)
            }
        }
    }

    /// Decodes a window-geometry message through the Rust core, throwing the same
    /// ``VideoProtocolError`` cases the native decoder does (`.malformed` for a non-finite
    /// coordinate / non-UTF-8 title / unknown type, `.truncated` for a short body).
    static func decodeWindowGeometry(_ data: Data) throws -> WindowGeometryMessage {
        var out = AisdWindowGeometry()
        let status: AisdStatus = data.withUnsafeBytes { raw in
            aisd_window_geometry_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        switch status {
        case AISD_OK:
            defer { aisd_window_geometry_free(&out) }
            // out.kind ∈ {1 move, 2 resize, 3 bounds, 4 title} on a successful decode.
            switch out.kind {
            case 1:
                return .move(VideoPoint(x: out.x, y: out.y))
            case 2:
                return .resize(VideoSize(width: out.width, height: out.height))
            case 3:
                return .bounds(VideoRect(x: out.x, y: out.y, width: out.width, height: out.height))
            default:
                return .title(string(from: out.title))
            }
        case AISD_ERR_MALFORMED:
            throw VideoProtocolError.malformed("rust: malformed window geometry")
        default:
            throw VideoProtocolError.truncated
        }
    }

    // MARK: - input_event (pointer/key/scroll/text; one owned text buffer)

    /// Encodes a client→host input event through the Rust core — the single source of truth.
    /// Scalar fields cross by value; a `text` payload is borrowed in (Rust copies it, never frees).
    /// Encoding a valid event cannot fail (the kind/button are always valid and a Swift `String`
    /// is always UTF-8), so the guard traps rather than masking corruption with a second codec.
    static func encode(_ event: InputEvent) -> Data {
        func emit(_ c: inout AisdInputEvent) -> Data {
            var out = AisdBytes()
            let status = aisd_input_event_encode(&c, &out)
            guard status == AISD_OK, let ptr = out.ptr, out.len > 0 else {
                preconditionFailure("aisd_input_event_encode failed for a valid event (status \(status))")
            }
            defer { aisd_bytes_free(out) }
            return Data(bytes: ptr, count: out.len)
        }
        var c = AisdInputEvent()
        c.kind = event.messageType
        c.tag = event.tag
        switch event {
        case let .mouseMove(n, _):
            c.x = n.x
            c.y = n.y
            return emit(&c)
        case let .mouseDown(button, n, clickCount, mods, _),
             let .mouseUp(button, n, clickCount, mods, _),
             let .mouseDrag(button, n, clickCount, mods, _):
            c.button = button.rawValue
            c.click_count = clickCount
            c.modifiers = mods.rawValue
            c.x = n.x
            c.y = n.y
            return emit(&c)
        case let .scroll(dx, dy, n, scrollPhase, momentumPhase, continuous, _):
            c.dx = dx
            c.dy = dy
            c.x = n.x
            c.y = n.y
            c.scroll_phase = scrollPhase
            c.momentum_phase = momentumPhase
            c.continuous = continuous ? 1 : 0
            return emit(&c)
        case let .key(keyCode, down, mods, _):
            c.key_code = keyCode
            c.down = down ? 1 : 0
            c.modifiers = mods.rawValue
            return emit(&c)
        case let .text(string, _):
            var bytes = Array(string.utf8)
            return bytes.withUnsafeMutableBufferPointer { buf in
                c.text = AisdBytes(ptr: buf.baseAddress, len: buf.count, cap: 0)
                return emit(&c)
            }
        }
    }

    /// Decodes a client→host input event through the Rust core, throwing the same
    /// ``VideoProtocolError`` cases the native decoder does (`.malformed` for a non-finite
    /// coordinate / unknown button / non-UTF-8 text / unknown type, `.truncated` for a short body).
    static func decodeInputEvent(_ data: Data) throws -> InputEvent {
        var out = AisdInputEvent()
        let status: AisdStatus = data.withUnsafeBytes { raw in
            aisd_input_event_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        switch status {
        case AISD_OK:
            defer { aisd_input_event_free(&out) }
            let n = VideoPoint(x: out.x, y: out.y)
            let mods = InputModifiers(rawValue: out.modifiers)
            // out.kind ∈ {1 move, 2 down, 3 up, 4 scroll, 5 key, 6 text, 7 drag} on success.
            switch out.kind {
            case 1:
                return .mouseMove(normalized: n, tag: out.tag)
            case 2,
                 3,
                 7:
                guard let button = MouseButton(rawValue: out.button) else {
                    throw VideoProtocolError.malformed("rust: unknown mouse button")
                }
                switch out.kind {
                case 2:
                    return .mouseDown(
                        button: button,
                        normalized: n,
                        clickCount: out.click_count,
                        modifiers: mods,
                        tag: out.tag,
                    )
                case 3:
                    return .mouseUp(
                        button: button,
                        normalized: n,
                        clickCount: out.click_count,
                        modifiers: mods,
                        tag: out.tag,
                    )
                default:
                    return .mouseDrag(
                        button: button,
                        normalized: n,
                        clickCount: out.click_count,
                        modifiers: mods,
                        tag: out.tag,
                    )
                }
            case 4:
                return .scroll(
                    dx: out.dx,
                    dy: out.dy,
                    normalized: n,
                    scrollPhase: out.scroll_phase,
                    momentumPhase: out.momentum_phase,
                    continuous: out.continuous != 0,
                    tag: out.tag,
                )
            case 5:
                return .key(keyCode: out.key_code, down: out.down != 0, modifiers: mods, tag: out.tag)
            default:
                return .text(string(from: out.text), tag: out.tag)
            }
        case AISD_ERR_MALFORMED:
            throw VideoProtocolError.malformed("rust: malformed input event")
        default:
            throw VideoProtocolError.truncated
        }
    }

    // MARK: - video_control (PATH-2 session bring-up + window/dialog discovery lists)

    /// The fields common to a `windowList` / `systemDialogList` record, unified so the two list
    /// variants share one marshaling path (`isSecure` / `keystrokesBlocked` are meaningful only for a
    /// system dialog).
    private struct SummaryParts {
        let windowID: UInt32
        let width: UInt16
        let height: UInt16
        let isSecure: Bool
        let keystrokesBlocked: Bool
        let name: String
        let title: String
    }

    /// Encodes a PATH-2 video control message through the Rust core — the single source of truth.
    /// Scalars cross by value; the `windowList`/`systemDialogList` records are borrowed in (Rust
    /// copies them, never frees). Encoding a valid message cannot fail (the kind is always valid
    /// and a Swift `String` is always UTF-8), so the guard traps rather than masking corruption
    /// with a second codec.
    static func encode(_ message: VideoControlMessage) -> Data {
        var c = AisdVideoControl()
        c.kind = message.messageType
        switch message {
        case let .hello(version, windowID, viewport):
            c.protocol_version = version
            c.requested_window_id = windowID
            c.viewport_w = viewport.width
            c.viewport_h = viewport.height
            return emitVideoControl(&c)
        case let .helloAck(accepted, streamID, captureWidth, captureHeight, bounds, fullRange):
            c.accepted = accepted ? 1 : 0
            c.stream_id = streamID
            c.capture_width = captureWidth
            c.capture_height = captureHeight
            c.full_range = fullRange ? 1 : 0
            c.bounds_x = bounds.origin.x
            c.bounds_y = bounds.origin.y
            c.bounds_w = bounds.size.width
            c.bounds_h = bounds.size.height
            return emitVideoControl(&c)
        case .bye,
             .keepalive,
             .listWindows,
             .focusWindow,
             .listSystemDialogs:
            return emitVideoControl(&c)
        case let .resizeRequest(desired, epoch):
            c.desired_w = desired.width
            c.desired_h = desired.height
            c.epoch = epoch
            return emitVideoControl(&c)
        case let .resizeAck(captureWidth, captureHeight, epoch):
            c.capture_width = captureWidth
            c.capture_height = captureHeight
            c.epoch = epoch
            return emitVideoControl(&c)
        case let .streamCadence(fps):
            c.fps = fps
            return emitVideoControl(&c)
        case let .windowList(windows):
            return encodeRecords(kind: message.messageType, windows.map {
                SummaryParts(
                    windowID: $0.windowID, width: $0.width, height: $0.height,
                    isSecure: false, keystrokesBlocked: false, name: $0.appName, title: $0.title,
                )
            })
        case let .systemDialogList(dialogs):
            return encodeRecords(kind: message.messageType, dialogs.map {
                SummaryParts(
                    windowID: $0.windowID, width: $0.width, height: $0.height,
                    isSecure: $0.isSecure, keystrokesBlocked: $0.keystrokesBlocked,
                    name: $0.owner, title: $0.title,
                )
            })
        }
    }

    /// Encodes a caller-built `AisdVideoControl` (the scalar fields already set) through the FFI.
    private static func emitVideoControl(_ c: inout AisdVideoControl) -> Data {
        var out = AisdBytes()
        let status = aisd_video_control_encode(&c, &out)
        guard status == AISD_OK, let ptr = out.ptr, out.len > 0 else {
            preconditionFailure("aisd_video_control_encode failed for a valid message (status \(status))")
        }
        defer { aisd_bytes_free(out) }
        return Data(bytes: ptr, count: out.len)
    }

    /// Marshals a record list (`windowList`/`systemDialogList`) and encodes it. Every record's two
    /// UTF-8 strings are flattened into one contiguous blob the record `AisdBytes` borrow into; Rust
    /// copies them during the call, so the blob only has to outlive `aisd_video_control_encode`.
    private static func encodeRecords(kind: UInt8, _ parts: [SummaryParts]) -> Data {
        var blob: [UInt8] = []
        var spans: [(nameOffset: Int, nameLen: Int, titleOffset: Int, titleLen: Int)] = []
        for part in parts {
            let name = Array(part.name.utf8)
            let title = Array(part.title.utf8)
            let nameOffset = blob.count
            blob.append(contentsOf: name)
            let titleOffset = blob.count
            blob.append(contentsOf: title)
            spans.append((nameOffset, name.count, titleOffset, title.count))
        }
        var c = AisdVideoControl()
        c.kind = kind
        return blob.withUnsafeMutableBytes { raw -> Data in
            let base = raw.baseAddress
            func bytes(_ offset: Int, _ len: Int) -> AisdBytes {
                guard len > 0, let base else { return AisdBytes() }
                return AisdBytes(ptr: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), len: len, cap: 0)
            }
            var summaries = parts.enumerated().map { index, part in
                AisdVideoSummary(
                    window_id: part.windowID,
                    width: part.width,
                    height: part.height,
                    is_secure: part.isSecure ? 1 : 0,
                    keystrokes_blocked: part.keystrokesBlocked ? 1 : 0,
                    name: bytes(spans[index].nameOffset, spans[index].nameLen),
                    title: bytes(spans[index].titleOffset, spans[index].titleLen),
                )
            }
            return summaries.withUnsafeMutableBufferPointer { buf -> Data in
                c.records = buf.baseAddress
                c.records_len = buf.count
                return emitVideoControl(&c)
            }
        }
    }

    /// Decodes a PATH-2 video control message through the Rust core, throwing the same
    /// ``VideoProtocolError`` cases the native decoder did (`.malformed` for a non-finite
    /// coordinate / unknown type, `.truncated` for a short body; record strings decode lossily).
    static func decodeVideoControl(_ data: Data) throws -> VideoControlMessage {
        var out = AisdVideoControl()
        let status: AisdStatus = data.withUnsafeBytes { raw in
            aisd_video_control_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        switch status {
        case AISD_OK:
            defer { aisd_video_control_free(&out) }
            // out.kind ∈ 1...12 on a successful decode; the record strings are copied out below
            // (into Swift `String`s) before the deferred free releases the borrowed buffers.
            switch out.kind {
            case 1:
                return .hello(
                    protocolVersion: out.protocol_version,
                    requestedWindowID: out.requested_window_id,
                    viewport: VideoSize(width: out.viewport_w, height: out.viewport_h),
                )
            case 2:
                return .helloAck(
                    accepted: out.accepted != 0,
                    streamID: out.stream_id,
                    captureWidth: out.capture_width,
                    captureHeight: out.capture_height,
                    windowBoundsCG: VideoRect(
                        x: out.bounds_x,
                        y: out.bounds_y,
                        width: out.bounds_w,
                        height: out.bounds_h,
                    ),
                    fullRange: out.full_range != 0,
                )
            case 3:
                return .bye
            case 4:
                return .resizeRequest(desired: VideoSize(width: out.desired_w, height: out.desired_h), epoch: out.epoch)
            case 5:
                return .resizeAck(captureWidth: out.capture_width, captureHeight: out.capture_height, epoch: out.epoch)
            case 6:
                return .keepalive
            case 7:
                return .listWindows
            case 8:
                return .windowList(summaries(from: out).map {
                    WindowSummary(
                        windowID: $0.window_id, appName: string(from: $0.name), title: string(from: $0.title),
                        width: $0.width, height: $0.height,
                    )
                })
            case 9:
                return .focusWindow
            case 10:
                return .streamCadence(fps: out.fps)
            case 11:
                return .listSystemDialogs
            default:
                return .systemDialogList(summaries(from: out).map {
                    SystemDialogSummary(
                        windowID: $0.window_id, owner: string(from: $0.name), title: string(from: $0.title),
                        width: $0.width, height: $0.height, isSecure: $0.is_secure != 0,
                        keystrokesBlocked: $0.keystrokes_blocked != 0,
                    )
                })
            }
        case AISD_ERR_MALFORMED:
            throw VideoProtocolError.malformed("rust: malformed video control")
        default:
            throw VideoProtocolError.truncated
        }
    }

    /// Reads the decoded record array (`records`/`records_len`) into a Swift array. The borrowed
    /// `AisdBytes` inside each record stay valid until the caller's `aisd_video_control_free`.
    private static func summaries(from control: AisdVideoControl) -> [AisdVideoSummary] {
        guard let base = control.records, control.records_len > 0 else { return [] }
        return (0..<control.records_len).map { base[$0] }
    }

    /// Copies a returned `AisdBytes` UTF-8 payload into a `String` (empty for the null buffer).
    /// The buffer itself is released by the caller's `*_free`.
    private static func string(from bytes: AisdBytes) -> String {
        guard let ptr = bytes.ptr, bytes.len > 0 else { return "" }
        // The bytes were already validated as UTF-8 by the Rust decoder, so the failable
        // initializer never returns nil here; `?? ""` is a total, unreachable fallthrough.
        return String(bytes: UnsafeBufferPointer(start: ptr, count: bytes.len), encoding: .utf8) ?? ""
    }

    // MARK: - adaptive_fec (pure scalar; env stays Swift-side, crosses as params)

    /// Maps a wire FEC tier to the group size both ends must use, or `nil` for the OFF
    /// (no-parity) tier. Wraps `aisd_adaptive_fec_group_size`. TOTAL over every tier.
    static func adaptiveFECGroupSize(tier: UInt8, defaultGroupSize: Int) -> Int? {
        var out = 0
        let isParity = withUnsafeMutablePointer(to: &out) { p in
            aisd_adaptive_fec_group_size(tier, defaultGroupSize, p)
        }
        return isParity != 0 ? out : nil
    }

    /// Picks the next wire tier from the EWMA loss and previous tier (plain decider). Wraps
    /// `aisd_adaptive_fec_tier`.
    static func adaptiveFECTier(loss: Double, previousTier: UInt8, allowOff: Bool) -> UInt8 {
        aisd_adaptive_fec_tier(loss, previousTier, allowOff ? 1 : 0)
    }

    /// Dwell-gated tier step (production entry point). Wraps `aisd_adaptive_fec_next_tier_state`,
    /// marshaling the value-type state through the flat `AisdTierState`.
    static func adaptiveFECNextTierState(
        loss: Double,
        tier: UInt8,
        relaxStreak: Int,
        stickyRelaxRemaining: Int,
        dwell: Int,
        allowOff: Bool,
        sawUnrecoveredLoss: Bool,
    ) -> (tier: UInt8, relaxStreak: Int, stickyRelaxRemaining: Int) {
        let inState = AisdTierState(
            tier: tier,
            relax_streak: Int32(clamping: relaxStreak),
            sticky_relax_remaining: Int32(clamping: stickyRelaxRemaining),
        )
        let out = aisd_adaptive_fec_next_tier_state(
            loss, inState, Int32(clamping: dwell), allowOff ? 1 : 0, sawUnrecoveredLoss ? 1 : 0,
        )
        return (out.tier, Int(out.relax_streak), Int(out.sticky_relax_remaining))
    }

    // MARK: - coordinate_mapping (pure scalar over flat structs; env-free)

    private static func cPoint(_ p: VideoPoint) -> AisdPoint { AisdPoint(x: p.x, y: p.y) }
    private static func point(_ c: AisdPoint) -> VideoPoint { VideoPoint(x: c.x, y: c.y) }
    private static func cRect(_ r: VideoRect) -> AisdRect {
        AisdRect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
    }

    /// Maps a normalised (0..1) window point to a host-window point in CG top-left space.
    static func coordWindowPoint(normalized: VideoPoint, windowBounds: VideoRect) -> VideoPoint {
        point(aisd_coord_window_point(cPoint(normalized), cRect(windowBounds)))
    }

    /// Flips a CG-top-left rect into Cocoa bottom-left space.
    static func coordCGRectToCocoa(_ cgRect: VideoRect, primaryHeight: Double) -> VideoRect {
        let r = aisd_coord_cg_rect_to_cocoa(cRect(cgRect), primaryHeight)
        return VideoRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    /// Picks the screen a window lives on (largest overlap) and returns its
    /// `backingScaleFactor`, or `nil` for no overlap. The screens array is borrowed for the call.
    static func coordBackingScaleFactor(
        windowBoundsCG: VideoRect,
        screens: [ScreenInfo],
        primaryHeight: Double,
    ) -> Double? {
        let cScreens = screens.map { s in
            AisdScreenInfo(cocoa_frame: cRect(s.cocoaFrame), backing_scale_factor: s.backingScaleFactor)
        }
        var scale = 0.0
        let status: AisdStatus = cScreens.withUnsafeBufferPointer { buf in
            aisd_coord_backing_scale_factor(
                cRect(windowBoundsCG), buf.baseAddress, buf.count, primaryHeight, &scale,
            )
        }
        return status == AISD_OK ? scale : nil
    }

    /// Pixel path: divide by `scale` to get points, then add the window origin.
    static func coordWindowPoint(
        pixel: VideoPoint,
        windowBoundsCG: VideoRect,
        backingScaleFactor scale: Double,
    ) -> VideoPoint {
        point(aisd_coord_window_point_from_pixel(cPoint(pixel), cRect(windowBoundsCG), scale))
    }

    // MARK: - recovery_policy (pure scalar; env-resolved floor stays Swift-side)

    /// Whether the client should escalate a stalled LTR-refresh recovery to a forced IDR.
    /// Wraps `aisd_recovery_policy_should_escalate_to_idr`.
    static func recoveryShouldEscalateToIDR(
        idrTimeoutRTTMultiple: Double,
        lossyIdrTimeoutRTTMultiple: Double,
        lossyEscalationFloor: Double,
        lossyEscalationFloorRTTMultiple: Double,
        elapsedSinceRequest: Double,
        rtt: Double,
        observingLoss: Bool,
    ) -> Bool {
        aisd_recovery_policy_should_escalate_to_idr(
            idrTimeoutRTTMultiple, lossyIdrTimeoutRTTMultiple, lossyEscalationFloor,
            lossyEscalationFloorRTTMultiple, elapsedSinceRequest, rtt, observingLoss ? 1 : 0,
        ) != 0
    }
}
