import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// The control sub-channel is deliberately unwindowed, so a
/// hostile/buggy peer can stream back-to-back tiny `.metadataRequest` frames faster than the
/// serial `metadataQueue` drains them. Unbounded admission queued one closure per request (each
/// retaining its payload + the session) and forked `git`/`lsof` without bound. The fix bounds
/// in-flight metadata work per session: at/over the cap the request is NOT enqueued — it is
/// answered IMMEDIATELY with the builder's standard `.error` status + empty payload, so the
/// "ALWAYS replies, the client never hangs" contract holds.
///
/// Driven WITHOUT a PTY or running relay (hang-safety): `serveMetadataForTesting` is the exact
/// call both control loops make; the flood uses an UNKNOWN verb byte so the pure
/// ``MetadataResponseBuilder`` answers `.unsupportedVerb` without any syscall/subprocess. The
/// serial queue is SUSPENDED for the flood so admitted work items are deterministically held
/// in-flight (and resumed exactly once before the test ends).
final class MuxChannelSessionMetadataBoundTests: XCTestCase {
    /// A verb byte no ``MetadataVerb`` case claims — the builder replies `.unsupportedVerb`
    /// with zero probe work, so a held work item is pure queue occupancy.
    private let unknownVerb: UInt8 = 0xEE

    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — hang-safety; the probe guards out on pid −1
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    /// Drains control-out and returns every `.metadataResponse` seen (other side-products dropped).
    private func drainMetadataResponses(_ session: MuxChannelSession) -> [(
        requestID: UInt32, status: UInt8, payload: Data,
    )] {
        var responses: [(UInt32, UInt8, Data)] = []
        while let batch = session.takeControlBatchForTesting() {
            for message in batch {
                if case let .metadataResponse(requestID, status, payload) = message {
                    responses.append((requestID, status, payload))
                }
            }
        }
        return responses
    }

    func testMetadataRequestFloodIsBoundedAndEveryRequestGetsAReply() async {
        let session = makeSession()
        let cap = MuxChannelSession.maxMetadataInFlightForTesting
        let total = cap * 3

        // Hold the serial queue so admitted work items stay in-flight for the whole flood.
        session.suspendMetadataQueueForTesting()
        for i in 0..<total {
            session.serveMetadataForTesting(requestID: UInt32(i), verb: unknownVerb, payload: Data())
        }

        // Bounded admission: exactly `cap` closures were enqueued (in-flight); the 2×cap overflow
        // requests were answered IMMEDIATELY with the standard error status + empty payload.
        XCTAssertEqual(
            session.metadataInFlightForTesting, cap,
            "at most maxMetadataInFlight work items may be queued per session — a metadataRequest "
                + "flood must not grow the serial queue (payload + self retained per closure) unboundedly",
        )
        let immediate = drainMetadataResponses(session)
        XCTAssertEqual(
            immediate.count, total - cap,
            "every over-cap request must get an IMMEDIATE busy reply — the client's pending-request "
                + "registry never hangs",
        )
        for reply in immediate {
            XCTAssertEqual(
                reply.status, MetadataStatus.error.rawValue,
                "the busy reply reuses the builder's standard error status byte (no new wire value)",
            )
            XCTAssertTrue(reply.payload.isEmpty, "the busy reply carries an empty payload")
        }

        // Release the held work items: the admitted `cap` requests now run and reply too.
        session.resumeMetadataQueueForTesting()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var admitted: [(requestID: UInt32, status: UInt8, payload: Data)] = []
        while ContinuousClock.now < deadline {
            admitted.append(contentsOf: drainMetadataResponses(session))
            if admitted.count >= cap { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            admitted.count, cap,
            "the admitted requests must each produce exactly one reply once the queue drains — "
                + "every one of the \(total) requests was answered",
        )
        XCTAssertEqual(
            session.metadataInFlightForTesting, 0,
            "each finished work item must release its in-flight slot (the defer-decrement)",
        )

        // The replied request IDs across both waves cover the whole flood exactly once.
        let allIDs = Set(immediate.map(\.requestID)).union(admitted.map(\.requestID))
        XCTAssertEqual(allIDs.count, total, "no request may be dropped or double-answered")
    }

    /// Slots must be REUSABLE: after a flood drains, fresh requests are admitted again (the
    /// counter decrements — the cap is in-flight, not lifetime).
    func testInFlightSlotsAreReleasedForLaterRequests() async {
        let session = makeSession()
        let cap = MuxChannelSession.maxMetadataInFlightForTesting

        session.suspendMetadataQueueForTesting()
        for i in 0..<cap {
            session.serveMetadataForTesting(requestID: UInt32(i), verb: unknownVerb, payload: Data())
        }
        XCTAssertEqual(session.metadataInFlightForTesting, cap, "precondition: the cap is reached")
        session.resumeMetadataQueueForTesting()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline, session.metadataInFlightForTesting > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.metadataInFlightForTesting, 0, "the drained flood released every slot")

        // A fresh request after the flood is served normally (not busy-rejected).
        _ = drainMetadataResponses(session)
        session.serveMetadataForTesting(requestID: 9999, verb: unknownVerb, payload: Data())
        let replyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        var replies: [(requestID: UInt32, status: UInt8, payload: Data)] = []
        while ContinuousClock.now < replyDeadline, replies.isEmpty {
            replies = drainMetadataResponses(session)
            if replies.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.requestID, 9999)
        XCTAssertEqual(
            replies.first?.status, MetadataStatus.unsupportedVerb.rawValue,
            "a post-flood request must be ADMITTED (served by the builder), not busy-rejected",
        )
    }
}
