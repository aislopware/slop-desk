import CSlopDeskFFI
import Foundation

/// Client→host loss-recovery / acknowledgement messages (doc 17 §3.6).
///
/// Recovery prefers an **LTR refresh** over a forced IDR to dodge a keyframe's
/// bandwidth/latency spike: the client sends an RFI (reference-frame-invalidate)
/// range naming the frames it missed; the host marks that long-term-reference frame
/// invalid and encodes the next frame against an older, still-valid LTR
/// (`kVTCompressionPropertyKey_EnableLTR` + `ForceLTRRefresh`). No usable frame within
/// ~2 RTT ⇒ escalate to a forced-IDR request. Invalidation direction is **client→host**
/// (doc 17 §3.6). Models the messages only; the LTR encode wiring lives in
/// `slopdesk-videohostd`'s `encode::Encoder`.
///
/// A client→host **NetworkStats** report rides this same `.recovery` channel. Fixed-width,
/// all-`UInt32`: a malformed/truncated report throws on decode → the router drops the one
/// datagram → no crash on hostile stats. All eleven fields are RELATIVE (windowed counters /
/// host-stamp echo / client-local deltas / detector output / depth gauge), so the host derives
/// RTT in its own clock free of clock skew.
public struct NetworkStatsReport: Equatable, Sendable {
    /// Complete frames the client received in this report window.
    public var framesReceived: UInt32
    /// Of those, how many completed via FEC recovery (parity filled a data hole).
    public var fecRecovered: UInt32
    /// Frames the client declared unrecoverably lost in this window (the loss numerator).
    public var unrecovered: UInt32
    /// The newest `hostSendTsMillis` the client has OBSERVED on a video fragment (0 = none /
    /// telemetry off). The host echoes it against its own clock to compute RTT.
    public var latestHostSendTs: UInt32
    /// Client-LOCAL elapsed ms since it observed `latestHostSendTs` (a relative delta in the
    /// client's own monotonic clock — NEVER an absolute client timestamp). The host subtracts it
    /// from `(hostNow − latestHostSendTs)` so the client-side processing hold is removed from RTT.
    public var clientHoldMs: UInt32
    /// Inter-arrival jitter (microseconds) from the client's OWN clock, RFC3550 2nd-difference form
    /// (relative deltas only) — fully clock-skew-immune.
    public var owdJitterMicros: UInt32
    /// Delay-gradient signal: the client trendline detector's `modifiedTrend` ×1000, clamped ±1e9,
    /// as an `Int32` bit-pattern (see ``owdTrendModifiedMilliSigned``). 0 when disabled
    /// (`SLOPDESK_TREND=0`) or not yet warmed up. Like the jitter field, computed PURELY from
    /// client-clock + host-stamp deltas — skew-immune.
    public var owdTrendMilli: UInt32
    /// Delay-gradient detector flags — bits 0-1 = state (0 normal / 1 overusing / 2 underusing),
    /// bits 8-15 = `min(numDeltas, 255)` (sample-count context for host logs). 0 = inert.
    public var owdTrendFlags: UInt32
    /// Adaptive-pacer signal: windowed count of presents that ENDED a dense-flow late gap (the clean
    /// client-side hitch signal). The host only logs it.
    public var pacerLateFrames: UInt32
    /// Windowed count of late-gap EPISODES OPENED (counted at the first re-show past the late
    /// threshold). A SUPERSET of ``pacerLateFrames`` — includes motion-stop boundaries.
    public var pacerPresentGaps: UInt32
    /// Gauge: the client pacer's live presentation depth (0 = no pacer attached).
    public var pacerDepth: UInt32

    public init(
        framesReceived: UInt32,
        fecRecovered: UInt32,
        unrecovered: UInt32,
        latestHostSendTs: UInt32,
        clientHoldMs: UInt32,
        owdJitterMicros: UInt32,
        owdTrendMilli: UInt32 = 0,
        owdTrendFlags: UInt32 = 0,
        pacerLateFrames: UInt32 = 0,
        pacerPresentGaps: UInt32 = 0,
        pacerDepth: UInt32 = 0,
    ) {
        self.framesReceived = framesReceived
        self.fecRecovered = fecRecovered
        self.unrecovered = unrecovered
        self.latestHostSendTs = latestHostSendTs
        self.clientHoldMs = clientHoldMs
        self.owdJitterMicros = owdJitterMicros
        self.owdTrendMilli = owdTrendMilli
        self.owdTrendFlags = owdTrendFlags
        self.pacerLateFrames = pacerLateFrames
        self.pacerPresentGaps = pacerPresentGaps
        self.pacerDepth = pacerDepth
    }

    /// Detector state from bits 0-1 of ``owdTrendFlags`` (0 normal / 1 overusing / 2 underusing).
    public var owdTrendStateRaw: UInt8 { UInt8(truncatingIfNeeded: owdTrendFlags) & 0x3 }
    /// Detector sample count from bits 8-15 of ``owdTrendFlags`` (saturated at 255).
    public var owdTrendDeltas: Int { Int((owdTrendFlags >> 8) & 0xFF) }
    /// ``owdTrendMilli`` reinterpreted as the signed milli-trend it carries.
    public var owdTrendModifiedMilliSigned: Int32 { Int32(bitPattern: owdTrendMilli) }
}

public enum RecoveryMessage: Equatable, Sendable {
    /// Acknowledge the highest contiguous `streamSeq` durably received, bounding the
    /// host's retransmit / LTR-pin window.
    ///
    /// Doubles as the LTR ack: sent after a SUCCESSFUL decode of an LTR-flagged frame
    /// (``FrameFragmentHeader/Flags/isLTR``), carrying that frame's `frameID` in the `streamSeq`
    /// field — the field name is a misnomer in that arm, the host feeds the value to
    /// `slopdesk_video::ltr::LtrController::ack_frame`, NOT to a streamSeq. Tells the host the
    /// client holds
    /// that long-term reference and may `ForceLTRRefresh` against it.
    case ack(streamSeq: UInt32)

    /// Request-for-invalidate: the client lost frames `[fromFrameID, toFrameID]`
    /// (inclusive) and asks the host to refresh from an earlier LTR, not a full IDR.
    ///
    /// DELIVERY-KEYED COOLDOWN: carries `lastDecodedFrameID` — the
    /// client's wrap-aware highest SUCCESSFULLY-DECODED frameID (``noFrameDecodedSentinel`` when
    /// none yet) — so the host's `RecoveryIDRPolicy` can tell a recently-sent keyframe that was
    /// delivered (request newer than it) from one that's a casualty (request older + past the
    /// in-flight grace ⇒ bypass the cooldown immediately).
    case requestLTRRefresh(fromFrameID: UInt32, toFrameID: UInt32, lastDecodedFrameID: UInt32)

    /// Escalation after the ~2-RTT LTR-refresh timeout elapsed without a decodable
    /// frame: demand a forced IDR keyframe. Carries the client's `lastDecodedFrameID`
    /// (see ``requestLTRRefresh(fromFrameID:toFrameID:lastDecodedFrameID:)``) so the
    /// host can key its recovery-IDR cooldown on DELIVERY instead of send-time.
    case requestIDR(lastDecodedFrameID: UInt32)

    /// Re-request a cursor SHAPE bitmap the client is missing (doc 17 §3.3 self-heal). A shape
    /// ships over the cursor socket ONCE per `shapeID`; a lost (or over-MTU, IP-fragment-lost)
    /// shape datagram would otherwise leave the overlay permanently wrong/invisible for the whole
    /// session (the host strips the real cursor). When a cursor POSITION update references a
    /// `shapeID` not in the client cache, the client sends this on the EXISTING recovery channel
    /// (mirroring ``requestIDR``) and the host re-emits the bitmap. The cache re-insert is idempotent.
    case requestCursorShape(shapeID: UInt16)

    /// Periodic client→host network-feedback telemetry. Carries a ``NetworkStatsReport`` (windowed
    /// loss/FEC counters + newest observed host-send-ts echo + client-local hold + inter-arrival
    /// jitter) so the host maintains+logs a clock-skew-free RTT/loss/jitter estimate. Telemetry
    /// only — it does not change stream behaviour.
    case networkStats(NetworkStatsReport)

    /// NACK / selective ARQ: the client is missing specific DATA fragments of `frameID` and asks the
    /// host to retransmit exactly those (from its send-history ring) instead of a full recovery-IDR.
    /// With the client's playout buffer ≫ RTT the retransmit lands before playout → no stutter.
    /// Variable-length but SELF-DELIMITING (a count precedes the indices) so the trailing-bytes
    /// rejection still holds. Capped at ``maxNackFragments`` (a larger loss escalates to LTR / IDR).
    case requestFragments(frameID: UInt32, fragIndices: [UInt16])

    /// Wire sentinel for "the client has not decoded any frame yet" in the
    /// `lastDecodedFrameID` field of ``requestIDR(lastDecodedFrameID:)`` /
    /// ``requestLTRRefresh(fromFrameID:toFrameID:lastDecodedFrameID:)``. Cannot collide
    /// with a real id at session start: `FramePacketizer` ids begin at 0, so 0xFFFF_FFFF
    /// is ~2³² frames (≈2.3 years at 60 fps) away across the wrap.
    public static let noFrameDecodedSentinel = slopdesk_recovery_constant(0)

    /// Max fragment indices a single ``requestFragments(frameID:fragIndices:)`` NACK may carry;
    /// a larger loss escalates to an LTR refresh / IDR rather than a big selective retransmit.
    public static let maxNackFragments = Int(slopdesk_recovery_constant(1))

    /// On-wire message-type byte.
    public var messageType: UInt8 {
        switch self {
        case .ack: 1
        case .requestLTRRefresh: 2
        case .requestIDR: 3
        case .requestCursorShape: 4
        case .networkStats: 5
        case .requestFragments: 6
        }
    }

    /// Serialises the message: `[UInt8 type][body...]`, byte-identical to the wire pinned by the
    /// golden vectors + the round-trip tests. The layout is `rust/slopdesk-video`'s; this method
    /// flattens the case into the shape the boundary reads and copies the answer back.
    public func encode() -> Data {
        var flat = SlopDeskRecoveryMessage()
        flat.message_type = messageType
        var frags: [UInt16] = []
        switch self {
        case let .ack(streamSeq):
            flat.stream_seq = streamSeq
        case let .requestLTRRefresh(fromFrameID, toFrameID, lastDecodedFrameID):
            flat.from_frame_id = fromFrameID
            flat.to_frame_id = toFrameID
            flat.last_decoded_frame_id = lastDecodedFrameID
        case let .requestIDR(lastDecodedFrameID):
            flat.last_decoded_frame_id = lastDecodedFrameID
        case let .requestCursorShape(shapeID):
            flat.shape_id = shapeID
        case let .networkStats(r):
            flat.frames_received = r.framesReceived
            flat.fec_recovered = r.fecRecovered
            flat.unrecovered = r.unrecovered
            flat.latest_host_send_ts = r.latestHostSendTs
            flat.client_hold_ms = r.clientHoldMs
            flat.owd_jitter_micros = r.owdJitterMicros
            flat.owd_trend_milli = r.owdTrendMilli
            flat.owd_trend_flags = r.owdTrendFlags
            flat.pacer_late_frames = r.pacerLateFrames
            flat.pacer_present_gaps = r.pacerPresentGaps
            flat.pacer_depth = r.pacerDepth
        case let .requestFragments(frameID, fragIndices):
            // The cap is the codec's; truncating here is the defensive backstop, never the live
            // path — the caller bounds the list before it ever gets here.
            frags = Array(fragIndices.prefix(Self.maxNackFragments))
            flat.frame_id = frameID
            flat.frag_count = UInt16(frags.count)
        }
        let needed = frags.withUnsafeBufferPointer { indices in
            slopdesk_recovery_encode(&flat, indices.baseAddress, nil, 0)
        }
        guard needed > 0 else { return Data() }
        var written = 0
        let bytes = [UInt8](unsafeUninitializedCapacity: needed) { out, count in
            written = frags.withUnsafeBufferPointer { indices in
                slopdesk_recovery_encode(&flat, indices.baseAddress, out.baseAddress, out.count)
            }
            count = Swift.min(written, out.count)
        }
        return written == needed ? Data(bytes) : Data()
    }

    /// Parses a recovery message. Throws ``VideoProtocolError`` on unknown type, short body, or
    /// TRAILING bytes. The trailing-bytes rejection is load-bearing: the client always emits
    /// exact-width datagrams and the host's `RecoveryRequestDeduper` keys on the RAW datagram
    /// bytes — a decoder tolerating suffixes would let suffix-varied copies of one logical request
    /// each decode identically yet bypass the byte-keyed dedup (re-triggering a second
    /// ForceLTRRefresh/IDR). No backcompat is owed here: both ends redeploy together, so a body
    /// missing a field is simply hostile input.
    ///
    /// Every guard is `rust/slopdesk-video`'s. The NACK indices come back in one pass: the codec
    /// caps them, so a buffer that size can never be told to ask again.
    public static func decode(_ data: Data) throws -> Self {
        try withUnsafeTemporaryAllocation(of: UInt16.self, capacity: maxNackFragments) { indices in
            try decode(data, into: indices)
        }
    }

    /// The decode proper, given somewhere to put the NACK indices.
    ///
    /// Split out only so the scratch buffer can be the stack: every arm but ``requestFragments``
    /// leaves it untouched, and that one reads exactly the prefix the codec says it wrote.
    private static func decode(
        _ data: Data, into indices: UnsafeMutableBufferPointer<UInt16>,
    ) throws -> Self {
        var flat = SlopDeskRecoveryMessage()
        let verdict = data.withUnsafeBytes { bytes in
            slopdesk_recovery_decode(
                bytes.baseAddress, bytes.count, &flat, indices.baseAddress, indices.count,
            )
        }
        switch verdict {
        case UInt32(SLOPDESK_RECOVERY_DECODE_TRUNCATED): throw VideoProtocolError.truncated
        case UInt32(SLOPDESK_RECOVERY_DECODE_MALFORMED):
            // The reason stays on the other side: nothing branches on it, and the datagram is being
            // dropped either way.
            throw VideoProtocolError.malformed("unacceptable recovery message")
        default: break
        }
        switch flat.message_type {
        case 1: return .ack(streamSeq: flat.stream_seq)
        case 2: return .requestLTRRefresh(
                fromFrameID: flat.from_frame_id, toFrameID: flat.to_frame_id,
                lastDecodedFrameID: flat.last_decoded_frame_id,
            )
        case 3: return .requestIDR(lastDecodedFrameID: flat.last_decoded_frame_id)
        case 4: return .requestCursorShape(shapeID: flat.shape_id)
        case 5: return .networkStats(NetworkStatsReport(
                framesReceived: flat.frames_received, fecRecovered: flat.fec_recovered,
                unrecovered: flat.unrecovered, latestHostSendTs: flat.latest_host_send_ts,
                clientHoldMs: flat.client_hold_ms, owdJitterMicros: flat.owd_jitter_micros,
                owdTrendMilli: flat.owd_trend_milli, owdTrendFlags: flat.owd_trend_flags,
                pacerLateFrames: flat.pacer_late_frames, pacerPresentGaps: flat.pacer_present_gaps,
                pacerDepth: flat.pacer_depth,
            ))
        case 6: return .requestFragments(
                frameID: flat.frame_id,
                fragIndices: Array(
                    UnsafeBufferPointer(start: indices.baseAddress, count: Int(flat.frag_count)),
                ),
            )
        default:
            // Unreachable: the boundary refuses a type no arm answers to before it gets here.
            throw VideoProtocolError.malformed("unknown recovery message type \(flat.message_type)")
        }
    }
}

/// Models the client-side recovery policy: which message to send for a detected
/// loss, and when to escalate to a forced IDR. Pure decision logic — the timer /
/// transport lives in `SlopDeskVideoClient`.
public struct RecoveryPolicy: Sendable {
    /// Escalate to IDR if no decodable frame arrives within this multiple of the
    /// measured RTT (doc 17 §3.6: "fallback IDR after timeout 2-RTT").
    public let idrTimeoutRTTMultiple: Double
    /// The HALVED escalation multiple used while the client is OBSERVING LOSS
    /// (``LossObservationWindow``). Once requests go out redundantly, the 2·RTT wait becomes the
    /// dominant residual freeze term — a lossy path has already shown that waiting longer rarely
    /// saves the IDR.
    public let lossyIdrTimeoutRTTMultiple: Double
    /// Floor on the LOSSY deadline, 60 ms. An LTR-refresh response PHYSICALLY needs host encode +
    /// flight + client decode ≈ 40-60 ms at the live path's 10-30 ms RTT, so a lower floor lets the
    /// client escalate to `requestIDR` BEFORE the LTR medicine can land — a 30 ms floor measures
    /// 202 requestIDR vs 100 LTR refreshes in 169 s (a 97-suppression storm). Effective floor
    /// `max(lossyEscalationFloor, lossyEscalationFloorRTTMultiple × rtt)` tracks the path: 60 ms at
    /// low RTT, 1.5·RTT once RTT dominates. `SLOPDESK_ESCALATION_FLOOR_MS` (default 60, clamp
    /// 20...500) tunes the constant part. The NORMAL (non-lossy) path has NO floor.
    public let lossyEscalationFloor: TimeInterval
    /// The RTT-proportional part of the lossy floor (see ``lossyEscalationFloor``): a refresh
    /// round-trip is ≥1·RTT, plus encode/decode/frame-interval overhead ≈ half an RTT on the
    /// target path — escalating earlier than ~1.5·RTT can only duplicate work.
    public let lossyEscalationFloorRTTMultiple: Double

    /// Pure env resolution for the lossy floor: `SLOPDESK_ESCALATION_FLOOR_MS`, default 60 ms,
    /// clamped to 20...500 ms; absent/garbage/out-of-band values keep the default.
    public static func escalationFloorSeconds(env: [String: String]) -> TimeInterval {
        let raw = Array((env["SLOPDESK_ESCALATION_FLOOR_MS"] ?? "").utf8)
        return raw.withUnsafeBufferPointer {
            slopdesk_recovery_escalation_floor_seconds($0.baseAddress, $0.count)
        }
    }

    /// The process-wide resolved default floor (read once, like the host's env-static flags).
    public static let defaultLossyEscalationFloor: TimeInterval =
        escalationFloorSeconds(env: ProcessInfo.processInfo.environment)

    public init(
        idrTimeoutRTTMultiple: Double = 2.0,
        lossyIdrTimeoutRTTMultiple: Double = 1.0,
        lossyEscalationFloor: TimeInterval = Self.defaultLossyEscalationFloor,
        lossyEscalationFloorRTTMultiple: Double = 1.5,
    ) {
        self.idrTimeoutRTTMultiple = idrTimeoutRTTMultiple
        self.lossyIdrTimeoutRTTMultiple = lossyIdrTimeoutRTTMultiple
        self.lossyEscalationFloor = lossyEscalationFloor
        self.lossyEscalationFloorRTTMultiple = lossyEscalationFloorRTTMultiple
    }

    /// The first message to send when frames `[from, to]` are detected lost: prefer
    /// an LTR refresh. `lastDecoded` is the client's decode frontier (wire value —
    /// ``RecoveryMessage/noFrameDecodedSentinel`` when nothing decoded yet), passed
    /// through so the host's delivery-keyed recovery-IDR cooldown has the context.
    public func initialRequest(lostFrom: UInt32, lostTo: UInt32, lastDecoded: UInt32) -> RecoveryMessage {
        .requestLTRRefresh(fromFrameID: lostFrom, toFrameID: lostTo, lastDecodedFrameID: lastDecoded)
    }

    /// Whether to escalate to a forced IDR given elapsed-since-request and the RTT estimate.
    /// Convenience 2-arg shape for callers with no loss context — `observingLoss: false`.
    public func shouldEscalateToIDR(elapsedSinceRequest: TimeInterval, rtt: TimeInterval) -> Bool {
        shouldEscalateToIDR(elapsedSinceRequest: elapsedSinceRequest, rtt: rtt, observingLoss: false)
    }

    /// The loss-adaptive escalation clock. `observingLoss == false` ⇒ the plain `2·RTT`, no floor.
    /// `observingLoss == true` ⇒ the halved clock floored at the physically-arrivable
    /// response time:
    /// `max(lossyIdrTimeoutRTTMultiple·RTT, lossyEscalationFloor, lossyEscalationFloorRTTMultiple·RTT)`
    /// — defaults `max(1·RTT, 60 ms, 1.5·RTT)`. The halving (1× vs 2×) stays ABOVE the floor; the
    /// floor just guarantees an LTR refresh gets the time it physically needs before the IDR
    /// sledgehammer.
    public func shouldEscalateToIDR(elapsedSinceRequest: TimeInterval, rtt: TimeInterval, observingLoss: Bool) -> Bool {
        slopdesk_recovery_should_escalate_to_idr(
            idrTimeoutRTTMultiple, lossyIdrTimeoutRTTMultiple, lossyEscalationFloor,
            lossyEscalationFloorRTTMultiple, elapsedSinceRequest, rtt, observingLoss,
        )
    }
}

/// How many byte-identical copies of one logical recovery request (`requestLTRRefresh` /
/// `requestIDR`) the client sends, and their spacing.
///
/// WHY redundancy: the recovery REQUEST is a single ≤17-byte datagram riding the same lossy path
/// it reports on (measured bursts 3-9%). A lost request costs the full escalation wait (~2·RTT ≈
/// 100 ms at the bootstrap EWMA) of extra frozen frame — the ranked hitch tail.
///
/// WHY 3 ms of spacing (not back-to-back like the input path's `redundantUpCount`): measured losses
/// are BURSTY (up to ~15 adjacent wire datagrams — the interleaver's own memory), so spacing
/// decorrelates the copies' fate; at recovery time the send lane is mostly idle so wire adjacency
/// is otherwise likely. COUPLING INVARIANT (vs the host dedup window, default 25 ms): the total
/// spread (copies−1)·spacing must stay ≤ HALF the window for every legal copies count — 6 ms at
/// the default 3 copies, 12 ms at the max 5 vs 12.5 — so a late copy can never age past the
/// window (duplicates do NOT refresh its timestamp) and re-admit as a second host action
/// (double-ForceLTRRefresh). A 5 ms spacing breaks that invariant — it stretches the max spread to
/// 20 ms at copies=5, a margin thin enough for a delayed copy to re-admit. Pinned by
/// `testRedundancySpreadVsDedupWindowCouplingAtDefaults`.
public struct RecoveryRequestRedundancy: Sendable, Equatable {
    /// Total sends per logical request, clamped to 1...5. 1 = no redundancy (a single send).
    public let copies: Int
    /// Gap between consecutive copies (seconds).
    public let spacing: TimeInterval

    public init(copies: Int = 3, spacing: TimeInterval = 0.003) {
        self.copies = slopdesk_recovery_clamped_copies(max(0, copies))
        self.spacing = spacing
    }

    /// Send-time offsets for one logical request: `[0, spacing, 2·spacing, ...]`.
    public var sendOffsets: [TimeInterval] {
        let needed = slopdesk_recovery_send_offsets(copies, spacing, nil, 0)
        var written = 0
        let offsets = [TimeInterval](unsafeUninitializedCapacity: needed) { out, count in
            written = slopdesk_recovery_send_offsets(copies, spacing, out.baseAddress, out.count)
            count = Swift.min(written, out.count)
        }
        return written == needed ? offsets : []
    }

    /// P(all copies lost) under i.i.d. per-datagram loss `p`: `clamp01(p)^copies`.
    public static func allCopiesLostProbability(perDatagramLoss: Double, copies: Int) -> Double {
        slopdesk_recovery_all_copies_lost_probability(perDatagramLoss, max(0, copies))
    }

    /// Expected freeze added by REQUEST loss per loss event: P(all copies lost) × the escalation
    /// delay the client then sits through — the freeze-time math as a testable function.
    public static func expectedRequestLossFreeze(
        perDatagramLoss: Double,
        copies: Int,
        escalationDelay: TimeInterval,
    ) -> TimeInterval {
        slopdesk_recovery_expected_request_loss_freeze(perDatagramLoss, max(0, copies), escalationDelay)
    }
}

/// The client-side LOSS-OBSERVING predicate gating the halved escalation clock
/// (``RecoveryPolicy/shouldEscalateToIDR(elapsedSinceRequest:rtt:observingLoss:)``).
///
/// Fed from data the client already has: (i) every UNRECOVERABLE loss, and (ii) every
/// FEC-RECOVERED frame completion (the early-warning channel — the measured 10 s bursts produce
/// multiple FEC recoveries per second BEFORE the first unrecoverable frame, so the FIRST
/// frozen-frame episode already runs the halved clock). Defaults {1.0 s, ≥2} keep a lone baseline
/// ~1% loss (1 event) on the conservative 2·RTT clock.
public struct LossObservationWindow: Sendable, Equatable {
    private let windowSeconds: TimeInterval
    private let minEvents: Int
    private let capacity: Int
    /// Ring of event timestamps (seconds, caller's monotonic clock), newest last.
    private var events: [TimeInterval] = []

    public init(windowSeconds: TimeInterval = 1.0, minEvents: Int = 2, capacity: Int = 8) {
        // Both floors are the boundary's — it reads these on every call and would apply them
        // again, and a clamp written on both sides is the drift this port exists to remove.
        self.windowSeconds = windowSeconds
        self.minEvents = minEvents
        self.capacity = capacity
    }

    /// Records one loss-ish event (unrecoverable loss or FEC recovery) at `now`. Prunes events
    /// older than the window; drop-oldest at capacity (bounded regardless of feed rate).
    ///
    /// The ring is data and stays here; only the pruning law is `rust/slopdesk-video`'s. It is
    /// handed over as ONE buffer the boundary rewrites in place — the answer is never longer than
    /// the argument plus the event being recorded, so the spare slot appended here is all the room
    /// it can need, and a window at its steady size stops allocating entirely.
    public mutating func noteEvent(now: TimeInterval) {
        let held = events.count
        events.append(now)
        let live = events.withUnsafeMutableBufferPointer { ring in
            slopdesk_recovery_loss_window_note(
                windowSeconds, capacity, ring.baseAddress, held, now, ring.count,
            )
        }
        events.removeLast(events.count - Swift.min(live, events.count))
    }

    /// Whether ≥ `minEvents` events lie within `windowSeconds` of `now`. Pure read (no prune):
    /// stale entries simply fail the recency test.
    public func isObservingLoss(now: TimeInterval) -> Bool {
        events.withUnsafeBufferPointer { held in
            slopdesk_recovery_loss_window_observing(
                windowSeconds, minEvents, held.baseAddress, held.count, now,
            )
        }
    }
}
