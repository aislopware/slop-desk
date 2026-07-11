import SlopDeskClient
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``ConnectionViewModel``'s wire type-33/34 routing. Both are HOST-gated single-source
/// truths (`MuxChannelSession.deriveProjectKey`: warm-up gate, dedupe anchor, probe-beats-stale-OSC-7
/// — pinned in `MuxChannelSessionProjectKeyTests`), so the VM applies them UNGATED; the old
/// client-side first-command gate would re-drop the host's reattach re-assert and leave the tab's
/// cwd line stale across a reconnect (the 2026-07-11 stale-cwd bug). Uses `foldEventForTesting` —
/// the DEBUG hook — so no async event loop or network is needed. No
/// `GhosttySurface`/`SCStream`/`VT`/Metal instantiation.
@MainActor
final class ConnectionViewModelWorkingDirectoryTests: XCTestCase {
    private func makeVM() -> ConnectionViewModel {
        ConnectionViewModel(
            terminal: TerminalViewModel(),
            target: { .default },
            makeClient: { SlopDeskClient(makeTransport: { fatalError("not used in cwd tests") }) },
        )
    }

    /// A `.cwd` edge reaches the store callback UNGATED — the host re-asserts the latched cwd on
    /// reattach BEFORE any command runs, and dropping it left the tab's cwd line stale until the
    /// next accepted change. FAILS if a first-command gate is reintroduced on this route.
    func testCwdRoutesToStoreCallbackWithoutCommandGate() {
        let vm = makeVM()
        var received: [String] = []
        vm.onWorkingDirectoryChanged = { received.append($0) }

        // No command has started (the reattach re-assert shape) — the cwd must still land.
        vm.foldEventForTesting(.cwd("/Users/me/project"))
        XCTAssertEqual(received, ["/Users/me/project"], "the pre-first-command re-assert is delivered")

        // And a later change edge lands too.
        vm.foldEventForTesting(.commandStatus(.running))
        vm.foldEventForTesting(.cwd("/Users/me/other"))
        XCTAssertEqual(received, ["/Users/me/project", "/Users/me/other"])
    }

    /// A reconnect must not wedge the route: cwd edges arriving AFTER a `.reconnected` (the host's
    /// reattach re-assert, then a post-reconnect `cd`'s change edge) all land. This is the exact
    /// user-visible regression: after a reconnect, `cd` no longer updated the tab's cwd line.
    func testCwdKeepsRoutingAcrossReconnect() {
        let vm = makeVM()
        var received: [String] = []
        vm.onWorkingDirectoryChanged = { received.append($0) }

        vm.foldEventForTesting(.commandStatus(.running))
        vm.foldEventForTesting(.cwd("/Users/me/project"))

        vm.foldEventForTesting(.reconnected(sessionID: UUID(), resumeFromSeq: 42))
        // The host's reattach re-assert (no command has run on the reattached link yet):
        vm.foldEventForTesting(.cwd("/Users/me/project"))
        // A genuine post-reconnect cd's change edge:
        vm.foldEventForTesting(.cwd("/Users/me/elsewhere"))
        XCTAssertEqual(
            received,
            ["/Users/me/project", "/Users/me/project", "/Users/me/elsewhere"],
            "reattach re-assert + post-reconnect change edges must all reach the store sink",
        )
    }

    /// An empty `.cwd` payload is dropped at the VM boundary (validate-then-drop — nothing useful
    /// to persist, and an empty path must never reach the store sink).
    func testEmptyCwdIsDropped() {
        let vm = makeVM()
        var received: [String] = []
        vm.onWorkingDirectoryChanged = { received.append($0) }
        vm.foldEventForTesting(.cwd(""))
        XCTAssertEqual(received, [], "an empty cwd is dropped, never forwarded")
    }

    // MARK: - Host-computed By-Project key (wire type 34) routing

    /// A `.projectKey` wire event reaches the store callback ungated (the same contract as `.cwd`) —
    /// the host re-asserts the latched key on reattach BEFORE any command runs, and dropping it would
    /// reintroduce the reconnect section flicker the host-side computation exists to remove (the
    /// plugin-dir poison is handled at the store's `setProjectKey` write guard instead).
    func testProjectKeyRoutesToStoreCallbackWithoutCommandGate() {
        let vm = makeVM()
        var received: [String] = []
        vm.onProjectKeyChanged = { received.append($0) }

        // No command has started (the reattach re-assert shape) — the key must still land.
        vm.foldEventForTesting(.projectKey("/Users/me/project"))
        XCTAssertEqual(received, ["/Users/me/project"], "the pre-first-command re-assert is delivered")

        // And a later change edge lands too.
        vm.foldEventForTesting(.commandStatus(.running))
        vm.foldEventForTesting(.projectKey("/Users/me/other"))
        XCTAssertEqual(received, ["/Users/me/project", "/Users/me/other"])
    }

    /// An empty `.projectKey` payload is dropped at the VM boundary (validate-then-drop — nothing useful
    /// to persist, and an empty key must never reach the store sink).
    func testEmptyProjectKeyIsDropped() {
        let vm = makeVM()
        var received: [String] = []
        vm.onProjectKeyChanged = { received.append($0) }
        vm.foldEventForTesting(.projectKey(""))
        XCTAssertEqual(received, [], "an empty key is dropped, never forwarded")
    }
}
