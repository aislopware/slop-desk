import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// WS-B / B4·B5·B6·B7 — the PURE, headless ``TerminalKeyInterceptor`` the per-surface key paths (the
/// libghostty terminal, the remote-video surface, the iOS responder) consult BEFORE their own raw-byte
/// branches. Driven entirely via `intercept(_:)` with an injected single-chord resolver and action sink —
/// no AppKit/UIKit. The interceptor is single-chord ONLY: the tmux-style prefix engine it once carried is
/// REMOVED (DECISIONS.md 2026-07-22), so a Ctrl-letter is never claimed and ⌃B reaches the PTY untouched.
@MainActor
final class TerminalKeyInterceptorTests: XCTestCase {
    /// Build an interceptor with a single-chord table {⌘D → .splitRight} and a recorder for routed actions.
    private func make(
        onAction: @escaping (WorkspaceAction) -> Void = { _ in },
    ) -> TerminalKeyInterceptor {
        TerminalKeyInterceptor(
            resolveChord: { $0 == KeyChord(character: "d", [.command]) ? .splitRight : nil },
            onAction: onAction,
        )
    }

    // MARK: Single-chord path — this is where B5's removed hard-coded ⌘D split now lives.

    /// A BOUND single chord (⌘D) → dispatch `.splitRight` and SWALLOW. Proves B5: the terminal no
    /// longer needs its own ⌘D branch — the interceptor owns the rebindable split.
    func testBoundSingleChordDispatchesAndSwallows() {
        var routed: [WorkspaceAction] = []
        let i = make(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(KeyChord(character: "d", [.command])), .swallow)
        XCTAssertEqual(routed, [.splitRight], "the single-chord path routed the split")
    }

    /// A BARE unmodified key → FORWARD (never swallow normal typing), nothing routed. The
    /// load-bearing "plain keys reach the PTY" contract.
    func testBareKeyForwardsAndRoutesNothing() {
        var routed: [WorkspaceAction] = []
        let i = make(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(KeyChord(character: "j")), .forward(KeyChord(character: "j")))
        XCTAssertTrue(routed.isEmpty, "a bare key routes nothing")
    }

    /// An unbound Ctrl-letter (NOT in the table) → FORWARD, so a normal Ctrl-C reaches the terminal's own
    /// C0 path. Pins that the interceptor does not over-claim Ctrl-letters.
    func testUnboundControlLetterForwards() {
        let i = make()
        let ctrlC = KeyChord(character: "c", [.control])
        XCTAssertEqual(i.intercept(ctrlC), .forward(ctrlC))
    }

    /// PREFIX-REMOVAL PIN: ⌃B — the RETIRED tmux prefix — is an ordinary forwarded Ctrl-letter against the
    /// live registry table (nothing arms, nothing swallows, nothing routes). This is the whole point of
    /// the removal: ⌃B is readline back-char / vi page-up / nested tmux, and it must reach the PTY.
    func testCtrlBForwardsAgainstLiveRegistryTable() {
        // The default resolver reads the PROCESS-GLOBAL `activeOverrides` — pin it empty for this test
        // (and restore) so an earlier suite's leftover rebind can't shadow the check.
        let saved = WorkspaceBindingRegistry.activeOverrides
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        defer { WorkspaceBindingRegistry.activeOverrides = saved }
        var routed: [WorkspaceAction] = []
        let i = TerminalKeyInterceptor(onAction: { routed.append($0) })
        let ctrlB = KeyChord(character: "b", [.control])
        XCTAssertEqual(i.intercept(ctrlB), .forward(ctrlB), "⌃B is normal terminal input, never claimed")
        // The old prefix follow-up idiom is dead too: a bare `d` after ⌃B is just typing.
        XCTAssertEqual(i.intercept(KeyChord(character: "d")), .forward(KeyChord(character: "d")))
        XCTAssertTrue(routed.isEmpty, "no action fired — no prefix machine exists to arm")
    }

    /// END-TO-END with the REAL registry defaults (no injected table): a default-built interceptor resolves
    /// ⌘D to the registry's split-right. Pins the shipped out-of-the-box behaviour.
    func testDefaultInterceptorResolvesCommandDAgainstRegistry() {
        let saved = WorkspaceBindingRegistry.activeOverrides
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        defer { WorkspaceBindingRegistry.activeOverrides = saved }
        var routed: [WorkspaceAction] = []
        let i = TerminalKeyInterceptor(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(KeyChord(character: "d", [.command])), .swallow)
        XCTAssertEqual(routed, [.splitRight], "⌘D = split right against the live registry table")
    }
}
