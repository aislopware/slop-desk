import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

/// The host-authoritative `resumeFromSeq` on `channelOpenAck` (docs/20 §8.2) — client-side
/// observation via ``MuxNWConnection/awaitOpenAck(for:)``.
final class MuxOpenAckResumeTests: XCTestCase {
    private func makeClient() async -> (client: MuxNWConnection, peerData: InMemoryMuxLink) {
        let (peerControl, clientControl) = InMemoryMuxLink.pair()
        let (peerData, clientData) = InMemoryMuxLink.pair()
        _ = peerControl
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        await client.start()
        return (client, peerData)
    }

    /// Ack arrives BEFORE the await (routed while the caller was elsewhere): the recorded
    /// verdict is returned immediately.
    func testVerdictRecordedBeforeAwaitIsDelivered() async throws {
        let (client, peerData) = try await makeClient()
        _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 7)
        try await peerData.send(MuxEnvelopeCodec.encode(
            .channelOpenAck(channelID: 1, accepted: true, resumeFromSeq: 7),
        ))
        try await Task.sleep(for: .milliseconds(100)) // let the receive loop route it
        let verdict = await client.awaitOpenAck(for: 1)
        XCTAssertTrue(verdict.accepted)
        XCTAssertEqual(verdict.resumeFromSeq, 7, "host-authoritative resume verdict")
    }

    /// Await parked BEFORE the ack arrives: the routed ack resumes it.
    func testParkedWaiterResumesOnAckArrival() async throws {
        let (client, peerData) = try await makeClient()
        _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 9)
        let waiter = Task { await client.awaitOpenAck(for: 1) }
        try await Task.sleep(for: .milliseconds(50))
        try await peerData.send(MuxEnvelopeCodec.encode(
            .channelOpenAck(channelID: 1, accepted: true, resumeFromSeq: 9),
        ))
        let verdict = await waiter.value
        XCTAssertTrue(verdict.accepted)
        XCTAssertEqual(verdict.resumeFromSeq, 9)
    }

    /// A refusal resolves the waiter `(false, 0)` — the transport's connect throws and the
    /// ReconnectManager retries, exactly the dead-channel outcome the refusal already meant.
    func testRefusalResolvesWaiterAsRefused() async throws {
        let (client, peerData) = try await makeClient()
        _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let waiter = Task { await client.awaitOpenAck(for: 1) }
        try await Task.sleep(for: .milliseconds(50))
        try await peerData.send(MuxEnvelopeCodec.encode(
            .channelOpenAck(channelID: 1, accepted: false, resumeFromSeq: 0),
        ))
        let verdict = await waiter.value
        XCTAssertFalse(verdict.accepted)
        XCTAssertEqual(verdict.resumeFromSeq, 0)
    }

    /// Cancellation (the connect timeout race losing) resumes the waiter immediately with
    /// `(false, 0)` — no stranded continuation, no hang.
    func testCancelledWaiterResumesImmediately() async throws {
        let (client, _) = try await makeClient()
        _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let waiter = Task { await client.awaitOpenAck(for: 1) }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let verdict = await waiter.value
        XCTAssertFalse(verdict.accepted)
    }

    /// An ack for an id this side never opened is ignored (phantom-entry discipline) — a
    /// waiter on an unknown id resolves refused instead of parking forever.
    func testUnknownIDResolvesRefusedWithoutParking() async throws {
        let (client, _) = try await makeClient()
        let verdict = await client.awaitOpenAck(for: 99)
        XCTAssertFalse(verdict.accepted)
    }

    // MARK: Wire format

    /// The pre-resume 1-byte ack body still decodes (`resumeFromSeq` reads as 0) — the
    /// `channelOpen` optional-cwd discipline.
    func testLegacyOneByteAckBodyDecodes() throws {
        var inner = Data([0, 0, 0, 3]) // channelID BE
        inner.append(MuxFrameType.channelOpenAck.rawValue)
        inner.append(1) // accepted, no resumeFromSeq field
        let frame = try MuxEnvelopeCodec.decode(inner: inner)
        XCTAssertEqual(frame, .channelOpenAck(channelID: 3, accepted: true, resumeFromSeq: 0))
    }

    func testAckRoundTripCarriesResumeFromSeq() throws {
        let frame = MuxFrame.channelOpenAck(channelID: 7, accepted: true, resumeFromSeq: 42)
        let encoded = MuxEnvelopeCodec.encode(frame)
        let decoded = try MuxEnvelopeCodec.decode(inner: encoded.dropFirst(4))
        XCTAssertEqual(decoded, frame)
    }

    func testAckTrailingGarbageIsRejected() {
        var inner = Data([0, 0, 0, 3]) // channelID BE
        inner.append(MuxFrameType.channelOpenAck.rawValue)
        inner.append(1)
        inner.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 5]) // resumeFromSeq BE
        inner.append(0xFF) // trailing junk past the resumeFromSeq field
        XCTAssertThrowsError(try MuxEnvelopeCodec.decode(inner: inner))
    }
}
