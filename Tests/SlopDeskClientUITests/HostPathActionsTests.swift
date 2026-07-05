import SlopDeskProtocol
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

/// E10 WI-7 (ES-E10-2 / ES-E10-6) — the FINAL client connection between the pane model's host path callbacks
/// (`onRequestOpenHostPath` / `onRequestRevealHostPath`, fired by the renderer ⌘click / ⌘⇧click, the Jump-To
/// open/reveal, and the Hint-to-open/reveal actuator) and the pane's ``MetadataClient`` (verb 9 `openPath` /
/// verb 10 `revealPath`). Before this wiring the two callbacks were NEVER assigned, so every host open/reveal
/// on a detected PATH was a silent no-op — these tests pin the wiring so a regression that drops it FAILS:
/// - `wire` leaves the callbacks non-nil and firing them round-trips to the client with the right verb + path;
/// - a non-`.ok` host status surfaces a `false` result (so the caller can toast it, not swallow it);
/// - `clear` nils both callbacks (teardown can't drive a dead leaf).
@MainActor
final class HostPathActionsTests: XCTestCase {
    func testWireRoutesOpenToVerb9WithRawPathAndReportsSuccess() async {
        let model = TerminalViewModel()
        let responder = PathActionResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        let path = "/Users/me/project/main.swift"
        responder.replies[MetadataVerb.openPath.rawValue] = (MetadataStatus.ok.rawValue, Data())

        let reported = expectation(description: "open result reported")
        var result: (action: HostPathActions.Action, path: String, ok: Bool)?
        HostPathActions.wire(model: model, client: { client }, onResult: { action, p, ok in
            result = (action, p, ok)
            reported.fulfill()
        })

        // The callback the renderer fires must now be live (it was nil before the wiring landed).
        XCTAssertNotNil(model.onRequestOpenHostPath, "wire assigns the host-open callback the renderer fires")
        model.onRequestOpenHostPath?(path)
        await fulfillment(of: [reported], timeout: 2)

        XCTAssertEqual(responder.captured.map(\.verb), [MetadataVerb.openPath.rawValue], "open uses verb 9")
        XCTAssertEqual(responder.captured.first?.payload, Data(path.utf8), "the resolved path is the raw payload")
        XCTAssertEqual(result?.action, .open)
        XCTAssertEqual(result?.path, path)
        XCTAssertEqual(result?.ok, true, "an .ok host reply reports success")
    }

    func testWireRoutesRevealToVerb10() async {
        let model = TerminalViewModel()
        let responder = PathActionResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        let path = "/tmp/héllo 文字/x.txt"
        responder.replies[MetadataVerb.revealPath.rawValue] = (MetadataStatus.ok.rawValue, Data())

        let reported = expectation(description: "reveal result reported")
        HostPathActions.wire(model: model, client: { client }, onResult: { _, _, _ in reported.fulfill() })

        XCTAssertNotNil(model.onRequestRevealHostPath, "wire assigns the host-reveal callback")
        model.onRequestRevealHostPath?(path)
        await fulfillment(of: [reported], timeout: 2)

        XCTAssertEqual(responder.captured.map(\.verb), [MetadataVerb.revealPath.rawValue], "reveal uses verb 10")
        XCTAssertEqual(responder.captured.first?.payload, Data(path.utf8), "a multi-byte path round-trips verbatim")
    }

    func testNotFoundHostStatusReportsFailureSoItCanBeSurfaced() async {
        let model = TerminalViewModel()
        let responder = PathActionResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.openPath.rawValue] = (MetadataStatus.notFound.rawValue, Data())

        let reported = expectation(description: "failure reported")
        var reportedOk = true
        HostPathActions.wire(model: model, client: { client }, onResult: { _, _, ok in
            reportedOk = ok
            reported.fulfill()
        })
        model.onRequestOpenHostPath?("/gone/file")
        await fulfillment(of: [reported], timeout: 2)

        XCTAssertFalse(reportedOk, ".notFound reports a failure (so the leaf can toast it, never a silent no-op)")
    }

    func testClearNilsBothCallbacks() {
        let model = TerminalViewModel()
        let client = MetadataClient(send: { _, _, _ in })
        HostPathActions.wire(model: model, client: { client })
        XCTAssertNotNil(model.onRequestOpenHostPath)
        XCTAssertNotNil(model.onRequestRevealHostPath)

        HostPathActions.clear(model: model)
        XCTAssertNil(model.onRequestOpenHostPath, "clear nils the host-open callback on teardown")
        XCTAssertNil(model.onRequestRevealHostPath, "clear nils the host-reveal callback on teardown")
    }

    func testNoLiveClientReportsFailureNeverHangs() async {
        let model = TerminalViewModel()
        let reported = expectation(description: "no-client result reported")
        var reportedOk = true
        // A disconnected pane has no metadata client → the action must report failure, never hang.
        HostPathActions.wire(model: model, client: { nil }, onResult: { _, _, ok in
            reportedOk = ok
            reported.fulfill()
        })
        model.onRequestOpenHostPath?("/x")
        await fulfillment(of: [reported], timeout: 2)
        XCTAssertFalse(reportedOk, "no live client (disconnected) reports failure")
    }
}

// MARK: - Fake

/// A fake `send` seam for ``MetadataClient`` that records each request and ECHOES a canned reply per verb on a
/// later main-actor turn (mirrors the async wire — the reply arrives via the inbound pump after `send`
/// returns and the façade has parked its continuation). Mirrors the WorkspaceCore `PathActionResponder`.
@MainActor
private final class PathActionResponder {
    weak var client: MetadataClient?
    var replies: [UInt8: (status: UInt8, payload: Data)] = [:]
    private(set) var captured: [(requestID: UInt32, verb: UInt8, payload: Data)] = []

    func send(_ requestID: UInt32, _ verb: UInt8, _ payload: Data) {
        captured.append((requestID: requestID, verb: verb, payload: payload))
        let reply = replies[verb] ?? (MetadataStatus.unsupportedVerb.rawValue, Data())
        Task { @MainActor [weak self] in
            self?.client?.resolve(requestID: requestID, status: reply.status, payload: reply.payload)
        }
    }
}
