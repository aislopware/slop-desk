import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// The title RETIREMENT as it reaches the wire — the session half of the fix the detector decides.
///
/// Driven WITHOUT a PTY or running relay (hang-safety rule): the REAL chunk handler
/// (`ingestPTYChunkForTesting`, fed the events superd's sniffer would have found), the REAL hook
/// ingest, and the REAL foreground fold, so the seam under test is the same code the daemon runs.
final class MuxChannelSessionTitleRetirementTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: unattachedPTY(), // unspawned — relay never started; truths driven via the seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            agentDetectEnabled: true,
        )
    }

    private func osc(_ body: String) -> Data { Data("\u{1B}]\(body)\u{07}".utf8) }

    /// Every control message queued so far, from BOTH producers: the sniffed messages ride the
    /// merged output frame, while a detector emission (the retirement) goes onto the control-out
    /// queue. Frames first, so a sniffed title and the retirement that follows it stay in order.
    private func drainControl(_ session: MuxChannelSession) -> [WireMessage] {
        var out: [WireMessage] = []
        while case let .output(_, _, control)? = session.takeMergedFrame() {
            out.append(contentsOf: control)
        }
        while let batch = session.takeControlBatchForTesting() {
            out.append(contentsOf: batch)
        }
        return out
    }

    private func titles(_ messages: [WireMessage]) -> [String] {
        messages.compactMap { if case let .title(t) = $0 { t } else { nil } }
    }

    /// End to end: claude takes the title, the session ends, and the pane is handed an explicit
    /// empty title on the wire — the one thing that lets the client's row fall back to its next
    /// rung instead of showing a dead agent's `✳ <topic>` indefinitely.
    func testSessionEndPutsAnExplicitTitleClearOnTheWire() {
        let session = makeSession()
        session.ingestAgentHookRecord(Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8))
        session.ingestPTYChunkForTesting(osc("0;✳ Claude Code"), sniffed: [.title("✳ Claude Code")])
        XCTAssertEqual(titles(drainControl(session)), ["✳ Claude Code"], "the agent titles the pane")

        session.ingestAgentHookRecord(Data(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#.utf8))
        XCTAssertEqual(titles(drainControl(session)), [""], "the agent hands the title back")
    }

    /// The hook-free path: presence absence is the only teardown signal such a pane ever gets, and
    /// it must retire the title just the same.
    func testForegroundAbsenceAlsoClearsTheTitle() {
        let session = makeSession()
        session.foldForegroundSampleForTesting(name: "claude", at: 0)
        session.ingestPTYChunkForTesting(osc("0;⠂ Say hi in one word"), sniffed: [.title("⠂ Say hi in one word")])
        _ = drainControl(session)

        session.foldForegroundSampleForTesting(name: "zsh", at: 1)
        XCTAssertEqual(titles(drainControl(session)), [""])
    }

    /// The retirement also drops the pane's cached title, so the ctl `list-panes` view of an
    /// agent-free pane does not keep advertising the dead agent's topic.
    func testRetirementClearsTheCachedTitle() {
        let session = makeSession()
        session.foldForegroundSampleForTesting(name: "claude", at: 0)
        session.ingestPTYChunkForTesting(osc("0;✳ Claude Code"), sniffed: [.title("✳ Claude Code")])
        XCTAssertEqual(session.currentTitle, "✳ Claude Code")

        session.foldForegroundSampleForTesting(name: "zsh", at: 1)
        XCTAssertEqual(session.currentTitle, "", "list-panes stops reporting the dead agent's title")
    }

    /// The coalescing reset, from hostd's side of it.
    ///
    /// The ANCHOR is superd's — it dedupes a title against the last one it emitted, and its own
    /// suite pins that retiring it lets a byte-identical `✳ Claude Code` through again. What is
    /// hostd's, and what this pins, is WHEN the retirement is asked for: on the agent's departure,
    /// once, and consumed by the chunk handler rather than by the detector's own thread.
    func testTheAgentLeavingAsksSuperdToRetireTheAnchor() {
        let session = makeSession()
        session.foldForegroundSampleForTesting(name: "claude", at: 0)
        session.ingestPTYChunkForTesting(osc("0;✳ Claude Code"), sniffed: [.title("✳ Claude Code")])
        XCTAssertEqual(session.titleAnchorRetirementsForTesting, 0, "nothing to retire while it runs")

        session.foldForegroundSampleForTesting(name: "zsh", at: 1)
        XCTAssertEqual(titles(drainControl(session)), ["✳ Claude Code", ""])
        XCTAssertEqual(
            session.titleAnchorRetirementsForTesting, 0,
            "the detector's thread only REQUESTS it — the read loop is what asks superd",
        )

        // A second claude in the same pane, opening on the byte-identical startup title.
        session.foldForegroundSampleForTesting(name: "claude", at: 10)
        session.ingestPTYChunkForTesting(osc("0;✳ Claude Code"), sniffed: [.title("✳ Claude Code")])
        XCTAssertEqual(titles(drainControl(session)), ["✳ Claude Code"])
        XCTAssertEqual(
            session.titleAnchorRetirementsForTesting, 1,
            "and it is asked exactly once, on the first chunk after the departure",
        )
    }

    /// A pane whose title the agent never wrote keeps it — the retirement is scoped to titles the
    /// agent demonstrably owned, not to every title a detected pane happens to carry.
    func testAForeignTitleSurvivesTheAgentLeaving() {
        let session = makeSession()
        session.foldForegroundSampleForTesting(name: "claude", at: 0)
        session.ingestPTYChunkForTesting(osc("0;nvim — README.md"), sniffed: [.title("nvim — README.md")])
        _ = drainControl(session)

        session.foldForegroundSampleForTesting(name: "zsh", at: 1)
        XCTAssertTrue(titles(drainControl(session)).isEmpty, "not the agent's title to retire")
        XCTAssertEqual(session.currentTitle, "nvim — README.md")
    }
}
