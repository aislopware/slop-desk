import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the pure ``PastePrecheck`` — the embedder's paste entry-point decision that makes
/// paste-protection reachable for the danger classes libghostty's own (narrower) `isSafe` gate misses.
///
/// The bug this guards: libghostty trips `confirm_read_clipboard_cb` (the only old caller of
/// ``PasteSafetyAnalyzer``) ONLY for a `\n` / bracketed-end payload, so a SINGLE-LINE `sudo`, an ESC-laced
/// control-char paste, or a bare-`\r` paste reached the shell SILENTLY — two of the four advertised
/// paste dangers were suppressed. ``PastePrecheck/decide(clipboard:protectionOn:isAlternateScreen:)`` runs the
/// analyzer BEFORE handing the bytes to libghostty, so all four classes confirm regardless of newlines.
///
/// These assertions are discriminating, not tautological: an implementation that returned `.pasteDirect`
/// for single-line `sudo` (the OLD silent behaviour) fails ``testSingleLineSudoConfirms``; one that ignored
/// the protection toggle fails ``testProtectionOffPastesDirect``; one that dropped the alt-screen skip fails
/// ``testAlternateScreenPastesDirectEvenWhenDangerous``.
final class PastePrecheckTests: XCTestCase {
    private typealias Dangers = PasteSafetyAnalyzer.PasteDangers

    /// Extracts the dangers from a `.confirm` decision (fails the test on `.pasteDirect`).
    private func confirmedDangers(
        _ decision: PastePrecheckDecision,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) -> Dangers {
        guard case let .confirm(dangers) = decision else {
            XCTFail("expected .confirm, got \(decision)", file: file, line: line)
            return []
        }
        return dangers
    }

    // MARK: - The reachability fix: single-line dangers libghostty's `isSafe` MISSES must confirm

    /// THE headline bug: a single-line `sudo rm -rf /` (no newline → libghostty `isSafe == true`) must still
    /// confirm. Before the embedder pre-check this pasted silently.
    func testSingleLineSudoConfirms() {
        let decision = PastePrecheck.decide(
            clipboard: "sudo rm -rf /",
            protectionOn: true,
            isAlternateScreen: false,
        )
        XCTAssertTrue(confirmedDangers(decision).contains(.sudoOrSu))
    }

    /// A single-line paste carrying an embedded ESC (no newline → `isSafe == true`) — the terminal-escape
    /// injection vector — must confirm.
    func testSingleLineControlCharConfirms() {
        let decision = PastePrecheck.decide(
            clipboard: "echo \u{1b}[31mhi",
            protectionOn: true,
            isAlternateScreen: false,
        )
        XCTAssertTrue(confirmedDangers(decision).contains(.controlChars))
    }

    /// A bare `\r` (CR, no LF) paste — libghostty's `isSafe` flags only `\n`, so this reached the shell
    /// silently and ran the command. The trailing CR is classified as a trailing-newline danger → confirm.
    func testBareCarriageReturnConfirms() {
        let decision = PastePrecheck.decide(
            clipboard: "make deploy\r",
            protectionOn: true,
            isAlternateScreen: false,
        )
        XCTAssertTrue(confirmedDangers(decision).contains(.trailingNewline))
    }

    /// A multi-line paste (libghostty WOULD catch this) still confirms through the pre-check — the embedder
    /// is now the single authority, so the same sheet appears whether or not libghostty's gate would route it.
    func testMultiLinePasteConfirms() {
        let decision = PastePrecheck.decide(
            clipboard: "echo one\necho two\n",
            protectionOn: true,
            isAlternateScreen: false,
        )
        let dangers = confirmedDangers(decision)
        XCTAssertTrue(dangers.contains(.multiLine))
        XCTAssertTrue(dangers.contains(.trailingNewline))
    }

    // MARK: - pasteDirect: safe / protection off / alt-screen

    /// A plainly-safe single line → paste straight through libghostty (no dialog).
    func testSafeSingleLinePastesDirect() {
        XCTAssertEqual(
            PastePrecheck.decide(clipboard: "git status", protectionOn: true, isAlternateScreen: false),
            .pasteDirect,
        )
    }

    /// Protection OFF → never confirm, even for an unambiguously dangerous payload.
    func testProtectionOffPastesDirect() {
        XCTAssertEqual(
            PastePrecheck.decide(clipboard: "sudo rm -rf /\n", protectionOn: false, isAlternateScreen: false),
            .pasteDirect,
        )
    }

    /// A full-screen TUI owns the screen (alt-screen) → the paste lands inertly, so skip the sheet even for a
    /// dangerous payload (matches the analyzer's alt-screen skip rule).
    func testAlternateScreenPastesDirectEvenWhenDangerous() {
        XCTAssertEqual(
            PastePrecheck.decide(clipboard: "sudo reboot", protectionOn: true, isAlternateScreen: true),
            .pasteDirect,
        )
    }

    // MARK: - Bracketed-safe skip (the "Paste Bracketed Safe" setting on a program advertising DEC ?2004h)

    /// The headline Bug-1 fix: with "Paste Bracketed Safe" ON and the foreground program advertising
    /// bracketed paste (DECSET `?2004h`), even a multi-line / trailing-newline paste lands inertly framed →
    /// paste direct, NO sheet. Before the fix these flags were hardcoded `false`, so this nagged on every
    /// multi-line paste into a bracketed-paste shell.
    func testBracketedSafeAndProgramAdvertisedPastesDirect() {
        XCTAssertEqual(
            PastePrecheck.decide(
                clipboard: "echo one\necho two\n",
                protectionOn: true,
                isAlternateScreen: false,
                bracketedSafe: true,
                programAdvertisedBracketed: true,
            ),
            .pasteDirect,
        )
    }

    /// The skip requires BOTH: with the setting on but the program NOT advertising bracketed paste, the
    /// multi-line paste still confirms (a raw shell that never sent `?2004h` executes each line).
    func testBracketedSafeButProgramNotAdvertisingConfirms() {
        let decision = PastePrecheck.decide(
            clipboard: "echo one\necho two\n",
            protectionOn: true,
            isAlternateScreen: false,
            bracketedSafe: true,
            programAdvertisedBracketed: false,
        )
        XCTAssertTrue(confirmedDangers(decision).contains(.multiLine))
    }

    /// Symmetrically: program advertises bracketed paste but the user turned "Paste Bracketed Safe" OFF →
    /// the multi-line paste still confirms.
    func testProgramAdvertisedButSettingOffConfirms() {
        let decision = PastePrecheck.decide(
            clipboard: "echo one\necho two\n",
            protectionOn: true,
            isAlternateScreen: false,
            bracketedSafe: false,
            programAdvertisedBracketed: true,
        )
        XCTAssertTrue(confirmedDangers(decision).contains(.multiLine))
    }

    /// Empty clipboard → nothing to warn about → paste direct (a no-op paste downstream).
    func testEmptyClipboardPastesDirect() {
        XCTAssertEqual(
            PastePrecheck.decide(clipboard: "", protectionOn: true, isAlternateScreen: false),
            .pasteDirect,
        )
    }
}
