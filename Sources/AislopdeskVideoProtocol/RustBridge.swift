import CAislopdeskFFI
import Foundation

/// Swift-side bridge from `AislopdeskVideoProtocol` to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` for the video wire codecs is contained here; the codec types
/// call these typed wrappers so their public Swift APIs stay stable. The Rust core is the
/// canonical implementation of the video wire codecs; its byte-/bit-exact output is verified
/// by golden vectors and re-checked through these wrappers by the `Rust*ParityTests`. The same
/// core is the basis for the Android client over the same C ABI.
///
/// Memory contract (mirrors `aislopdesk_ffi.h`): buffers passed *in* are borrowed for the
/// call only; any `AisdBytes` the library returns owns a Rust allocation and is released with
/// `aisd_bytes_free` before the wrapper returns.
enum RustVideoFFI {
    /// Encodes a cursor update (fixed 36 bytes) through the Rust core. The guard defensively
    /// returns the in-process Swift encoding on the (unreachable) FFI failure.
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
            return update.encodeNative()
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
