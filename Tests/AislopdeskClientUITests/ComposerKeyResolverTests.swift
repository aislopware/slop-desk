// ComposerKeyResolverTests (E12 / WI-5) — the PURE Return-key mapping the Composer field dispatches. The
// core invariant is "Return alone never sends — accidental sends are impossible by design"; this pins that
// contract headlessly (no SwiftUI view, no responder, no GhosttySurface/VT/Metal). The view only DISPATCHES
// the action this resolver returns, so proving the mapping here proves the keyboard behaviour.
//
// Revert-to-confirm-fail: change the bare-Return arm to `.send` and `testBareReturnIsNewlineNeverSend` fails
// — these are not tautologies against the resolver's own derivation.

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI

final class ComposerKeyResolverTests: XCTestCase {
    /// `⌘↩` sends — the only send gesture.
    func testCommandReturnSends() {
        XCTAssertEqual(
            ComposerKeyResolver.resolveReturn(command: true, option: false, queueMode: false),
            .send,
        )
    }

    /// `⌥⌘↩` always enqueues — never sends — regardless of mode (checked BEFORE the bare `⌘↩` send arm).
    func testOptionCommandReturnEnqueuesInBothModes() {
        XCTAssertEqual(
            ComposerKeyResolver.resolveReturn(command: true, option: true, queueMode: false),
            .enqueue,
        )
        XCTAssertEqual(
            ComposerKeyResolver.resolveReturn(command: true, option: true, queueMode: true),
            .enqueue,
        )
    }

    /// A bare Return (and `⇧↩`, which carries no command/option) in normal Composer mode is a NEWLINE — the
    /// "Return never sends" safety invariant. If this ever resolved to `.send`, a half-written message could fire.
    func testBareReturnIsNewlineNeverSend() {
        let action = ComposerKeyResolver.resolveReturn(command: false, option: false, queueMode: false)
        XCTAssertEqual(action, .newline)
        XCTAssertNotEqual(action, .send)
    }

    /// A bare Return in Prompt-Queue INPUT mode adds the typed line to the queue (the `⌘⇧M` bar's `↩`).
    func testBareReturnInQueueModeEnqueues() {
        XCTAssertEqual(
            ComposerKeyResolver.resolveReturn(command: false, option: false, queueMode: true),
            .enqueue,
        )
    }

    /// `⌘↩` still SENDS even in queue-input mode (send precedence over the bare-↩ enqueue) — the spec's
    /// "`⌘↩` (plain) … sends and runs the draft immediately".
    func testCommandReturnSendsEvenInQueueMode() {
        XCTAssertEqual(
            ComposerKeyResolver.resolveReturn(command: true, option: false, queueMode: true),
            .send,
        )
    }

    /// `⎋` is the Composer's cancel-keep-draft ONLY when no IME composition is in flight. While the text view
    /// `hasMarkedText()` (Telex / Pinyin / Kotoeri mid-composition), `⎋` belongs to the input context — it
    /// drops the marked text — so it must NOT be treated as composer-cancel. Revert-to-confirm-fail: drop the
    /// `!` in `escapeCancels` and the marked-text arm flips.
    func testEscapeCancelsOnlyWithoutMarkedText() {
        XCTAssertTrue(
            ComposerKeyResolver.escapeCancels(hasMarkedText: false),
            "no IME composition → ⎋ cancels the Composer (keeps the draft)",
        )
        XCTAssertFalse(
            ComposerKeyResolver.escapeCancels(hasMarkedText: true),
            "IME composing → ⎋ drops the marked text, it does NOT cancel the Composer",
        )
    }

    /// Return must defer to the input context while an IME composition is in flight — otherwise a bare `↩`
    /// in Prompt-Queue mode (or `⌘↩`) would enqueue/send the raw, uncommitted marked text (Telex/Pinyin/
    /// Kotoeri) instead of letting the input context commit it. Revert-to-confirm-fail: hardcode `false` in
    /// `returnDefersToIME` and this fails.
    func testReturnDefersToIMEOnlyWithMarkedText() {
        XCTAssertFalse(
            ComposerKeyResolver.returnDefersToIME(hasMarkedText: false),
            "no IME composition → Return resolves normally (newline/enqueue/send)",
        )
        XCTAssertTrue(
            ComposerKeyResolver.returnDefersToIME(hasMarkedText: true),
            "IME composing → Return belongs to the input context, it does NOT enqueue/send the draft",
        )
    }
}
#endif
