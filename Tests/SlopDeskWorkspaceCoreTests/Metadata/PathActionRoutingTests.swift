import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// The CLIENT half of the side-effecting host path verbs (``MetadataVerb/openPath`` = 9 /
/// ``MetadataVerb/revealPath`` = 10): ``MetadataClient/openPath(_:)`` / ``MetadataClient/revealPath(_:)``
/// must encode the right verb byte + the path as a RAW-UTF-8 request payload, and surface the host's
/// `ok`/`notFound`/`error` status as a `Bool` (true ONLY on `.ok`). Each behavior has a test that FAILS
/// on the un-fixed code:
/// - send the wrong verb byte → the verb-capture assertions fail (revert-to-confirm-fail);
/// - return `true` on a non-`.ok` status → the notFound/error/unknown tests fail;
/// - drop the never-hangs timeout → the dropped-reply test hangs.
///
/// The HOST shim (`HostPathActionPerformer`, `NSWorkspace`) is compiled + code-reviewed ONLY (the
/// hang-safety rule) — never instantiated here, exactly like `HostMetadataProbe`.
@MainActor
final class PathActionRoutingTests: XCTestCase {
    func testOpenPathEncodesVerb9AndRawUTF8PayloadAndSucceedsOnOk() async {
        let responder = PathActionResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        let path = "/Users/me/project/main.swift"
        responder.replies[MetadataVerb.openPath.rawValue] = (status: MetadataStatus.ok.rawValue, payload: Data())

        let ok = await client.openPath(path)

        XCTAssertTrue(ok, "an .ok host reply surfaces as true")
        XCTAssertEqual(responder.captured.map(\.verb), [MetadataVerb.openPath.rawValue], "openPath uses verb byte 9")
        XCTAssertEqual(responder.captured.first?.payload, Data(path.utf8), "the path is the raw-UTF-8 request payload")
    }

    func testRevealPathEncodesVerb10AndRawUTF8PayloadAndSucceedsOnOk() async {
        let responder = PathActionResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        let path = "/tmp/héllo 文字/x.txt"
        responder.replies[MetadataVerb.revealPath.rawValue] = (status: MetadataStatus.ok.rawValue, payload: Data())

        let ok = await client.revealPath(path)

        XCTAssertTrue(ok)
        XCTAssertEqual(
            responder.captured.map(\.verb), [MetadataVerb.revealPath.rawValue], "revealPath uses verb byte 10",
        )
        XCTAssertEqual(
            responder.captured.first?.payload, Data(path.utf8),
            "a multi-byte UTF-8 path round-trips verbatim in the payload",
        )
    }

    func testNotFoundStatusSurfacesAsFalse() async {
        let responder = PathActionResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.openPath.rawValue] = (status: MetadataStatus.notFound.rawValue, payload: Data())
        let ok = await client.openPath("/gone/file")
        XCTAssertFalse(ok, ".notFound (the path is gone) is false, never true")
    }

    func testErrorStatusSurfacesAsFalse() async {
        let responder = PathActionResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.revealPath.rawValue] = (status: MetadataStatus.error.rawValue, payload: Data())
        let ok = await client.revealPath("relative/path")
        XCTAssertFalse(ok, ".error surfaces as false")
    }

    func testUnknownStatusByteClampsToFalse() async {
        let responder = PathActionResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        // An unknown future status byte (99) clamps to .error client-side → false (forward-tolerant).
        responder.replies[MetadataVerb.openPath.rawValue] = (status: 99, payload: Data([0xFF]))
        let ok = await client.openPath("/x")
        XCTAssertFalse(ok, "an unknown status byte clamps to error → false (never trusts a non-ok reply)")
    }

    func testDroppedReplyTimesOutToFalseNeverHangs() async {
        // The host never replies → the registry's timeout resolves the façade to .error → false. A short
        // timeout keeps it fast; removing the never-hangs timeout would hang this test.
        let responder = PathActionResponder()
        responder.dropAll = true
        let client = MetadataClient(timeout: .milliseconds(50), send: responder.send)
        responder.client = client
        let ok = await client.openPath("/x")
        XCTAssertFalse(ok, "a dropped reply times out to false — the action never hangs the UI")
    }
}

// MARK: - Fake

/// A fake `send` seam for ``MetadataClient`` that records each request and ECHOES a canned reply per
/// verb on a later main-actor turn (mimicking the async wire — the real reply arrives via the inbound
/// pump after `send` returns and the façade has parked its continuation).
@MainActor
private final class PathActionResponder {
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
