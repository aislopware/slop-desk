import SlopDeskClient
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``ConnectionViewModel``'s OSC-7 working-directory routing + its startup-noise gate
/// (`commandStartSeen`). Uses `foldEventForTesting` — the DEBUG hook — so no async event loop or
/// network is needed. No `GhosttySurface`/`SCStream`/`VT`/Metal instantiation.
@MainActor
final class ConnectionViewModelWorkingDirectoryTests: XCTestCase {
    private func makeVM() -> ConnectionViewModel {
        ConnectionViewModel(
            terminal: TerminalViewModel(),
            target: { .default },
            makeClient: { SlopDeskClient(makeTransport: { fatalError("not used in cwd tests") }) },
        )
    }

    /// A pre-first-command OSC 7 (plugin-manager startup noise) must be DROPPED; a cwd edge after the
    /// first command-start (a genuine interactive `cd`) is accepted.
    func testWorkingDirectoryGatedUntilFirstCommand() {
        let vm = makeVM()
        var received: [String] = []
        vm.onWorkingDirectoryChanged = { received.append($0) }

        vm.foldEventForTesting(.cwd("/plugins/zsh-users---zsh-autosuggestions"))
        XCTAssertEqual(received, [], "a pre-first-command OSC 7 must be dropped (startup noise)")

        vm.foldEventForTesting(.commandStatus(.running))
        vm.foldEventForTesting(.cwd("/Users/me/project"))
        XCTAssertEqual(received, ["/Users/me/project"], "a cwd edge after the first command-start is accepted")
    }

    /// Bug 2/3: a reconnect spawns a BRAND-NEW host shell that re-sources `.zshrc`, replaying the exact
    /// plugin-manager OSC-7 startup noise. The gate must RE-ARM at the reconnect boundary so that fresh
    /// shell's pre-first-command OSC 7 is dropped again — otherwise the stale-true gate admits the plugin
    /// cache dir and poisons `lastKnownCwd` (the exact regression the initial-connect gate fixed).
    func testReconnectReArmsStartupNoiseGate() {
        let vm = makeVM()
        var received: [String] = []
        vm.onWorkingDirectoryChanged = { received.append($0) }

        // Arm the gate with a real command on the first shell.
        vm.foldEventForTesting(.commandStatus(.running))
        vm.foldEventForTesting(.cwd("/Users/me/project"))
        XCTAssertEqual(received, ["/Users/me/project"])

        // Reconnect → brand-new shell. The gate must reset.
        vm.foldEventForTesting(.reconnected(sessionID: UUID(), resumeFromSeq: 0))
        vm.foldEventForTesting(.cwd("/plugins/zsh-users---zsh-autosuggestions"))
        XCTAssertEqual(
            received,
            ["/Users/me/project"],
            "a reconnect must re-arm the startup-noise gate so the fresh shell's plugin OSC 7 is dropped",
        )

        // A real command on the reconnected shell re-arms the gate and the next cwd is accepted.
        vm.foldEventForTesting(.commandStatus(.running))
        vm.foldEventForTesting(.cwd("/Users/me/project2"))
        XCTAssertEqual(received, ["/Users/me/project", "/Users/me/project2"])
    }

    // MARK: - Host-computed By-Project key (wire type 34) routing

    /// A `.projectKey` wire event reaches the store callback UNGATED by `commandStartSeen` — the host
    /// re-asserts the latched key on reattach BEFORE any command runs, and dropping it would reintroduce
    /// the reconnect section flicker the host-side computation exists to remove (the plugin-dir poison is
    /// handled at the store's `setProjectKey` write guard instead). FAILS if the route were folded into the
    /// gated `routeWorkingDirectory` path.
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
