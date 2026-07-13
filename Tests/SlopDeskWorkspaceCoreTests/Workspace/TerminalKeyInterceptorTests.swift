import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// WS-B / B4·B5·B6·B7 — the PURE, headless ``TerminalKeyInterceptor`` the per-surface key paths (the
/// libghostty terminal, the remote-video surface, the iOS responder) consult BEFORE their own raw-byte
/// branches. Driven entirely via `intercept(_:)` with an INJECTED clock + an injected single-chord resolver
/// and action sink — no AppKit/UIKit. Each test pins one decided behaviour and FAILS on the un-fixed code
/// (the interceptor did not exist), per revert-to-confirm-fail discipline.
@MainActor
final class TerminalKeyInterceptorTests: XCTestCase {
    private let prefix = KeyChord(character: "a", [.control])

    /// A clock the test advances; the interceptor reads it for the escape-timeout.
    private final class Clock { var t: TimeInterval = 0 }

    /// Build an interceptor with a single-chord table {⌘D → .splitRight} and a recorder for routed actions.
    private func make(
        timeout: TimeInterval = 1,
        clock: Clock = Clock(),
        onAction: @escaping (WorkspaceAction) -> Void = { _ in },
    ) -> TerminalKeyInterceptor {
        TerminalKeyInterceptor(
            prefix: prefix,
            timeout: timeout,
            resolveChord: { $0 == KeyChord(character: "d", [.command]) ? .splitRight : nil },
            onAction: onAction,
            now: { clock.t },
        )
    }

    // MARK: Single-chord (idle) path — this is where B5's removed hard-coded ⌘D split now lives.

    /// Idle + a BOUND single chord (⌘D) → dispatch `.splitRight` and SWALLOW. Proves B5: the terminal no
    /// longer needs its own ⌘D branch — the interceptor owns the rebindable split.
    func testIdleBoundSingleChordDispatchesAndSwallows() {
        var routed: [WorkspaceAction] = []
        let i = make(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(KeyChord(character: "d", [.command])), .swallow)
        XCTAssertEqual(routed, [.splitRight], "the idle single-chord path routed the split")
    }

    /// Idle + a BARE unmodified key → FORWARD (never swallow normal typing), nothing routed. The
    /// load-bearing "plain keys reach the PTY" contract.
    func testIdleBareKeyForwardsAndRoutesNothing() {
        var routed: [WorkspaceAction] = []
        let i = make(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(KeyChord(character: "j")), .forward(KeyChord(character: "j")))
        XCTAssertTrue(routed.isEmpty, "a bare key routes nothing")
    }

    /// Idle + an unbound Ctrl-letter (NOT the prefix, NOT in the table) → FORWARD, so a normal Ctrl-C reaches
    /// the terminal's own C0 path. Pins that the interceptor does not over-claim Ctrl-letters.
    func testIdleUnboundControlLetterForwards() {
        let i = make()
        let ctrlC = KeyChord(character: "c", [.control])
        XCTAssertEqual(i.intercept(ctrlC), .forward(ctrlC))
    }

    // MARK: Prefix path.

    /// idle + prefix → SWALLOW (arm; never leak the prefix byte to the terminal). Distinct from a bare Ctrl-
    /// letter (above): the configured prefix IS claimed.
    func testPrefixArmsAndSwallows() {
        let i = make()
        XCTAssertEqual(i.intercept(prefix), .swallow)
        XCTAssertTrue(i.isArmed)
    }

    /// armed + a BARE follow-up key → the implied-⌘ fold resolves it against the same table (`prefix, d` →
    /// the ⌘D binding) — the tmux prefix-converts-the-next-key idiom. FAILS on the un-folded machine
    /// (armed bare `d` disarm-swallowed: the "⌃B D doesn't split" bug).
    func testArmedBareFollowUpResolvesViaImpliedCommandFold() {
        var routed: [WorkspaceAction] = []
        let i = make(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(prefix), .swallow)
        XCTAssertEqual(i.intercept(KeyChord(character: "d")), .swallow)
        XCTAssertEqual(routed, [.splitRight], "prefix then bare d fires the ⌘D-bound action")
    }

    /// END-TO-END with the REAL registry defaults (no injected table): a default-built interceptor arms on
    /// ⌃B (``WorkspaceBindingRegistry/defaultPrefixChord``) and `⌃B, d` routes the registry's ⌘D
    /// split-right. Pins the shipped out-of-the-box behaviour, not just the injected-resolver contract.
    func testDefaultInterceptorArmsOnCtrlBAndBareDSplitsRight() {
        // The default resolvers read the PROCESS-GLOBAL `activeOverrides` — pin it empty for this test
        // (and restore) so an earlier suite's leftover rebind can't hide the registry's ⌘D.
        let saved = WorkspaceBindingRegistry.activeOverrides
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        defer { WorkspaceBindingRegistry.activeOverrides = saved }
        var routed: [WorkspaceAction] = []
        let i = TerminalKeyInterceptor(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(KeyChord(character: "b", [.control])), .swallow, "⌃B is the default prefix")
        XCTAssertEqual(i.intercept(KeyChord(character: "d")), .swallow)
        XCTAssertEqual(routed, [.splitRight], "⌃B then D = split right against the live registry table")
    }

    /// armed + a bound follow-up chord (⌘D) → dispatch `.splitRight` and swallow (the ⌃B→⌘D tmux sequence).
    func testArmedBoundFollowupDispatchesAndSwallows() {
        var routed: [WorkspaceAction] = []
        let i = make(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(prefix), .swallow)
        XCTAssertEqual(i.intercept(KeyChord(character: "d", [.command])), .swallow)
        XCTAssertEqual(routed, [.splitRight])
        XCTAssertFalse(i.isArmed, "resolving disarms")
    }

    /// armed + the prefix AGAIN (double-tap) → emit the literal prefix byte (tmux send-prefix), disarm. ⌃A's
    /// literal byte is 0x01.
    func testDoubleTapPrefixSendsLiteralByte() {
        let i = make()
        XCTAssertEqual(i.intercept(prefix), .swallow)
        XCTAssertEqual(i.intercept(prefix), .sendLiteral([0x01]))
        XCTAssertFalse(i.isArmed)
    }

    /// armed + an UNBOUND key → tmux-faithful DISARM + SWALLOW (the prefix is NOT replayed, the key is eaten).
    func testArmedUnboundKeyDisarmsAndSwallows() {
        var routed: [WorkspaceAction] = []
        let i = make(onAction: { routed.append($0) })
        XCTAssertEqual(i.intercept(prefix), .swallow)
        XCTAssertEqual(i.intercept(KeyChord(character: "z")), .swallow, "unbound second key is swallowed")
        XCTAssertTrue(routed.isEmpty)
        XCTAssertFalse(i.isArmed)
    }

    /// armed + escape-TIMEOUT → the stale arm expires to idle BEFORE the late key is classified, so a normal
    /// key arriving after the window FORWARDS (not swallowed). Pins the configurable escape timeout.
    func testEscapeTimeoutFallsBackToIdleThenForwards() {
        let clock = Clock()
        let i = make(timeout: 1, clock: clock)
        XCTAssertEqual(i.intercept(prefix), .swallow)
        clock.t = 2 // past the 1s escape window
        XCTAssertEqual(i.intercept(KeyChord(character: "j")), .forward(KeyChord(character: "j")))
    }

    // MARK: Configurable prefix moved off a Ctrl-letter.

    /// A prefix moved to a non-Ctrl chord (⌥-Space) still arms, but its double-tap has NO single literal byte
    /// → `.sendLiteral([])` (a graceful no-op), proving the "configurable-away-from-Ctrl" policy.
    func testCustomNonControlPrefixDoubleTapSendsNoBytes() {
        let custom = KeyChord(character: " ", [.option])
        let i = TerminalKeyInterceptor(prefix: custom, resolveChord: { _ in nil }, onAction: { _ in })
        XCTAssertEqual(i.intercept(custom), .swallow)
        XCTAssertEqual(i.intercept(custom), .sendLiteral([]), "no Ctrl-letter literal → empty send (no-op)")
    }

    /// `setPrefix` re-keys the live machine: after moving the prefix to ⌃B, ⌃A is just a forwarded Ctrl-letter
    /// and ⌃B is what arms. Pins that a settings change re-points the engine.
    func testSetPrefixRekeysLive() {
        let i = make()
        i.setPrefix(KeyChord(character: "b", [.control]))
        let oldPrefix = KeyChord(character: "a", [.control])
        XCTAssertEqual(i.intercept(oldPrefix), .forward(oldPrefix), "the old prefix is now an ordinary Ctrl-letter")
        XCTAssertEqual(i.intercept(KeyChord(character: "b", [.control])), .swallow, "the new prefix arms")
    }

    // MARK: literalBytes (shared with the macOS surfaces + iOS).

    func testLiteralBytesMapsControlLetters() {
        XCTAssertEqual(TerminalKeyInterceptor.literalBytes(for: KeyChord(character: "a", [.control])), [0x01])
        XCTAssertEqual(TerminalKeyInterceptor.literalBytes(for: KeyChord(character: "b", [.control])), [0x02])
        // Non-Ctrl-letter prefixes have no single literal byte.
        XCTAssertEqual(TerminalKeyInterceptor.literalBytes(for: KeyChord(character: "a", [.command])), [])
        XCTAssertEqual(TerminalKeyInterceptor.literalBytes(for: KeyChord(.tab, [.control])), [])
    }
}
