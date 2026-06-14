#if os(macOS)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// In-memory datagram-routing harness for the HOST UDP-mux (Stage S3) — the analogue of the TCP
/// `MuxLoopbackTests`, but WITHOUT a socket / `NWListener` / SCStream. It drives the SAME pure
/// pieces the live ``NWVideoMuxDatagramTransport`` drives (``VideoMuxRouter`` admit/route +
/// ``VideoMuxHeaderCodec`` decode + the shared ``VideoMuxSinkTable``) and asserts that N channels'
/// datagrams reach the CORRECT per-channel sink, that a lost datagram / one channel's retire never
/// disturbs siblings (RTP per-channel loss isolation), and that a stale-generation datagram is
/// dropped.
final class VideoMuxDatagramRoutingTests: XCTestCase {
    /// A minimal in-memory host demux: the exact decode + route + deliver pipeline the live receive
    /// loop runs, with the sinks recording what they got. No socket. `@unchecked Sendable` via the
    /// `NSLock` so the `@Sendable` sink closures can record into it.
    private final class Harness: @unchecked Sendable {
        var router = VideoMuxRouter()
        let table = VideoMuxSinkTable()
        private let lock = NSLock()
        private var _received: [UInt32: [(VideoChannel, Data)]] = [:]

        /// Admit a lane + register its recording sink (what the daemon does on a hello-mint).
        func openLane(_ channelID: UInt32) {
            router.admit(channelID)
            table.register(channelID) { [weak self] channel, data in
                self?.lock.withLock { self?._received[channelID, default: []].append((channel, data)) }
            }
        }

        /// Register ONLY the recording sink for a lane WITHOUT admitting it (the bootstrap case: a
        /// sink exists to observe the first hello before the router has admitted the lane).
        func registerRecordingSink(_ channelID: UInt32) {
            table.register(channelID) { [weak self] channel, data in
                self?.lock.withLock { self?._received[channelID, default: []].append((channel, data)) }
            }
        }

        /// Retire a lane (a `bye`): drop in-flight bytes + unregister the sink. Siblings untouched.
        func retireLane(_ channelID: UInt32) {
            router.retire(channelID)
            table.unregister(channelID)
        }

        /// Feed one fully-framed media datagram (`[channelID][tag][payload]`) through decode → route
        /// → deliver, exactly like `NWVideoMuxDatagramTransport.routeMedia` (incl. the bootstrap
        /// exception: an unadmitted CONTROL datagram is delivered so the registry can mint). Returns
        /// the raw router decision so a test can assert the loss-isolation semantics.
        @discardableResult
        func feedMedia(channelID: UInt32, channel: VideoChannel, payload: Data) -> VideoMuxRouter.Decision {
            var inner = Data([channel.rawValue])
            inner.append(payload)
            let datagram = VideoMuxHeaderCodec.encode(channelID: channelID, payload: inner)
            guard let (decodedID, rest) = try? VideoMuxHeaderCodec.decode(datagram), rest.count >= 1 else {
                return .drop(reason: "undecodable")
            }
            let tag = rest[rest.startIndex]
            let decodedChannel = VideoChannel(rawValue: tag)!
            let decision = router.route(channelID: decodedID, channel: decodedChannel, bytesCount: datagram.count)
            let deliver: Bool =
                switch decision {
                case .route: true
                case .rejectUnadmitted: decodedChannel == .control // bootstrap: the first hello
                case .dropRetired,
                     .dropDraining,
                     .drop: false
                }
            if deliver {
                table.sink(decodedID)?(decodedChannel, Data(rest[(rest.startIndex + 1)...]))
            }
            return decision
        }

        func count(_ channelID: UInt32) -> Int { lock.withLock { _received[channelID]?.count ?? 0 } }
        func payloads(_ channelID: UInt32) -> [Data] { lock.withLock { (_received[channelID] ?? []).map(\.1) } }
    }

    func testNChannelsRouteToTheirOwnSink() {
        let h = Harness()
        h.openLane(10)
        h.openLane(20)
        h.openLane(30)

        h.feedMedia(channelID: 10, channel: .video, payload: Data([0x0A]))
        h.feedMedia(channelID: 20, channel: .video, payload: Data([0x14]))
        h.feedMedia(channelID: 30, channel: .control, payload: Data([0x1E]))
        h.feedMedia(channelID: 10, channel: .input, payload: Data([0x0B]))

        XCTAssertEqual(h.payloads(10), [Data([0x0A]), Data([0x0B])])
        XCTAssertEqual(h.payloads(20), [Data([0x14])])
        XCTAssertEqual(h.payloads(30), [Data([0x1E])])
    }

    func testUnadmittedChannelIDIsDroppedNeverDelivered() {
        let h = Harness()
        h.openLane(10)
        let decision = h.feedMedia(channelID: 99, channel: .video, payload: Data([0xFF]))
        XCTAssertEqual(decision, .rejectUnadmitted)
        XCTAssertEqual(h.count(99), 0)
        XCTAssertEqual(h.count(10), 0, "an unknown lane never touches a sibling sink")
    }

    func testRetiringOneLaneKeepsSiblingsStreaming() {
        // Per-channel loss isolation: a `bye` on lane 10 retires ONLY 10; 20 keeps routing.
        let h = Harness()
        h.openLane(10)
        h.openLane(20)
        h.feedMedia(channelID: 10, channel: .video, payload: Data([0x01]))
        h.retireLane(10)

        // A still-in-flight datagram for the retired lane is DROPPED (reconnect-generation safety),
        // not delivered to a survivor.
        XCTAssertEqual(h.feedMedia(channelID: 10, channel: .video, payload: Data([0x02])), .dropRetired)
        XCTAssertEqual(h.count(10), 1, "retired lane stops receiving (only the pre-bye datagram landed)")

        // The sibling lane is completely unaffected.
        h.feedMedia(channelID: 20, channel: .video, payload: Data([0x03]))
        XCTAssertEqual(h.payloads(20), [Data([0x03])])
    }

    func testFirstHelloOnUnadmittedLaneBootstrapsThroughToTheRegistry() {
        // The bootstrap exception: a lane is admitted only once its session is minted, but the FIRST
        // hello arrives BEFORE that. routeMedia must forward an unadmitted CONTROL datagram (so the
        // daemon's registry can mint), while a non-control unadmitted datagram is still dropped.
        let h = Harness()
        // No lane opened yet (unadmitted). Register a RECORDING sink to OBSERVE the control bootstrap.
        h.registerRecordingSink(5)
        let helloLike = VideoControlMessage.hello(
            protocolVersion: AislopdeskVideoProtocol.version,
            requestedWindowID: 42,
            viewport: VideoSize(width: 1, height: 1),
        )
        .encode()
        let controlDecision = h.feedMedia(channelID: 5, channel: .control, payload: helloLike)
        let videoDecision = h.feedMedia(channelID: 5, channel: .video, payload: Data([0x01]))
        XCTAssertEqual(controlDecision, .rejectUnadmitted, "router still reports unadmitted...")
        XCTAssertEqual(videoDecision, .rejectUnadmitted)
        XCTAssertEqual(h.count(5), 1, "...but the CONTROL (hello) is delivered for mint; the video is not")
    }

    func testReconnectAdmitsFreshLaneWhileOldStaleFramesDrop() {
        // A reconnecting client opens a NEW channelID; the old one's stale frames must drop, the new
        // one's route — no cross-generation leak into the fresh session.
        let h = Harness()
        h.openLane(7)
        h.retireLane(7) // client went away
        h.openLane(9) // reconnect under a fresh lane
        XCTAssertEqual(h.feedMedia(channelID: 9, channel: .video, payload: Data([0x09])), .route(channelID: 9))
        XCTAssertEqual(h.feedMedia(channelID: 7, channel: .video, payload: Data([0x07])), .dropRetired)
        XCTAssertEqual(h.payloads(9), [Data([0x09])])
        XCTAssertEqual(h.count(7), 0)
    }
}
#endif
