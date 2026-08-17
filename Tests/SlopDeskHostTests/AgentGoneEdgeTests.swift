import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskHost

/// The AGENT-GONE edge as the rest of the host sees it — the ctl supervision stream, the sniffer's
/// title coalescing, and the `Stop` payload's live-work count.
final class AgentGoneEdgeTests: XCTestCase {
    // MARK: The bit the four-state vocabulary cannot carry

    /// `.none` and `.idle` are the same supervision word, so the `events` dedupe (keyed on the
    /// state string) swallowed the agent-gone transition entirely: a subscriber watching a pane go
    /// `idle → gone` saw one `"idle"` and then silence forever. `presence(from:)` is that lost bit.
    func testPresenceSeparatesGoneFromIdle() {
        XCTAssertEqual(AgentControlState.string(from: .none), AgentControlState.string(from: .idle))
        XCTAssertFalse(AgentControlState.presence(from: .none), "no agent in the pane")
        XCTAssertTrue(AgentControlState.presence(from: .idle), "an agent at rest is still an agent")
        XCTAssertTrue(AgentControlState.presence(from: .working))
        XCTAssertTrue(AgentControlState.presence(from: .done))
        XCTAssertTrue(AgentControlState.presence(from: .needsPermission))
    }

    /// The dedupe key the events pump builds must distinguish the two `"idle"`s — otherwise the
    /// fix above is invisible downstream.
    func testEventDedupeKeyDistinguishesIdleFromGone() {
        func key(_ status: ClaudeStatus) -> String {
            "\(AgentControlState.string(from: status))|\(AgentControlState.presence(from: status))"
        }
        XCTAssertNotEqual(key(.idle), key(.none), "idle → gone must survive consecutive-dupe dedupe")
        XCTAssertEqual(key(.idle), key(.idle), "a genuinely repeated idle still dedupes")
    }

    // MARK: The sniffer's coalescing anchor

    //
    // The anchor itself lives in superd now (`rust/slopdesk-superd/src/sniffer.rs`), and so do the
    // two cases that used to sit here — that retiring it lets a byte-identical `✳ Claude Code`
    // through again, and that retiring it does NOT weaken the empty-title guard it is built around.
    // What stays hostd's, and is covered above, is WHEN the retirement is asked for.

    // MARK: Stop — the work that outlives the turn

    //
    // The label a `Stop` arrives with is read where the body is parsed, in `rust/slopdesk-hookevent`
    // — which is also where the four cases that used to sit here are pinned: a turn that spoke keeps
    // its own words, a silent one that left work running says so, the singular reads "1 background
    // task", and every non-array `background_tasks` shape counts zero rather than failing the Stop.
    // Nothing between the socket and the fold is a value hostd holds, so there is nothing here to
    // assert against.
}
