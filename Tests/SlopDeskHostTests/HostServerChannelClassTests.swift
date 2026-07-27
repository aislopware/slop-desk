import Foundation
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskProtocol
@testable import SlopDeskTransport

/// `MuxChannelOpen.channelClass` decides what a channel IS, and a class this host does not serve
/// must open nothing at all.
///
/// ``MuxChannelClass`` documents exactly that — "an unknown class from a newer peer is refused with
/// `accepted: false`, never guessed at" — and the reason is concrete: every class that is not
/// explicitly routed falls into the PTY spawn path, which FORKS A SHELL. A peer one version ahead
/// asking for something this host has never heard of gets a login shell it never asked for, holding
/// a pty, a reaper thread and a scrollback journal, addressed by nobody.
///
/// Loopback over a REAL mux (the `WorkspaceChannelLoopbackTests` rig): a test that called the
/// handler directly would prove the handler works and say nothing about the ROUTING decision, which
/// is the part that can regress.
final class HostServerChannelClassTests: XCTestCase {
    private struct Rig {
        let server: HostServer
        let client: MuxNWConnection
        let host: MuxNWConnection
    }

    /// `/bin/cat` rather than the login shell: if the refusal regresses, this test forks whatever
    /// `shellPath` names, and an interactive zsh would read and rewrite the developer's real shell
    /// history. `cat` on a pty stays alive (so a leaked pane is VISIBLE to the assertion) and reads
    /// no startup files.
    private func makeRig() async -> Rig {
        let server = HostServer(port: 0, shellPath: "/bin/cat", workspaceDocEnabled: false)
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

    private func openClass(_ rig: Rig, _ channelClass: UInt8) async throws -> Bool {
        let pair = try await rig.client.openChannel(
            sessionID: UUID(),
            lastReceivedSeq: 0,
            channelClass: channelClass,
        )
        return await rig.client.awaitOpenAck(for: pair.data.channelID).accepted
    }

    /// A class from the future opens NOTHING — no ack, no pane, no shell.
    func testAnUnknownChannelClassOpensNoPane() async throws {
        let rig = await makeRig()
        let accepted = try await openClass(rig, 3)
        XCTAssertFalse(accepted, "class 3 is not a class this host serves")
        // `listPanesForControl` enumerates every pane across all three inventories — the same
        // invariant `testAWorkspaceOpenNeverForksAPTY` pins for the workspace class.
        XCTAssertTrue(
            rig.server.listPanesForControl().isEmpty,
            "an unserved class must never reach the PTY spawn path",
        )
        await rig.server.stop()
    }

    /// The far end of the byte range behaves the same way — 255 is not a lenient wildcard.
    func testTheMaximumChannelClassOpensNoPane() async throws {
        let rig = await makeRig()
        let accepted = try await openClass(rig, 255)
        XCTAssertFalse(accepted)
        XCTAssertTrue(rig.server.listPanesForControl().isEmpty)
        await rig.server.stop()
    }

    /// Class 2 (`paneObserver`) is a READ-ONLY view of a live pane, and this rig runs with
    /// `SLOPDESK_PANE_FANOUT` off — so it is refused exactly as an unknown class is, and forks
    /// nothing for a pane it was never going to be allowed to watch. The flag-ON route is
    /// `HostServerObserverRoutingTests`.
    func testTheObserverClassForksNothingWithTheFanoutOff() async throws {
        let rig = await makeRig()
        let accepted = try await openClass(rig, MuxChannelClass.paneObserver.rawValue)
        XCTAssertFalse(accepted, "the observer class is gated by SLOPDESK_PANE_FANOUT")
        XCTAssertTrue(rig.server.listPanesForControl().isEmpty)
        await rig.server.stop()
    }

    /// The control: class 0 still spawns a pane. A refusal that swallowed the ordinary case would
    /// pass every assertion above and break the product.
    func testThePaneClassStillOpensAPane() async throws {
        let rig = await makeRig()
        let accepted = try await openClass(rig, MuxChannelClass.pane.rawValue)
        XCTAssertTrue(accepted, "class 0 is the PTY channel")
        XCTAssertEqual(rig.server.listPanesForControl().count, 1)
        await rig.server.stop()
    }
}
