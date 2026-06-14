import Foundation

/// Client→host loss-recovery / acknowledgement messages (doc 17 §3.6).
///
/// Recovery prefers an **LTR refresh** over a forced IDR to avoid the bandwidth /
/// latency spike of a keyframe: the client sends an RFI (reference-frame-invalidate)
/// range naming the frames it failed to receive; the host marks the referenced
/// long-term-reference frame invalid and encodes the next frame against an older,
/// still-valid LTR (`kVTCompressionPropertyKey_EnableLTR` + `ForceLTRRefresh`). If
/// the client gets no usable frame within ~2 RTT it escalates to a forced-IDR
/// request. The invalidation direction is **client→host** (doc 17 §3.6 correction).
///
/// This type models the messages only; the LTR encode wiring lives in
/// `AislopdeskVideoHost.VideoEncoder`.
///
/// A client→host **NetworkStats** report (the network-feedback telemetry channel) rides this same
/// `.recovery` channel. It is a fixed-width, all-`UInt32` body, so a malformed/truncated report
/// throws on decode → the router drops the single datagram → the host never crashes on hostile
/// stats input. All eleven fields are RELATIVE (windowed counters / a host-stamp echo / client-local
/// deltas / client-computed detector output / a depth gauge), so the host can derive RTT in its own
/// clock without any cross-machine clock skew.
public struct NetworkStatsReport: Equatable, Sendable {
    /// Complete frames the client received in this report window.
    public var framesReceived: UInt32
    /// Of those, how many were completed via FEC recovery (a data hole the parity filled).
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
    /// Component 3 (delay-gradient, 2026-06-11): the client trendline detector's `modifiedTrend`
    /// ×1000, clamped ±1e9, carried as an `Int32` bit-pattern (see ``owdTrendModifiedMilliSigned``).
    /// 0 when the trendline is disabled (`AISLOPDESK_TREND=0`) or has not warmed up. Like the jitter
    /// field, it is computed PURELY from client-clock deltas + host-stamp deltas — skew-immune.
    public var owdTrendMilli: UInt32
    /// Component 3: detector flags — bits 0-1 = state (0 normal / 1 overusing / 2 underusing),
    /// bits 8-15 = `min(numDeltas, 255)` (sample-count context for host logs). 0 = inert.
    public var owdTrendFlags: UInt32
    /// Component 4 (adaptive pacer depth, 2026-06-11): windowed count of presents that ENDED a
    /// dense-flow late gap (the clean client-side hitch signal). Phase-0: host LOGS only.
    public var pacerLateFrames: UInt32
    /// Component 4: windowed count of late-gap EPISODES OPENED (counted at the first re-show past
    /// the late threshold). A SUPERSET of ``pacerLateFrames`` — includes motion-stop boundaries.
    public var pacerPresentGaps: UInt32
    /// Component 4: gauge — the client pacer's live presentation depth (0 = no pacer attached).
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
    /// Acknowledge the highest contiguous `streamSeq` durably received. Lets the
    /// host bound its retransmit / LTR-pin window.
    ///
    /// WF-8 REUSE (single-user repo, no backcompat): the client now sends this after a SUCCESSFUL
    /// decode of an LTR-flagged frame (``FrameFragmentHeader/Flags/isLTR``), carrying that frame's
    /// `frameID` in the `streamSeq` field (the field name is historical — the host's `.ack` arm feeds
    /// it to ``LTRController/ackFrame(frameID:)``, NOT as a streamSeq). This is the ACKED-ONLY signal:
    /// the host learns the client holds that long-term reference and may `ForceLTRRefresh` against it.
    case ack(streamSeq: UInt32)

    /// Request-for-invalidate: the client lost the frames in `[fromFrameID,
    /// toFrameID]` (inclusive) and asks the host to refresh from an earlier LTR
    /// rather than send a full IDR.
    ///
    /// DELIVERY-KEYED COOLDOWN (component 2, 2026-06-11): carries `lastDecodedFrameID`
    /// — the client's wrap-aware highest SUCCESSFULLY-DECODED frameID
    /// (``noFrameDecodedSentinel`` when nothing decoded yet) — so the host's
    /// `RecoveryIDRPolicy` can prove whether a recently-sent keyframe was delivered
    /// (request newer than it ⇒ delivered) or is a casualty (request older + past the
    /// in-flight grace ⇒ bypass the cooldown immediately).
    case requestLTRRefresh(fromFrameID: UInt32, toFrameID: UInt32, lastDecodedFrameID: UInt32)

    /// Escalation after the ~2-RTT LTR-refresh timeout elapsed without a decodable
    /// frame: demand a forced IDR keyframe. Carries the client's `lastDecodedFrameID`
    /// (see ``requestLTRRefresh(fromFrameID:toFrameID:lastDecodedFrameID:)``) so the
    /// host can key its recovery-IDR cooldown on DELIVERY instead of send-time.
    case requestIDR(lastDecodedFrameID: UInt32)

    /// Re-request a cursor SHAPE bitmap the client is missing (doc 17 §3.3 self-heal). A
    /// cursor shape is shipped over the cursor socket ONCE per `shapeID`; a lost (or
    /// over-MTU, IP-fragment-lost) shape datagram would otherwise leave the overlay
    /// permanently wrong/invisible for the whole session (the host strips the real cursor).
    /// When a cursor POSITION update references a `shapeID` not in the client cache, the
    /// client sends this on the EXISTING recovery channel (mirroring ``requestIDR``) and the
    /// host re-emits that shape's bitmap. The cache re-insert is idempotent.
    case requestCursorShape(shapeID: UInt16)

    /// Periodic client→host network-feedback telemetry (the network-feedback channel). Carries a
    /// ``NetworkStatsReport`` (windowed loss/FEC counters + the newest observed host-send-ts echo +
    /// the client-local hold + inter-arrival jitter) so the host can MAINTAIN+LOG a clock-skew-free
    /// RTT/loss/jitter estimate. Telemetry only — it does not change stream behaviour this phase.
    case networkStats(NetworkStatsReport)

    /// Wire sentinel for "the client has not decoded any frame yet" in the
    /// `lastDecodedFrameID` field of ``requestIDR(lastDecodedFrameID:)`` /
    /// ``requestLTRRefresh(fromFrameID:toFrameID:lastDecodedFrameID:)``. Cannot collide
    /// with a real id at session start: `FramePacketizer` ids begin at 0, so 0xFFFF_FFFF
    /// is ~2³² frames (≈2.3 years at 60 fps) away across the wrap.
    public static let noFrameDecodedSentinel: UInt32 = 0xFFFF_FFFF

    /// On-wire message-type byte.
    public var messageType: UInt8 {
        switch self {
        case .ack: 1
        case .requestLTRRefresh: 2
        case .requestIDR: 3
        case .requestCursorShape: 4
        case .networkStats: 5
        }
    }

    /// Serialises the message: `[UInt8 type][body...]`.
    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case let .ack(streamSeq):
            out.appendBE(streamSeq)
        case let .requestLTRRefresh(fromFrameID, toFrameID, lastDecodedFrameID):
            out.appendBE(fromFrameID)
            out.appendBE(toFrameID)
            out.appendBE(lastDecodedFrameID)
        case let .requestIDR(lastDecodedFrameID):
            out.appendBE(lastDecodedFrameID)
        case let .requestCursorShape(shapeID):
            out.appendBE(shapeID)
        case let .networkStats(r):
            out.appendBE(r.framesReceived)
            out.appendBE(r.fecRecovered)
            out.appendBE(r.unrecovered)
            out.appendBE(r.latestHostSendTs)
            out.appendBE(r.clientHoldMs)
            out.appendBE(r.owdJitterMicros)
            out.appendBE(r.owdTrendMilli)
            out.appendBE(r.owdTrendFlags)
            out.appendBE(r.pacerLateFrames)
            out.appendBE(r.pacerPresentGaps)
            out.appendBE(r.pacerDepth)
        }
        return out
    }

    /// Parses a recovery message. Throws ``VideoProtocolError`` on an unknown type, a short body,
    /// or TRAILING bytes. The trailing-bytes rejection (2026-06-11) is load-bearing: the client
    /// always emits exact-width datagrams, and the host's `RecoveryRequestDeduper` keys on the RAW
    /// datagram bytes — a decoder that tolerated suffixes would let suffix-varied copies of one
    /// logical request each decode identically yet bypass the byte-keyed dedup (re-triggering a
    /// second ForceLTRRefresh/IDR). No backcompat needed; both ends redeploy together.
    public static func decode(_ data: Data) throws -> Self {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        let message: Self
        switch type {
        case 1:
            message = try .ack(streamSeq: reader.readUInt32())
        case 2:
            // Three fixed-width UInt32s; bounds-checked reads ⇒ a body < 12 bytes throws .truncated
            // → the router drops the single datagram (never crashes on hostile input).
            let from = try reader.readUInt32()
            let to = try reader.readUInt32()
            let lastDecoded = try reader.readUInt32()
            message = .requestLTRRefresh(fromFrameID: from, toFrameID: to, lastDecodedFrameID: lastDecoded)
        case 3:
            // One bounds-checked UInt32 (lastDecodedFrameID); a 0-byte legacy body now throws
            // .truncated and is dropped — no backcompat (both ends redeploy together).
            message = try .requestIDR(lastDecodedFrameID: reader.readUInt32())
        case 4:
            message = try .requestCursorShape(shapeID: reader.readUInt16())
        case 5:
            // Eleven fixed-width UInt32s; each read is bounds-checked, so a body < 44 bytes throws
            // .truncated → the router drops the datagram (no OOB / overflow / force-unwrap surface).
            let framesReceived = try reader.readUInt32()
            let fecRecovered = try reader.readUInt32()
            let unrecovered = try reader.readUInt32()
            let latestHostSendTs = try reader.readUInt32()
            let clientHoldMs = try reader.readUInt32()
            let owdJitterMicros = try reader.readUInt32()
            let owdTrendMilli = try reader.readUInt32()
            let owdTrendFlags = try reader.readUInt32()
            let pacerLateFrames = try reader.readUInt32()
            let pacerPresentGaps = try reader.readUInt32()
            let pacerDepth = try reader.readUInt32()
            message = .networkStats(NetworkStatsReport(
                framesReceived: framesReceived, fecRecovered: fecRecovered, unrecovered: unrecovered,
                latestHostSendTs: latestHostSendTs, clientHoldMs: clientHoldMs, owdJitterMicros: owdJitterMicros,
                owdTrendMilli: owdTrendMilli, owdTrendFlags: owdTrendFlags,
                pacerLateFrames: pacerLateFrames, pacerPresentGaps: pacerPresentGaps, pacerDepth: pacerDepth,
            ))
        default:
            throw VideoProtocolError.malformed("unknown recovery message type \(type)")
        }
        guard reader.bytesRemaining == 0 else {
            throw VideoProtocolError.malformed("trailing bytes")
        }
        return message
    }
}

/// Models the client-side recovery policy: which message to send for a detected
/// loss, and when to escalate to a forced IDR. Pure decision logic — the timer /
/// transport lives in `AislopdeskVideoClient`.
public struct RecoveryPolicy: Sendable {
    /// Escalate to IDR if no decodable frame arrives within this multiple of the
    /// measured RTT (doc 17 §3.6: "fallback IDR after timeout 2-RTT").
    public let idrTimeoutRTTMultiple: Double
    /// Component 5 (recovery-redundancy, 2026-06-11): the HALVED escalation multiple used while
    /// the client is OBSERVING LOSS (``LossObservationWindow``). Under loss the conservative
    /// 2·RTT wait is the dominant residual freeze term once requests are sent redundantly — a
    /// lossy path has already corroborated that waiting longer rarely saves the IDR.
    public let lossyIdrTimeoutRTTMultiple: Double
    /// Floor on the LOSSY deadline. RAISED 30 → 60 ms (2026-06-11 telemetry round): an LTR-refresh
    /// response PHYSICALLY needs host encode + flight + client decode ≈ 40-60 ms at the live path's
    /// 10-30 ms RTT — the old 30 ms floor let the client escalate to `requestIDR` BEFORE the LTR
    /// medicine could land (measured: 202 requestIDR vs 100 LTR refreshes in 169 s; the host
    /// absorbed a 97-suppression storm). The effective floor is
    /// `max(lossyEscalationFloor, lossyEscalationFloorRTTMultiple × rtt)` so it tracks the path:
    /// 60 ms at low RTT, 1.5·RTT once the RTT itself dominates the response time.
    /// `AISLOPDESK_ESCALATION_FLOOR_MS` (default 60, clamp 20...500) tunes the constant part.
    /// The NORMAL (non-lossy) path has NO floor and stays byte-identical to today.
    public let lossyEscalationFloor: TimeInterval
    /// The RTT-proportional part of the lossy floor (see ``lossyEscalationFloor``): a refresh
    /// round-trip is ≥1·RTT, plus encode/decode/frame-interval overhead ≈ half an RTT on the
    /// target path — escalating earlier than ~1.5·RTT can only duplicate work.
    public let lossyEscalationFloorRTTMultiple: Double

    /// Pure env resolution for the lossy floor: `AISLOPDESK_ESCALATION_FLOOR_MS`, default 60 ms,
    /// clamped to 20...500 ms; absent/garbage/out-of-band values keep the default.
    public static func escalationFloorSeconds(env: [String: String]) -> TimeInterval {
        guard let s = env["AISLOPDESK_ESCALATION_FLOOR_MS"], let v = Double(s), v.isFinite,
              v >= 20, v <= 500 else { return 0.06 }
        return v / 1000.0
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

    /// Whether the client should escalate to a forced IDR given how long it has
    /// waited since the LTR-refresh request, and the current RTT estimate.
    /// Convenience for the historical 2-arg call shape — `observingLoss: false`
    /// (byte-identical to the pre-component-5 behaviour).
    public func shouldEscalateToIDR(elapsedSinceRequest: TimeInterval, rtt: TimeInterval) -> Bool {
        shouldEscalateToIDR(elapsedSinceRequest: elapsedSinceRequest, rtt: rtt, observingLoss: false)
    }

    /// Component 5: the loss-adaptive escalation clock. `observingLoss == false` ⇒ today's
    /// `2·RTT`, no floor. `observingLoss == true` ⇒ the halved clock floored at the
    /// physically-arrivable response time:
    /// `max(lossyIdrTimeoutRTTMultiple·RTT, lossyEscalationFloor, lossyEscalationFloorRTTMultiple·RTT)`
    /// — at the defaults `max(1·RTT, 60 ms, 1.5·RTT)`. The loss-state halving (1× vs 2×) is kept
    /// ABOVE the floor; the floor just guarantees an LTR refresh gets the time it physically needs
    /// before the IDR sledgehammer.
    public func shouldEscalateToIDR(elapsedSinceRequest: TimeInterval, rtt: TimeInterval, observingLoss: Bool) -> Bool {
        // Delegated to the Rust `aislopdesk-core` recovery policy (single source of truth shared
        // with the Android client); byte-identical to the former native clock (pinned by the
        // existing recovery tests + `RustRecoveryPolicyParityTests`). The env-resolved lossy floor
        // (`lossyEscalationFloor`, from AISLOPDESK_ESCALATION_FLOOR_MS) stays Swift-side, passed in.
        RustVideoFFI.recoveryShouldEscalateToIDR(
            idrTimeoutRTTMultiple: idrTimeoutRTTMultiple,
            lossyIdrTimeoutRTTMultiple: lossyIdrTimeoutRTTMultiple,
            lossyEscalationFloor: lossyEscalationFloor,
            lossyEscalationFloorRTTMultiple: lossyEscalationFloorRTTMultiple,
            elapsedSinceRequest: elapsedSinceRequest, rtt: rtt, observingLoss: observingLoss,
        )
    }
}

/// Component 5 (recovery-redundancy, 2026-06-11): how many byte-identical copies of one logical
/// recovery request (`requestLTRRefresh` / `requestIDR`) the client sends, and their spacing.
///
/// WHY redundancy: the recovery REQUEST is a single ≤17-byte datagram riding the same lossy path
/// it is reporting on (measured bursts 3-9%). A lost request costs the full escalation wait
/// (~2·RTT ≈ 100 ms at the bootstrap EWMA) of extra frozen frame — the ranked hitch tail.
///
/// SPACING 5 ms → 3 ms (2026-06-11): 5 ms left only a 10 ms margin between the max copy spread
/// (20 ms at copies=5) and the host dedup window — thin enough that a delayed copy could re-admit.
///
/// WHY 3 ms spacing (not back-to-back like the input path's `redundantUpCount`): measured losses
/// are BURSTY (up to ~15 adjacent wire datagrams — the FragmentInterleaver memory), so spacing
/// decorrelates the copies' fate; at recovery time the send lane is mostly idle so wire adjacency
/// is otherwise likely. COUPLING INVARIANT (vs the host dedup window, default 25 ms): the total
/// spread (copies−1)·spacing must stay ≤ HALF the window for every legal copies count — 6 ms at
/// the default 3 copies, 12 ms at the max 5 vs 12.5 — so a late copy can never age past the
/// window (duplicates do NOT refresh its timestamp) and re-admit as a second host action
/// (double-ForceLTRRefresh). Pinned by `testRedundancySpreadVsDedupWindowCouplingAtDefaults`.
public struct RecoveryRequestRedundancy: Sendable, Equatable {
    /// Total sends per logical request, clamped to 1...5. 1 = today's single send.
    public let copies: Int
    /// Gap between consecutive copies (seconds).
    public let spacing: TimeInterval

    public init(copies: Int = 3, spacing: TimeInterval = 0.003) {
        self.copies = min(5, max(1, copies))
        self.spacing = spacing
    }

    /// Send-time offsets for one logical request: `[0, spacing, 2·spacing, ...]`.
    public var sendOffsets: [TimeInterval] {
        (0..<copies).map { Double($0) * spacing }
    }

    /// P(all copies lost) under i.i.d. per-datagram loss `p`: `clamp01(p)^copies`.
    public static func allCopiesLostProbability(perDatagramLoss: Double, copies: Int) -> Double {
        let p = min(1.0, max(0.0, perDatagramLoss))
        let n = min(5, max(1, copies))
        var out = 1.0
        for _ in 0..<n { out *= p }
        return out
    }

    /// Expected freeze added by REQUEST loss per loss event: P(all copies lost) × the escalation
    /// delay the client then sits through. THE before/after freeze-time math as a testable function.
    public static func expectedRequestLossFreeze(
        perDatagramLoss: Double,
        copies: Int,
        escalationDelay: TimeInterval,
    ) -> TimeInterval {
        allCopiesLostProbability(perDatagramLoss: perDatagramLoss, copies: copies) * escalationDelay
    }
}

/// Component 5: the client-side LOSS-OBSERVING predicate gating the halved escalation clock
/// (``RecoveryPolicy/shouldEscalateToIDR(elapsedSinceRequest:rtt:observingLoss:)``).
///
/// Events are fed from data the client already has: (i) every UNRECOVERABLE loss, and (ii) every
/// FEC-RECOVERED frame completion (the early-warning channel — the measured 10 s bursts produce
/// multiple FEC recoveries per second BEFORE the first unrecoverable frame, so the FIRST
/// frozen-frame episode of a burst already runs the halved clock). Defaults {1.0 s, ≥2} keep a
/// lone baseline ~1% loss (1 event) on today's conservative 2·RTT clock.
public struct LossObservationWindow: Sendable, Equatable {
    private let windowSeconds: TimeInterval
    private let minEvents: Int
    private let capacity: Int
    /// Ring of event timestamps (seconds, caller's monotonic clock), newest last.
    private var events: [TimeInterval] = []

    public init(windowSeconds: TimeInterval = 1.0, minEvents: Int = 2, capacity: Int = 8) {
        self.windowSeconds = windowSeconds
        self.minEvents = max(1, minEvents)
        self.capacity = max(1, capacity)
    }

    /// Records one loss-ish event (unrecoverable loss or FEC recovery) at `now`. Prunes events
    /// older than the window; drop-oldest at capacity (bounded regardless of feed rate).
    public mutating func noteEvent(now: TimeInterval) {
        events.removeAll { now - $0 > windowSeconds }
        if events.count >= capacity { events.removeFirst(events.count - capacity + 1) }
        events.append(now)
    }

    /// Whether ≥ `minEvents` events lie within `windowSeconds` of `now`. Pure read (no prune):
    /// stale entries simply fail the recency test.
    public func isObservingLoss(now: TimeInterval) -> Bool {
        events.count(where: { now - $0 <= windowSeconds && now - $0 >= 0 }) >= minEvents
    }
}
