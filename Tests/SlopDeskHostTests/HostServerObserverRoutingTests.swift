import Foundation
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskProtocol
@testable import SlopDeskTransport

/// `channelClass == 2` opens a READ-ONLY view of a pane somebody else is already holding
/// (docs/45 §8.4) — and opens nothing at all when `SLOPDESK_PANE_FANOUT` is off.
///
/// Loopback over a REAL mux (the `HostServerChannelClassTests` rig): the thing under test is the
/// ROUTING decision, which a direct handler call would step straight over.
///
/// `/bin/cat` rather than the login shell: if the refusal regresses, this test forks whatever
/// `shellPath` names, and an interactive zsh would read and rewrite the developer's real shell
/// history. `cat` stays alive on a pty, so a leaked pane is VISIBLE to the assertion.
final class HostServerObserverRoutingTests: XCTestCase {
    private struct Rig {
        let server: HostServer
        let client: MuxNWConnection
        let host: MuxNWConnection
    }

    private func makeRig(fanout: Bool) async -> Rig {
        let server = HostServer(
            port: 0,
            shellPath: "/bin/cat",
            workspaceDocEnabled: false,
            paneFanoutEnabled: fanout,
        )
        let (clientControl, hostControl) = LoopbackMuxLink.pair()
        let (clientData, hostData) = LoopbackMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let connectionID = host.connectionID
        await host.setHostOpenHandler { [weak server] open in
            server?.spawnMuxChannelForTesting(open, on: host, connectionID: connectionID)
        }
        await host.start()
        await client.start()
        return Rig(server: server, client: client, host: host)
    }

    @discardableResult
    private func open(
        _ rig: Rig,
        sessionID: UUID,
        channelClass: UInt8,
    ) async throws -> (accepted: Bool, channelID: UInt32) {
        let pair = try await rig.client.openChannel(
            sessionID: sessionID,
            lastReceivedSeq: 0,
            channelClass: channelClass,
        )
        let verdict = await rig.client.awaitOpenAck(for: pair.data.channelID)
        return (verdict.accepted, pair.data.channelID)
    }

    // MARK: - Flag OFF: the shipping path is untouched

    /// The flag is the whole safety story for the riskiest phase in the plan. With it unset, class 2
    /// is refused exactly as an unrouted class is — mirroring `openWorkspaceChannel`'s own flag-off
    /// refusal — so no observer subscriber can exist on the shipping path.
    func testAnObserverIsRefusedWhenFanoutIsOff() async throws {
        let rig = await makeRig(fanout: false)
        let live = UUID()
        let pane = try await open(rig, sessionID: live, channelClass: MuxChannelClass.pane.rawValue)
        XCTAssertTrue(pane.accepted, "precondition: the pane itself opens")

        let observer = try await open(rig, sessionID: live, channelClass: MuxChannelClass.paneObserver.rawValue)
        XCTAssertFalse(observer.accepted, "the observer class is gated by SLOPDESK_PANE_FANOUT")
        XCTAssertEqual(
            rig.server.listPanesForControl().count, 1,
            "a refused observer forks nothing — the one pane is the one that opened",
        )
        await rig.server.stop()
    }

    // MARK: - Flag ON: a read-only view of a live pane

    /// The point of the class: a second client watches a pane it may not type into. It joins the
    /// EXISTING session — one PTY, two subscribers — rather than forking a second shell.
    func testAnObserverJoinsALivePaneWithoutForkingASecondShell() async throws {
        let rig = await makeRig(fanout: true)
        let live = UUID()
        let pane = try await open(rig, sessionID: live, channelClass: MuxChannelClass.pane.rawValue)
        XCTAssertTrue(pane.accepted)
        let session = try XCTUnwrap(
            rig.server.listPanesForControl().first,
            "precondition: the pane is live",
        )
        XCTAssertEqual(session.paneId, live.uuidString)

        let observer = try await open(rig, sessionID: live, channelClass: MuxChannelClass.paneObserver.rawValue)
        XCTAssertTrue(observer.accepted, "a live pane accepts a read-only watcher")
        XCTAssertEqual(
            rig.server.listPanesForControl().count, 1,
            "ONE pane, two channels — an observer never spawns a PTY",
        )
        await rig.server.stop()
    }

    /// An observer of NOTHING is refused rather than served a fresh shell. The class means "watch
    /// that pane"; with no such pane the only answers are a refusal or a login shell nobody asked
    /// for, and the second is how `channelClass` routing broke before it was gated at all.
    func testAnObserverOfAnUnknownSessionForksNothing() async throws {
        let rig = await makeRig(fanout: true)
        let accepted = try await open(
            rig,
            sessionID: UUID(),
            channelClass: MuxChannelClass.paneObserver.rawValue,
        ).accepted
        XCTAssertFalse(accepted, "there is nothing to observe")
        XCTAssertTrue(
            rig.server.listPanesForControl().isEmpty,
            "and no shell was forked to give it something",
        )
        await rig.server.stop()
    }

    /// A class from the future stays refused with the fan-out ON: widening the accepted set to
    /// {0, 1, 2} must not turn the guard into a wildcard.
    func testAnUnknownClassIsStillRefusedWithFanoutOn() async throws {
        let rig = await makeRig(fanout: true)
        let accepted = try await open(rig, sessionID: UUID(), channelClass: 3).accepted
        XCTAssertFalse(accepted)
        XCTAssertTrue(rig.server.listPanesForControl().isEmpty)
        await rig.server.stop()
    }
}
