import AislopdeskVideoProtocol
import CAislopdeskFFI
import CoreGraphics
import Foundation

/// Swift-side bridge from `AislopdeskVideoHost` to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` for the host module is contained here; the host's policy types
/// call these typed wrappers so their public APIs stay unchanged. The realtime bitrate logic
/// lives in the Rust core (`aislopdesk-core`) and is exposed over the C-ABI boundary; golden
/// vectors assert byte-/bit-exact output, so the macOS/iOS host and a future Android client
/// drive the identical algorithm from one core. Env knobs stay resolved Swift-side and are
/// passed in, keeping the core env-free.
public enum RustVideoHostFFI {
    /// Resolution-aware target bitrate (bits/sec). Wraps `aisd_live_bitrate_target`.
    static func liveBitrateTarget(
        pixelWidth: Int,
        pixelHeight: Int,
        fps: Int,
        floor: Int,
        bitsPerPixel: Double,
    ) -> Int {
        Int(
            aisd_live_bitrate_target(
                Int64(pixelWidth), Int64(pixelHeight), Int64(fps), Int64(floor), bitsPerPixel,
            ),
        )
    }

    /// The absolute minimum live bitrate (bits/sec). Wraps `aisd_live_bitrate_minimum`.
    static func liveBitrateMinimum() -> Int {
        Int(aisd_live_bitrate_minimum())
    }

    // MARK: - frame_hash (NEON NV12 frame hash; host static-frame suppression)

    /// The sentinel `frameHashNV12` returns for a null/degenerate call (never a real frame's hash).
    /// Mirrors `AISD_FRAME_HASH_SENTINEL` (`UInt64.max`).
    static let frameHashSentinel: UInt64 = .max

    /// Hashes an NV12 frame's already-locked luma + interleaved-chroma planes into one strong 64-bit
    /// value, reading ONLY the first `width` bytes of each `*Stride`-spaced row (padding-independent).
    /// ZERO-COPY: the base addresses are the LOCKED `CVPixelBuffer` plane pointers — they are
    /// borrowed for the call only, never retained or freed by Rust. On Apple Silicon the kernel is
    /// NEON-vectorised and byte-identical to the scalar core. Wraps `aisd_frame_hash_nv12`.
    ///
    /// Returns `frameHashSentinel` for a null `y` / zero dims / `yStride < width` (never a crash).
    /// `cbcr == nil` ⇒ a luma-only hash.
    static func frameHashNV12(
        y: UnsafeRawPointer,
        yStride: Int,
        width: Int,
        height: Int,
        cbcr: UnsafeRawPointer?,
        cbcrStride: Int,
    ) -> UInt64 {
        aisd_frame_hash_nv12(
            y.assumingMemoryBound(to: UInt8.self),
            yStride,
            width,
            height,
            cbcr?.assumingMemoryBound(to: UInt8.self),
            cbcrStride,
        )
    }

    /// SCROLL REPROJECTION (2026-06-16): the dominant VERTICAL content shift (pixel rows) between two
    /// locked NV12 luma planes (the previous + current captured frames), via the NEON per-row hasher +
    /// the pure core estimator (`aisd_estimate_scroll_shift_nv12`). Returns `(shift, confidenceMilli)`
    /// — `shift` positive = content moved DOWN; `confidenceMilli` ∈ 0…1000 (the caller gates on it).
    /// Pointers are borrowed for the call only. `(0, 0)` on a null/degenerate input (never a crash).
    static func estimateScrollShift(
        prevY: UnsafeRawPointer,
        prevStride: Int,
        curY: UnsafeRawPointer,
        curStride: Int,
        width: Int,
        height: Int,
        maxShift: Int,
    ) -> (shift: Int32, confidenceMilli: UInt32) {
        var shift: Int32 = 0
        var conf: UInt32 = 0
        _ = aisd_estimate_scroll_shift_nv12(
            prevY.assumingMemoryBound(to: UInt8.self),
            prevStride,
            curY.assumingMemoryBound(to: UInt8.self),
            curStride,
            width,
            height,
            maxShift,
            &shift,
            &conf,
        )
        return (shift, conf)
    }

    // A 1:1 mirror of the wide C ABI signature, hence the parameter count.
    // swiftlint:disable function_parameter_count
    /// ADAPTIVE QP (2026-06-16): the per-frame `MaxAllowedFrameQP` ceiling for "sharp on a small
    /// change, blur graded by burst" — NEON per-row hash of both planes → changed-row fraction → the
    /// pure core curve (`aisd_adaptive_frame_qp_nv12`). Returns `(qp, changeMilli)`: `qp` is the
    /// ceiling to set on the live frame; `changeMilli` is the measured change fraction ×1000 (logging).
    /// Pointers borrowed for the call only. On a degenerate input → `qp == qpMax` (no narrowing).
    static func adaptiveFrameQP(
        prevY: UnsafeRawPointer,
        prevStride: Int,
        curY: UnsafeRawPointer,
        curStride: Int,
        width: Int,
        height: Int,
        qpSharp: Int,
        qpMax: Int,
        bLoMilli: UInt32,
        bHiMilli: UInt32,
    ) -> (qp: Int, changeMilli: UInt32) {
        var qp: UInt8 = 0
        var chg: UInt32 = 0
        _ = aisd_adaptive_frame_qp_nv12(
            prevY.assumingMemoryBound(to: UInt8.self),
            prevStride,
            curY.assumingMemoryBound(to: UInt8.self),
            curStride,
            width,
            height,
            UInt8(clamping: qpSharp),
            UInt8(clamping: qpMax),
            bLoMilli,
            bHiMilli,
            &qp,
            &chg,
        )
        return (Int(qp), chg)
    }

    // swiftlint:enable function_parameter_count

    // MARK: - window_placement (pure, flat-struct; HiDPI VD-park path)

    /// Clamp `windowSize` DOWN to `displayBounds` (never enlarge) and place it at the display's
    /// top-left origin. Wraps `aisd_window_placement`.
    static func windowPlacement(windowSize: CGSize, displayBounds: CGRect)
        -> (origin: CGPoint, size: CGSize, needsResize: Bool)
    {
        let p = aisd_window_placement(
            Double(windowSize.width), Double(windowSize.height), aisdRect(displayBounds),
        )
        return (
            CGPoint(x: p.x, y: p.y),
            CGSize(width: p.width, height: p.height),
            p.needs_resize != 0,
        )
    }

    /// Whether `size` fits inside `bounds` (½-pt tolerance). Wraps `aisd_window_fits`.
    static func windowFits(_ size: CGSize, within bounds: CGRect) -> Bool {
        aisd_window_fits(Double(size.width), Double(size.height), aisdRect(bounds)) != 0
    }

    // MARK: - virtual_display_geometry (VD creation path)

    /// Builds a (clamped) VD geometry with its derived pixel dims + chip-limit check. Wraps
    /// `aisd_vd_geometry`.
    public static func vdGeometry(
        pointWidth: Int,
        pointHeight: Int,
        scale: Int,
        maxHorizontalPixels: Int = 7680,
    ) -> VDGeometry {
        let r = aisd_vd_geometry(
            Int64(pointWidth), Int64(pointHeight), Int64(scale), Int64(maxHorizontalPixels),
        )
        return VDGeometry(
            pointWidth: Int(r.point_width),
            pointHeight: Int(r.point_height),
            scale: Int(r.scale),
            maxHorizontalPixels: Int(r.max_horizontal_pixels),
            pixelWidth: Int(r.pixel_width),
            pixelHeight: Int(r.pixel_height),
            exceedsPixelLimit: r.exceeds_pixel_limit != 0,
        )
    }

    /// Physical size in millimetres for a `pixelWidth × pixelHeight` display at `targetPPI`.
    /// Wraps `aisd_vd_size_in_millimeters`.
    static func vdSizeInMillimeters(pixelWidth: Int, pixelHeight: Int, targetPPI: Double = 163) -> CGSize {
        let mm = aisd_vd_size_in_millimeters(Int64(pixelWidth), Int64(pixelHeight), targetPPI)
        return CGSize(width: mm.width, height: mm.height)
    }

    /// The VD origin flush right of the rightmost display (`(0,0)` when none). Wraps
    /// `aisd_vd_origin_to_right`.
    static func vdOriginToRight(of displayBounds: [CGRect]) -> CGPoint {
        let rects = displayBounds.map { aisdRect($0) }
        let p = rects.withUnsafeBufferPointer { buf in
            aisd_vd_origin_to_right(buf.baseAddress, buf.count)
        }
        return CGPoint(x: p.x, y: p.y)
    }

    /// The chip's horizontal pixel ceiling from a CPU brand string. Wraps
    /// `aisd_vd_chip_pixel_limit`.
    public static func vdChipPixelLimit(cpuBrand: String) -> Int {
        Int(cpuBrand.withCString { aisd_vd_chip_pixel_limit($0) })
    }

    /// The descending refresh-rate modes for a VD at `fps` (always 2 or 3). Wraps
    /// `aisd_vd_refresh_rates`.
    static func vdRefreshRates(fps: Int) -> [Double] {
        var buf = [Double](repeating: 0, count: 3) // max output is (fps, 60, 30)
        let count = buf.withUnsafeMutableBufferPointer { ptr in
            aisd_vd_refresh_rates(Int64(fps), ptr.baseAddress, ptr.count)
        }
        return Array(buf.prefix(count))
    }

    // MARK: - capture_region (dialog-expand capture math; AX-event-driven)

    /// The capture union region: target window ∪ qualifying same-pid panels in front, clamped to
    /// the display. Wraps `aisd_capture_union_region`.
    static func captureUnionRegion(
        targetFrame: CGRect,
        targetWindowID: UInt32,
        targetPID: Int32,
        windowsInFront: [CaptureWindow],
        displayBounds: CGRect,
        minOverlapFraction: Double = 0.30,
    ) -> CGRect {
        let cWindows = windowsInFront.map {
            AisdCaptureWindowSnapshot(
                window_id: $0.windowID,
                owner_pid: $0.ownerPID,
                layer: $0.layer,
                frame: aisdRect($0.frame),
            )
        }
        let out = cWindows.withUnsafeBufferPointer { buf in
            aisd_capture_union_region(
                aisdRect(targetFrame), targetWindowID, targetPID,
                buf.baseAddress, buf.count,
                aisdRect(displayBounds), minOverlapFraction,
            )
        }
        return cgRect(out)
    }

    /// The OPAQUE content rectangles of the capture region (window frame + qualifying same-pid
    /// popups), each clamped to the display — the per-rect form the client masks the black flank
    /// with. Wraps `aisd_capture_content_rects` (caller-arena; capped at 16 rects, ample for a
    /// window + nested menus). Returns the rects that fit (the total may exceed 16 only pathologically).
    static func captureContentRects(
        targetFrame: CGRect,
        targetWindowID: UInt32,
        targetPID: Int32,
        windowsInFront: [CaptureWindow],
        displayBounds: CGRect,
        minOverlapFraction: Double = 0.30,
    ) -> [CGRect] {
        let cWindows = windowsInFront.map {
            AisdCaptureWindowSnapshot(
                window_id: $0.windowID,
                owner_pid: $0.ownerPID,
                layer: $0.layer,
                frame: aisdRect($0.frame),
            )
        }
        // Cap MUST match the client shader's `MetalVideoRenderer.maxMaskRects` (8): a rect the host
        // sends past the client's loop bound would be masked transparent = real content disappears.
        let cap = 8
        var out = [AisdRect](repeating: AisdRect(x: 0, y: 0, width: 0, height: 0), count: cap)
        let total = cWindows.withUnsafeBufferPointer { buf in
            out.withUnsafeMutableBufferPointer { obuf in
                aisd_capture_content_rects(
                    aisdRect(targetFrame), targetWindowID, targetPID,
                    buf.baseAddress, buf.count,
                    aisdRect(displayBounds), minOverlapFraction,
                    obuf.baseAddress, obuf.count,
                )
            }
        }
        return (0..<min(total, cap)).map { cgRect(out[$0]) }
    }

    /// Hysteresis gate: `true` if `desired` differs from `current` by more than `minDelta` on any
    /// edge. Wraps `aisd_capture_should_retarget`.
    static func captureShouldRetarget(current: CGRect, desired: CGRect, minDelta: Double = 8) -> Bool {
        aisd_capture_should_retarget(aisdRect(current), aisdRect(desired), minDelta) != 0
    }

    /// Whether a geometry change should re-origin capture to the plain window frame (no union
    /// active). Wraps `aisd_capture_reorigin_on_geometry`.
    static func captureReoriginOnGeometry(activeRegionGlobal: CGRect?) -> Bool {
        aisd_capture_reorigin_on_geometry(activeRegionGlobal == nil ? 1 : 0) != 0
    }

    // MARK: - system_dialog_detector (pure classifier; the ~1 Hz listSystemDialogs poll)

    /// The minimum on-screen size (points) for a window to be a surfaced system dialog. Wraps
    /// `aisd_system_dialog_min_size`.
    static func systemDialogMinSize() -> Int {
        Int(aisd_system_dialog_min_size())
    }

    /// Classify ONE on-screen window into a surfaced system dialog (or `nil`). Wraps
    /// `aisd_system_dialog_classify`; the secure/system allowlists + the on-screen / min-size rules
    /// live in the Rust core, so this only marshals the borrowed strings in and the owned strings out.
    static func systemDialogClassify(
        windowID: UInt32,
        ownerName: String,
        bundleID: String,
        isOnScreen: Bool,
        title: String,
        frame: CGRect,
        minSize: Int,
    ) -> SystemDialogClassification? {
        let owner = Array(ownerName.utf8)
        let bundle = Array(bundleID.utf8)
        let titleBytes = Array(title.utf8)
        var out = AisdSystemDialog()
        let status = owner.withUnsafeBufferPointer { o in
            bundle.withUnsafeBufferPointer { b in
                titleBytes.withUnsafeBufferPointer { t in
                    aisd_system_dialog_classify(
                        windowID,
                        o.baseAddress, o.count,
                        b.baseAddress, b.count,
                        isOnScreen ? 1 : 0,
                        t.baseAddress, t.count,
                        aisdRect(frame), Int64(minSize),
                        &out,
                    )
                }
            }
        }
        guard status == AISD_OK else { return nil }
        defer { aisd_system_dialog_free(&out) }
        return SystemDialogClassification(
            windowID: out.window_id,
            owner: string(from: out.owner),
            title: string(from: out.title),
            width: Int(out.width),
            height: Int(out.height),
            isSecure: out.is_secure != 0,
        )
    }

    // MARK: - recovery_request_deduper (opaque handle; host-session recovery-request dedup)

    /// Creates a recovery-request dedup ring owned by the Rust core; release with
    /// `recoveryDeduperFree`. Wraps `aisd_recovery_deduper_new` (never returns null).
    static func recoveryDeduperNew(windowSeconds: TimeInterval, capacity: Int) -> OpaquePointer {
        aisd_recovery_deduper_new(windowSeconds, capacity)
    }

    /// Destroys a deduper handle. Wraps `aisd_recovery_deduper_free`.
    static func recoveryDeduperFree(_ handle: OpaquePointer) {
        aisd_recovery_deduper_free(handle)
    }

    /// Admits a recovery-request datagram: `true` = first sighting (process it), `false` =
    /// byte-identical duplicate (drop it). Wraps `aisd_recovery_deduper_admit`.
    static func recoveryDeduperAdmit(_ handle: OpaquePointer, datagram: Data, now: TimeInterval) -> Bool {
        datagram.withUnsafeBytes { raw in
            aisd_recovery_deduper_admit(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, now) != 0
        }
    }

    // MARK: - static_idr_decider (opaque handle; host static-window forced-IDR heartbeat)

    /// Creates a static-IDR decider owned by the Rust core; release with `staticIDRDeciderFree`.
    /// `quietWindow == nil` takes the core default (one cadence). Wraps
    /// `aisd_static_idr_decider_new` (never returns null).
    static func staticIDRDeciderNew(heartbeat: TimeInterval, quietWindow: TimeInterval?) -> OpaquePointer {
        aisd_static_idr_decider_new(heartbeat, quietWindow ?? 0, quietWindow != nil ? 1 : 0)
    }

    /// Destroys a decider handle. Wraps `aisd_static_idr_decider_free`.
    static func staticIDRDeciderFree(_ handle: OpaquePointer) {
        aisd_static_idr_decider_free(handle)
    }

    /// The configured heartbeat cadence (seconds). Wraps `aisd_static_idr_decider_heartbeat`.
    static func staticIDRDeciderHeartbeat(_ handle: OpaquePointer) -> TimeInterval {
        aisd_static_idr_decider_heartbeat(handle)
    }

    /// The configured quiet window (seconds). Wraps `aisd_static_idr_decider_quiet_window`.
    static func staticIDRDeciderQuietWindow(_ handle: OpaquePointer) -> TimeInterval {
        aisd_static_idr_decider_quiet_window(handle)
    }

    /// Uptime seconds of the last REAL `.complete`-frame encode (0 = none).
    static func staticIDRDeciderLastCompleteEncode(_ handle: OpaquePointer) -> TimeInterval {
        aisd_static_idr_decider_last_complete_encode(handle)
    }

    /// Uptime seconds of the last SYNTHETIC re-encode (0 = none).
    static func staticIDRDeciderLastSyntheticEncode(_ handle: OpaquePointer) -> TimeInterval {
        aisd_static_idr_decider_last_synthetic_encode(handle)
    }

    /// Re-anchors the live clock (a REAL `.complete` frame at `now`).
    static func staticIDRDeciderOnCompleteFrame(_ handle: OpaquePointer, now: TimeInterval) {
        aisd_static_idr_decider_on_complete_frame(handle, now)
    }

    /// Re-anchors the synthetic clock (the timer fired a synthetic re-encode at `now`).
    static func staticIDRDeciderRecordSynthetic(_ handle: OpaquePointer, now: TimeInterval) {
        aisd_static_idr_decider_record_synthetic(handle, now)
    }

    /// `true` ⇒ re-encode the cached buffer as a forced IDR now. Wraps
    /// `aisd_static_idr_decider_should_reencode`.
    static func staticIDRDeciderShouldReencode(
        _ handle: OpaquePointer,
        now: TimeInterval,
        forcedLatched: Bool,
        hasRetainedBuffer: Bool,
    ) -> Bool {
        aisd_static_idr_decider_should_reencode(handle, now, forcedLatched ? 1 : 0, hasRetainedBuffer ? 1 : 0) != 0
    }

    // MARK: - input_button_balance (opaque handle; host input-injection button balance)

    /// Creates a button-balance owned by the Rust core; release with `inputButtonBalanceFree`.
    /// Wraps `aisd_input_button_balance_new` (never returns null).
    static func inputButtonBalanceNew() -> OpaquePointer {
        aisd_input_button_balance_new()
    }

    /// Destroys a balance handle. Wraps `aisd_input_button_balance_free`.
    static func inputButtonBalanceFree(_ handle: OpaquePointer) {
        aisd_input_button_balance_free(handle)
    }

    /// Folds one event (`kind` = `AISD_INPUT_*`, `button` = raw 0/1/2) and returns its plan as
    /// `(preRelease, suppress)`. Wraps `aisd_input_button_balance_plan`.
    static func inputButtonBalancePlan(
        _ handle: OpaquePointer,
        kind: UInt8,
        button: UInt8,
    ) -> (preRelease: MouseButton?, suppress: Bool) {
        let plan = aisd_input_button_balance_plan(handle, kind, button)
        let preRelease = plan.has_pre_release != 0 ? MouseButton(rawValue: plan.pre_release_button) : nil
        return (preRelease, plan.suppress != 0)
    }

    /// The held buttons as a bitmask (bit0=left, bit1=right, bit2=other). Wraps
    /// `aisd_input_button_balance_held_mask`.
    static func inputButtonBalanceHeldMask(_ handle: OpaquePointer) -> UInt8 {
        aisd_input_button_balance_held_mask(handle)
    }

    // MARK: - recovery_idr_policy (opaque handle; host delivery-keyed recovery-IDR admission)

    /// Creates a recovery-IDR policy owned by the Rust core from the resolved config scalars (env
    /// is resolved Swift-side). Release with `recoveryIdrPolicyFree`. Wraps
    /// `aisd_recovery_idr_policy_new` (never returns null).
    static func recoveryIdrPolicyNew(
        graceFraction: Double,
        graceFloorSeconds: Double,
        graceCeilSeconds: Double,
        bucketCapacity: Double,
        refillTokensPerSecond: Double,
        grantPendingTimeout: Double,
        keyframeRingCapacity: Int,
    ) -> OpaquePointer {
        aisd_recovery_idr_policy_new(
            graceFraction, graceFloorSeconds, graceCeilSeconds, bucketCapacity,
            refillTokensPerSecond, grantPendingTimeout, keyframeRingCapacity,
        )
    }

    /// Destroys a policy handle. Wraps `aisd_recovery_idr_policy_free`.
    static func recoveryIdrPolicyFree(_ handle: OpaquePointer) {
        aisd_recovery_idr_policy_free(handle)
    }

    /// Token-bucket level. Wraps `aisd_recovery_idr_policy_available_tokens`.
    static func recoveryIdrPolicyAvailableTokens(_ handle: OpaquePointer) -> Double {
        aisd_recovery_idr_policy_available_tokens(handle)
    }

    /// Records a keyframe handed to the wire at `now`. Wraps
    /// `aisd_recovery_idr_policy_note_keyframe_sent`.
    static func recoveryIdrPolicyNoteKeyframeSent(_ handle: OpaquePointer, frameID: UInt32, now: Double) {
        aisd_recovery_idr_policy_note_keyframe_sent(handle, frameID, now)
    }

    /// Records the client decode-ACKed a keyframe. Wraps
    /// `aisd_recovery_idr_policy_note_keyframe_delivered`.
    static func recoveryIdrPolicyNoteKeyframeDelivered(_ handle: OpaquePointer, frameID: UInt32) {
        aisd_recovery_idr_policy_note_keyframe_delivered(handle, frameID)
    }

    /// The admission verdict as the raw `AISD_RECOVERY_IDR_*` discriminant. `clientLastDecoded ==
    /// nil` is the wire sentinel "nothing decoded yet". Wraps `aisd_recovery_idr_policy_decide`.
    static func recoveryIdrPolicyDecide(
        _ handle: OpaquePointer,
        now: Double,
        clientLastDecoded: UInt32?,
        smoothedRTTSeconds: Double,
    ) -> UInt8 {
        aisd_recovery_idr_policy_decide(
            handle, now, clientLastDecoded ?? 0, clientLastDecoded != nil ? 1 : 0, smoothedRTTSeconds,
        )
    }

    /// In-flight grace window (seconds) for the given smoothed RTT. Wraps
    /// `aisd_recovery_idr_policy_grace`.
    static func recoveryIdrPolicyGrace(_ handle: OpaquePointer, rtt: Double) -> Double {
        aisd_recovery_idr_policy_grace(handle, rtt)
    }

    // MARK: - video_mux_router (opaque handle; host per-datagram mux routing)

    /// Creates a mux router owned by the Rust core; release with `videoMuxRouterFree`. Wraps
    /// `aisd_video_mux_router_new` (never returns null).
    static func videoMuxRouterNew() -> OpaquePointer {
        aisd_video_mux_router_new()
    }

    /// Destroys a router handle. Wraps `aisd_video_mux_router_free`.
    static func videoMuxRouterFree(_ handle: OpaquePointer) {
        aisd_video_mux_router_free(handle)
    }

    /// Admits a lane. Wraps `aisd_video_mux_router_admit`.
    static func videoMuxRouterAdmit(_ handle: OpaquePointer, channelID: UInt32) {
        aisd_video_mux_router_admit(handle, channelID)
    }

    /// Retires a lane. Wraps `aisd_video_mux_router_retire`.
    static func videoMuxRouterRetire(_ handle: OpaquePointer, channelID: UInt32) {
        aisd_video_mux_router_retire(handle, channelID)
    }

    /// Begins draining a lane. Wraps `aisd_video_mux_router_begin_drain`.
    static func videoMuxRouterBeginDrain(_ handle: OpaquePointer, channelID: UInt32) {
        aisd_video_mux_router_begin_drain(handle, channelID)
    }

    /// Finishes draining a lane (draining → retired). Wraps `aisd_video_mux_router_end_drain`.
    static func videoMuxRouterEndDrain(_ handle: OpaquePointer, channelID: UInt32) {
        aisd_video_mux_router_end_drain(handle, channelID)
    }

    /// Whether a lane is admitted. Wraps `aisd_video_mux_router_is_admitted`.
    static func videoMuxRouterIsAdmitted(_ handle: OpaquePointer, channelID: UInt32) -> Bool {
        aisd_video_mux_router_is_admitted(handle, channelID) != 0
    }

    /// Whether a lane is draining. Wraps `aisd_video_mux_router_is_draining`.
    static func videoMuxRouterIsDraining(_ handle: OpaquePointer, channelID: UInt32) -> Bool {
        aisd_video_mux_router_is_draining(handle, channelID) != 0
    }

    /// The routing decision as the raw `AISD_MUX_DECISION_*` discriminant. `channel` is a
    /// `VideoChannel` rawValue. Wraps `aisd_video_mux_router_route`.
    static func videoMuxRouterRoute(
        _ handle: OpaquePointer,
        channelID: UInt32,
        channel: UInt8,
        bytesCount: Int,
    ) -> UInt8 {
        aisd_video_mux_router_route(handle, channelID, channel, bytesCount)
    }

    /// The bootstrap action as the raw `AISD_MUX_BOOTSTRAP_*` discriminant. `decision` is an
    /// `AISD_MUX_DECISION_*` value, `channel` a `VideoChannel` rawValue. PURE (no handle). Wraps
    /// `aisd_video_mux_router_bootstrap_action`.
    static func videoMuxRouterBootstrapAction(
        decision: UInt8,
        channel: UInt8,
        payloadIsHello: Bool,
        payloadIsListRequest: Bool,
    ) -> UInt8 {
        aisd_video_mux_router_bootstrap_action(
            decision, channel, payloadIsHello ? 1 : 0, payloadIsListRequest ? 1 : 0,
        )
    }

    /// Flattens a `CGRect` into the C-ABI `AisdRect` (x, y, width, height — all `Double`).
    private static func aisdRect(_ r: CGRect) -> AisdRect {
        AisdRect(
            x: Double(r.origin.x),
            y: Double(r.origin.y),
            width: Double(r.size.width),
            height: Double(r.size.height),
        )
    }

    /// Rebuilds a `CGRect` from the C-ABI `AisdRect`.
    private static func cgRect(_ r: AisdRect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    /// Copies a returned `AisdBytes` UTF-8 payload into a `String` (empty for the null buffer). The
    /// buffer itself is released by the caller's `*_free`.
    private static func string(from bytes: AisdBytes) -> String {
        guard let ptr = bytes.ptr, bytes.len > 0 else { return "" }
        // The bytes came from a Rust `String`, so the failable init never returns nil here.
        return String(bytes: UnsafeBufferPointer(start: ptr, count: bytes.len), encoding: .utf8) ?? ""
    }
}

/// A virtual-display geometry value: clamped fields + derived pixel dims + chip-limit check.
///
/// The geometry math lives in the Rust core (`aislopdesk_core::virtual_display_geometry`);
/// this is the value carrier the host's VD-creation path consumes.
public struct VDGeometry: Equatable, Sendable {
    public let pointWidth: Int
    public let pointHeight: Int
    public let scale: Int
    public let maxHorizontalPixels: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let exceedsPixelLimit: Bool

    /// Physical size in millimetres at `targetPPI` (computed by the Rust core).
    public func sizeInMillimeters(targetPPI: Double = 163) -> CGSize {
        RustVideoHostFFI.vdSizeInMillimeters(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, targetPPI: targetPPI,
        )
    }
}

/// One on-screen window (`CGWindowListCopyWindowInfo` row) fed to the capture-region math.
struct CaptureWindow {
    let windowID: UInt32
    let ownerPID: Int32
    let layer: Int64
    let frame: CGRect
}

/// The Rust core's `Dialog` classification carried back across the C-ABI (a plain value carrier so
/// this contained-FFI file stays decoupled from the host's `#if os(macOS)` `SystemDialogDetector`).
struct SystemDialogClassification {
    let windowID: UInt32
    let owner: String
    let title: String
    let width: Int
    let height: Int
    let isSecure: Bool
}
