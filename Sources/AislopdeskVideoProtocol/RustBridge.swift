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

/// Public Swift handle over the Rust-core scroll-hint reprojection law (`aisd_scroll_reprojector_*`).
///
/// PUBLIC so the client's `FramePacer` / `MetalVideoRenderer` wiring (in `AislopdeskVideoClient`) can
/// own one per video pane. The Rust core is the SINGLE SOURCE OF TRUTH for the offset law — this
/// type holds only the opaque handle and forwards. v1 is CLIENT-ONLY: the client already originates
/// the scroll delta locally, so there is no wire / protocol change.
///
/// The law: integrate the local scroll velocity into a small normalized UV offset on the pacer's
/// *between-content* display ticks (so a remote window scrolls at the display rate), clamp it to a
/// band, decay it once the scroll stops, and RESET it to exactly zero the instant a real decoded
/// frame is presented (that frame already contains the scrolled content — resetting is what prevents
/// the double-count). One owner per pane; not thread-safe (the caller's main actor / pacer lock
/// serializes it).
public final class ScrollReprojector: @unchecked Sendable {
    /// The `AISD_SCROLL_PHASE_*` discriminant, mirrored so callers do not import `CAislopdeskFFI`.
    public enum Phase: UInt8 {
        /// Finger on glass: track velocity, no decay.
        case active = 0
        /// Inertial coast: track velocity, no decay.
        case momentum = 1
        /// Gesture finished: arm the decay.
        case ended = 2
    }

    private let handle: OpaquePointer

    /// Builds a reprojector with the band (normalized units) + decay time-constant (seconds). The
    /// Rust core sanitizes both, so a hostile value can never produce a runaway / negative offset.
    public init(maxBand: Double, decaySeconds: Double) {
        let config = AisdScrollReprojectorConfig(max_band: maxBand, decay_seconds: decaySeconds)
        // `aisd_scroll_reprojector_new` never returns null (the allocation is infallible), so the
        // force-unwrap is total — a null here would mean OOM, which traps everywhere anyway.
        guard let handle = aisd_scroll_reprojector_new(config) else {
            preconditionFailure("aisd_scroll_reprojector_new returned null")
        }
        self.handle = handle
    }

    deinit { aisd_scroll_reprojector_free(handle) }

    /// Folds one scroll-velocity sample (`vx`/`vy` in normalized units per second) with its phase.
    public func noteVelocity(vx: Double, vy: Double, phase: Phase) {
        aisd_scroll_reprojector_note_velocity(handle, vx, vy, phase.rawValue)
    }

    /// Integrates over `elapsedSeconds` (or decays a stopped scroll), clamps to the band, and returns
    /// the current normalized offset `(x, y)`.
    public func advance(elapsedSeconds: Double) -> (x: Double, y: Double) {
        var ox = 0.0
        var oy = 0.0
        // The only non-OK return is a null handle / null out-param, neither reachable here, so the
        // status is ignored — a defensive failure leaves `ox`/`oy` at zero (a no-op offset).
        _ = aisd_scroll_reprojector_advance(handle, elapsedSeconds, &ox, &oy)
        return (ox, oy)
    }

    /// Resets the offset (and integration baseline) to exactly zero — call the instant a real decoded
    /// frame is presented so the hint is never added on top of the real scroll (the double-count
    /// guard). The live velocity is preserved.
    public func noteRealFrame() {
        aisd_scroll_reprojector_note_real_frame(handle)
    }

    /// Fully resets the reprojector (offset AND velocity to zero) — call when a pane goes idle / loses
    /// focus so a stale velocity can never resume.
    public func reset() {
        aisd_scroll_reprojector_reset(handle)
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

    // MARK: - mux_header (the per-datagram `[u32 BE channelID][payload]` prefix; the live video wire)

    /// Stamps the 4-byte big-endian channelID prefix in FRONT of `payload` through the Rust core —
    /// the single source of truth shared with the Android shell. The framing buffer is allocated
    /// ONCE (`channelIDLength + payload.count`); the FFI writes only the 4 prefix bytes (caller-out,
    /// no per-packet heap on the Rust side), then the payload is copied after. Byte-identical to the
    /// prior native `appendBE` framing (the `muxBare` golden vector pins it). Encoding cannot fail
    /// for a buffer we sized ourselves, so the guard traps rather than masking corruption.
    static func encodeMuxHeader(channelID: UInt32, payload: Data) -> Data {
        let prefix = Int(AISD_VIDEO_MUX_CHANNEL_ID_LENGTH)
        var framed = Data(count: prefix + payload.count)
        var written = 0
        framed.withUnsafeMutableBytes { raw in
            let status = aisd_video_mux_header_encode(
                channelID, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &written,
            )
            guard status == AISD_OK, written == prefix else {
                preconditionFailure("aisd_video_mux_header_encode failed for a sized buffer (status \(status))")
            }
        }
        // Copy the opaque payload after the prefix (the payload is the caller's, never the codec's).
        if !payload.isEmpty {
            framed.replaceSubrange((framed.startIndex + prefix)..., with: payload)
        }
        return framed
    }

    /// Splits a muxed datagram into its leading channelID and the opaque remainder through the Rust
    /// core. The FFI borrows the datagram and returns the channelID + the payload byte offset
    /// (always `channelIDLength`); the payload sub-slice is formed here as a zero-copy `Data` view,
    /// exactly as the prior native `VideoByteReader.remaining()` did.
    ///
    /// - Throws: ``VideoProtocolError/truncated`` when fewer than 4 bytes are present (a corrupt
    ///   single datagram must never crash the receiver — same contract as before).
    static func decodeMuxHeader(_ datagram: Data) throws -> (channelID: UInt32, payload: Data) {
        var channelID: UInt32 = 0
        var offset = 0
        let status: AisdStatus = datagram.withUnsafeBytes { raw in
            aisd_video_mux_header_decode(
                raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &channelID, &offset,
            )
        }
        guard status == AISD_OK else { throw VideoProtocolError.truncated }
        // The payload begins `offset` bytes in; a zero-copy `Data` sub-view over the same storage.
        let payload = datagram[(datagram.startIndex + offset)...]
        return (channelID, Data(payload))
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
    /// variants share one marshaling path (`isSecure` is meaningful only for a system dialog).
    private struct SummaryParts {
        let windowID: UInt32
        let width: UInt16
        let height: UInt16
        let isSecure: Bool
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
        case let .scrollOffset(dx, dy):
            c.scroll_dx = dx
            c.scroll_dy = dy
            return emitVideoControl(&c)
        case let .contentMask(rects):
            return encodeMaskRects(kind: message.messageType, rects)
        case let .windowList(windows):
            return encodeRecords(kind: message.messageType, windows.map {
                SummaryParts(
                    windowID: $0.windowID, width: $0.width, height: $0.height,
                    isSecure: false, name: $0.appName, title: $0.title,
                )
            })
        case let .systemDialogList(dialogs):
            return encodeRecords(kind: message.messageType, dialogs.map {
                SummaryParts(
                    windowID: $0.windowID, width: $0.width, height: $0.height,
                    isSecure: $0.isSecure, name: $0.owner, title: $0.title,
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

    /// Marshals a content-mask rect list (POD — no owned strings, unlike `encodeRecords`) and
    /// encodes it. The C rect array is borrowed for the call; Rust copies it during the encode.
    private static func encodeMaskRects(kind: UInt8, _ rects: [MaskRect]) -> Data {
        var c = AisdVideoControl()
        c.kind = kind
        var cRects = rects.map { AisdMaskRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return cRects.withUnsafeMutableBufferPointer { buf -> Data in
            c.mask_rects = buf.baseAddress
            c.mask_rects_len = buf.count
            return emitVideoControl(&c)
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
            case 13:
                return .scrollOffset(dx: out.scroll_dx, dy: out.scroll_dy)
            case 14:
                return .contentMask(maskRects(from: out).map {
                    MaskRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                })
            default:
                return .systemDialogList(summaries(from: out).map {
                    SystemDialogSummary(
                        windowID: $0.window_id, owner: string(from: $0.name), title: string(from: $0.title),
                        width: $0.width, height: $0.height, isSecure: $0.is_secure != 0,
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

    /// Reads the decoded content-mask rect array (`mask_rects`/`mask_rects_len`) into a Swift array.
    /// Valid until the caller's `aisd_video_control_free`.
    private static func maskRects(from control: AisdVideoControl) -> [AisdMaskRect] {
        guard let base = control.mask_rects, control.mask_rects_len > 0 else { return [] }
        return (0..<control.mask_rects_len).map { base[$0] }
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

    // MARK: - ycbcr (pure scalar; the BT.709 coefficient table the Metal shader applies)

    /// The BT.709 YCbCr→RGB coefficients for the negotiated luma range, through the Rust core —
    /// the single source of truth for the shader constants (there is no native Swift table). Wraps
    /// `aisd_ycbcr_coefficients`.
    static func ycbcrCoefficients(fullRange: Bool) -> YCbCrCoefficients {
        let c = aisd_ycbcr_coefficients(fullRange ? 1 : 0)
        return YCbCrCoefficients(
            lumaScale: c.luma_scale,
            lumaBias: c.luma_bias,
            chromaBias: c.chroma_bias,
            crToR: c.cr_to_r,
            cbToG: c.cb_to_g,
            crToG: c.cr_to_g,
            cbToB: c.cb_to_b,
        )
    }

    // MARK: - recovery (client→host loss-recovery / ack / cursor-reship / netstats codec)

    /// Encodes a recovery message through the Rust core — the single source of truth. Every field
    /// is scalar (no owned buffers). Encoding a valid message cannot fail (the kind is always
    /// valid), so the guard traps rather than masking corruption with a second codec.
    static func encode(_ message: RecoveryMessage) -> Data {
        var c = AisdRecoveryMessage()
        c.kind = message.messageType
        switch message {
        case let .ack(streamSeq):
            c.stream_seq = streamSeq
        case let .requestLTRRefresh(from, to, lastDecoded):
            c.from_frame_id = from
            c.to_frame_id = to
            c.last_decoded_frame_id = lastDecoded
        case let .requestIDR(lastDecoded):
            c.last_decoded_frame_id = lastDecoded
        case let .requestCursorShape(shapeID):
            c.shape_id = shapeID
        case let .networkStats(report):
            c.stats = cNetworkStats(report)
        }
        var out = AisdBytes()
        let status = aisd_recovery_message_encode(&c, &out)
        guard status == AISD_OK, let ptr = out.ptr, out.len > 0 else {
            preconditionFailure("aisd_recovery_message_encode failed for a valid message (status \(status))")
        }
        defer { aisd_bytes_free(out) }
        return Data(bytes: ptr, count: out.len)
    }

    /// Decodes a recovery message through the Rust core, throwing the same ``VideoProtocolError``
    /// cases the native decoder did (`.malformed` for an unknown type / trailing bytes — the
    /// byte-keyed-dedup contract — `.truncated` for a short body).
    static func decodeRecovery(_ data: Data) throws -> RecoveryMessage {
        var out = AisdRecoveryMessage()
        let status: AisdStatus = data.withUnsafeBytes { raw in
            aisd_recovery_message_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        switch status {
        case AISD_OK:
            // out.kind ∈ {1 ack, 2 ltrRefresh, 3 idr, 4 cursorShape, 5 networkStats} on success.
            switch out.kind {
            case 1:
                return .ack(streamSeq: out.stream_seq)
            case 2:
                return .requestLTRRefresh(
                    fromFrameID: out.from_frame_id,
                    toFrameID: out.to_frame_id,
                    lastDecodedFrameID: out.last_decoded_frame_id,
                )
            case 3:
                return .requestIDR(lastDecodedFrameID: out.last_decoded_frame_id)
            case 4:
                return .requestCursorShape(shapeID: out.shape_id)
            default:
                return .networkStats(networkStatsReport(out.stats))
            }
        case AISD_ERR_MALFORMED:
            throw VideoProtocolError.malformed("rust: malformed recovery message")
        default:
            throw VideoProtocolError.truncated
        }
    }

    /// Flattens a Swift ``NetworkStatsReport`` into the C `AisdNetworkStats` (eleven scalars).
    private static func cNetworkStats(_ r: NetworkStatsReport) -> AisdNetworkStats {
        AisdNetworkStats(
            frames_received: r.framesReceived,
            fec_recovered: r.fecRecovered,
            unrecovered: r.unrecovered,
            latest_host_send_ts: r.latestHostSendTs,
            client_hold_ms: r.clientHoldMs,
            owd_jitter_micros: r.owdJitterMicros,
            owd_trend_milli: r.owdTrendMilli,
            owd_trend_flags: r.owdTrendFlags,
            pacer_late_frames: r.pacerLateFrames,
            pacer_present_gaps: r.pacerPresentGaps,
            pacer_depth: r.pacerDepth,
        )
    }

    /// Reads a decoded C `AisdNetworkStats` back into a Swift ``NetworkStatsReport``.
    private static func networkStatsReport(_ s: AisdNetworkStats) -> NetworkStatsReport {
        NetworkStatsReport(
            framesReceived: s.frames_received,
            fecRecovered: s.fec_recovered,
            unrecovered: s.unrecovered,
            latestHostSendTs: s.latest_host_send_ts,
            clientHoldMs: s.client_hold_ms,
            owdJitterMicros: s.owd_jitter_micros,
            owdTrendMilli: s.owd_trend_milli,
            owdTrendFlags: s.owd_trend_flags,
            pacerLateFrames: s.pacer_late_frames,
            pacerPresentGaps: s.pacer_present_gaps,
            pacerDepth: s.pacer_depth,
        )
    }

    // MARK: - reassembler (opaque handle; the per-datagram video RECEIVE hot path)

    /// Creates a reassembler owned by the Rust core: it OWNS a freshly-built NEON-backed Reed-Solomon
    /// codec (`[k + m, k]`), so there is no second FEC handle and no double-FEC. Pass `k == 0` (or
    /// `m == 0`) for a no-FEC reassembler. Returns `nil` ONLY for an invalid FEC config (`k >= 1`
    /// with `k + m > 255`), which the `FrameReassembler` constructor rules out for a real
    /// ``FECScheme``. Wraps `aisd_reassembler_new`.
    static func reassemblerNew(k: Int, m: Int, fecReorderGrace: Int) -> OpaquePointer? {
        aisd_reassembler_new(k, m, Int32(clamping: fecReorderGrace))
    }

    /// Destroys a reassembler handle. Wraps `aisd_reassembler_free`.
    static func reassemblerFree(_ handle: OpaquePointer) {
        aisd_reassembler_free(handle)
    }

    /// Parses + ingests one fragment datagram (the raw 19-byte header + payload), returning the
    /// marshaled outcome. The datagram is BORROWED for the call; a COMPLETED frame's owned `avcc`
    /// is copied into a Swift ``Data`` and freed before returning, so the result carries no Rust
    /// allocation. Wraps `aisd_reassembler_ingest` / `aisd_reassembly_result_free`.
    static func reassemblerIngest(_ handle: OpaquePointer, datagram: Data) -> ReassemblyResult {
        var out = AisdReassemblyResult()
        let status: AisdStatus = datagram.withUnsafeBytes { raw in
            aisd_reassembler_ingest(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        // A null-pointer error is unreachable here (handle + out are always valid), so a non-OK
        // status can only mean "nothing produced" — surface it as incomplete (the benign no-op).
        guard status == AISD_OK else { return .incomplete }
        defer { aisd_reassembly_result_free(&out) }
        switch out.kind {
        case UInt8(AISD_REASSEMBLY_COMPLETED):
            let avcc: Data = out.avcc.ptr.map { Data(bytes: $0, count: out.avcc.len) } ?? Data()
            return .completed(ReassembledFrame(
                frameID: out.frame_id,
                keyframe: out.keyframe != 0,
                crisp: out.crisp != 0,
                avcc: avcc,
                recoveredViaFEC: out.recovered_via_fec != 0,
                isLTR: out.is_ltr != 0,
                ackedAnchored: out.acked_anchored != 0,
            ))
        case UInt8(AISD_REASSEMBLY_DROPPED):
            return .dropped(frameID: out.frame_id)
        case UInt8(AISD_REASSEMBLY_STALE):
            return .stale
        default:
            return .incomplete
        }
    }

    /// Pops the next unrecoverably-lost frame id the prior ingest's sweep declared hopeless, or
    /// `nil`. Wraps `aisd_reassembler_next_dropped`.
    static func reassemblerNextDropped(_ handle: OpaquePointer) -> UInt32? {
        var out: UInt32 = 0
        return aisd_reassembler_next_dropped(handle, &out) != 0 ? out : nil
    }

    // MARK: - packetizer (opaque handle; the per-frame video SEND hot path)

    /// Creates a packetizer owned by the Rust core: it OWNS a freshly-built NEON-backed Reed-Solomon
    /// codec (`[k + m, k]`), so there is no second FEC handle and no double-FEC (symmetric with the
    /// reassembler). Pass `k == 0` (or `m == 0`) for a no-FEC packetizer. Returns `nil` ONLY for an
    /// invalid FEC config (`k >= 1` with `k + m > 255`), which a real ``FECScheme`` rules out. Wraps
    /// `aisd_video_packetizer_new`.
    static func packetizerNew(k: Int, m: Int) -> OpaquePointer? {
        aisd_video_packetizer_new(k, m)
    }

    /// Destroys a packetizer handle. Wraps `aisd_video_packetizer_free`.
    static func packetizerFree(_ handle: OpaquePointer) {
        aisd_video_packetizer_free(handle)
    }

    /// The `frameID` the next ``packetize`` call will assign. Wraps
    /// `aisd_video_packetizer_peek_next_frame_id`.
    static func packetizerPeekNextFrameID(_ handle: OpaquePointer) -> UInt32 {
        aisd_video_packetizer_peek_next_frame_id(handle)
    }

    /// The `streamSeq` the next emitted datagram will carry. Wraps
    /// `aisd_video_packetizer_peek_next_stream_seq`.
    static func packetizerPeekNextStreamSeq(_ handle: OpaquePointer) -> UInt32 {
        aisd_video_packetizer_peek_next_stream_seq(handle)
    }

    /// The per-frame packetize options, bundled so the call stays under the parameter-count limit.
    /// Mirrors the C-ABI `AisdPacketizeOptions` field-for-field (flags, tier, ts, the per-frame group
    /// override, and the interleave knob).
    struct PacketizeOptions {
        var keyframe: Bool
        var crisp: Bool
        var hostSendTsMillis: UInt32
        var fecTier: UInt8
        var isLTR: Bool
        var ackedAnchored: Bool
        /// Per-frame data-fragment group size `k` (0 ⇒ the codec's default `k`).
        var fecGroupSize: Int
        var interleave: Bool
    }

    /// Fragments ONE AVCC frame (borrowed in) into the fully-formed wire datagrams (header + payload,
    /// data then parity; column-major when `opts.interleave`), parses each back into a
    /// ``FrameFragment``, and returns them in transmit order. The packetizer assigns frameID +
    /// monotonic streamSeq and runs the FEC parity through its OWNED codec (no double-FEC).
    /// `opts.fecGroupSize == 0` ⇒ the codec's default `k`. Wraps `aisd_packetize` /
    /// `aisd_bytes_array_free`.
    static func packetize(_ handle: OpaquePointer, frame: Data, opts: PacketizeOptions) -> [FrameFragment] {
        let cOpts = cPacketizeOptions(opts)
        var out = AisdBytesArray()
        let status: AisdStatus = frame.withUnsafeBytes { raw in
            aisd_packetize(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, cOpts, &out)
        }
        // The only non-OK return is a null handle / out, neither reachable here — surface as empty.
        guard status == AISD_OK else { return [] }
        defer { aisd_bytes_array_free(&out) }
        return decodeFragments(out)
    }

    /// Like ``packetize(_:frame:opts:)`` but returns the FINISHED wire datagrams as raw `[Data]`,
    /// skipping the parse-into-`FrameFragment`-then-re-encode round-trip the host send path does not
    /// need: it sends every fragment on the SAME `.video` channel via `FrameFragment.encode()`, which
    /// is the exact inverse of the decode → the bytes are identical to these. One copy per datagram
    /// instead of decode+struct-alloc+re-encode+alloc ⇒ ~3× fewer allocs/frame on the send path
    /// (several ms off dense IDR/kfDup bursts). Byte-identity vs the old path is unit-pinned
    /// (`PacketizeRawByteIdentityTests`). `packetize` (-> `[FrameFragment]`) stays for the loopback
    /// validator + reassembler tests, which DO read fragment fields.
    static func packetizeRaw(_ handle: OpaquePointer, frame: Data, opts: PacketizeOptions) -> [Data] {
        let cOpts = cPacketizeOptions(opts)
        var out = AisdBytesArray()
        let status: AisdStatus = frame.withUnsafeBytes { raw in
            aisd_packetize(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, cOpts, &out)
        }
        guard status == AISD_OK else { return [] }
        defer { aisd_bytes_array_free(&out) }
        return rawDatagrams(out)
    }

    /// Flattens a returned `AisdBytesArray` of finished wire datagrams into `[Data]` (one copy each,
    /// NO parse). A null/zero-length element is skipped (never produced by the core, defensive).
    private static func rawDatagrams(_ array: AisdBytesArray) -> [Data] {
        let count = array.count
        guard let items = array.items, count > 0 else { return [] }
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let b = items[i]
            guard let ptr = b.ptr, b.len > 0 else { continue }
            out.append(Data(bytes: ptr, count: b.len))
        }
        return out
    }

    /// Shared `PacketizeOptions` → C-ABI struct, so `packetize` and `packetizeRaw` can never drift.
    private static func cPacketizeOptions(_ opts: PacketizeOptions) -> AisdPacketizeOptions {
        AisdPacketizeOptions(
            keyframe: opts.keyframe ? 1 : 0,
            crisp: opts.crisp ? 1 : 0,
            is_ltr: opts.isLTR ? 1 : 0,
            acked_anchored: opts.ackedAnchored ? 1 : 0,
            fec_tier: opts.fecTier,
            interleave: opts.interleave ? 1 : 0,
            host_send_ts_millis: opts.hostSendTsMillis,
            fec_group_size: opts.fecGroupSize,
        )
    }

    /// Reorders already-encoded wire fragments into burst-resilient transmit order (m-aware) —
    /// the standalone counterpart of the ``packetize`` `interleave` knob. Encodes the fragments to
    /// their wire datagrams, runs the Rust reorder, and decodes the reordered datagrams back. NO wire
    /// change: only the send order differs. Wraps `aisd_interleave` / `aisd_bytes_array_free`.
    static func interleave(_ fragments: [FrameFragment], groupSize: Int) -> [FrameFragment] {
        guard !fragments.isEmpty else { return [] }
        // Stage every datagram's wire bytes into ONE contiguous buffer, then borrow `AisdBytes`
        // pointing into it (O(1) stack regardless of count — never a per-fragment recursive borrow).
        let datagrams = fragments.map { $0.encode() }
        var blob = [UInt8]()
        blob.reserveCapacity(datagrams.reduce(0) { $0 + $1.count })
        var spans: [(offset: Int, len: Int)] = []
        spans.reserveCapacity(datagrams.count)
        for d in datagrams {
            spans.append((blob.count, d.count))
            blob.append(contentsOf: d)
        }
        var out = AisdBytesArray()
        let status: AisdStatus = blob.withUnsafeBytes { raw -> AisdStatus in
            let base = raw.baseAddress
            var borrowed = spans.map { span -> AisdBytes in
                guard span.len > 0, let base else { return AisdBytes() }
                return AisdBytes(
                    ptr: UnsafeMutablePointer(mutating: base.advanced(by: span.offset)
                        .assumingMemoryBound(to: UInt8.self)),
                    len: span.len,
                    cap: 0,
                )
            }
            return borrowed.withUnsafeBufferPointer { buf in
                aisd_interleave(buf.baseAddress, buf.count, groupSize, &out)
            }
        }
        guard status == AISD_OK else { return fragments }
        defer { aisd_bytes_array_free(&out) }
        return decodeFragments(out)
    }

    /// Decodes a returned `AisdBytesArray` of wire datagrams back into `[FrameFragment]`. Each
    /// datagram was just produced by the Rust core, so the decode never fails (a failure would be a
    /// codec bug); an unexpected failure drops that fragment rather than trapping.
    private static func decodeFragments(_ array: AisdBytesArray) -> [FrameFragment] {
        // Bind the C `count` to a local Int up front (the `AisdBytesArray` struct has no `isEmpty`).
        let count = array.count
        guard let items = array.items, count > 0 else { return [] }
        var frags: [FrameFragment] = []
        frags.reserveCapacity(count)
        for i in 0..<count {
            let b = items[i]
            guard let ptr = b.ptr, b.len > 0 else { continue }
            let datagram = Data(bytes: ptr, count: b.len)
            if let frag = try? FrameFragment.decode(datagram) { frags.append(frag) }
        }
        return frags
    }
}
