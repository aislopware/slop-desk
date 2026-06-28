import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

// MARK: - SnippetAliasExpanderTests (E16 ES-E16-4 — at-prompt alias auto-expansion engine)

/// Pins the PURE ``SnippetAliasExpander`` brain that drives otty's "typing an alias at the shell prompt expands
/// it" feature (`textsnippet-apply.gif`). Everything is headless — no view, no NSWindow, no surface: the engine
/// is fed a prompt mark + outbound bytes and asked for the expansion to send. The wiring into the live input
/// path (`TerminalViewModel.sendInput` / `ingestOutput` / `expandSnippetAlias`) is pinned by
/// ``SnippetAliasExpansionWiringTests``.
@MainActor
final class SnippetAliasExpanderTests: XCTestCase {
    /// The spec's example snippet: alias `gco`, body `git checkout {{cursor}}`. The injected `resolveBytes`
    /// stub stands in for the real reserved-var/`{{cursor}}` resolution (pinned separately) — it returns the
    /// already-resolved `git checkout ` body so this suite isolates the ENGINE (gating + erase + concat).
    private static let gco = Snippet(name: "Checkout", body: "git checkout {{cursor}}", alias: "gco")
    private static let resolvedBody = Array("git checkout ".utf8)

    private func makeExpander(
        enabled: Bool = true,
        atPrompt: Bool = true,
        snippets: [Snippet] = [SnippetAliasExpanderTests.gco],
        resolve: @escaping (Snippet) -> [UInt8] = { _ in SnippetAliasExpanderTests.resolvedBody },
    ) -> SnippetAliasExpander {
        SnippetAliasExpander(
            snippets: { snippets },
            isEnabled: { enabled },
            isAtPrompt: { atPrompt },
            resolveBytes: resolve,
        )
    }

    /// Type each character of `text` as the surface would: one printable-ASCII byte per `noteSent`.
    private func type(_ text: String, into expander: SnippetAliasExpander) {
        for byte in Array(text.utf8) { expander.noteSent([byte]) }
    }

    // MARK: - The happy path (erase the alias, inject the body)

    /// After a prompt mark, typing the alias and triggering expands it: `alias.count` DELs erase the typed
    /// alias, then the resolved body. REVERT-TO-CONFIRM-FAIL: with the engine unwired (no `expansion()` caller
    /// in production), the alias would never expand — exactly the gap this fixes.
    func testExpandsTrailingAliasAfterPromptMark() {
        let expander = makeExpander()
        expander.notePromptMark()
        type("gco", into: expander)

        let expansion = expander.expansion()
        XCTAssertEqual(expansion?.erasedCharacters, 3, "erases the 3-char alias `gco`")
        XCTAssertEqual(
            expansion?.bytes,
            [0x7F, 0x7F, 0x7F] + Self.resolvedBody,
            "3 DELs to erase `gco`, then the resolved `git checkout ` body",
        )
    }

    /// The trailing-word boundary is preserved: leading shell text (`git status && `) is untouched — only the
    /// alias word is erased and replaced.
    func testExpandsOnlyTheTrailingWord() {
        let expander = makeExpander()
        expander.notePromptMark()
        type("git status && gco", into: expander)

        XCTAssertEqual(
            expander.expansion()?.bytes,
            [0x7F, 0x7F, 0x7F] + Self.resolvedBody,
            "still 3 DELs (only the trailing `gco`), then the body — the prefix is left in place",
        )
    }

    /// A DEL keystroke pops the mirror so a typo-then-correct still matches: `gcox` ⌫ → `gco` → expands.
    func testDeleteEditsTheMirror() {
        let expander = makeExpander()
        expander.notePromptMark()
        type("gcox", into: expander)
        expander.noteSent([0x7F]) // backspace the stray `x`

        XCTAssertEqual(expander.expansion()?.erasedCharacters, 3, "after ⌫ the mirror is `gco` again → expands")
    }

    // MARK: - The gates (each one alone blocks expansion)

    /// No prompt mark → the mirror is never TRUSTED → no expansion (we only expand a line we can prove).
    func testNoExpansionWithoutPromptMark() {
        let expander = makeExpander()
        type("gco", into: expander) // typed while untrusted → mirror stays empty
        XCTAssertNil(expander.expansion(), "without an OSC-133;A prompt mark the line is untrusted → no expand")
    }

    /// The `snippetAutoExpand` setting OFF blocks expansion even with a perfect trailing-alias match (default
    /// OFF means ordinary typing is untouched until the user opts in).
    func testDisabledNeverExpands() {
        let expander = makeExpander(enabled: false)
        expander.notePromptMark()
        type("gco", into: expander)
        XCTAssertNil(expander.expansion(), "setting off → never expands")
    }

    /// Not at an OSC-133;A prompt (e.g. an alt-screen TUI owns the screen) → no expansion.
    func testNotAtPromptNeverExpands() {
        let expander = makeExpander(atPrompt: false)
        expander.notePromptMark()
        type("gco", into: expander)
        XCTAssertNil(expander.expansion(), "not at a shell prompt → never expands")
    }

    /// An alias that is only PART of a longer word (`mygco`) does NOT expand — never corrupt ordinary typing.
    func testMidWordDoesNotExpand() {
        let expander = makeExpander()
        expander.notePromptMark()
        type("mygco", into: expander)
        XCTAssertNil(expander.expansion(), "no word boundary in front of the alias → no expand")
    }

    /// An unknown trailing word matches no alias → nil.
    func testUnknownAliasDoesNotExpand() {
        let expander = makeExpander()
        expander.notePromptMark()
        type("deploy", into: expander)
        XCTAssertNil(expander.expansion(), "unknown alias → no expand")
    }

    /// A snippet that DECLINES (empty resolved body — the wiring declines a still-parameterized `ssh {{host}}`)
    /// never expands, even on a perfect alias match.
    func testEmptyResolvedBodyDeclines() {
        let expander = makeExpander(resolve: { _ in [] })
        expander.notePromptMark()
        type("gco", into: expander)
        XCTAssertNil(expander.expansion(), "an empty resolved body (declined snippet) → no expand")
    }

    // MARK: - Trust discipline (mirror only the unambiguous; clear on everything else)

    /// A control byte (here ESC) on the line drops trust — we cannot mirror it, so we refuse to expand until the
    /// next prompt mark. Guards against a stale mirror driving a wrong-character erase.
    func testControlByteDropsTrust() {
        let expander = makeExpander()
        expander.notePromptMark()
        type("gco", into: expander)
        expander.noteSent([0x1B]) // ESC — un-mirrorable → drop trust
        XCTAssertNil(expander.expansion(), "an ESC on the line untrusts the mirror → no expand")
    }

    /// A multi-byte chunk (paste / committed IME / mouse report) drops trust; subsequent typing is NOT mirrored
    /// until the next prompt mark, so a paste anywhere on the line disables expansion (conservative + safe).
    func testMultiByteChunkDropsTrust() {
        let expander = makeExpander()
        expander.notePromptMark()
        expander.noteSent(Array("paste".utf8)) // 5-byte chunk → drop trust
        type("gco", into: expander) // ignored — mirror is untrusted
        XCTAssertNil(expander.expansion(), "a paste untrusts the line → later typing is not mirrored → no expand")
    }

    /// After an expansion the mirror is untrusted so a SECOND expansion cannot chain on the same line — a fresh
    /// prompt mark is required. Re-arming with `notePromptMark()` lets the next alias expand again.
    func testExpansionUntrustsToPreventChaining() {
        let expander = makeExpander()
        expander.notePromptMark()
        type("gco", into: expander)
        XCTAssertNotNil(expander.expansion(), "first expansion fires")

        type("gco", into: expander) // untrusted after the first expand → not mirrored
        XCTAssertNil(expander.expansion(), "no chaining without a fresh prompt mark")

        expander.notePromptMark()
        type("gco", into: expander)
        XCTAssertNotNil(expander.expansion(), "a fresh prompt mark re-arms expansion")
    }

    /// `reset()` drops trust (focus loss / alt-screen entry) so a previously-trusted line no longer expands.
    func testResetDropsTrust() {
        let expander = makeExpander()
        expander.notePromptMark()
        type("gco", into: expander)
        expander.reset()
        XCTAssertNil(expander.expansion(), "reset() untrusts the mirror → no expand")
    }
}
