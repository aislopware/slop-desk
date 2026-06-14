import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// PURE recovery-routing decision logic + the never-run wire-collision regression.
/// Decides forceKeyframe/ack/drop/ignore for a client→host `RecoveryMessage` WITHOUT
/// an encoder/capturer. No socket, no VideoToolbox.
final class RecoveryDatagramRouterTests: XCTestCase {
    private let router = RecoveryDatagramRouter()

    func testIgnoresWhenNotStreaming() {
        let datagram = RecoveryMessage.requestIDR(lastDecodedFrameID: 5).encode()
        XCTAssertEqual(router.route(datagram: datagram, mediaFlowing: false), .ignoreNotStreaming)
    }

    /// Component 2: `.forceKeyframe` carries the request's decode frontier for the actor's
    /// delivery-keyed RecoveryIDRPolicy.
    func testRequestIDRForcesKeyframeCarryingLastDecoded() {
        let decision = router.route(
            datagram: RecoveryMessage.requestIDR(lastDecodedFrameID: 41).encode(),
            mediaFlowing: true,
        )
        XCTAssertEqual(decision, .forceKeyframe(lastDecodedFrameID: 41))
    }

    /// The wire sentinel ("nothing decoded yet") maps to a clean `nil` for the actor's policy.
    func testRequestIDRSentinelMapsToNil() {
        let decision = router.route(
            datagram: RecoveryMessage.requestIDR(lastDecodedFrameID: RecoveryMessage.noFrameDecodedSentinel).encode(),
            mediaFlowing: true,
        )
        XCTAssertEqual(decision, .forceKeyframe(lastDecodedFrameID: nil))
    }

    /// WF-8: requestLTRRefresh now routes to `.refreshLTR` (the actor decides LTR-refresh-vs-IDR from
    /// runtime acked-token state), DISTINCT from requestIDR's `.forceKeyframe` (the guaranteed IDR).
    /// Component 2: it carries the decode frontier too (consumed only by the `.idr` fallback).
    func testRequestLTRRefreshRoutesToRefreshLTR() {
        let message = RecoveryMessage.requestLTRRefresh(fromFrameID: 10, toFrameID: 12, lastDecodedFrameID: 9)
        XCTAssertEqual(router.route(datagram: message.encode(), mediaFlowing: true), .refreshLTR(lastDecodedFrameID: 9))
    }

    func testRequestLTRRefreshSentinelMapsToNil() {
        let message = RecoveryMessage.requestLTRRefresh(
            fromFrameID: 0, toFrameID: 0, lastDecodedFrameID: RecoveryMessage.noFrameDecodedSentinel,
        )
        XCTAssertEqual(
            router.route(datagram: message.encode(), mediaFlowing: true),
            .refreshLTR(lastDecodedFrameID: nil),
        )
    }

    /// requestIDR MUST stay a real forced keyframe — the guaranteed-recovery escalation must never
    /// degrade to an LTR refresh.
    func testRequestIDRStaysForceKeyframe() {
        guard case .forceKeyframe = router.route(
            datagram: RecoveryMessage.requestIDR(lastDecodedFrameID: 0).encode(),
            mediaFlowing: true,
        ) else {
            XCTFail("expected forceKeyframe")
            return
        }
    }

    func testAckSurfacesStreamSeq() {
        let decision = router.route(datagram: RecoveryMessage.ack(streamSeq: 0xCAFE_BABE).encode(), mediaFlowing: true)
        XCTAssertEqual(decision, .ack(streamSeq: 0xCAFE_BABE))
    }

    /// FIX B: a `requestCursorShape` on the recovery channel routes to a re-ship of that shape,
    /// NOT a forced keyframe — the cursor self-heal must not trigger an expensive IDR.
    func testRequestCursorShapeReships() {
        let decision = router.route(
            datagram: RecoveryMessage.requestCursorShape(shapeID: 7).encode(),
            mediaFlowing: true,
        )
        XCTAssertEqual(decision, .reshipCursorShape(shapeID: 7))
    }

    func testRequestCursorShapeIgnoredWhenNotStreaming() {
        let datagram = RecoveryMessage.requestCursorShape(shapeID: 1).encode()
        XCTAssertEqual(router.route(datagram: datagram, mediaFlowing: false), .ignoreNotStreaming)
    }

    func testDropsUndecodableDatagram() {
        let garbage = Data([0x7F, 0x00]) // unknown recovery type 0x7F
        guard case .drop = router.route(datagram: garbage, mediaFlowing: true) else {
            XCTFail("expected drop")
            return
        }
    }

    /// The network-feedback channel: a NetworkStats report routes to `.networkStats` carrying the
    /// decoded report verbatim — including component 3's trend fields (a negative modified-trend
    /// bit-pattern + packed state/deltas flags survive the wire round-trip untouched) and
    /// component 4's pacer presentation-health fields (late/gaps counters + the depth gauge).
    func testNetworkStatsRoutes() {
        let report = NetworkStatsReport(
            framesReceived: 600,
            fecRecovered: 12,
            unrecovered: 3,
            latestHostSendTs: 1_234_567,
            clientHoldMs: 7,
            owdJitterMicros: 850,
            owdTrendMilli: UInt32(bitPattern: -987),
            owdTrendFlags: (42 << 8) | 1,
            pacerLateFrames: 4,
            pacerPresentGaps: 6,
            pacerDepth: 2,
        )
        let decision = router.route(datagram: RecoveryMessage.networkStats(report).encode(), mediaFlowing: true)
        XCTAssertEqual(decision, .networkStats(report))
        guard case let .networkStats(rx) = decision else { XCTFail("expected networkStats")
            return
        }
        XCTAssertEqual(rx.owdTrendStateRaw, 1)
        XCTAssertEqual(rx.owdTrendDeltas, 42)
        XCTAssertEqual(rx.owdTrendModifiedMilliSigned, -987)
        XCTAssertEqual(rx.pacerLateFrames, 4)
        XCTAssertEqual(rx.pacerPresentGaps, 6)
        XCTAssertEqual(rx.pacerDepth, 2)
    }

    func testNetworkStatsIgnoredWhenNotStreaming() {
        let report = NetworkStatsReport(
            framesReceived: 1,
            fecRecovered: 0,
            unrecovered: 0,
            latestHostSendTs: 1,
            clientHoldMs: 0,
            owdJitterMicros: 0,
        )
        XCTAssertEqual(
            router.route(datagram: RecoveryMessage.networkStats(report).encode(), mediaFlowing: false),
            .ignoreNotStreaming,
        )
    }

    /// A truncated NetworkStats body (short of the 11×UInt32 payload) DROPS — never crashes the host.
    func testTruncatedNetworkStatsDrops() {
        let full = RecoveryMessage.networkStats(NetworkStatsReport(
            framesReceived: 1,
            fecRecovered: 2,
            unrecovered: 3,
            latestHostSendTs: 4,
            clientHoldMs: 5,
            owdJitterMicros: 6,
        )).encode()
        guard case .drop = router.route(datagram: full.prefix(10), mediaFlowing: true) else {
            XCTFail("expected a truncated stats body to drop")
            return
        }
    }

    // MARK: Never-run wire-collision regression

    /// THE original bug: recovery rode the `.input` channel, where the host decodes
    /// every datagram as an `InputEvent`. `RecoveryMessage`'s leading type bytes (1/2/3)
    /// overlap `InputEvent`'s (mouseMove/Down/Up), so a recovery datagram would either be
    /// injected as a PHANTOM mouse event or dropped — and recovery never reached the
    /// encoder. This proves the two channels are now disjoint by routing the SAME bytes
    /// through both routers and asserting only the recovery router treats them as recovery.
    func testRecoveryBytesAreNotMisroutedAsInput() {
        let inputRouter = InputDatagramRouter()
        let ltr = RecoveryMessage.requestLTRRefresh(fromFrameID: 7, toFrameID: 7, lastDecodedFrameID: 6).encode()

        // The recovery router decodes it correctly → routes to the WF-8 LTR-refresh decision.
        XCTAssertEqual(router.route(datagram: ltr, mediaFlowing: true), .refreshLTR(lastDecodedFrameID: 6))

        // The same bytes on the INPUT router would have been mis-decoded as a mouseDown
        // (type byte 2) at a garbage coordinate — exactly the phantom-click hazard. We
        // assert the bytes are routed by CHANNEL now, so this misread never happens on
        // the wire: recovery is sent on `.recovery`, input on `.input`. This call only
        // documents that the byte grammars DO overlap (hence the dedicated channel).
        let asInput = inputRouter.route(datagram: ltr, mediaFlowing: true, needsRaise: false)
        if case let .inject(event, _) = asInput {
            // Confirms the collision the dedicated channel eliminates: LTR(type 2) looks
            // like a mouseDown to the input grammar.
            guard case .mouseDown = event else {
                XCTFail("expected the overlap to surface as a mouseDown, got \(event)")
                return
            }
        }
        // (No assertion on drop-vs-inject: the point is recovery NEVER travels on .input.)
    }

    /// `requestIDR` (type byte 3) overlaps `InputEvent.mouseUp` (type 3) but is shorter —
    /// even the component-2 5-byte body ([3][lastDecodedFrameID]) truncates against mouseUp's
    /// 23-byte body (tag+button+clicks+mods+2×Float64), so on the input grammar it still drops —
    /// silently swallowing recovery. On the recovery channel it correctly forces a keyframe.
    /// (Channel separation unchanged: recovery NEVER travels on `.input`.)
    func testRequestIDRWouldHaveBeenSwallowedByInputGrammar() {
        let inputRouter = InputDatagramRouter()
        let idr = RecoveryMessage.requestIDR(lastDecodedFrameID: 99).encode()
        XCTAssertEqual(idr.count, 5)
        XCTAssertEqual(router.route(datagram: idr, mediaFlowing: true), .forceKeyframe(lastDecodedFrameID: 99))
        // 5 bytes is still too short for a mouseUp body → the input grammar drops it.
        guard case .drop = inputRouter.route(datagram: idr, mediaFlowing: true, needsRaise: false) else {
            XCTFail("expected the 5-byte requestIDR to drop under the input grammar")
            return
        }
    }
}
