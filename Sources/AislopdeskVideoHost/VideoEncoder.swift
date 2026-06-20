#if os(macOS)
import AislopdeskVideoProtocol
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

/// Errors raised by the video encoder.
public enum VideoEncoderError: Error {
    case sessionCreateFailed(OSStatus)
    case notHardwareBacked
    case encodeFailed(OSStatus)
    /// A LATENCY-CRITICAL property failed to set. Carries the property key + the
    /// `OSStatus` so the caller can see exactly which proven low-latency setting did
    /// not apply (a silent failure here corrupts the measured doc-18 config).
    case propertyFailed(key: String, status: OSStatus)
}

/// The single-session HEVC encoder (doc 18 §E — **MEASURED + SOLVED**), built to the
/// EXACT configs validated in `docs/research/spikes/vtbench/encode-decode-bench.swift`.
///
/// ⚠️ **HANG-SAFETY:** `VTCompressionSessionCreate` + encode HW-accelerated HANG
/// without a window-server + Screen-Recording TCC session (RESULTS.md). This type is
/// COMPILED and code-reviewed but is NEVER instantiated in a test — only in a real
/// GUI host app.
///
/// - **Live session** = low-latency-RC (MEASURED p50 7.5ms vs constant-quality
///   24ms → live MUST be low-latency-RC). Specification keys
///   `EnableLowLatencyRateControl=true` + `RequireHardwareAcceleratedVideoEncoder=
///   true`; property keys `RealTime=true`, `ExpectedFrameRate=30`,
///   `PrioritizeEncodingSpeedOverQuality=false` (QUALITY-first since 2026-06-10;
///   `AISLOPDESK_SPEED_OVER_QUALITY=1` restores the speed hint), `AllowFrameReordering=false`,
///   `MaxKeyFrameInterval=INT_MAX`, `AverageBitRate` + `DataRateLimits=[12_000_000/8,
///   1.0]` (12 Mbps hard cap, **/8 not /4**), `SpatialAdaptiveQPLevel=Disable` (BEST-EFFORT —
///   `kVTPropertyNotSupportedErr`/-12900 on encoders without the key; not latency-critical).
///   ProfileLevel OMITTED. HEVC Main 8-bit 4:2:0.
/// - **Crisp static refresh** (Design A, 2026-06-08) = NOT a second session. When the window
///   goes static the heartbeat timer re-encodes the cached frame on this SAME live session with a
///   momentarily-dropped QP ceiling + widened rate cap (``encodeLiveCrispKeyframe``), then restores
///   the live config — near-lossless text with NO parameter-set change (no client decoder rebuild)
///   and the crisp IDR seeds the next live delta. (Replaced the old dead all-intra "Session B",
///   which double-occupied the HW encoder block and forced a cross-session reference break.)
///
/// Quirks honoured (RESULTS.md / doc 18 §E,§G):
/// - Do NOT query `UsingHardwareAcceleratedVideoEncoder` while low-latency is on
///   (returns -12900). HW support is gated at creation by
///   `RequireHardwareAcceleratedVideoEncoder=true` instead.
/// - Recreate the session on resize.
/// - Retry create on -12905 (XPC race) with 50-100ms backoff.
public final class VideoEncoder: @unchecked Sendable {
    /// 12 Mbps hard bitrate cap (doc 18 §E). DataRateLimits is `[maxBytes, seconds]`
    /// → `[12_000_000 / 8, 1.0]` = 1.5 MB per 1 s. **/8 (bits→bytes), not /4.**
    public static let bitrateBitsPerSecond = 12_000_000
    public static let dataRateMaxBytes = bitrateBitsPerSecond / 8 // 1_500_000
    /// -12905 (XPC) create-race retry backoff, 50-100ms (doc 18 §G).
    public static let createRetryBackoffNanos: UInt64 = 75_000_000
    /// SHARPNESS (2026-06-10): `PrioritizeEncodingSpeedOverQuality` default flipped true → FALSE.
    /// The hint tilts the HW encoder's rate-distortion choices toward coarser quantization at equal
    /// bitrate — a direct sharpness loss ("không nét bằng Parsec") — while Apple-silicon HEVC HW
    /// encodes 4K60 in real time comfortably without it (RealTime + low-latency RC stay set, so the
    /// latency contract is unchanged). `AISLOPDESK_SPEED_OVER_QUALITY=1` restores the speed-first hint
    /// for A/B or for hardware where quality-first encode misses the 16.7 ms frame budget.
    static let speedOverQuality = ProcessInfo.processInfo.environment["AISLOPDESK_SPEED_OVER_QUALITY"] == "1"
    /// §A1 (doc 26 §A) worst-case quantizer CEILING for the live session. HEVC QP range is
    /// 1 (lossless) … 51 (coarsest). VideoToolbox RAISES QP up to this ceiling to keep a frame under
    /// the hard `DataRateLimits` cap, and DROPS the frame if even at this ceiling it cannot fit — so
    /// this ceiling is the dial between "coarsen" and "drop" under bitrate pressure.
    ///
    /// 2026-06-08 (scroll-smoothness): raised 32 → 40. A dropped frame IS visible stutter, and with
    /// the 2× HiDPI display (feature #1) a heavy scroll frame routinely could not fit at QP 32 → it
    /// was dropped → the user's "scroll/content-change not smooth" report. 40 lets such a frame
    /// coarsen-and-ship instead of dropping; the CRISP static refresh (``encodeLiveCrispKeyframe``)
    /// restores razor-sharp text the instant motion stops, so trading a hair of MOTION sharpness for
    /// never dropping a motion frame is pure win for smoothness. Pure upside vs 32: only frames that
    /// WOULD have been dropped are affected — a frame that already fit at ≤32 is byte-identical.
    /// Paired with the now resolution-aware bitrate (``LiveBitratePolicy``) the ceiling rarely even
    /// binds. A/B without a rebuild via `AISLOPDESK_MAX_QP`. Best-effort: -12900/unsupported → tolerated.
    /// NOTE (2026-06-08): the "hover blurs the pane" bug was NOT this — HW A/B showed keyframes
    /// stayed a constant ~52 KB at both 12 and 40 Mbps and a 32→22 ceiling drop did not fix it;
    /// the real cause was SCK bounding-rect expansion from Chrome's tooltip child window (see
    /// WindowCapturer.makeConfiguration `includeChildWindows = false`).
    public static let maxAllowedFrameQP: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_MAX_QP"], let v = Int(s), v >= 1,
           v <= 51 { return v }
        // 51 (uncapped) since 2026-06-11, paired with default pure-VBR: the encoder must ALWAYS
        // be able to coarsen its way under the budget rather than drop (R7 HW-validated QP51;
        // the crisp static refresh restores sharpness the moment motion stops).
        return 51
    }()

    /// OWN RATE-CONTROL — CONSTANT-QP (2026-06-18, `AISLOPDESK_CONST_QP`, default OFF = nil). When set
    /// (1…51), the LIVE delta path pins `MinAllowedFrameQP` to this value — the sharp FLOOR VT may
    /// never undercut — so VideoToolbox encodes every live frame at least this crisp. This takes QP
    /// control away from VT's `AverageBitRate` VBR steering, which otherwise banks budget while idle and
    /// then SLAMS QP on the frames after a post-idle burst (the "idle → hard-scroll → rất mờ" clawback).
    /// `MaxAllowedFrameQP` is normally pinned to the SAME value (constant QP), so a static frame is
    /// Min==Max==floor; but when a per-frame motion ceiling is supplied (``constQPBand`` — the capturer's
    /// adaptive-QP measurement under `AISLOPDESK_ADAPTIVE_QP`), the MAX rises above the floor on motion so
    /// VT may coarsen the huge whole-viewport SCROLL frame (shrinking it ~80 KB → ~15-25 KB so it drains
    /// in a few ms, not ~30 ms — the scroll "nặng"), then the ceiling snaps back to the floor the instant
    /// motion stops. Frame size floats with content (idle tiny, scroll bounded). Brackets (crisp/compact
    /// IDRs) keep their own QP. The link backstop is the slow ABR (the link-AIMD nudges this Q).
    public static let constQP: Int? = {
        guard let s = ProcessInfo.processInfo.environment["AISLOPDESK_CONST_QP"], let v = Int(s),
              v >= 1, v <= 51 else { return nil }
        return v
    }()

    /// QP MIN/MAX DECOUPLE (2026-06-19, `AISLOPDESK_QP_DECOUPLE`, default **ON**; `=0` disables). Keeps
    /// `MinAllowedFrameQP` pinned to the SHARP const-QP floor on a MOTION frame while only
    /// `MaxAllowedFrameQP` rises to the content-driven ceiling — i.e. a `[floor, ceiling]` BAND instead
    /// of the legacy `Min==Max` constant. Keeps the STATIC sidebar sharp during scroll: its blocks are
    /// skip-coded (~free), so VT's per-CTU rate-distortion holds them at the floor while coarsening only
    /// the expensive moving body up to the ceiling. (VideoToolbox has no per-region/ROI QP and
    /// `SpatialAdaptiveQPLevel` is rejected under low-latency RC — HW-confirmed −12900 — so this band is
    /// the ONLY in-RC lever.) HW-VALIDATED 2026-06-19: sidebar stops blurring whole-frame, scroll stays
    /// light, ~1 VT drop / 150 frames, depth 1, no loss. ⚠️ TRADE-OFF: scroll frames run BIGGER (some
    /// >50 KB vs ~10-20 KB pinned) because the band doesn't fully bite under the ~60 Mbps backstop — fine
    /// on a clean link, but on a LOSSY WAN the fatter frames risk burst loss (the old scroll-giật cliff),
    /// so it is LOSS-TIER-ADAPTIVE (``setLinkCongested``): the `[floor,q]` band is used only while the
    /// link is CLEAN and auto-collapses to Min==Max==q (small frames) the moment the ABR reports
    /// congestion (RTT-streak / loss / gradient / catastrophic). `=0` forces the legacy pin. Only bites
    /// when ``constQP`` != nil.
    /// Resolves through ``EnvConfig`` (ProcessInfo env → overlay) — W12 — so a GUI setting can override
    /// it; with an EMPTY overlay this is byte-identical to the previous `ProcessInfo` read (default-ON
    /// `!= "0"` idiom preserved exactly).
    static let qpDecouple: Bool = EnvConfig.boolDefaultOn("AISLOPDESK_QP_DECOUPLE")

    /// CRISP STATIC REFRESH (doc 17 §3.4 — Design A, single-session QP-bump, 2026-06-08).
    /// When the window goes static the heartbeat timer re-encodes the cached frame as a
    /// near-lossless intra refresh ON THE LIVE SESSION (not a second session): we momentarily
    /// drop the QP ceiling + widen the rate cap for exactly that one forced IDR, then restore the
    /// proven low-latency config. Because it is the SAME session the VPS/SPS/PPS are unchanged, so
    /// the client does NOT rebuild its decoder (no stall), and the crisp IDR becomes the reference
    /// for the next live delta — so motion resumes seamlessly with no cross-session reference gap.
    /// HEVC QP 1(lossless)…51(coarsest); ~18 is visually transparent for text while far smaller
    /// than QP 14. Override for A/B via `AISLOPDESK_CRISP_QP` (no rebuild). Best-effort: if the encoder
    /// rejects a mid-session `MaxAllowedFrameQP` change (-12900) the refresh degrades to a normal
    /// keyframe (observable — the `crisp=…` host log shows it stayed ~live-keyframe-sized).
    public static let crispMaxQP: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_CRISP_QP"], let v = Int(s), v >= 1,
           v <= 51 { return v }
        return 18
    }()

    /// Widened `DataRateLimits` byte budget for the one-second window around a crisp IDR (64 Mbit),
    /// so the hard rate cap does not DROP the (much larger) near-lossless intra frame. The live cap
    /// (`dataRateMaxBytes`, 1.5 MB) is restored immediately after. Generous enough for a 2× HiDPI
    /// intra frame (feature #1) without ever clamping it.
    public static let crispDataRateMaxBytes = 8_000_000

    /// WF-5 (#5) TUNABLE VBV WINDOW. `DataRateLimits = [maxBytes, seconds]`: a hard cap of `maxBytes`
    /// over a sliding `seconds` window. Default 1.0s (today exactly). A TIGHTER window caps per-frame
    /// size spikes / queueing latency while PRESERVING the average rate, because the byte budget
    /// scales WITH the window: `[(bytesPerSecond)*T, T]` keeps `bytesPerSecond` constant and only
    /// narrows the burst. A/B via `AISLOPDESK_VBV_WINDOW` (seconds). Resolution/QP untouched. Clamped to a
    /// sane A/B range so a bad env value cannot zero the budget. NOTE (gotcha 5): a TIGHT window
    /// re-tightens the per-frame byte budget and, paired with the QP40 ceiling, can re-introduce the
    /// 2× HiDPI scroll drops QP40 was raised to avoid — default stays 1.0 = today.
    public static let vbvWindowSeconds: Double = resolveVBVWindow(ProcessInfo.processInfo
        .environment["AISLOPDESK_VBV_WINDOW"])

    /// PURE: parse + clamp the `AISLOPDESK_VBV_WINDOW` env string to a sane window in seconds. `nil` /
    /// unparseable / out-of-`[0.01, 4.0]` → 1.0 (today's default, so a bad env can never zero the
    /// budget). Extracted so the clamp is unit-testable without re-triggering the once-resolved static.
    static func resolveVBVWindow(_ raw: String?) -> Double {
        if let raw, let v = Double(raw), v >= 0.01, v <= 4.0 { return v }
        return 1.0
    }

    /// PURE: scale a per-1.0s byte budget over `seconds` → `(maxBytes, seconds)`, PRESERVING the
    /// average rate (budget scales WITH the window). At `seconds == 1.0` returns
    /// `(bytesPerSecond, 1.0)` exactly — `Int(Double(b)*1.0) == b` for `b ≤ 2^53` — so the default
    /// path is byte-identical. The wrong shape the task warns against is `(budget, T)`, which would
    /// slash the average to `budget/T`; this always returns `(budget*T, T)`.
    static func vbvComponents(bytesPerSecond: Int, seconds: Double) -> (maxBytes: Int, seconds: Double) {
        (Int(Double(bytesPerSecond) * seconds), seconds)
    }

    /// Builds `[maxBytes, seconds]` for `bytesPerSecond` (a per-1.0s byte budget) over the resolved
    /// ``vbvWindowSeconds``. At T==1.0 it returns exactly `[bytesPerSecond, 1.0]` — element[0] an
    /// `Int` and element[1] the same `Double 1.0` — so the default path bridges to a byte-identical
    /// CFArray (NSNumber long + NSNumber double). Pass the per-1.0s budget UNCHANGED (`clamped/8`,
    /// `currentLiveBitrate()/8`, `crispDataRateMaxBytes`, `live/8`); the helper applies `*T`. Routing
    /// all DataRateLimits set-sites through this one helper makes a half-threaded window impossible.
    static func dataRateLimits(bytesPerSecond: Int) -> CFArray {
        // PURE-VBR (AISLOPDESK_PURE_VBR=1): Parsec-style rate control — AverageBitRate steers, the hard
        // cap never binds. VT's DataRateLimits enforcement DROPS a frame that exceeds the window
        // budget (silently — the encode callback gets sampleBuffer=nil), and the 2026-06-10 khựng
        // ladder measured exactly that: capture clean at 60fps, send gaps 28-400ms, on dense
        // high-entropy content whenever the live budget was tight. Unbinding the cap here (1 GB/s
        // ≈ ∞) flows through EVERY set-site (create / crisp bracket / compact bracket / ABR
        // actuate / probe) so a half-threaded gate is impossible; the encoder then COARSENS via
        // QP under pressure instead of dropping — a soft frame beats a missing one.
        let effective = pureVBR ? 1_000_000_000 : bytesPerSecond
        let c = vbvComponents(bytesPerSecond: effective, seconds: vbvWindowSeconds)
        return [c.maxBytes, c.seconds] as CFArray
    }

    /// See ``dataRateLimits(bytesPerSecond:)``. DEFAULT **ON** since 2026-06-11 (defaults
    /// consolidation): the R7 khựng ladder HW-measured VT's hard cap silently DROPPING dense
    /// frames (send gaps 28–400ms); pure VBR + a high QP ceiling coarsens instead — a soft frame
    /// beats a missing one (drop-frame-keep-cadence). `AISLOPDESK_PURE_VBR=0` restores the hard cap.
    static let pureVBR = ProcessInfo.processInfo.environment["AISLOPDESK_PURE_VBR"] != "0"
    /// Drop visibility (AISLOPDESK_VIDEO_DEBUG): VT signals a dropped frame as `sampleBuffer == nil`
    /// in the encode callback — swallowing it silently hid the khựng factory for a whole session.
    static let dbgDropEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil

    // MARK: Compact recovery/heartbeat IDR (motion-smoothness, 2026-06-08)

    //
    // At 2× HiDPI (feature #1) a full intra frame is ~100 KB. A RECOVERY IDR (client requested it
    // after losing fragments) sent as one ~100 KB UDP burst routinely loses fragments of ITSELF →
    // the client still can't decode → it re-requests → another ~100 KB IDR. F1's cooldown caps that
    // loop at one-per-500 ms, so on a lossy link the IDRs fire in PAIRS 0.5 s apart — each a wire
    // burst that delays the next delta frame = a periodic motion HITCH ("giật"). A recovery/heartbeat
    // IDR does NOT need to be pretty (motion masks coarseness; the static-timer CRISP refresh restores
    // razor-sharp text the instant the screen goes quiet) — it needs to SURVIVE. So it is bracketed
    // the OPPOSITE way to crisp: QP ceiling RAISED + rate-control target LOWERED, shrinking the IDR to
    // ~30–50 KB ⇒ ~⅓ the fragments ⇒ it fits inside the single-loss XOR FEC's burst-recovery budget ⇒
    // the loop breaks. Both knobs A/B-tunable without a rebuild. Best-effort sets (`set`): an encoder
    // that rejects the mid-session change ships a normal-size IDR (observable — the keyframe byte size
    // in the host log stays ~100 KB instead of dropping to ~40 KB).
    //
    /// QP ceiling for a compact IDR — coarser than the live ceiling (`maxAllowedFrameQP`) so the
    /// encoder can shrink the forced IDR by coarsening instead of dropping it. A/B via `AISLOPDESK_COMPACT_QP`.
    public static let compactMaxQP: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_COMPACT_QP"], let v = Int(s), v >= 1,
           v <= 51 { return v }
        return 46
    }()

    /// Rate-control target (bits/sec) applied for EXACTLY the compact IDR — far below the live
    /// `bitrate` so the controller budgets the forced IDR small; restored to `bitrate` immediately
    /// after. A/B via `AISLOPDESK_COMPACT_KBPS` (kbit/s; 500…100000).
    public static let compactBitrate: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_COMPACT_KBPS"], let v = Int(s), v >= 500,
           v <= 100_000 { return v * 1000 }
        return 8_000_000
    }()

    /// Which session produced an output (carried to the packetizer's crisp flag).
    /// `.crisp` now means "a QP-bumped near-lossless keyframe from the LIVE session" (Design A) —
    /// purely informational on the wire (the client treats every keyframe identically). Kept so the
    /// `crisp=…` host log marks the refresh frames and their byte size verifies the QP-bump took.
    public enum Mode: Sendable { case live, crisp }

    /// Emitted for each finished encode: the AVCC bytes, keyframe flag, which session produced it,
    /// and (WF-8) the LTR acknowledgement token if this is a Long-Term-Reference frame.
    ///
    /// `ltrToken` is non-nil ONLY when `AISLOPDESK_LTR` is on AND the encoded sample carried
    /// `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken` — i.e. this is an LTR frame the client
    /// must ack. nil on every LTR-off / non-LTR frame, so the OFF path is byte-identical (the 4th arg
    /// is simply always nil). The host records `frameID ↔ token` and sets the `isLTR` wire bit when it
    /// is present.
    public typealias OutputHandler = @Sendable (
        _ avcc: Data,
        _ keyframe: Bool,
        _ mode: Mode,
        _ ltrToken: Int64?,
        _ ackedAnchored: Bool,
    ) -> Void

    private let log = Logger(subsystem: "aislopdesk.video.host", category: "VideoEncoder")
    private let width: Int32
    private let height: Int32
    private let outputHandler: OutputHandler
    /// Live-session target bitrate (bits/sec). The 12 Mbps spike default is great for video,
    /// but SHARP TEXT (screen sharing) needs more bits or HEVC softens glyph edges — so the
    /// host can raise it (e.g. ~40 Mbps over LAN/NetBird) for crisp text.
    private let bitrate: Int
    /// Live-session `ExpectedFrameRate` hint (fps). Default 60 to match the 60fps capture cap; the
    /// encoder uses it to size its rate-control window. Best-effort (a hint, not latency-critical).
    private let fps: Int

    /// WF-6 (#8): emit EXPLICIT BT.709 VUI (ColorPrimaries/TransferFunction/YCbCrMatrix) when true.
    /// Default false ⇒ NO new VUI keys ⇒ the SPS VUI bytes are byte-identical to today, so the OFF
    /// path never changes the parameter sets (and thus never trips the client's first-keyframe decoder
    /// rebuild). The luma RANGE itself (video vs full) is conveyed by the SOURCE pixel-buffer's format
    /// variant the ``WindowCapturer`` chooses — VT reads it and stamps SPS `video_full_range_flag`; it
    /// is NOT a VT compression key. So both knobs are driven by the SAME host flag, atomically.
    private let fullRange: Bool

    /// WF-8: when true, set `kVTCompressionPropertyKey_EnableLTR` on the live session, READ the
    /// `RequireLTRAcknowledgementToken` attachment off each encoded sample (surfaced as the
    /// OutputHandler's 4th arg), feed acknowledged tokens via `AcknowledgedLTRTokens`, and honour
    /// `ForceLTRRefresh` on ``encodeLiveLTRRefresh(pixelBuffer:presentationTime:)``. Default false ⇒
    /// none of that happens ⇒ the encoder is byte-identical to today (EnableLTR unset, no token read,
    /// the props dict reduces to today's `[ForceKeyFrame:true]`-or-nil). Probe-proven supported on
    /// this host (WF-7).
    private let ltrEnabled: Bool

    private var liveSession: VTCompressionSession?

    /// WF-8 acked-token STAGING. The host actor calls ``stageAcknowledgedToken(_:)`` from its `.ack`
    /// recovery arm (off the capture queue) to hand the encoder a token the client has DECODED+ACKED;
    /// the next ``encode(...)`` drains+clears this list and feeds it as `AcknowledgedLTRTokens`, so it
    /// can never grow unbounded (drained every encode). NSLock-guarded — written on the actor, read on
    /// the capture queue (same `@unchecked Sendable` + NSLock discipline as `bitrateLock`).
    private let ackedLock = NSLock()
    private var pendingAckedTokens: [Int64] = []

    /// MUTABLE live target bitrate (bits/sec) — the SINGLE source of truth for the rate-control
    /// properties (AverageBitRate + DataRateLimits). Seeded to `bitrate` (the immutable CEILING) so
    /// when WF-2 adaptive bitrate (`AISLOPDESK_ABR`) is OFF this never moves and every RC property is
    /// byte-identical to before. The WF-2 controller lowers/raises it at runtime via
    /// ``setLiveBitrate(_:)``; the crisp/compact brackets RESTORE from it (via ``currentLiveBitrate()``)
    /// so a bracket can never revert a controller-lowered rate back to the original ceiling.
    ///
    /// CONCURRENCY: read on the capture queue (create + bracket restores) and written on the host
    /// actor (``setLiveBitrate(_:)``), so ALL access goes through `bitrateLock` (NSLock) — the same
    /// `@unchecked Sendable` + NSLock discipline used elsewhere (InboundQueue/EncodedFrameQueue).
    private let bitrateLock = NSLock()
    private var liveBitrate: Int
    /// > 0 while a crisp/compact bracket is mid-relax (between its RELAX and its `defer` RESTORE).
    /// ``setLiveBitrate(_:)`` always updates `liveBitrate` under the lock, but SKIPS issuing the
    /// VTSessionSetProperty writes while a bracket is active — the active bracket's `defer` re-reads
    /// ``currentLiveBitrate()`` and applies the newest value on restore, so the controller can never
    /// clobber the relaxed crisp/compact config mid-IDR and the bracket never reverts the controller.
    private var bracketDepth = 0
    /// LIVE constant-QP value (bitrateLock-guarded) when const-QP mode is on (``constQP`` != nil). Seeded
    /// from the env, then driven per network report by the host's link-AIMD (``QPController``) via
    /// ``setConstQP(_:)`` — so the constant quality adapts to the link (coarsen on congestion) without
    /// VT's per-frame VBR clawback. Only read on the live delta path when ``constQP`` != nil.
    private var liveConstQP: Int = VideoEncoder.constQP ?? maxAllowedFrameQP
    /// Last per-frame adaptive `MaxAllowedFrameQP` actually written (bitrateLock-guarded). Skips the
    /// redundant VTSessionSetProperty + CFNumber bridge when the smoothed QP is unchanged (the common
    /// static/typing case → QP pinned at qp_sharp). INVALIDATED to nil by every crisp/compact bracket
    /// restore (which writes the static ceiling) so the next live frame always re-applies its own QP.
    private var lastAdaptiveQP: Int?
    /// LINK CONGESTED (bitrateLock-guarded) — the host's per-report ABR cut verdict (RTT-streak / loss /
    /// gradient / catastrophic). Driven by ``setLinkCongested(_:)``. When TRUE, ``qpDecouple`` is
    /// SUPPRESSED (Min re-pinned to Max==q) so scroll frames stay small on a stressed link instead of
    /// fattening for sidebar sharpness — i.e. the decouple is loss-tier-adaptive. Default false (clean).
    private var linkCongested = false

    /// COMPACT LAZY-RESTORE (2026-06-18, HW-measured). The compact recovery IDR relaxes the session
    /// QP/rate then drained twice (`VTCompressionSessionCompleteFrames`) to isolate the IDR before
    /// restoring — but each drain blocked the SCStream capture queue ~115ms (probe E6b: 24 stalls>100ms),
    /// and under the lossy-WAN recovery-IDR storm (~6 IDR/s) those drains ARE the scroll "giật". Instead,
    /// when ``compactLazyRestore`` is on, the compact IDR encodes under the relaxed config and DEFERS the
    /// restore to the next live encode (no drain): the small compact IDR finishes well within the ~16ms
    /// before the next delta, so it keeps its compact size, and the next delta restores live config first.
    /// `bitrateLock`-guarded. `AISLOPDESK_COMPACT_LAZY_RESTORE=0` reverts to the (drain-bracketed) path.
    private static let compactLazyRestore =
        ProcessInfo.processInfo.environment["AISLOPDESK_COMPACT_LAZY_RESTORE"] != "0"
    private var pendingCompactRestore = false

    /// Restore the live config after a lazy-restore compact IDR — called at the START of every encode
    /// entry so the relaxed config never bleeds past the single IDR. No-op unless a compact IDR deferred
    /// its restore. Mirrors the compact bracket's `defer` body (idempotent RC writes).
    private func restorePendingCompactBracket() {
        bitrateLock.lock()
        guard pendingCompactRestore else { bitrateLock.unlock()
            return
        }
        pendingCompactRestore = false
        let live = liveBitrate
        let sess = liveSession
        bitrateLock.unlock()
        guard let sess else { return }
        set(sess, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.maxAllowedFrameQP as CFNumber)
        set(sess, kVTCompressionPropertyKey_AverageBitRate, live as CFNumber)
        set(sess, kVTCompressionPropertyKey_DataRateLimits, Self.dataRateLimits(bytesPerSecond: live / 8))
        bitrateLock.lock()
        bracketDepth -= 1
        lastAdaptiveQP = nil
        bitrateLock.unlock()
    }

    public init(
        width: Int,
        height: Int,
        bitrate: Int = bitrateBitsPerSecond,
        fps: Int = 60,
        fullRange: Bool = false,
        ltrEnabled: Bool = false,
        outputHandler: @escaping OutputHandler,
    ) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = max(1_000_000, bitrate)
        liveBitrate = max(1_000_000, bitrate) // seed the mutable live rate to the ceiling
        self.fps = max(1, fps)
        self.fullRange = fullRange
        self.ltrEnabled = ltrEnabled
        self.outputHandler = outputHandler
    }

    /// WF-8: stage a token the client has ACKNOWLEDGED (decoded an LTR frame for) so the next encode
    /// feeds it as `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens`. Called from the host actor's `.ack`
    /// recovery arm. No-op when LTR is off (the actor only calls this under its `AISLOPDESK_LTR` gate, but
    /// the drain is gated again in `encode` so a stray stage is harmless). DEDUP + BOUNDED: the encode
    /// drain usually outpaces acks, but acks can arrive while no frame is being encoded (a capture
    /// stall), so dedup repeats and cap to the most-recent few — the encoder only needs the current
    /// acknowledged set, and an unbounded staging list is the codebase's documented no-no.
    public func stageAcknowledgedToken(_ token: Int64) {
        ackedLock.lock()
        defer { ackedLock.unlock() }
        if pendingAckedTokens.contains(token) { return }
        pendingAckedTokens.append(token)
        if pendingAckedTokens.count > 32 { pendingAckedTokens.removeFirst(pendingAckedTokens.count - 32) }
    }

    /// STALE-LTR FIX (2026-06-12): drops every staged-but-not-yet-drained acked token. Called by
    /// the host when an encoded KEYFRAME ships — the IDR clears the decoder's DPB (long-term
    /// references included, HEVC spec), so a pre-IDR ack describes a reference the client no
    /// longer holds and must never be fed to a later encode as `AcknowledgedLTRTokens`.
    public func clearStagedAckedTokens() {
        ackedLock.lock()
        defer { ackedLock.unlock() }
        pendingAckedTokens = []
    }

    /// Atomically takes + clears the staged acked tokens (called once per encode under `ltrEnabled`).
    private func drainPendingAckedTokens() -> [Int64] {
        ackedLock.lock()
        defer { ackedLock.unlock() }
        let out = pendingAckedTokens
        pendingAckedTokens = []
        return out
    }

    /// Thread-safe read of the current live target bitrate (bits/sec). Used at the create site and by
    /// the crisp/compact bracket restores so they always restore the controller's LATEST rate, not the
    /// immutable ceiling. (NSLock is non-recursive — never call this while already holding `bitrateLock`.)
    private func currentLiveBitrate() -> Int {
        bitrateLock.lock()
        defer { bitrateLock.unlock() }
        return liveBitrate
    }

    /// WF-2 ADAPTIVE BITRATE actuator. Sets the live target bitrate to `target`, clamped to
    /// `[LiveBitratePolicy.minimumBitrate, bitrate]` — i.e. never 0/negative and never above the
    /// immutable ceiling. Called from the host actor (handleRecovery, throttled to material changes).
    ///
    /// Updates `liveBitrate` (the source of truth) under the lock ALWAYS. It issues the actual
    /// VTSessionSetProperty writes (BOTH AverageBitRate and DataRateLimits together, so the two RC
    /// knobs stay consistent) ONLY when no crisp/compact bracket is mid-relax; while a bracket is
    /// active it skips the writes and lets that bracket's `defer` apply the new value on restore.
    /// Best-effort (`set`, not `setCritical`): a rejected mid-session change keeps the prior rate and
    /// never throws/aborts the encoder. Returns whether `liveBitrate` actually changed.
    @discardableResult
    public func setLiveBitrate(_ target: Int) -> Bool {
        let clamped = max(LiveBitratePolicy.minimumBitrate, min(bitrate, target))
        bitrateLock.lock()
        let changed = clamped != liveBitrate
        liveBitrate = clamped
        let midBracket = bracketDepth > 0
        let sess = liveSession
        bitrateLock.unlock()
        guard changed, let sess else { return false }
        if !midBracket {
            // Not mid-bracket: apply both RC properties now so steady-state stays consistent.
            set(sess, kVTCompressionPropertyKey_AverageBitRate, clamped as CFNumber)
            set(sess, kVTCompressionPropertyKey_DataRateLimits, Self.dataRateLimits(bytesPerSecond: clamped / 8))
        }
        // Mid-bracket: skip — the active bracket's defer re-reads currentLiveBitrate() and applies it.
        return changed
    }

    /// OWN RATE-CONTROL: set the live constant-QP (the link-AIMD ``QPController``'s current Q). No-op
    /// unless const-QP mode is on (``constQP`` != nil). Clamped to the HEVC range. Clears
    /// `lastAdaptiveQP` so the next live delta frame re-applies Min==Max==Q; the actual VTSessionSet
    /// happens on that next `encode()` (not here), so this is a cheap lock-guarded store callable from
    /// the host actor per network report. Returns whether the value changed.
    @discardableResult
    public func setConstQP(_ q: Int) -> Bool {
        guard Self.constQP != nil else { return false }
        let clamped = max(1, min(51, q))
        bitrateLock.lock()
        let changed = clamped != liveConstQP
        liveConstQP = clamped
        if changed { lastAdaptiveQP = nil } // force the next live frame to re-pin Min==Max==clamped
        bitrateLock.unlock()
        return changed
    }

    /// LOSS-TIER-ADAPTIVE DECOUPLE: set whether the link is currently congested (the host's ABR cut
    /// verdict). When TRUE, ``qpDecouple`` is suppressed so the live delta path re-pins `Min==Max==q`
    /// (small scroll frames — safe on a stressed link); when FALSE (clean), the `[floor, q]` band is
    /// restored (sharp sidebar). Clears `lastAdaptiveQP` on change so the next `encode()` re-applies the
    /// new Min. Lock-guarded store, callable from the host actor per network report. No-op unless
    /// const-QP mode is on. Returns whether it changed.
    @discardableResult
    public func setLinkCongested(_ congested: Bool) -> Bool {
        guard Self.constQP != nil else { return false }
        bitrateLock.lock()
        let changed = congested != linkCongested
        linkCongested = congested
        if changed { lastAdaptiveQP = nil } // force the next live frame to re-apply Min under the new band
        bitrateLock.unlock()
        return changed
    }

    /// FPS-GOVERNOR actuation (2026-06-11): live `ExpectedFrameRate` hint. Best-effort mid-session
    /// `VTSessionSetProperty` — the same proven-live mechanism as ``setLiveBitrate(_:)``'s
    /// AverageBitRate writes; a -12900 is tolerated (it is an RC-window-sizing HINT, not the
    /// latency contract — the ``EncodeCadenceGate`` enforces the actual cadence regardless).
    /// Deliberately NOT bracketed: the crisp/compact brackets save/restore only QP +
    /// AverageBitRate + DataRateLimits, so there is no save/restore interplay to honour. And
    /// `AverageBitRate` is deliberately NOT changed on an fps step — fewer frames sharing the same
    /// bitrate = bigger, sharper frames (the Parsec behaviour the governor wants).
    public func setExpectedFrameRate(_ fps: Int) {
        bitrateLock.lock()
        let sess = liveSession
        bitrateLock.unlock()
        guard let sess else { return }
        set(sess, kVTCompressionPropertyKey_ExpectedFrameRate, max(1, fps) as CFNumber)
    }

    deinit {
        if let liveSession { VTCompressionSessionInvalidate(liveSession) }
    }

    // MARK: Session A — live (low-latency-RC)

    /// Creates Session A exactly per the validated spike config. Throws
    /// ``VideoEncoderError/notHardwareBacked`` if HW is unavailable (gated at
    /// creation, not by querying UsingHW while low-latency is on — that returns
    /// -12900). Retries -12905 once with backoff (doc 18 §G).
    public func createLiveSession() throws {
        // Specification keys go in the CREATE dict, not via SetProperty (doc 17 §3.2).
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session,
        )
        if status == -12905 { // XPC create race — retry once after backoff (doc 18 §G).
            log.notice("live session create -12905, retrying after backoff")
            usleep(useconds_t(Self.createRetryBackoffNanos / 1000))
            status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height,
                codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &session,
            )
        }
        guard status == noErr, let session else { throw VideoEncoderError.sessionCreateFailed(status) }

        // Property keys (via VTSessionSetProperty). EXACT spike config. The
        // LATENCY-CRITICAL keys THROW on failure — a silent failure here corrupts the
        // proven low-latency config (doc 18 §E). Best-effort keys are set leniently
        // (logged on failure) since they degrade quality, not the latency contract.
        try setCritical(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber) // best-effort (60 default)
        set(
            session,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            Self.speedOverQuality ? kCFBooleanTrue : kCFBooleanFalse,
        ) // best-effort; default QUALITY-first (sharpness)
        try setCritical(
            session,
            kVTCompressionPropertyKey_AllowFrameReordering,
            kCFBooleanFalse,
        ) // no B-frames — latency-critical
        // Explicitly opt OUT of the power-efficiency hint: left unset, the HW encoder may apply
        // an efficiency clock policy that adds encode latency. We always trade watts for ms here.
        // Best-effort: tolerated as -12900 on encoders without the key.
        set(session, kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
        set(
            session,
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            Int(Int32.max) as CFNumber,
        ) // IDR on-demand (best-effort)
        // AverageBitRate + DataRateLimits together ARE the low-latency rate-control
        // contract — both latency-critical.
        // Read the LIVE bitrate (== ceiling `bitrate` unless WF-2 ABR has already lowered it) so a
        // session rebuilt mid-stream (resize) comes up at the controller's current rate, not the ceiling.
        try setCritical(session, kVTCompressionPropertyKey_AverageBitRate, currentLiveBitrate() as CFNumber)
        // DataRateLimits = [maxBytes, seconds]; hard cap at the live bitrate (/8 not /4).
        try setCritical(
            session,
            kVTCompressionPropertyKey_DataRateLimits,
            Self.dataRateLimits(bytesPerSecond: currentLiveBitrate() / 8),
        )
        // SpatialAdaptiveQPLevel=Disable is a QP-modulation HINT. The spike host advertised it,
        // but it is kVTPropertyNotSupportedErr (-12900) on HEVC encoders that don't implement
        // the key — and low-latency rate control is ALREADY established by
        // EnableLowLatencyRateControl (spec) + AverageBitRate/DataRateLimits. So set it
        // BEST-EFFORT: apply it where supported, tolerate -12900 elsewhere. (Forcing it as
        // critical aborted the WHOLE encoder on such hardware, leaving PATH 2 unable to produce
        // a single frame — observed via check-video.sh's host diagnostics, 2026-06-02.)
        set(session, kVTCompressionPropertyKey_SpatialAdaptiveQPLevel, kVTQPModulationLevel_Disable as CFNumber)
        // §A1 part 2 (doc 26 §A): cap the worst-case quantizer so text never smears under a
        // bitrate-starved frame. With low-latency RC + a 12 Mbps DataRateLimits hard cap, a busy
        // frame can otherwise blow its budget and the encoder coarsens QP → blurry glyph edges.
        // MaxAllowedFrameQP tells the encoder to DROP a frame (or spend an extra IDR) rather than
        // ship a frame above this QP — on a 24–30fps desktop a held-but-sharp frame beats a
        // delivered-but-blurry one. QP ~32 (1=lossless..51=worst) keeps text crisp while leaving
        // motion headroom; tune on hardware.
        // BEST-EFFORT (NOT setCritical): kVTCompressionPropertyKey_MaxAllowedFrameQP is
        // kVTPropertyNotSupportedErr/-12900 on some HEVC encoders — same -12900-prone family as
        // SpatialAdaptiveQPLevel above; forcing it critical would abort the whole encoder on such
        // hardware (the exact regression class the 2026-06-02 fix #1 guards against). The key
        // exists on macOS 26; on older OSes it is simply tolerated as a no-op.
        set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.maxAllowedFrameQP as CFNumber)
        // WF-6 (#8): EXPLICIT BT.709 VUI (color primaries / transfer / matrix). GATED behind
        // `fullRange` so the OFF path sets NO new keys and the emitted SPS VUI is byte-identical to
        // today — an UNCONDITIONAL set would change the parameter-set bytes (→ a needless client
        // decoder rebuild on the first keyframe) and would also relabel the sRGB-transfer capture as
        // 709-transfer. Best-effort (`set`, NOT `setCritical`): hygiene/quality, not the latency
        // contract, so a -12900 on an encoder lacking the key is tolerated. NOTE: the luma RANGE is
        // NOT set here — it rides the source pixel-buffer's FullRange variant (WindowCapturer), which
        // VT reads to stamp `video_full_range_flag`; these keys only label primaries/transfer/matrix.
        if fullRange {
            set(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
            set(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
            set(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
        // WF-8: LONG-TERM-REFERENCE recovery. Enable LTR so the encoder periodically promotes frames
        // to long-term references (each emitted carrying `RequireLTRAcknowledgementToken`) and honours
        // a later `ForceLTRRefresh` against an ACKNOWLEDGED LTR — a cheap P-frame recovery with NO
        // decoder flush, vs a full IDR. GATED behind `ltrEnabled` (`AISLOPDESK_LTR`) so the OFF path sets
        // NO new key and the session is byte-identical to today. Best-effort (`set`, NOT `setCritical`,
        // like fullRange): an encoder lacking the key returns -12900 and the encoder degrades to the
        // IDR-only recovery path — never aborts. WF-7's HW probe confirmed noErr on THIS host.
        if ltrEnabled {
            set(session, kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue)
        }
        // ProfileLevel OMITTED for the low-latency session (doc 18 §E).
        // NOTE: do NOT query UsingHardwareAcceleratedVideoEncoder here — it returns
        // -12900 with low-latency on; HW is already gated by Require...=true above.

        VTCompressionSessionPrepareToEncodeFrames(session)
        liveSession = session
    }

    // MARK: WF-7 (#9) LTR capability probe — DIAGNOSTIC ONLY (AISLOPDESK_LTR_PROBE)

    //
    // Answers the CRITICAL UNKNOWN for Long-Term-Reference recovery: does
    // `kVTCompressionPropertyKey_EnableLTR` + per-frame `ForceLTRRefresh` actually work on a
    // LOW-LATENCY HEVC session on THIS hardware? EnableLTR shipped H.264-ONLY at launch, so whether it
    // returns noErr or `kVTPropertyNotSupportedErr` (-12900) on a low-latency HEVC session on macOS 26
    // is UNVERIFIED. The probe is ISOLATED ON PURPOSE: it is a `static` func with NO instance access,
    // so it can NEVER read/write `liveSession`, `bitrateLock`, or the crisp/compact bracket state, and
    // it runs on its OWN throwaway VTCompressionSession that is torn down on every exit path. It does
    // NOT change the live encode/recovery behaviour — it only logs ONE `LTR-PROBE:` verdict line.

    /// The single-word verdict of the LTR capability probe. `unknown` = the probe could not be
    /// completed (session-create or pixel-buffer alloc failed → re-run); `unsupported` = EnableLTR or a
    /// ForceLTRRefresh encode was rejected (keep the compact-IDR fallback — do NOT switch to H.264);
    /// `ambiguous` = EnableLTR took but the documented `kCFBooleanTrue` ForceLTRRefresh form was
    /// rejected while the `CFNumber` form was accepted (the header's CFNumber-vs-Boolean contradiction
    /// resolves toward CFNumber); `supported` = EnableLTR + the documented ForceLTRRefresh form both
    /// took (the full LTR wire/ack path is worth building).
    enum LTRProbeVerdict: String {
        case supported
        case unsupported
        case ambiguous
        case unknown
    }

    /// PURE: maps the probe's captured `OSStatus` values to a ``LTRProbeVerdict``. Extracted so the
    /// status→verdict mapping is unit-testable WITHOUT a HW VTCompressionSession (the session itself is
    /// hang-gated and never runs headlessly). `enableStatus == nil` means "EnableLTR was never reached"
    /// (create / pixel-buffer alloc failed first) → `.unknown`. `forceLTRNumberStatus == nil` means the
    /// CFNumber retry was not attempted (the Boolean form already succeeded, or there was nothing to
    /// disambiguate).
    static func interpretLTRProbe(
        enableStatus: OSStatus?,
        keyframeEncodeStatus: OSStatus = noErr,
        forceLTRBooleanStatus: OSStatus = noErr,
        forceLTRNumberStatus: OSStatus? = nil,
        sawAckToken: Bool = false,
    ) -> LTRProbeVerdict {
        guard let enableStatus else { return .unknown } // never reached EnableLTR → re-run
        guard enableStatus == noErr else { return .unsupported } // EnableLTR rejected (likely -12900)
        guard keyframeEncodeStatus == noErr else { return .unsupported } // could not seed an LTR ref
        let booleanTook = forceLTRBooleanStatus == noErr // documented kCFBooleanTrue form
        let numberTook = forceLTRNumberStatus == noErr // CFNumber retry (header contradiction)
        guard booleanTook || numberTook else { return .unsupported } // both ForceLTRRefresh forms rejected
        // API ACCEPTANCE ALONE IS NOT ENOUGH: trust `.supported` ONLY when the documented Boolean form
        // took AND the encoder actually emitted an LTR frame carrying the RequireLTRAcknowledgementToken
        // attachment (proves real LTR-frame emission, not just a no-op property accept). Anything else
        // accepted-but-unconfirmed (no ack-token, or only the non-documented CFNumber form) is `.ambiguous`
        // → manual HW inspection before building the LTR wire/ack path.
        guard booleanTook, sawAckToken else { return .ambiguous }
        return .supported
    }

    /// Records, from the throwaway probe's `@Sendable` block output handler, the last callback
    /// `OSStatus` and whether ANY emitted sample carried the `RequireLTRAcknowledgementToken`
    /// attachment (mirror of ``deliver(sampleBuffer:mode:handler:)``'s attachment inspection). The VT
    /// output block is `@Sendable` and fires on VT's own queue, so the writes are `NSLock`-guarded.
    private final class LTRProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lastCallbackStatus: OSStatus = noErr
        private var sawToken = false
        func record(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
            lock.lock()
            defer { lock.unlock() }
            lastCallbackStatus = status
            guard status == noErr, let sampleBuffer,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(
                      sampleBuffer,
                      createIfNecessary: false,
                  ) as? [[CFString: Any]],
                  let first = attachments.first else { return }
            if first[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] != nil { sawToken = true }
        }

        func snapshot() -> (status: OSStatus, sawToken: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (lastCallbackStatus, sawToken)
        }
    }

    /// WF-7 (#9) HARDWARE CAPABILITY PROBE. Creates a THROWAWAY low-latency HEVC VTCompressionSession
    /// (the SAME spec/properties as ``createLiveSession()``), tries `EnableLTR` + a `ForceLTRRefresh`
    /// encode, and logs ONE `LTR-PROBE:` verdict line. Every `VTSessionSetProperty` /
    /// `VTCompressionSessionEncodeFrame` status is captured into a local and reported — there is NO
    /// `setCritical`, NO force-unwrap, NO precondition on any LTR result, so an unsupported property is
    /// a normal logged branch, never an abort. Gated default-off behind `AISLOPDESK_LTR_PROBE` at the daemon
    /// startup, run BEFORE the listener admits clients so no live session can coexist on the HW encoder.
    ///
    /// ⚠️ HANG-SAFETY: like the rest of this type, the HW create/encode HANG without a window-server +
    /// TCC session — NEVER call this from a test; only from the gated daemon path on a real GUI host.
    public static func runLTRCapabilityProbe(
        width: Int = 1280, height: Int = 720,
        bitrate: Int = bitrateBitsPerSecond, fps: Int = 60,
        log: (String) -> Void,
    ) {
        let w = Int32(max(16, width)), h = Int32(max(16, height))
        let fpsClamped = Int32(max(1, fps))
        let bitrateClamped = max(1_000_000, bitrate)

        // (a) SAME spec dict as createLiveSession 277-280 (low-latency RC + require-HW), HEVC codec.
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: nil, width: w, height: h,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session,
        )
        guard createStatus == noErr, let session else {
            // -12905 (XPC race) reads as VERDICT=unknown (re-run), distinct from -12900 (unsupported).
            log("LTR-PROBE: session-create=\(createStatus) VERDICT=\(interpretLTRProbe(enableStatus: nil).rawValue)")
            return
        }
        // ALWAYS tear the throwaway session down on every exit path.
        defer { VTCompressionSessionInvalidate(session) }

        // (b) Mirror the proven property keys best-effort — statuses IGNORED (they don't affect the LTR
        //     verdict; mirroring is only for config fidelity). Plain VTSessionSetProperty (NOT the
        //     instance `setCritical`/`set`) so the probe stays static/independent. None throw.
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: fpsClamped as CFNumber,
        )
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: bitrateClamped as CFNumber,
        )
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: Self.dataRateLimits(bytesPerSecond: bitrateClamped / 8),
        )
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
            value: Self.maxAllowedFrameQP as CFNumber,
        )

        // (c) THE PROBE step 1 — EnableLTR (the CRITICAL unknown). CFBoolean per the header (macos 12.0).
        let enableStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_EnableLTR,
            value: kCFBooleanTrue,
        )
        guard enableStatus == noErr else {
            log(
                "LTR-PROBE: EnableLTR=\(enableStatus) (kVTPropertyNotSupportedErr=-12900) keyframe-encode=n/a ForceLTRRefresh-encode=n/a RequireAckToken=n/a VERDICT=\(interpretLTRProbe(enableStatus: enableStatus).rawValue)",
            )
            return
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        // (d) Throwaway zeroed NV12 buffer (content is irrelevant for a capability check).
        var pixelBuffer: CVPixelBuffer?
        let pbStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(w), Int(h),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer,
        )
        guard pbStatus == kCVReturnSuccess, let pixelBuffer else {
            log(
                "LTR-PROBE: EnableLTR=\(enableStatus) pixelbuffer-create=\(pbStatus) VERDICT=\(interpretLTRProbe(enableStatus: nil).rawValue)",
            )
            return
        }

        // (e) NSLock-guarded box records the block callback status + ack-token observation.
        let box = LTRProbeBox()

        // (f) Frame #1 — a normal forced keyframe SEEDS an LTR reference. With no acknowledged LTR yet,
        //     ForceLTRRefresh would otherwise just emit an IDR (header 1269-1270), so encode this first.
        let enc1 = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: 0, timescale: fpsClamped),
            duration: .invalid,
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
            infoFlagsOut: nil,
        ) { status, _, sampleBuffer in box.record(status: status, sampleBuffer: sampleBuffer) }

        // (g) Frame #2 WITH ForceLTRRefresh — documented prose form (kCFBooleanTrue) FIRST.
        let enc2Boolean = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: 1, timescale: fpsClamped),
            duration: .invalid,
            frameProperties: [kVTEncodeFrameOptionKey_ForceLTRRefresh: kCFBooleanTrue] as CFDictionary,
            infoFlagsOut: nil,
        ) { status, _, sampleBuffer in box.record(status: status, sampleBuffer: sampleBuffer) }

        // (3) Disambiguate the header's CFNumber-vs-Boolean contradiction (decl says CFNumberRef,
        //     @abstract says "set to kCFBooleanTrue"): if the Boolean form was rejected, RETRY the same
        //     refresh with the CFNumber form to see which the SDK actually accepts. Status captured;
        //     passing the "wrong" CFType yields a status (or is ignored), never a trap.
        var enc2Number: OSStatus?
        if enc2Boolean != noErr {
            enc2Number = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: 2, timescale: fpsClamped),
                duration: .invalid,
                frameProperties: [kVTEncodeFrameOptionKey_ForceLTRRefresh: 1 as CFNumber] as CFDictionary,
                infoFlagsOut: nil,
            ) { status, _, sampleBuffer in box.record(status: status, sampleBuffer: sampleBuffer) }
        }

        // (h) Drain ALL pending block callbacks synchronously so the box is fully populated before read.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        // (i) Single verdict line. (defer above invalidates the throwaway session.)
        let (lastCallback, sawToken) = box.snapshot()
        let verdict = interpretLTRProbe(
            enableStatus: enableStatus,
            keyframeEncodeStatus: enc1,
            forceLTRBooleanStatus: enc2Boolean,
            forceLTRNumberStatus: enc2Number,
            sawAckToken: sawToken,
        )
        let enc2Desc = enc2Number.map { "boolean=\(enc2Boolean)/number=\($0)" } ?? "\(enc2Boolean)"
        log(
            "LTR-PROBE: EnableLTR=\(enableStatus), keyframe-encode=\(enc1), ForceLTRRefresh-encode=\(enc2Desc), callback-status=\(lastCallback), RequireAckToken=\(sawToken), VERDICT=\(verdict.rawValue)",
        )
    }

    // MARK: Crisp static refresh (Design A — single-session QP-bump, doc 17 §3.4)

    /// Emits a near-lossless intra refresh ON THE LIVE SESSION without a parameter-set change.
    /// Called by ``WindowCapturer``'s static-IDR timer (frameQueue-serial, and ONLY while the live
    /// path is quiet — so no live frame is encoding concurrently). Mechanism:
    ///   1. `CompleteFrames` drains any in-flight frame so the QP swap doesn't affect a still-live-QP encode.
    ///   2. Drop the QP ceiling (`crispMaxQP`) + widen the rate cap (`crispDataRateMaxBytes`) so the
    ///      forced IDR is near-lossless and not dropped by the hard cap.
    ///   3. Encode the cached frame as a forced keyframe (tagged `.crisp` for the host log).
    ///   4. `CompleteFrames` AGAIN — the VT output callback is async, so this guarantees the crisp
    ///      frame is fully encoded UNDER the relaxed config BEFORE we restore (restoring first would
    ///      let it encode at the live ceiling → soft). This second drain is the gap-closer.
    ///   5. `defer` restores the proven low-latency rate-control config (QP 32 + 1.5 MB cap).
    /// Same VPS/SPS/PPS ⇒ the client does NOT rebuild its decoder; the crisp IDR becomes the
    /// reference for the next live delta ⇒ motion resumes seamlessly. The QP/cap sets are
    /// best-effort: an encoder that rejects a mid-session `MaxAllowedFrameQP` change (-12900) simply
    /// ships a normal keyframe (visible: the `crisp=…` log byte size stays ~live-keyframe-sized).
    public func encodeLiveCrispKeyframe(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        guard let session = liveSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        restorePendingCompactBracket() // settle any prior lazy compact bracket before relaxing for crisp
        // WF-2: mark a bracket active so a concurrent setLiveBitrate (host actor) skips its own RC
        // writes; the restore defer below re-applies the controller's latest rate.
        bitrateLock.lock()
        bracketDepth += 1
        bitrateLock.unlock()
        // 1. Drain prior in-flight frames so they finish under the LIVE config (not the relaxed one).
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        // 2. Relax: drop the QP ceiling + widen the hard rate cap for exactly this one IDR.
        set(
            session,
            kVTCompressionPropertyKey_DataRateLimits,
            Self.dataRateLimits(bytesPerSecond: Self.crispDataRateMaxBytes),
        )
        set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.crispMaxQP as CFNumber)
        // CONST-QP: the live path pins Min==constQP; the crisp IDR's sharp Max (crispMaxQP < constQP)
        // would then be Min>Max. Pin Min to the crisp QP too so the IDR is sharp + valid. No-op when
        // const-QP is off (no Min is ever set). The defer restores Max to maxAllowedFrameQP (≥ Min), and
        // the next live frame re-pins Min==Max==constQP.
        if Self.constQP != nil {
            set(session, kVTCompressionPropertyKey_MinAllowedFrameQP, Self.crispMaxQP as CFNumber)
        }
        // 5. Restore the proven live low-latency config no matter how we exit. CRITICAL: restore the
        //    LIVE cap (`currentLiveBitrate() / 8`, matching the create-site), NOT the static 12 Mbps
        //    default — otherwise the first static refresh on a `--bitrate >12` session would permanently
        //    clamp the live stream to 1.5 MB (~⅓ of e.g. a 40 Mbps config) and never recover. Reading
        //    the LIVE value (not the immutable ceiling) also means a WF-2-lowered rate is preserved.
        //    Decrement bracketDepth in the SAME defer so it drops only after the restore lands.
        //    Restore BOTH RC knobs (AverageBitRate + DataRateLimits) from the SAME live snapshot: a
        //    controller `setLiveBitrate` that landed mid-bracket updated `liveBitrate` but SKIPPED its
        //    own VTSessionSetProperty writes, so this defer is the ONLY place the new rate is applied.
        //    The crisp relax only widened DataRateLimits, so restoring just that knob would leave
        //    AverageBitRate stale at the pre-controller value; writing both keeps the two consistent
        //    (each is a no-op when no controller change occurred — the value is already current).
        defer {
            let live = currentLiveBitrate()
            set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.maxAllowedFrameQP as CFNumber)
            set(session, kVTCompressionPropertyKey_AverageBitRate, live as CFNumber)
            set(session, kVTCompressionPropertyKey_DataRateLimits, Self.dataRateLimits(bytesPerSecond: live / 8))
            bitrateLock.lock()
            bracketDepth -= 1
            lastAdaptiveQP = nil // bracket restored the static ceiling → next live frame re-applies its QP
            bitrateLock.unlock()
        }
        // 3. Encode the forced crisp keyframe.
        try encode(
            session: session,
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            forceKeyframe: true,
            mode: .crisp,
        )
        // 4. Ensure it is fully emitted under the relaxed config before `defer` restores.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Emits a COMPACT forced IDR on the live session for loss-recovery / active-path heartbeat — the
    /// INVERSE of ``encodeLiveCrispKeyframe`` (see the "Compact recovery/heartbeat IDR" note above for
    /// why). Same bracket discipline so it cannot bleed into the live deltas:
    ///   1. `CompleteFrames` drains in-flight frames so they finish under the LIVE config.
    ///   2. RAISE the QP ceiling (`compactMaxQP`) + LOWER the rate-control target (`compactBitrate`)
    ///      so the forced IDR is small enough to survive a UDP burst.
    ///   3. Encode the forced keyframe (tagged `.live` — it is a normal keyframe on the wire, just
    ///      smaller; the host-log byte size is the verification that the bracket took).
    ///   4. `CompleteFrames` AGAIN so the IDR is fully emitted under the relaxed config BEFORE restore.
    ///   5. `defer` restores the proven live config (QP ceiling + `bitrate`). Same VPS/SPS/PPS ⇒ no
    ///      client decoder rebuild. Best-effort sets: a rejected change just ships a normal-size IDR.
    public func encodeCompactKeyframe(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        guard let session = liveSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        restorePendingCompactBracket() // settle any prior lazy bracket before starting a new one
        // LAZY-RESTORE path (default): relax → encode the IDR → DEFER the restore to the next live
        // encode, with NO synchronous CompleteFrames drain (the capture-stall source). The compact IDR
        // is small, so it finishes under the relaxed config within the ~16ms before the next delta.
        if Self.compactLazyRestore {
            bitrateLock.lock()
            bracketDepth += 1
            pendingCompactRestore = true
            bitrateLock.unlock()
            set(session, kVTCompressionPropertyKey_AverageBitRate, Self.compactBitrate as CFNumber)
            set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.compactMaxQP as CFNumber)
            try encode(
                session: session,
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                forceKeyframe: true,
                mode: .live,
            )
            return // restore happens at the next encodeLive (restorePendingCompactBracket)
        }
        // LEGACY drain-bracketed path (AISLOPDESK_COMPACT_LAZY_RESTORE=0).
        // WF-2: mark a bracket active (see encodeLiveCrispKeyframe) — restore re-applies the live rate.
        bitrateLock.lock()
        bracketDepth += 1
        bitrateLock.unlock()
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        set(session, kVTCompressionPropertyKey_AverageBitRate, Self.compactBitrate as CFNumber)
        set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.compactMaxQP as CFNumber)
        defer {
            // Restore BOTH RC knobs from the SAME live snapshot (not the immutable ceiling) so a
            // WF-2-lowered rate is preserved. The compact relax only lowered AverageBitRate, but a
            // controller `setLiveBitrate` that landed mid-bracket skipped BOTH writes — so
            // DataRateLimits (the HARD cap) must be re-applied here too, else it stays stale at the
            // pre-controller (looser) value and a complex frame can exceed a concurrent congestion
            // back-off. Each write is a no-op when no controller change occurred.
            let live = currentLiveBitrate()
            set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.maxAllowedFrameQP as CFNumber)
            set(session, kVTCompressionPropertyKey_AverageBitRate, live as CFNumber)
            set(session, kVTCompressionPropertyKey_DataRateLimits, Self.dataRateLimits(bytesPerSecond: live / 8))
            bitrateLock.lock()
            bracketDepth -= 1
            lastAdaptiveQP = nil // bracket restored the static ceiling → next live frame re-applies its QP
            bitrateLock.unlock()
        }
        try encode(
            session: session,
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            forceKeyframe: true,
            mode: .live,
        )
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    // MARK: Encode

    /// Encodes a live frame on Session A. `forceKeyframe` sets the IDR frame property
    /// (heartbeat / loss recovery). The pixel buffer is the NV12 `CVPixelBuffer`
    /// handed straight from `WindowCapturer` (zero-copy).
    public func encodeLive(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        forceKeyframe: Bool,
        perFrameMaxQP: Int? = nil,
    ) throws {
        guard let session = liveSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        restorePendingCompactBracket() // restore live config left relaxed by a prior lazy compact IDR
        try encode(
            session: session,
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            forceKeyframe: forceKeyframe,
            mode: .live,
            perFrameMaxQP: perFrameMaxQP,
        )
    }

    /// WF-8: emit a cheap LTR-refresh P-frame against an ACKNOWLEDGED long-term reference — the
    /// low-cost alternative to a recovery IDR (no decoder flush, a fraction of the bytes). Deliberately
    /// NOT wrapped in the crisp/compact bitrate bracket (those force large IDRs); this is a small
    /// normal live encode with `ForceLTRRefresh` set. VT references the acknowledged LTR (or emits an
    /// IDR if none is acknowledged — its own contract, a second safety net under the host's ACKED-ONLY
    /// gate). The actor only calls this when ``LTRController/hasAckedToken`` is true.
    public func encodeLiveLTRRefresh(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        guard let session = liveSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        restorePendingCompactBracket() // restore live config left relaxed by a prior lazy compact IDR
        try encode(
            session: session,
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            forceKeyframe: false,
            mode: .live,
            forceLTRRefresh: true,
        )
    }

    /// MOTION-KEYED CONSTANT QP under const-QP (2026-06-18, Parsec-style scroll). Returns the single QP
    /// to pin BOTH `Min` and `Max` `AllowedFrameQP` to for one live delta frame:
    /// * `floor` on a STATIC frame (`perFrameMaxQP` nil or ≤ floor) ⇒ Min==Max==floor — pure const-QP,
    ///   byte-identical to before this lever; text stays crisp, no VBR clawback.
    /// * `perFrameMaxQP` on MOTION (the capturer's adaptive-QP measurement ramps it above the floor)
    ///   ⇒ Min==Max==that coarser QP, so VT is FORCED to shrink the huge whole-viewport scroll frame
    ///   (~80 KB → ~10-20 KB → drains in a few ms, not ~32 ms = the scroll "nặng").
    ///
    /// Pinning Min==Max (a CONSTANT QP) rather than a `[floor, ceiling]` band is deliberate and was
    /// HW-required: a mere ceiling never bites because the const-QP bitrate backstop (AverageBitRate
    /// ~60 Mbps) leaves VT no budget pressure, so it keeps picking the sharp floor and the scroll frame
    /// stays fat. Forcing the QP takes the choice away from VT's VBR steering entirely — the same
    /// anti-clawback property as pure const-QP, with the constant now keyed to motion (and snapping
    /// back to the floor the instant motion stops, via the capturer's sharp-instant asymmetric EMA).
    /// A `perFrameMaxQP` below the floor is clamped UP (the sharp floor always wins).
    static func constQPForFrame(floor: Int, perFrameMaxQP: Int?) -> Int {
        Swift.max(floor, perFrameMaxQP ?? floor)
    }

    private func encode(
        session: VTCompressionSession,
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        forceKeyframe: Bool,
        mode: Mode,
        forceLTRRefresh: Bool = false,
        perFrameMaxQP: Int? = nil,
    ) throws {
        // ADAPTIVE-QP (AISLOPDESK_ADAPTIVE_QP): apply the per-frame change-driven QP ceiling on the
        // LIVE delta path only, and ONLY when no crisp/compact bracket already owns the QP property
        // (bracketDepth>0). A small change carries a low (sharp) ceiling, a burst carries the higher
        // configured ceiling. Best-effort (the `set` helper tolerates a -12900 reject); no restore —
        // the next live frame sets its own, and a bracket restores the static ceiling when it runs.
        // OWN RATE-CONTROL — CONSTANT-QP (motion-keyed, 2026-06-18): pin Min to the const-QP floor so VT
        // can't blur below the sharp guarantee (no VBR clawback after a post-idle burst); the MAX is the
        // floor on a STATIC frame (Min==Max==floor → constant QP, today's behavior) but rises to the
        // capturer's content-driven `perFrameMaxQP` on MOTION so VT may coarsen the fat scroll frame
        // (``constQPBand``). With adaptive-QP off, `perFrameMaxQP` is nil ⇒ Max==floor ⇒ byte-identical.
        // Brackets own the QP (bracketDepth>0) → skip. Best-effort (`set` tolerates -12900). Setting Min
        // is what forces the sharp floor (Max alone is only a ceiling VT undershoots under budget).
        if Self.constQP != nil {
            bitrateLock.lock()
            // floor = the link-AIMD's current Q (seeded from env, nudged per report). Static ⇒ floor;
            // motion ⇒ a coarser content-driven constant (``constQPForFrame``). Captured under the lock
            // so the DECOUPLE branch below reads a consistent floor.
            let floor = liveConstQP
            let congested = linkCongested
            let q = Self.constQPForFrame(floor: floor, perFrameMaxQP: perFrameMaxQP)
            // Dedup on the applied QP: a static stream holds q == floor ⇒ no per-frame property write
            // (today's hot path). A const-QP nudge clears `lastAdaptiveQP` (setConstQP) so q re-applies.
            let shouldSet = bracketDepth == 0 && lastAdaptiveQP != q
            if shouldSet { lastAdaptiveQP = q }
            bitrateLock.unlock()
            if shouldSet {
                set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, q as CFNumber)
                // DECOUPLE (``qpDecouple``), LOSS-TIER-ADAPTIVE: on a CLEAN link hold Min at the SHARP
                // floor so VT's per-CTU rate-distortion keeps the cheap skip-coded static region (sidebar)
                // crisp while only the moving body coarsens to `q` — a `[floor, q]` band. But when the
                // link is CONGESTED (``linkCongested`` — the ABR cut verdict), re-pin Min==Max==q so the
                // fatter-band scroll frames don't risk burst loss on a stressed WAN (the old giật cliff).
                // The default (decouple off) and the congested case both pin Min==Max==q.
                let minQP = (Self.qpDecouple && !congested) ? floor : q
                set(session, kVTCompressionPropertyKey_MinAllowedFrameQP, minQP as CFNumber)
            }
        } else if let q = perFrameMaxQP {
            bitrateLock.lock()
            // Skip the set when not in a bracket AND the QP is unchanged from the last applied one —
            // avoids a per-frame VTSessionSetProperty + CFNumber bridge on static/typing (QP pinned).
            let shouldSet = bracketDepth == 0 && lastAdaptiveQP != q
            if shouldSet { lastAdaptiveQP = q }
            bitrateLock.unlock()
            if shouldSet {
                set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, q as CFNumber)
            }
        }
        var props: [CFString: Any] = [:]
        if forceKeyframe { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if ltrEnabled {
            // WF-8: request an LTR refresh against an ACKED long-term reference (a cheap P-frame). Form
            // is kCFBooleanTrue — WF-7-probe-proven + the header @abstract, despite the CFNumberRef
            // decl. VT falls back to an IDR if no LTR is acknowledged (its own contract) — a second
            // safety net under the actor's ACKED-ONLY gate.
            if forceLTRRefresh { props[kVTEncodeFrameOptionKey_ForceLTRRefresh] = kCFBooleanTrue }
            // Feed the tokens the client has acknowledged (drained+cleared each encode → can't grow).
            // The [Int64] bridges element-wise to the CFNumberRefs VT expects inside the CFArray.
            let acked = drainPendingAckedTokens()
            if !acked.isEmpty {
                props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acked as CFArray
            }
        }
        // When ltrEnabled is false this is EXACTLY today's dict: [ForceKeyFrame:true] or nil.
        let frameProperties: CFDictionary? = props.isEmpty ? nil : (props as CFDictionary)
        let handler = outputHandler
        let readLTRToken = ltrEnabled
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil,
        ) { status, infoFlags, sampleBuffer in
            guard status == noErr, let sampleBuffer else {
                // A nil sampleBuffer at status==noErr IS a VT frame drop (rate-control budget,
                // .frameDropped flag) — make it visible; silence here cost a whole debug session.
                if Self.dbgDropEnabled {
                    FileHandle.standardError
                        .write(
                            Data(
                                "aislopdesk-videohostd[encoder]: VT DROP status=\(status) frameDropped=\(infoFlags.contains(.frameDropped))\n"
                                    .utf8,
                            ),
                        )
                }
                return
            }
            Self.deliver(
                sampleBuffer: sampleBuffer,
                mode: mode,
                readLTRToken: readLTRToken,
                ackedAnchored: forceLTRRefresh,
                handler: handler,
            )
        }
        guard status == noErr else { throw VideoEncoderError.encodeFailed(status) }
    }

    /// Extracts the AVCC bytes + keyframe flag from a finished `CMSampleBuffer` and
    /// forwards them. The block buffer holds length-prefixed NAL units (the client
    /// re-prefixes when it reassembles fragments — see AislopdeskVideoProtocol.NALUnit).
    private static func deliver(
        sampleBuffer: CMSampleBuffer,
        mode: Mode,
        readLTRToken: Bool,
        ackedAnchored: Bool,
        handler: OutputHandler,
    ) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer,
        ) == noErr,
            let dataPointer else { return }
        var avcc = Data(bytes: dataPointer, count: totalLength)

        // Read the per-frame sample attachments ONCE and pull BOTH the keyframe flag and (when LTR
        // is on) the LTR ack token from the same dictionary — they live on the same attachments
        // object, so a single `CMSampleBufferGetSampleAttachmentsArray` + bridge per frame suffices.
        // Keyframe? Absence of the not-sync attachment ⇒ keyframe (default true, unchanged).
        // WF-8: `ltrToken` (an Int64) is read only when `readLTRToken` (the instance `ltrEnabled`);
        // with LTR off it stays nil ⇒ the handler call is byte-identical to today.
        var keyframe = true
        var ltrToken: Int64?
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false,
        ) as? [[CFString: Any]],
            let first = attachments.first
        {
            if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
                keyframe = !notSync
            }
            if readLTRToken {
                ltrToken = first[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? Int64
            }
        }

        // CRITICAL: VTCompressionSession keeps the HEVC VPS/SPS/PPS parameter sets in the sample
        // buffer's FORMAT DESCRIPTION, NOT inline in the CMBlockBuffer — so the bytes above are
        // the coded slice ONLY. The client builds its CMVideoFormatDescription from parameter
        // sets it expects to find INLINE ahead of the IDR slice (HEVCParameterSets.extract); with
        // none present it can never decode (`awaitingKeyframe`) and the window stays blank. So on
        // a keyframe we prepend the VPS/SPS/PPS (length-prefixed, same 4-byte AVCC framing) pulled
        // from the format description. (Found via check-video.sh's client decode diagnostics,
        // 2026-06-02 — the prior "host emits parameter sets inline" assumption was wrong.)
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
           let params = hevcParameterSetsAVCC(from: fmt)
        {
            avcc = params + avcc
        }
        handler(avcc, keyframe, mode, ltrToken, ackedAnchored)
    }

    /// Extracts the HEVC VPS/SPS/PPS parameter sets from a `CMVideoFormatDescription` and returns
    /// them as length-prefixed (4-byte big-endian) AVCC NAL units, in index order — ready to
    /// prepend to a keyframe's coded slice so the client can build its decode format description.
    /// Returns `nil` if the description carries no parameter sets.
    private static func hevcParameterSetsAVCC(from formatDescription: CMFormatDescription) -> Data? {
        var count = 0
        let probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil,
        )
        guard probe == noErr, count > 0 else { return nil }

        var out = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil,
            )
            guard status == noErr, let pointer, size > 0 else { return nil }
            var lengthBE = UInt32(size).bigEndian
            withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) } // 4-byte AVCC length
            out.append(UnsafeBufferPointer(start: pointer, count: size))
        }
        return out
    }

    /// Re-creates both sessions on a window resize (doc 18 §G — recreate on resize).
    /// The caller passes the new dimensions by constructing a fresh `VideoEncoder`.

    /// Drains BOTH compression sessions, blocking until every in-flight frame's output
    /// callback has fired (`VTCompressionSessionCompleteFrames` with an INVALID timestamp = the
    /// documented "complete ALL pending frames" sentinel). Call this before dropping the OLD
    /// encoder on a resize swap: without it the encoder is invalidated (by `deinit`) while frames
    /// are still queued, silently dropping their already-encoded output (FFmpeg videotoolboxenc
    /// CompleteFrames-before-invalidate pattern). Purely ADDITIVE — does NOT touch the hot
    /// `encodeLive` path. Safe to call once; the sessions are not reused afterward.
    public func completeFrames() {
        if let liveSession { VTCompressionSessionCompleteFrames(liveSession, untilPresentationTimeStamp: .invalid) }
    }

    /// Sets a LATENCY-CRITICAL property and THROWS ``VideoEncoderError/propertyFailed(key:status:)``
    /// if it does not apply. Used for the proven low-latency rate-control keys
    /// (RealTime, AllowFrameReordering, AverageBitRate, DataRateLimits) where a silent
    /// failure corrupts the measured config (doc 18 §E). The encoder must NOT proceed with a
    /// half-applied low-latency config. (SpatialAdaptiveQPLevel is deliberately NOT here — it
    /// is best-effort; some HEVC encoders return -12900 for it and aborting would yield zero
    /// frames.)
    private func setCritical(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            log.error("critical VTSessionSetProperty \(key as String) failed: \(status)")
            throw VideoEncoderError.propertyFailed(key: key as String, status: status)
        }
    }

    /// Sets a best-effort property: a failure degrades quality, not the latency
    /// contract, so it is logged and tolerated (e.g. ExpectedFrameRate). Returns the
    /// status for callers that care.
    @discardableResult
    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) -> OSStatus {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            log.error("VTSessionSetProperty \(key as String) failed (best-effort, tolerated): \(status)")
        }
        return status
    }
}
#endif
