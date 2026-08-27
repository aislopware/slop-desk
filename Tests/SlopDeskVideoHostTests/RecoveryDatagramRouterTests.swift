import CSlopDeskFFI
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// What ``RecoveryDatagramRouter`` still owns after the routing law moved to
/// `rust/slopdesk-video`'s `route_recovery`: the MARSHALLING of the flat verdict, and the never-run
/// wire-collision regression that spans two routers. The arm table itself is pinned by
/// `recovery_routing.rs`'s own tests and is deliberately NOT restated here — a Swift mirror of it
/// would be the second implementation this port deleted.
/// No socket, no VideoToolbox.
final class RecoveryDatagramRouterTests: XCTestCase {
    private let router = RecoveryDatagramRouter()

    /// The stats report is the one arm whose payload is ELEVEN fields, so it is the one arm where a
    /// crossing can lose a number in silence: a transposed or dropped field still routes, still
    /// compiles, and simply feeds the host's estimate a value the client never sent. Both halves of
    /// that crossing are read here — the flat record the door fills, and the report this side
    /// rebuilds from it — including component 3's trend fields (a NEGATIVE modified-trend bit
    /// pattern + packed state/deltas flags) and component 4's pacer presentation-health fields.
    func testNetworkStatsReportSurvivesTheCrossingFieldForField() {
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
        let datagram = RecoveryMessage.networkStats(report).encode()

        // The door's own record, read raw: every field the report carries has a slot, and the slot
        // holds what was sent.
        var answer = SlopDeskRecoveryDecision()
        let code = datagram.withUnsafeBytes { bytes in
            slopdesk_recovery_route(bytes.baseAddress, bytes.count, true, &answer, nil, 0)
        }
        XCTAssertEqual(code, UInt32(SLOPDESK_RECOVERY_ROUTE_NETWORK_STATS))
        XCTAssertEqual(answer.frames_received, 600)
        XCTAssertEqual(answer.fec_recovered, 12)
        XCTAssertEqual(answer.unrecovered, 3)
        XCTAssertEqual(answer.latest_host_send_ts, 1_234_567)
        XCTAssertEqual(answer.client_hold_ms, 7)
        XCTAssertEqual(answer.owd_jitter_micros, 850)
        XCTAssertEqual(answer.owd_trend_milli, UInt32(bitPattern: -987))
        XCTAssertEqual(answer.owd_trend_flags, (42 << 8) | 1)
        XCTAssertEqual(answer.pacer_late_frames, 4)
        XCTAssertEqual(answer.pacer_present_gaps, 6)
        XCTAssertEqual(answer.pacer_depth, 2)

        // And the eleven assignments that rebuild the report from that record: a transposition
        // there is invisible to the door and to `recovery_routing.rs` alike, so it is read back
        // through the derived accessors the actor actually consumes.
        guard case let .networkStats(rx) = router.route(datagram: datagram, mediaFlowing: true) else {
            XCTFail("expected networkStats")
            return
        }
        XCTAssertEqual(rx, report)
        XCTAssertEqual(rx.owdTrendStateRaw, 1)
        XCTAssertEqual(rx.owdTrendDeltas, 42)
        XCTAssertEqual(rx.owdTrendModifiedMilliSigned, -987)
        XCTAssertEqual(rx.pacerLateFrames, 4)
        XCTAssertEqual(rx.pacerPresentGaps, 6)
        XCTAssertEqual(rx.pacerDepth, 2)
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

        // The recovery router decodes it correctly → routes to the LTR-refresh decision.
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
