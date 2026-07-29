import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskHost

/// What mints one finished turn (`pane/completionEpoch`) — herdr's
/// `is_background_completion_transition`, which is `Working|Blocked → Idle` and NOT a `done` state.
///
/// The distinction is the whole bug: `ClaudeStatus.done` exists only on the authoritative hook
/// path, hooks are opt-in and off by default, and the screen-manifest engine that actually runs on
/// most panes has no `done` verdict at all. Counting only `.done` left a hook-free host unable to
/// tell a finished turn from one that never happened — the pane went straight to grey.
final class CompletionTransitionTests: XCTestCase {
    private func mints(_ previous: ClaudeStatus, _ next: ClaudeStatus) -> Bool {
        MuxChannelSession.isCompletionTransition(previous: previous, next: next)
    }

    /// The hook-free path — the one that was silent. The screen engine publishes `working`, then
    /// `idle`; that edge IS the finish.
    func testWorkingToIdleMintsACompletion() {
        XCTAssertTrue(mints(.working, .idle))
    }

    /// herdr counts a blocked pane returning to rest as a finish too (an answered — or cancelled —
    /// approval gate is a turn that ended).
    func testBlockedToIdleMintsACompletion() {
        XCTAssertTrue(mints(.needsPermission, .idle))
    }

    /// The hook path is unchanged: `Stop` announces the finish and mints it there.
    func testEnteringDoneMintsACompletion() {
        XCTAssertTrue(mints(.working, .done))
        XCTAssertTrue(mints(.idle, .done))
    }

    /// …and the done→idle DECAY that follows it is the same turn ending twice. Minting there would
    /// double-count every hook-driven finish.
    func testTheDoneToIdleDecayMintsNothing() {
        XCTAssertFalse(mints(.done, .idle))
    }

    /// An agent APPEARING is not a turn ending. `.none → .idle` is the presence floor lifting —
    /// minting here would put an unread finish on every pane the moment claude was first detected.
    func testPresenceAppearingMintsNothing() {
        XCTAssertFalse(mints(.none, .idle))
    }

    /// Nothing else counts: a turn starting, a gate opening, a pane dying, or a re-assertion of the
    /// state the pane already stood at.
    func testTheRestOfTheTransitionsMintNothing() {
        XCTAssertFalse(mints(.idle, .working))
        XCTAssertFalse(mints(.working, .needsPermission))
        XCTAssertFalse(mints(.needsPermission, .working))
        XCTAssertFalse(mints(.done, .none))
        XCTAssertFalse(mints(.idle, .none))
        for status in [ClaudeStatus.none, .idle, .working, .needsPermission, .done] {
            XCTAssertFalse(mints(status, status), "a re-assertion is not a transition: \(status)")
        }
    }
}
