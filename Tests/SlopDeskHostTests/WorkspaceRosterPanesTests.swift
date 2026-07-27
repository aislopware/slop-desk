import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskHost

/// The roster's PANE half: what grid the fold resolved for each pane, and who is holding it there.
///
/// Two facts the design leans on and this pins. First, the join from a pane to a human-readable
/// device runs `MuxSessionKey.connectionID → workspaceChannels[connectionID].clientInstanceID`, and
/// it legitimately MISSES — `slopdesk-client` opens no workspace channel — so an unlabelled
/// attachment must still be published and must still COUNT. Second, size-passivity is decided
/// HOST-side from the workspace channel's `clientKind`, because `MuxChannelOpen` carries no client
/// kind and a client-side rule would be defeated by any build that predates it.
///
/// Headless throughout: unspawned `PTYProcess` (masterFD −1, no reaper thread), no server `start()`.
///
/// Records the rosters the document fans, so the pane half can be decoded off the wire form rather
/// than read out of a property that never proves it encodes.
private final class RosterRecordingChannel: MessageChannel, @unchecked Sendable {
    let channel: Channel = .control
    private let lock = NSLock()
    private var _sent: [WireMessage] = []

    var rosters: [WorkspacePresenceRoster] {
        lock.lock()
        let sent = _sent
        lock.unlock()
        return sent.compactMap {
            guard case let .workspaceEvent(kind, _, _, _, payload) = $0,
                  kind == WorkspaceEventKind.presence.rawValue
            else { return nil }
            return try? WorkspacePresenceRoster.decode(payload)
        }
    }

    var inbound: AsyncThrowingStream<WireMessage, Error> { AsyncThrowingStream { $0.finish() } }

    /// Synchronous so the lock is never held across a suspension.
    private func record(_ message: WireMessage) {
        lock.lock()
        _sent.append(message)
        lock.unlock()
    }

    func send(_ message: WireMessage) async {
        await Task.yield()
        record(message)
    }
}

final class WorkspaceRosterPanesTests: XCTestCase {
    private func makeSession(sessionID: UUID) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned: no PTY, no read loop
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            sessionID: sessionID,
        )
    }

    private func registerWorkspaceChannel(
        on server: HostServer,
        connectionID: UUID,
        clientInstanceID: UUID,
        clientKind: UInt8,
    ) {
        _ = server.registerWorkspaceChannel(connectionID: connectionID) {
            WorkspaceChannelSession(
                channel: RosterRecordingChannel(),
                subscribe: WorkspaceSubscribe(clientInstanceID: clientInstanceID, clientKind: clientKind),
            )
        }
    }

    // MARK: - Size-passivity is a HOST verdict

    /// The fallback that keeps the CLI working. A pane channel with no workspace channel behind it is
    /// `slopdesk-client` (and every `SLOPDESK_WORKSPACE_DOC=0` client); defaulting it to passive would
    /// leave it unable to size its own pane, and would take the two-subscriber E2E gate with it.
    func testAPaneWithNoWorkspaceChannelContributes() {
        let server = HostServer(port: 0, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }
        XCTAssertFalse(
            server.sizePassiveForConnection(UUID()),
            "no workspace channel means CONTRIBUTES, never silently passive",
        )
    }

    func testAnIOSClientIsSizePassiveAndAMacIsNot() {
        let server = HostServer(port: 0, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let phone = UUID()
        let mac = UUID()
        registerWorkspaceChannel(
            on: server, connectionID: phone, clientInstanceID: UUID(),
            clientKind: WorkspaceClientKind.iOS.rawValue,
        )
        registerWorkspaceChannel(
            on: server, connectionID: mac, clientInstanceID: UUID(),
            clientKind: WorkspaceClientKind.macOS.rawValue,
        )

        XCTAssertTrue(server.sizePassiveForConnection(phone), "a phone must never crush a Mac")
        XCTAssertFalse(server.sizePassiveForConnection(mac))
    }

    /// A pane channel and the workspace channel are announced independently on one connection, so a
    /// client that opens its panes BEFORE it subscribes resolves them against a workspace channel
    /// that does not exist yet. The subscribe is the edge that settles it.
    func testASubscribeReresolvesPassivityForPanesOpenedFirst() {
        let server = HostServer(port: 0, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let connectionID = UUID()
        let session = makeSession(sessionID: UUID())
        session.addResizeContributor(sizePassive: server.sizePassiveForConnection(connectionID))
        server.registerMuxSessionForTesting(session, key: MuxSessionKey(connectionID: connectionID, channelID: 1))
        XCTAssertEqual(
            session.resizeContributionsForWorkspace.first?.contributes, true,
            "opened before the subscribe: resolved against nothing, so it contributes",
        )

        registerWorkspaceChannel(
            on: server, connectionID: connectionID, clientInstanceID: UUID(),
            clientKind: WorkspaceClientKind.iOS.rawValue,
        )
        server.reresolveSizePassivity(connectionID: connectionID)

        XCTAssertEqual(
            session.resizeContributionsForWorkspace.first?.contributes, false,
            "the subscribe named the device, and the fold's predicate follows it",
        )
    }

    // MARK: - The published record

    func testTheRosterNamesTheResolvedGridAndTheDeviceHoldingIt() {
        let server = HostServer(port: 0, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let connectionID = UUID()
        let clientInstanceID = UUID()
        let paneID = UUID()
        registerWorkspaceChannel(
            on: server, connectionID: connectionID, clientInstanceID: clientInstanceID,
            clientKind: WorkspaceClientKind.macOS.rawValue,
        )
        let session = makeSession(sessionID: paneID)
        session.addResizeContributor(sizePassive: false)
        session.scheduleResize(cols: 120, rows: 40, px: 0, py: 0)
        session.applyResolvedGrid()
        server.registerMuxSessionForTesting(session, key: MuxSessionKey(connectionID: connectionID, channelID: 1))

        let records = server.paneRosterRecords()
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.paneID, paneID)
        XCTAssertEqual(record.resolvedCols, 120)
        XCTAssertEqual(record.resolvedRows, 40)
        XCTAssertEqual(record.attachments.count, 1)
        XCTAssertEqual(
            record.attachments.first?.clientInstanceID, clientInstanceID,
            "the pane joins to its device through the connection they share",
        )
        XCTAssertEqual(record.attachments.first?.contributes, true)
        XCTAssertEqual(record.attachments.first?.cols, 120, "the attachment carries what IT offered")
    }

    /// The join misses for `slopdesk-client`, which opens no workspace channel. Dropping the
    /// attachment there would publish a pane that a client is demonstrably holding as unheld.
    func testAnUnlabelledAttachmentIsStillPublished() {
        let server = HostServer(port: 0, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let session = makeSession(sessionID: UUID())
        session.addResizeContributor(sizePassive: false)
        session.scheduleResize(cols: 100, rows: 30, px: 0, py: 0)
        session.applyResolvedGrid()
        server.registerMuxSessionForTesting(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1))

        let attachment = try? XCTUnwrap(server.paneRosterRecords().first?.attachments.first)
        XCTAssertEqual(
            attachment?.clientInstanceID, WireMessage.newSessionID,
            "unlabelled, not absent — the all-zero id says 'a client we cannot name'",
        )
        XCTAssertEqual(attachment?.contributes, true, "…and it still votes in the fold")
    }

    /// `broadcastRoster()` fans the pane half to every subscriber, encoded. The literal empty array
    /// it used to publish made the whole `WorkspaceRosterPane` codec dead weight on the wire.
    func testBroadcastRosterCarriesThePanesToEverySubscriber() async {
        let document = HostWorkspaceDocument(onLog: nil)
        let paneID = UUID()
        let holder = UUID()
        await document.setPaneRoster {
            [WorkspaceRosterPane(
                paneID: paneID,
                resolvedCols: 120,
                resolvedRows: 40,
                attachments: [.init(clientInstanceID: holder, contributes: true, cols: 120, rows: 40)],
            )]
        }
        let channel = RosterRecordingChannel()
        let subscriber = WorkspaceChannelSession(
            channel: channel,
            subscribe: WorkspaceSubscribe(clientInstanceID: UUID(), clientKind: 0),
        )
        await document.addSubscriber(subscriber)

        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, channel.rosters.last?.panes.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let panes = channel.rosters.last?.panes ?? []
        XCTAssertEqual(panes.count, 1, "the pane half reached the wire")
        XCTAssertEqual(panes.first?.paneID, paneID)
        XCTAssertEqual(panes.first?.resolvedCols, 120)
        XCTAssertEqual(panes.first?.attachments.first?.clientInstanceID, holder)
        subscriber.close()
    }
}
