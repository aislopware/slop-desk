#if os(macOS)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// In-memory transport-level harness for the FIX #2 (retired re-admit on hello) + FIX #6 (no
/// stray-control flow stamp) changes to `NWVideoMuxDatagramTransport.routeMedia` — WITHOUT a socket.
/// It reproduces the EXACT decode → route → `bootstrapAction` → deliver/stamp pipeline the live
/// `routeMedia` runs (incl. the shared one-shot hello-peek), recording deliveries AND the flow-stamp
/// table so a test can assert both the re-admit and the leak-avoidance behavior.
final class VideoMuxReadmitRoutingTests: XCTestCase {
    /// A faux NWConnection identity (the live code keys `channelMediaConn` by the conn that carried
    /// the lane). We only need object identity, so a bare class instance stands in for the conn.
    private final class FakeConn {}

    /// Mirrors `routeMedia`'s decode + route + bootstrap logic over an injected router + flow table.
    private final class Harness {
        var router = VideoMuxRouter()
        /// channelID → the conn we remembered (FIX #6: only ever stamped for a hello bootstrap or a route).
        private(set) var channelMediaConn: [UInt32: FakeConn] = [:]
        private(set) var delivered: [(UInt32, VideoChannel, Data)] = []

        /// One framed datagram through the SAME pipeline as `routeMedia` (sans socket/reaper).
        @discardableResult
        func feed(channelID: UInt32, channel: VideoChannel, payload: Data, on conn: FakeConn) -> Bool {
            var inner = Data([channel.rawValue])
            inner.append(payload)
            let datagram = VideoMuxHeaderCodec.encode(channelID: channelID, payload: inner)
            guard let (decodedID, rest) = try? VideoMuxHeaderCodec.decode(datagram),
                  rest.count >= 1 else { return false }
            let tag = rest[rest.startIndex]
            guard let decodedChannel = VideoChannel(rawValue: tag) else { return false }
            let p = Data(rest[(rest.startIndex + 1)...])

            let decision = router.route(channelID: decodedID, channel: decodedChannel, bytesCount: datagram.count)
            let deliver: Bool
            switch decision {
            case .route:
                channelMediaConn[decodedID] = conn
                deliver = true
            case .rejectUnadmitted,
                 .dropRetired:
                // The one-shot hello peek mirrors the private `payloadIsHello` helper.
                let isHello: Bool = {
                    guard decodedChannel == .control, let msg = try? VideoControlMessage.decode(p),
                          case .hello = msg else { return false }
                    return true
                }()
                switch VideoMuxRouter.bootstrapAction(for: decision, channel: decodedChannel, payloadIsHello: isHello) {
                case .bootstrapDeliver:
                    channelMediaConn[decodedID] = conn
                    deliver = true
                case .dropNoStamp:
                    deliver = false
                }
            case .dropDraining,
                 .drop:
                deliver = false
            }
            if deliver { delivered.append((decodedID, decodedChannel, p)) }
            return deliver
        }

        var deliveredIDs: [UInt32] { delivered.map(\.0) }
    }

    private func helloPayload() -> Data {
        VideoControlMessage.hello(
            protocolVersion: AislopdeskVideoProtocol.version,
            requestedWindowID: 7,
            viewport: VideoSize(width: 100, height: 100),
        ).encode()
    }

    func testRetiredLaneReconnectsOnHelloAfterCrossProcessReuse() {
        // The exact reconnect bug: client restarts, allocator resets, its fresh channelID collides
        // with a retired one. Pre-FIX, that hello was hard-dropped forever. Now a hello re-admits it.
        let h = Harness()
        let conn1 = FakeConn(), conn2 = FakeConn()

        // Lane 1 admitted (via a first hello), then retired (the client went away / bye).
        XCTAssertTrue(h.feed(channelID: 1, channel: .control, payload: helloPayload(), on: conn1))
        h.router.admit(1) // mint path admits on session.start
        h.router.retire(1) // client gone

        // A stale old-gen video datagram for the retired lane drops (generation safety).
        XCTAssertFalse(h.feed(channelID: 1, channel: .video, payload: Data([0xAA]), on: conn1))

        // The restarted client reuses channelID 1 with a fresh HELLO → re-admit bootstrap (delivered
        // for mint, and the NEW flow remembered so the helloAck replies on conn2).
        XCTAssertTrue(h.feed(channelID: 1, channel: .control, payload: helloPayload(), on: conn2))
        XCTAssertTrue(h.channelMediaConn[1] === conn2, "the re-admit remembers the NEW reply flow")
        h.router.admit(1) // session.start re-admits → clears retired
        XCTAssertTrue(
            h.feed(channelID: 1, channel: .video, payload: Data([0xBB]), on: conn2),
            "after re-admission the reused lane routes again — reconnect is no longer blocked",
        )
    }

    func testStrayNonHelloControlForUnknownLaneNeverStampsFlow() {
        // FIX #6: a non-hello control datagram for a never-helloed lane drops WITHOUT remembering its
        // flow, so `channelMediaConn` cannot grow from stray/adversarial channelIDs.
        let h = Harness()
        let conn = FakeConn()
        let bye = VideoControlMessage.bye.encode()
        XCTAssertFalse(h.feed(channelID: 999, channel: .control, payload: bye, on: conn))
        XCTAssertNil(h.channelMediaConn[999], "a stray non-hello control datagram leaves no flow entry")
        XCTAssertTrue(h.deliveredIDs.isEmpty)
    }

    func testStrayNonHelloControlForRetiredLaneNeverStampsFlow() {
        // FIX #6 + FIX #2 interaction: a non-hello control datagram for a RETIRED lane drops without a
        // stamp too (only a hello re-admits a retired id).
        let h = Harness()
        let conn = FakeConn()
        h.router.admit(3)
        h.router.retire(3)
        let bye = VideoControlMessage.bye.encode()
        XCTAssertFalse(h.feed(channelID: 3, channel: .control, payload: bye, on: conn))
        XCTAssertNil(h.channelMediaConn[3], "a non-hello control datagram for a retired lane stamps no flow")
    }

    func testFirstHelloOnNeverSeenLaneStillBootstraps() {
        // The original bootstrap (a never-seen lane's first hello) still delivers + stamps.
        let h = Harness()
        let conn = FakeConn()
        XCTAssertTrue(h.feed(channelID: 50, channel: .control, payload: helloPayload(), on: conn))
        XCTAssertTrue(h.channelMediaConn[50] === conn)
        XCTAssertEqual(h.deliveredIDs, [50])
    }

    func testEmptyControlPayloadIsBoundsSafeAndDrops() {
        // Bounds-safety regression lock (review): a 0-byte control payload (truncated / adversarial)
        // must NOT crash the hello-peek — VideoControlMessage.decode under `try?` throws on underflow
        // → false — and must drop WITHOUT stamping a flow.
        let h = Harness()
        let conn = FakeConn()
        XCTAssertFalse(h.feed(channelID: 60, channel: .control, payload: Data(), on: conn))
        XCTAssertNil(h.channelMediaConn[60], "an empty/truncated control datagram leaves no flow entry")
        XCTAssertTrue(h.deliveredIDs.isEmpty)
    }
}
#endif
