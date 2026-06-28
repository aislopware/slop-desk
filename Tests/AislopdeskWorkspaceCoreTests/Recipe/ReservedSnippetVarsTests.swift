import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins WI-2 of E16: the `ReservedSnippetVars` reserved-var layer ABOVE the user-prompt `SnippetExpander`.
/// Reserved `{{clipboard}}`/`{{date}}`/`{{time}}` resolve from INJECTED strings (never the real clock /
/// pasteboard), `{{cursor}}` strips to a byte offset with NO auto-Enter, reserved names never surface in
/// `missing`/`placeholders`, and any other `{{x}}` still falls through to the user-prompt expander.
/// Fully headless — no view, no NSWindow, no pasteboard, no `Date()`.
final class ReservedSnippetVarsTests: XCTestCase {
    // MARK: - {{date}} / {{time}} resolve from injected strings (empty missing)

    func testDateAndTimeResolveFromInjectedStringsWithEmptyMissing() {
        let reserved = ReservedSnippetValues(date: "2026-06-28", time: "09:41")
        let r = ReservedSnippetVars.resolve(body: "{{date}} {{time}}", reserved: reserved)
        XCTAssertEqual(r.text, "2026-06-28 09:41", "injected date/time substituted in place")
        // Revert-to-confirm-fail: a bare SnippetExpander reports `date`/`time` in `missing`; the reserved
        // layer must resolve them so `missing` is empty.
        XCTAssertEqual(r.missing, [], "reserved names are NEVER reported as missing user prompts")
        XCTAssertNil(r.cursorOffset, "no {{cursor}} → no caret offset")
    }

    func testReservedNamesAreNotMissingEvenWhenInjectedValueIsEmpty() {
        // An EMPTY injected clipboard still counts as "resolved" — it must not fall back to a user prompt.
        let r = ReservedSnippetVars.resolve(body: "echo {{clipboard}}", reserved: ReservedSnippetValues())
        XCTAssertEqual(r.text, "echo ", "empty clipboard substitutes to empty, not the literal {{clipboard}}")
        XCTAssertEqual(r.missing, [], "an empty reserved value is still resolved, never missing")
    }

    // MARK: - {{cursor}} → byte offset, no auto-Enter

    func testCursorStrippedToByteOffsetWithNoTrailingEnter() {
        let r = ReservedSnippetVars.resolve(body: "git checkout {{cursor}}", reserved: ReservedSnippetValues())
        XCTAssertEqual(r.text, "git checkout ", "the {{cursor}} marker is stripped from the text")
        XCTAssertEqual(r.cursorOffset, 13, "caret byte offset sits at the end of 'git checkout '")
        XCTAssertFalse(r.text.hasSuffix("\n"), "NO auto-Enter is ever appended for {{cursor}}")
        XCTAssertEqual(r.missing, [])
    }

    func testCursorOffsetIsComputedAfterSubstitutionNotIntoTheRawBody() {
        // The offset is into the FINAL text: substituting {{date}} (10 chars) before the caret moves the
        // offset to 11 — a naive byte index into the raw body ("{{date}} " = 9) would be wrong.
        let r = ReservedSnippetVars.resolve(
            body: "{{date}} {{cursor}}",
            reserved: ReservedSnippetValues(date: "2026-06-28"),
        )
        XCTAssertEqual(r.text, "2026-06-28 ")
        XCTAssertEqual(r.cursorOffset, 11, "caret offset reflects the substituted date length")
    }

    func testCursorOffsetIsUTF8ByteCountForMultibyteText() {
        // 'é' is two UTF-8 bytes, so the caret after "café " is at byte 6, not character 5.
        let r = ReservedSnippetVars.resolve(body: "café {{cursor}}", reserved: ReservedSnippetValues())
        XCTAssertEqual(r.text, "café ")
        XCTAssertEqual(r.cursorOffset, 6, "byte offset, not character offset")
    }

    func testCursorInTheMiddleKeepsTrailingText() {
        let r = ReservedSnippetVars.resolve(body: "vim {{cursor}}/etc/hosts", reserved: ReservedSnippetValues())
        XCTAssertEqual(r.text, "vim /etc/hosts", "text after the caret is preserved")
        XCTAssertEqual(r.cursorOffset, 4, "caret lands right after 'vim '")
    }

    // MARK: - {{clipboard}} substituted

    func testClipboardSubstituted() {
        let reserved = ReservedSnippetValues(clipboard: "feature/login")
        let r = ReservedSnippetVars.resolve(body: "git checkout {{clipboard}}", reserved: reserved)
        XCTAssertEqual(r.text, "git checkout feature/login")
        XCTAssertEqual(r.missing, [])
    }

    // MARK: - unknown {{x}} still falls through to the user-prompt expander

    func testUnknownPlaceholderStillReportedInMissing() {
        // A mixed body: reserved {{date}} resolves, but unknown {{host}} is left literal and reported as a
        // user prompt (the expander layer below still owns it).
        let r = ReservedSnippetVars.resolve(
            body: "ssh {{host}} {{date}}",
            reserved: ReservedSnippetValues(date: "2026-06-28"),
        )
        XCTAssertEqual(r.text, "ssh {{host}} 2026-06-28", "unknown {{host}} stays literal; reserved {{date}} resolves")
        XCTAssertEqual(r.missing, ["host"], "the unknown name is still a user prompt")
    }

    func testUnknownPlaceholderResolvedWhenAUserValueIsProvided() {
        // The reserved layer composes with user values — a provided value clears the prompt.
        let r = ReservedSnippetVars.resolve(
            body: "ssh {{host}}",
            reserved: ReservedSnippetValues(),
            values: ["host": "build01"],
        )
        XCTAssertEqual(r.text, "ssh build01")
        XCTAssertEqual(r.missing, [], "a supplied user value resolves the slot")
    }

    func testUserValueCannotShadowAReservedName() {
        // A user can't override a reserved name by smuggling it into `values` — the injected reserved string
        // always wins.
        let r = ReservedSnippetVars.resolve(
            body: "{{date}}",
            reserved: ReservedSnippetValues(date: "2026-06-28"),
            values: ["date": "HACKED"],
        )
        XCTAssertEqual(r.text, "2026-06-28", "the injected reserved value wins over a user-supplied 'date'")
    }

    // MARK: - reserved names NEVER appear in placeholders

    func testReservedNamesNeverAppearInUserPlaceholders() {
        let body = "{{date}} {{host}} {{cursor}} {{clipboard}} {{user}} {{time}}"
        XCTAssertEqual(
            ReservedSnippetVars.userPlaceholders(in: body),
            ["host", "user"],
            "only the non-reserved names are surfaced as user prompts, in first-appearance order",
        )
    }

    func testUserPlaceholdersEmptyWhenBodyIsAllReserved() {
        // A body of only reserved vars needs no value-entry sheet — it can run straight away.
        XCTAssertEqual(ReservedSnippetVars.userPlaceholders(in: "git checkout {{cursor}}"), [])
        XCTAssertEqual(ReservedSnippetVars.userPlaceholders(in: "echo {{date}} {{time}} {{clipboard}}"), [])
    }
}
