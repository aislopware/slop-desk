import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// The CLIENT half of ``MetadataVerb/hostVitals`` (verb 17 — the sidebar footer's host-pulse line):
/// an EMPTY request payload on verb byte 17, a typed decode of the 3-byte reply, and `nil` for every
/// non-answer (an old host's `.unsupportedVerb`, the host's "no reading yet" `.error`, a malformed
/// body, a dropped reply). Each behaviour has a test that FAILS on the un-fixed code:
/// - send the wrong verb byte / a payload → the verb+payload capture fails;
/// - decode without the `.ok` gate → the error/unsupported tests return a fabricated 0%;
/// - decode without `try?` → the malformed test crashes;
/// - drop the never-hangs timeout → the dropped-reply test hangs.
@MainActor
final class MetadataClientHostVitalsTests: XCTestCase {
    func testEncodesVerb17WithEmptyPayloadAndDecodesTheReply() async {
        let responder = HostVitalsResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.hostVitals.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: MetadataCodec.encodeHostVitals(
                .init(cpuPercent: 34, memoryPercent: 61, pressure: .warn, diskFreeMiB: 245_760),
            ),
        )

        let vitals = await client.hostVitals()

        XCTAssertEqual(
            vitals, .init(cpuPercent: 34, memoryPercent: 61, pressure: .warn, diskFreeMiB: 245_760),
        )
        XCTAssertEqual(responder.captured.map(\.verb), [MetadataVerb.hostVitals.rawValue])
        XCTAssertEqual(responder.captured.first?.payload, Data(), "the request is host-global — no argument")
    }

    func testNonOkStatusReturnsNilSoTheCallerKeepsItsLastReading() async {
        for status in [MetadataStatus.error, .unsupportedVerb, .notFound] {
            let responder = HostVitalsResponder()
            let client = MetadataClient(send: responder.send)
            responder.client = client
            responder.replies[MetadataVerb.hostVitals.rawValue] = (
                status: status.rawValue,
                payload: MetadataCodec.encodeHostVitals(.init(cpuPercent: 9, memoryPercent: 9, pressure: .normal)),
            )
            let vitals = await client.hostVitals()
            XCTAssertNil(vitals, "\(status): a non-ok reply is never read as a reading, even with a body")
        }
    }

    func testMalformedOkPayloadReturnsNilNeverThrows() async {
        let responder = HostVitalsResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.hostVitals.rawValue] = (
            status: MetadataStatus.ok.rawValue, payload: Data([0x01]),
        )
        let vitals = await client.hostVitals()
        XCTAssertNil(vitals)
    }

    func testDroppedReplyTimesOutToNil() async {
        let responder = HostVitalsResponder()
        responder.dropAll = true
        let client = MetadataClient(timeout: .milliseconds(50), send: responder.send)
        responder.client = client
        let vitals = await client.hostVitals()
        XCTAssertNil(vitals)
    }
}

/// Echoes canned replies keyed by verb byte on a later main-actor turn (mimicking the async wire —
/// the `AgentHooksResponder` idiom) and records what the client actually sent.
@MainActor
private final class HostVitalsResponder {
    weak var client: MetadataClient?
    var replies: [UInt8: (status: UInt8, payload: Data)] = [:]
    var dropAll = false
    private(set) var captured: [(requestID: UInt32, verb: UInt8, payload: Data)] = []

    func send(_ requestID: UInt32, _ verb: UInt8, _ payload: Data) {
        captured.append((requestID: requestID, verb: verb, payload: payload))
        guard !dropAll else { return }
        let reply = replies[verb] ?? (status: MetadataStatus.unsupportedVerb.rawValue, payload: Data())
        Task { @MainActor [weak self] in
            self?.client?.resolve(requestID: requestID, status: reply.status, payload: reply.payload)
        }
    }
}
