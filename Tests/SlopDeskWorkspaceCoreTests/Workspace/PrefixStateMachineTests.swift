import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// WS-B / B2 — the PURE, clock-injected tmux/zellij-style prefix state machine (``PrefixStateMachine``).
/// Tested entirely via `feed(_:at:)` with an INJECTED clock (no AppKit, no `Date()`), mirroring the
/// ``ClaudeStatusMachine`` precedent + the existing `CommandInterpreter.feed` test style. Each test pins
/// one transition of the decided PREFIX POLICY and FAILS on the un-fixed code (the machine did not exist).
@MainActor
final class PrefixStateMachineTests: XCTestCase {
    /// Default prefix is `⌃A` (tmux-like). A bound table that maps post-prefix `d` → `.splitRight`.
    private func makeMachine(
        prefix: KeyChord = KeyChord(character: "a", [.control]),
        timeout: TimeInterval = 1,
    ) -> PrefixStateMachine {
        PrefixStateMachine(prefix: prefix, timeout: timeout) { chord in
            chord == KeyChord(character: "d") ? .splitRight : nil
        }
    }

    /// Step 1: idle + the prefix → ARM (swallow, do not leak the prefix to the terminal).
    func testIdlePlusPrefixArmsAndSwallows() {
        let m = makeMachine()
        XCTAssertFalse(m.isArmed)
        XCTAssertEqual(m.feed(KeyChord(character: "a", [.control]), at: 0), .consumedArm)
        XCTAssertTrue(m.isArmed, "the prefix arms the machine")
    }

    /// Step 2: armed + a BOUND key → resolve its action (swallowed), and disarm.
    func testArmedPlusBoundKeyResolvesAction() {
        let m = makeMachine()
        _ = m.feed(KeyChord(character: "a", [.control]), at: 0)
        XCTAssertEqual(m.feed(KeyChord(character: "d"), at: 0.1), .resolved(.splitRight))
        XCTAssertFalse(m.isArmed, "resolving a bound key disarms")
    }

    /// Step 3: armed + the prefix AGAIN (double-tap) → send the LITERAL prefix byte (send-prefix
    /// passthrough), and disarm.
    func testArmedPlusPrefixSendsLiteralAndDisarms() {
        let m = makeMachine()
        _ = m.feed(KeyChord(character: "a", [.control]), at: 0)
        XCTAssertEqual(m.feed(KeyChord(character: "a", [.control]), at: 0.1), .sendPrefixLiteral)
        XCTAssertFalse(m.isArmed, "double-tap disarms after sending the literal prefix")
    }

    /// Step 4: armed + escape-TIMEOUT → the stale arm falls back to idle; a key arriving past the deadline is
    /// classified as NORMAL typing (passthrough), NOT swallowed.
    func testArmedTimeoutFallsThroughToPassthrough() {
        let m = makeMachine(timeout: 1)
        _ = m.feed(KeyChord(character: "a", [.control]), at: 0)
        XCTAssertTrue(m.isArmed)
        // A bare key 1.5s later: the arm has expired → the key passes through (the prefix is forgotten).
        XCTAssertEqual(m.feed(KeyChord(character: "x"), at: 1.5), .passthrough(KeyChord(character: "x")))
        XCTAssertFalse(m.isArmed)
    }

    /// Step 4 (no-key path): advancing the clock past the timeout disarms via `expireIfStale` alone (the
    /// view's idle timer), with no keystroke.
    func testExpireIfStaleDisarmsWithoutAKey() {
        let m = makeMachine(timeout: 1)
        _ = m.feed(KeyChord(character: "a", [.control]), at: 0)
        m.expireIfStale(at: 0.5)
        XCTAssertTrue(m.isArmed, "still within the window")
        m.expireIfStale(at: 1.0)
        XCTAssertFalse(m.isArmed, "the arm expires once now reaches since+timeout")
    }

    /// Step 5: armed + an UNBOUND key → DISARM and SWALLOW that key (tmux-faithful; the prefix is NOT
    /// replayed and the follow-up key is eaten).
    func testArmedPlusUnboundKeyDisarmSwallows() {
        let m = makeMachine()
        _ = m.feed(KeyChord(character: "a", [.control]), at: 0)
        XCTAssertEqual(m.feed(KeyChord(character: "z"), at: 0.1), .disarmSwallow)
        XCTAssertFalse(m.isArmed, "an unbound key disarms")
    }

    /// Step 6: idle + a bare UNMODIFIED key → ALWAYS passthrough (never swallow normal typing). This is the
    /// load-bearing PTY-passthrough guard.
    func testIdlePlusBareKeyAlwaysPassesThrough() {
        let m = makeMachine()
        XCTAssertEqual(m.feed(KeyChord(character: "h"), at: 0), .passthrough(KeyChord(character: "h")))
        XCTAssertEqual(m.feed(KeyChord(character: "i"), at: 0.01), .passthrough(KeyChord(character: "i")))
        XCTAssertFalse(m.isArmed, "normal typing never arms the machine")
    }

    /// The prefix is CONFIGURABLE off a Ctrl-letter: with prefix `⌘B`, `⌃A` is now NORMAL typing
    /// (passthrough) and `⌘B` arms. Proves the policy "move the prefix off a Ctrl-letter".
    func testConfigurablePrefixMovesArmKey() {
        let m = makeMachine(prefix: KeyChord(character: "b", [.command]))
        // The OLD default ⌃A is now just a key → passthrough.
        XCTAssertEqual(
            m.feed(KeyChord(character: "a", [.control]), at: 0),
            .passthrough(KeyChord(character: "a", [.control])),
        )
        XCTAssertFalse(m.isArmed)
        // The configured ⌘B arms.
        XCTAssertEqual(m.feed(KeyChord(character: "b", [.command]), at: 0.1), .consumedArm)
        XCTAssertTrue(m.isArmed)
    }

    /// The live registry table can be injected as the resolver: after the prefix, `d` resolves to the
    /// registry's split-right via `resolvedSequenceTable` (single-chord sequences resolve through it). Ties
    /// B2 to the B1 sequence table without an AppKit dispatcher.
    func testResolverCanReadResolvedSequenceTable() {
        let table = WorkspaceBindingRegistry.resolvedSequenceTable
        let m = PrefixStateMachine(prefix: KeyChord(character: "a", [.control]), timeout: 1) { chord in
            table[KeySequence(single: chord)]
        }
        _ = m.feed(KeyChord(character: "a", [.control]), at: 0)
        // ⌘D split-right is a single-chord sequence in the registry table.
        XCTAssertEqual(m.feed(KeyChord(character: "d", [.command]), at: 0.1), .resolved(.splitRight))
    }

    /// FINDING-2 regression: a multi-key prefix SEQUENCE whose tail key is NOT a standalone single-chord
    /// binding still fires. The injected `resolveSequenceAfterPrefix` is consulted FIRST with the completed
    /// `[prefix, follow-up]` sequence; the single-chord `resolveAfterPrefix` here returns `nil` for the tail
    /// key, so on the un-fixed machine (sequence resolver absent) this would `.disarmSwallow` instead of
    /// `.resolved`. Proves the machine — not the surface — owns the sequence walk.
    func testMultiKeySequenceFiresWhenTailKeyIsNotAStandaloneBinding() throws {
        let prefix = KeyChord(character: "a", [.control])
        // The tail key `g` is bound ONLY as the second key of the sequence ⌃A→g — never standalone.
        let prefixThenG = try XCTUnwrap(KeySequence([prefix, KeyChord(character: "g")]))
        let sequenceTable: [KeySequence: WorkspaceAction] = [prefixThenG: .splitDown]
        let m = PrefixStateMachine(
            prefix: prefix,
            timeout: 1,
            resolveAfterPrefix: { _ in nil }, // `g` is NOT a standalone single chord
            resolveSequenceAfterPrefix: { sequenceTable[$0] },
        )
        XCTAssertEqual(m.feed(prefix, at: 0), .consumedArm)
        XCTAssertEqual(
            m.feed(KeyChord(character: "g"), at: 0.1), .resolved(.splitDown),
            "the completed ⌃A→g sequence resolves via the sequence resolver even though `g` is unbound alone",
        )
        XCTAssertFalse(m.isArmed)
    }

    /// FINDING-2: the sequence resolver takes PRECEDENCE over the single-chord fallback when BOTH could match
    /// the tail key, but a tail key the sequence table does NOT cover still falls back to the single-chord
    /// resolver — so the seeded ⌃A→⌘D (⌘D also a standalone chord) keeps working.
    func testSequenceResolverFallsBackToSingleChordTable() {
        let prefix = KeyChord(character: "a", [.control])
        let m = PrefixStateMachine(
            prefix: prefix,
            timeout: 1,
            resolveAfterPrefix: { $0 == KeyChord(character: "d", [.command]) ? .splitRight : nil },
            resolveSequenceAfterPrefix: { _ in nil }, // no multi-key sequence covers this tail key
        )
        _ = m.feed(prefix, at: 0)
        XCTAssertEqual(
            m.feed(KeyChord(character: "d", [.command]), at: 0.1), .resolved(.splitRight),
            "a tail key uncovered by the sequence table falls back to the single-chord resolver",
        )
    }
}
