import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskHost

/// Presence — who is here and what each of them is looking at.
///
/// The rules that bite are all about IDENTITY and ORDER. Presence is keyed by the client's own
/// instance id rather than the subscriber id, so two windows of one app are two entries and not one
/// overwriting the other; it is newest-wins with no merge, so a client reconnecting with a stale
/// clock cannot resurrect a view it has since left; and it never touches `stateNum`, because a frame
/// that advanced it would make the host retire — via `assumedAcked` — a diff it never sent.
private final class RecordingChannel: MessageChannel, @unchecked Sendable {
    let channel: Channel = .control

    private let lock = NSLock()
    private var _sent: [WireMessage] = []

    var sent: [WireMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    /// Every roster the host has fanned to this client, decoded.
    var rosters: [WorkspacePresenceRoster] {
        sent.compactMap {
            guard case let .workspaceEvent(kind, _, _, _, payload) = $0,
                  kind == WorkspaceEventKind.presence.rawValue
            else { return nil }
            return try? WorkspacePresenceRoster.decode(payload)
        }
    }

    var inbound: AsyncThrowingStream<WireMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

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

private func expect(
    _ predicate: @Sendable () -> Bool,
    _ what: String = "condition",
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    if !predicate() { XCTFail("timed out waiting for \(what)", file: file, line: line) }
}

final class WorkspacePresenceTests: XCTestCase {
    private let paneA = UUID(uuidString: "5D05DE5C-0000-4000-8000-0000000000A1")!
    private let paneB = UUID(uuidString: "5D05DE5C-0000-4000-8000-0000000000B2")!
    private let tab = UUID(uuidString: "5D05DE5C-0000-4000-8000-00000000CAB1")!

    private func update(
        clock: Int64, pane: UUID, tab: UUID? = nil, cols: UInt16 = 0, rows: UInt16 = 0,
    ) -> WorkspacePresenceUpdate {
        WorkspacePresenceUpdate(
            presenceClock: clock,
            viewingTabID: tab ?? self.tab,
            viewingPaneID: pane,
            cols: cols,
            rows: rows,
            flags: 0,
        )
    }

    private func makeSession(
        _ channel: RecordingChannel, instance: UUID = UUID(), label: String = "mac-studio",
    ) -> WorkspaceChannelSession {
        WorkspaceChannelSession(
            channel: channel,
            subscribe: WorkspaceSubscribe(clientInstanceID: instance, clientKind: 0, label: label),
        )
    }

    // MARK: - Clock ordering

    /// Newest wins with NO merge. A client reconnecting with a stale clock — its own counter reset,
    /// or a frame that overtook another on a different path — must not resurrect a view it has left.
    func testAStaleClockIsRefusedAndChangesNothing() {
        let session = makeSession(RecordingChannel())

        XCTAssertTrue(session.note(presence: update(clock: 5, pane: paneA)))
        XCTAssertEqual(session.rosterRecord().viewingPaneID, paneA)

        XCTAssertFalse(
            session.note(presence: update(clock: 4, pane: paneB)),
            "an older clock is refused",
        )
        XCTAssertEqual(session.rosterRecord().viewingPaneID, paneA, "…and leaves the view standing")

        XCTAssertFalse(
            session.note(presence: update(clock: 5, pane: paneB)),
            "so is a repeat of the same clock — newest means strictly newer",
        )
        XCTAssertEqual(session.rosterRecord().viewingPaneID, paneA)

        XCTAssertTrue(session.note(presence: update(clock: 6, pane: paneB)))
        XCTAssertEqual(session.rosterRecord().viewingPaneID, paneB)
        session.close()
    }

    /// A client that has said nothing yet is IN the roster — it subscribed — but viewing nothing.
    /// The zero UUID is that "none", and it must not read as a pane.
    func testASilentSubscriberViewsNothing() {
        let session = makeSession(RecordingChannel())
        let record = session.rosterRecord()

        XCTAssertEqual(record.viewingPaneID, WireMessage.newSessionID)
        XCTAssertEqual(record.viewingTabID, WireMessage.newSessionID)
        XCTAssertEqual(record.cols, 0)
        XCTAssertEqual(record.rows, 0)
        session.close()
    }

    /// A closed subscriber accepts nothing. Presence is per-CONNECTION and dies with the link — the
    /// connection IS the TTL, which is why no timer exists: one could only ever fire after the
    /// subscriber was already gone.
    func testAClosedSubscriberAcceptsNoPresence() {
        let session = makeSession(RecordingChannel())
        XCTAssertTrue(session.note(presence: update(clock: 1, pane: paneA)))
        session.close()

        XCTAssertFalse(session.note(presence: update(clock: 2, pane: paneB)))
    }

    // MARK: - Two windows of one app

    /// Presence is keyed by the client's OWN instance id, not by the subscriber id the host mints.
    /// Two windows of one app are two connections and two identities — and both belong in the roster,
    /// because "who is here" is a question about windows, not about processes.
    func testTwoConnectionsFromOneDeviceAreTwoEntries() async throws {
        let document = HostWorkspaceDocument(onLog: nil)
        let first = RecordingChannel()
        let second = RecordingChannel()
        let one = makeSession(first, label: "mac-studio")
        let two = makeSession(second, label: "mac-studio")

        await document.addSubscriber(one)
        await document.addSubscriber(two)
        _ = one.note(presence: update(clock: 1, pane: paneA))
        _ = two.note(presence: update(clock: 1, pane: paneB))
        await document.broadcastRoster()

        await expect({ first.rosters.last?.clients.count == 2 }, "both windows in the roster")
        let roster = try XCTUnwrap(first.rosters.last)
        XCTAssertEqual(
            Set(roster.clients.map(\.viewingPaneID)), [paneA, paneB],
            "each window reports its own view",
        )
        XCTAssertEqual(
            Set(roster.clients.map(\.clientInstanceID)).count, 2,
            "…under two identities, not one overwriting the other",
        )
        one.close()
        two.close()
    }

    /// Everyone sees the same roster — that is the whole point of a shared one.
    func testTheRosterIsFannedToEverySubscriber() async {
        let document = HostWorkspaceDocument(onLog: nil)
        let first = RecordingChannel()
        let second = RecordingChannel()
        let one = makeSession(first)
        let two = makeSession(second)

        await document.addSubscriber(one)
        await document.addSubscriber(two)
        _ = one.note(presence: update(clock: 1, pane: paneA))
        await document.broadcastRoster()

        await expect({ !first.rosters.isEmpty && !second.rosters.isEmpty }, "a roster on both links")
        XCTAssertEqual(first.rosters.last?.clients, second.rosters.last?.clients)
        one.close()
        two.close()
    }

    /// A subscriber that left is out of the roster on the next broadcast. Nothing expires it on a
    /// timer; the close is the event.
    func testALeavingSubscriberDropsOutOfTheRoster() async {
        let document = HostWorkspaceDocument(onLog: nil)
        let staying = RecordingChannel()
        let leaving = RecordingChannel()
        let one = makeSession(staying)
        let two = makeSession(leaving)

        await document.addSubscriber(one)
        await document.addSubscriber(two)
        await document.broadcastRoster()
        await expect({ staying.rosters.last?.clients.count == 2 }, "both present")

        two.close()
        await document.removeSubscriber(id: two.id)
        await document.broadcastRoster()

        await expect({ staying.rosters.last?.clients.count == 1 }, "the leaver is gone")
        one.close()
    }

    // MARK: - Presence never moves the version

    /// The rule the whole document's convergence rests on. A presence frame that advanced `stateNum`
    /// would make the host retire, via `assumedAcked`, a diff it never sent — permanent silent
    /// divergence on the very first rename after it.
    func testPresenceNeverAdvancesTheStateNum() async {
        let document = HostWorkspaceDocument(onLog: nil)
        let channel = RecordingChannel()
        let session = makeSession(channel)
        await document.addSubscriber(session)
        await expect({ !channel.sent.isEmpty }, "the opening snapshot")
        let before = await document.stateNum

        _ = session.note(presence: update(clock: 1, pane: paneA))
        await document.broadcastRoster()
        await expect({ !channel.rosters.isEmpty }, "the roster")

        let after = await document.stateNum
        XCTAssertEqual(after, before, "presence is derived, never versioned")
        XCTAssertTrue(
            channel.sent.allSatisfy { message in
                guard case let .workspaceEvent(kind, _, _, new, _) = message else { return true }
                return kind != WorkspaceEventKind.presence.rawValue || new == 0
            },
            "a presence frame declares stateNum 0 — it is not a version of anything",
        )
        session.close()
    }

    // MARK: - The viewport offer

    /// Phase 4 carries the viewport but folds nothing from it: the subscribe declares no
    /// `contributesSize`, so a client's cols/rows are an OFFER and the roster says so.
    func testTheViewportIsCarriedButNotClaimed() {
        let session = makeSession(RecordingChannel())
        _ = session.note(presence: update(clock: 1, pane: paneA, cols: 120, rows: 40))
        let record = session.rosterRecord()

        XCTAssertEqual(record.cols, 120)
        XCTAssertEqual(record.rows, 40)
        XCTAssertEqual(
            record.flags & WorkspaceSubscribe.flagContributesSize, 0,
            "carrying a size is not offering to be folded into one",
        )
        session.close()
    }
}
