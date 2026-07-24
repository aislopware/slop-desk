import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// The host's type-25 duplicate gate: while a pane's agent status is HOOK-established, the agent's
/// OWN terminal notification (OSC 9 / 777 — Claude Code's `ghostty` notification channel under
/// `TERM=xterm-ghostty`) must NOT ride the wire as a `.notification` — the type-27 agent edge
/// already raises the client's banner, so forwarding the blind OSC copy double-bangs every
/// permission/idle prompt. A hook-free pane keeps the OSC path: it is the only signal there.
///
/// Driven WITHOUT a PTY or running relay (hang-safety rule): the REAL chunk handler
/// (`ingestPTYChunkForTesting` → the live ``HostOutputSniffer`` → the FIFO filter) plus the REAL
/// hook ingest (`ingestAgentHookRecord` — the exact method the hook socket calls).
final class MuxChannelSessionNotificationGateTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; truths driven via the seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    /// A BEL-terminated OSC sequence as raw PTY bytes (`ESC ] <body> BEL`).
    private func osc(_ body: String) -> Data { Data("\u{1B}]\(body)\u{07}".utf8) }

    /// The control messages riding the next merged output frame (empty when no frame is queued).
    private func nextFrameControl(_ session: MuxChannelSession) -> [WireMessage] {
        guard case let .output(_, _, control)? = session.takeMergedFrame() else { return [] }
        return control
    }

    func testHookFreePaneForwardsChildNotification() {
        let session = makeSession()
        session.ingestPTYChunkForTesting(osc("9;build finished"))
        XCTAssertEqual(
            nextFrameControl(session), [.notification(title: "", body: "build finished")],
            "no hook truth — the OSC 9 notification is the pane's only signal and must pass",
        )
    }

    func testHookAuthorityDropsChildNotificationKeepsBytesAndTitles() {
        let session = makeSession()
        // The hook socket delivered a real record — the pane's status is hook-established.
        session.ingestAgentHookRecord(Data(#"{"hook_event_name":"SessionStart"}"#.utf8))

        // Claude's own OSC 9 arrives with a title edge in the same chunk.
        let chunk = osc("0;✳ Claude Code") + osc("9;Claude needs your permission")
        session.ingestPTYChunkForTesting(chunk)

        guard case let .output(bytes, _, control)? = session.takeMergedFrame() else {
            XCTFail("the chunk itself must still ride the FIFO — the gate is control-only")
            return
        }
        XCTAssertEqual(bytes, chunk, "the sniffer is non-destructive — raw bytes are untouched")
        XCTAssertFalse(
            control.contains { if case .notification = $0 { true } else { false } },
            "hook truth live — the blind OSC copy of the agent edge is dropped",
        )
        XCTAssertTrue(
            control.contains { if case .title = $0 { true } else { false } },
            "only .notification is gated — the title edge in the same batch still ships",
        )
    }

    func testHookAuthorityDropsOSC777Too() {
        let session = makeSession()
        session.ingestAgentHookRecord(Data(#"{"hook_event_name":"UserPromptSubmit"}"#.utf8))
        session.ingestPTYChunkForTesting(osc("777;notify;Claude;waiting for input"))
        XCTAssertEqual(
            nextFrameControl(session).filter { if case .notification = $0 { true } else { false } },
            [],
            "both explicit-notification OSC forms are the same duplicate while hooks own the edge",
        )
    }

    func testProgressOSCUnaffectedByGate() {
        let session = makeSession()
        session.ingestAgentHookRecord(Data(#"{"hook_event_name":"SessionStart"}"#.utf8))
        session.ingestPTYChunkForTesting(osc("9;4;1;40"))
        XCTAssertEqual(
            nextFrameControl(session), [.progress(state: 1, percent: 40)],
            "OSC 9;4 is progress (type 32), never a notification — the gate must not touch it",
        )
    }
}
