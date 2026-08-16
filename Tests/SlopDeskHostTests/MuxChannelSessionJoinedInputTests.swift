import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// A JOINED member types into the pane like the client that opened it — tmux's fan-out, where every
/// attachment writes to the same shell.
///
/// The relay is per-SUBSCRIBER (``MuxChannelSession/startInputRelay(for:)``), so the join builds a
/// second copy of it. Nothing else pins that the copy is wired: the primary's relay is built at
/// `init` and would keep every input test green while a joiner's input went nowhere.
///
/// Headless: unspawned ``PTYProcess`` (masterFD −1, no reaper thread), input intercepted at the
/// serial writer's test seam, so nothing here forks a shell — the hang-safety rule.
final class MuxChannelSessionJoinedInputTests: XCTestCase {
    // MARK: - Rig

    /// Records what the PTY writer was asked to write, from the session's serial `inputQueue`.
    private final class WriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []

        func record(_ bytes: Data) {
            lock.lock()
            chunks.append(bytes)
            lock.unlock()
        }

        var written: Data {
            lock.lock()
            defer { lock.unlock() }
            return chunks.reduce(into: Data()) { $0.append($1) }
        }
    }

    private var sessions: [MuxChannelSession] = []

    override func tearDown() {
        for session in sessions { session.shutdownDetached() }
        sessions = []
    }

    /// - Parameter relay: whether to `startRelay()`. The AGENT test passes `false`: the relay arms a
    ///   ~1 Hz foreground poll, and on this unspawned PTY that poll folds "no process here" through
    ///   the presence heuristic and can reset the detector's status out from under an assertion —
    ///   a wall-clock race that only shows up under a loaded full-suite run. The primary subscriber
    ///   is seeded at `init`, so a join still works without it.
    private func makeSession(
        agentDetectEnabled: Bool = false,
        relay: Bool = true,
    ) -> MuxChannelSession {
        let session = MuxChannelSession(
            channelID: 1,
            pty: unattachedPTY(), // unspawned — no fork, no reaper
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            agentDetectEnabled: agentDetectEnabled,
        )
        session.installGateForTesting(PausableQueueGate(capacity: 8 * 1024 * 1024) { _ in })
        if relay { session.startRelay() }
        sessions.append(session)
        return session
    }

    private func makeDataChannel() -> MuxSubChannel {
        MuxSubChannel(
            channelID: 1,
            channel: .data,
            sendWindowBytes: MuxFlowControl.initialWindowBytes,
        ) { _, _ in }
    }

    private func makeControlChannel() -> MuxSubChannel {
        MuxSubChannel(channelID: 1, channel: .control, sendWindowBytes: nil) { _, _ in }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The second member writes

    /// The bytes a joiner sends reach the master fd, unchanged and in order.
    func testAJoinedMembersInputReachesThePTY() async {
        let writes = WriteRecorder()
        let session = makeSession()
        session.ptyWriteOverrideForTesting = { writes.record($0) }

        let peerData = makeDataChannel()
        let joined = await session.joinSubscriber(
            data: peerData,
            control: makeControlChannel(),
            sizePassive: false,
        )
        XCTAssertNotNil(joined)

        await peerData.deliver(payload: WireMessage.input(Data("ls\r".utf8)).encode())
        await waitUntil { writes.written == Data("ls\r".utf8) }
        XCTAssertEqual(writes.written, Data("ls\r".utf8), "every member of a pane writes to its shell")
    }

    /// `foldUserInput` is the Esc-cancel UNBLOCK edge: a keystroke into a `.needsPermission` pane
    /// demotes it to `.idle` because the human is handling the dialog. It hangs off the input relay,
    /// so a joiner whose relay skipped the fold would leave the supervision alert up on every other
    /// client after the person at THIS one already answered.
    func testAJoinedMembersKeystrokeUnblocksABlockedAgent() async {
        let session = makeSession(agentDetectEnabled: true, relay: false)
        session.ptyWriteOverrideForTesting = { _ in }
        session.ingestAgentHookRecord(Data(
            #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash?"}"#
                .utf8,
        ))
        XCTAssertEqual(
            session.agentStatusForControl, .needsPermission,
            "precondition: the pane is blocked on a human",
        )

        let peerData = makeDataChannel()
        let joined = await session.joinSubscriber(
            data: peerData,
            control: makeControlChannel(),
            sizePassive: false,
        )
        XCTAssertNotNil(joined)

        await peerData.deliver(payload: WireMessage.input(Data([0x1B])).encode())
        await waitUntil { session.agentStatusForControl == .idle }
        XCTAssertEqual(
            session.agentStatusForControl, .idle,
            "the Esc is the human handling the dialog, whichever attachment they typed it into",
        )
    }
}
