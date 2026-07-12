import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// The CLIENT half of the agent-hooks host verbs (``MetadataVerb/installAgentHooks`` = 11 /
/// ``MetadataVerb/uninstallAgentHooks`` = 12 / ``MetadataVerb/agentHookStatus`` = 13): the typed
/// ``MetadataClient`` methods must encode the right verb byte with an EMPTY request payload, surface the
/// host's `ok`/`error` status as a `Bool` (true ONLY on `.ok`) for install/uninstall, and decode the
/// 2-byte `[installed][listenerActive]` flags for `agentHookStatus` (a missing/short payload beyond
/// byte 0 conservatively reads listener-INACTIVE, an absent byte 0 ⇒ `nil`). Each behavior has a test
/// that FAILS on the un-fixed code:
/// - send the wrong verb byte / a non-empty payload → the verb/payload-capture assertions fail;
/// - return `true` on a non-`.ok` status → the error/unsupported tests fail;
/// - decode the flags without the `payload.first`/`status == .ok` gate → the nil / 0-byte tests fail;
/// - conflate installed with listener-active (the false-green bug) → the [1,0] / 1-byte tests fail;
/// - drop the never-hangs timeout → the dropped-reply test hangs.
///
/// The HOST shim (`HostAgentActionPerformer`, disk I/O) is compiled + code-reviewed ONLY (the hang/IO-safety
/// rule) — never instantiated here, exactly like `HostPathActionPerformer`.
@MainActor
final class MetadataClientAgentHooksTests: XCTestCase {
    func testInstallEncodesVerb11AndEmptyPayloadAndSucceedsOnOk() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.installAgentHooks.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: Data(),
        )

        let ok = await client.installAgentHooks()

        XCTAssertTrue(ok, "an .ok host reply surfaces as true")
        XCTAssertEqual(
            responder.captured.map(\.verb), [MetadataVerb.installAgentHooks.rawValue], "install uses verb byte 11",
        )
        XCTAssertEqual(responder.captured.first?.payload, Data(), "the install request carries an EMPTY payload")
    }

    func testUninstallEncodesVerb12AndEmptyPayloadAndSucceedsOnOk() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.uninstallAgentHooks.rawValue] = (
            status: MetadataStatus.ok.rawValue,
            payload: Data(),
        )

        let ok = await client.uninstallAgentHooks()

        XCTAssertTrue(ok)
        XCTAssertEqual(
            responder.captured.map(\.verb), [MetadataVerb.uninstallAgentHooks.rawValue], "uninstall uses verb byte 12",
        )
        XCTAssertEqual(responder.captured.first?.payload, Data(), "the uninstall request carries an EMPTY payload")
    }

    func testInstallErrorStatusSurfacesAsFalse() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.installAgentHooks.rawValue] =
            (status: MetadataStatus.error.rawValue, payload: Data())
        let ok = await client.installAgentHooks()
        XCTAssertFalse(ok, ".error (the install threw) surfaces as false, never true")
    }

    func testUninstallUnsupportedVerbSurfacesAsFalse() async {
        // A host that does not know verb 12 answers unsupportedVerb (the default fake reply) → false.
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        let ok = await client.uninstallAgentHooks()
        XCTAssertFalse(ok, "an unsupportedVerb reply surfaces as false")
    }

    func testStatusEncodesVerb13AndEmptyPayload() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.agentHookStatus.rawValue] =
            (status: MetadataStatus.ok.rawValue, payload: Data([1, 1]))

        _ = await client.agentHookStatus()

        XCTAssertEqual(
            responder.captured.map(\.verb), [MetadataVerb.agentHookStatus.rawValue], "status uses verb byte 13",
        )
        XCTAssertEqual(responder.captured.first?.payload, Data(), "the status request carries an EMPTY payload")
    }

    func testStatusInstalledActiveFlagsDecode() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.agentHookStatus.rawValue] =
            (status: MetadataStatus.ok.rawValue, payload: Data([1, 1]))
        let report = await client.agentHookStatus()
        XCTAssertEqual(
            report, .init(installed: true, listenerActive: true),
            "[1,1] decodes installed + listener live — the ONLY combination that earns the green check",
        )
    }

    /// Installed-but-INACTIVE — the false-green bug. The hooks are
    /// in settings.json but the host's hook listener is unbound; the second flag byte carries that
    /// truth so the card can warn instead of showing "✓ Installed" over a dead integration.
    func testStatusInstalledButListenerInactiveDecodes() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.agentHookStatus.rawValue] =
            (status: MetadataStatus.ok.rawValue, payload: Data([1, 0]))
        let report = await client.agentHookStatus()
        XCTAssertEqual(
            report, .init(installed: true, listenerActive: false),
            "[1,0] decodes installed with the listener DOWN — never conflated with active",
        )
    }

    func testStatusNotInstalledFlagDecodes() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.agentHookStatus.rawValue] =
            (status: MetadataStatus.ok.rawValue, payload: Data([0, 0]))
        let report = await client.agentHookStatus()
        XCTAssertEqual(
            report, .init(installed: false, listenerActive: false),
            "a 0 install flag decodes to installed == false (NOT nil)",
        )
    }

    /// A 1-byte reply (no listener flag) decodes CONSERVATIVELY: installed, listener NOT active —
    /// the missing byte must never read as a live listener (never a false green).
    func testStatusMissingListenerByteDecodesAsInactive() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.agentHookStatus.rawValue] =
            (status: MetadataStatus.ok.rawValue, payload: Data([1]))
        let report = await client.agentHookStatus()
        XCTAssertEqual(
            report, .init(installed: true, listenerActive: false),
            "a missing second byte is conservative: NOT listener-active",
        )
    }

    func testStatusEmptyPayloadDecodesToNil() async {
        // status .ok but NO flag byte → nil (status-unknown), never a false "not installed".
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        responder.replies[MetadataVerb.agentHookStatus.rawValue] =
            (status: MetadataStatus.ok.rawValue, payload: Data())
        let report = await client.agentHookStatus()
        XCTAssertNil(report, "an ok reply with an EMPTY payload is status-unknown → nil")
    }

    func testStatusNonOkStatusDecodesToNil() async {
        let responder = AgentHooksResponder()
        let client = MetadataClient(send: responder.send)
        responder.client = client
        // Even with stray flag bytes, a non-ok status is status-unknown → nil (never trusts the payload).
        responder.replies[MetadataVerb.agentHookStatus.rawValue] =
            (status: MetadataStatus.error.rawValue, payload: Data([1, 1]))
        let report = await client.agentHookStatus()
        XCTAssertNil(report, "a non-ok status is nil regardless of any payload bytes")
    }

    func testInstallDroppedReplyTimesOutToFalseNeverHangs() async {
        let responder = AgentHooksResponder()
        responder.dropAll = true
        let client = MetadataClient(timeout: .milliseconds(50), send: responder.send)
        responder.client = client
        let ok = await client.installAgentHooks()
        XCTAssertFalse(ok, "a dropped reply times out to false — the action never hangs the card")
    }

    func testStatusDroppedReplyTimesOutToNilNeverHangs() async {
        let responder = AgentHooksResponder()
        responder.dropAll = true
        let client = MetadataClient(timeout: .milliseconds(50), send: responder.send)
        responder.client = client
        let report = await client.agentHookStatus()
        XCTAssertNil(report, "a dropped status reply times out to nil (status-unknown), never hangs")
    }
}

// MARK: - Fake

/// A fake `send` seam for ``MetadataClient`` that records each request and ECHOES a canned reply per
/// verb on a later main-actor turn (mimicking the async wire). Mirrors `PathActionResponder`.
@MainActor
private final class AgentHooksResponder {
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
