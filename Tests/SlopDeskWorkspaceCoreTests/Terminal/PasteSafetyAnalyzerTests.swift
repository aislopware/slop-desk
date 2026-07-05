import XCTest
@testable import SlopDeskWorkspaceCore

/// E8 WI-4 (ES-E8-3): pins the pure ``PasteSafetyAnalyzer`` — the paste-protection danger detection
/// (multi-line / trailing-newline / sudo-su / control-char) and the skip rules (protection off, empty,
/// full-screen TUI alt-screen, bracketed-safe). Every assertion targets a SINGLE behaviour and several
/// are deliberately discriminating (a naive substring / "any newline" implementation FAILS them), so the
/// suite is a real revert-to-confirm-fail oracle rather than a tautology.
final class PasteSafetyAnalyzerTests: XCTestCase {
    private typealias Dangers = PasteSafetyAnalyzer.PasteDangers

    // MARK: - analyze: empty / safe

    func testEmptyHasNoDangers() {
        XCTAssertEqual(PasteSafetyAnalyzer.analyze(""), [])
    }

    func testSingleSafeLineHasNoDangers() {
        // No newline, no control chars, no sudo/su token → no dangers at all.
        XCTAssertEqual(PasteSafetyAnalyzer.analyze("ls -la /tmp"), [])
    }

    // MARK: - analyze: multi-line vs trailing-newline (the discriminating pair)

    func testInteriorNewlineIsMultiLine() {
        let d = PasteSafetyAnalyzer.analyze("echo one\necho two")
        XCTAssertTrue(d.contains(.multiLine))
        // No trailing terminator → trailing-newline must NOT be set.
        XCTAssertFalse(d.contains(.trailingNewline))
    }

    func testSingleTrailingNewlineIsNotMultiLine() {
        // This is the case a naive `contains("\n")` would mis-flag as multi-line. A lone trailing
        // newline is ONLY the trailing-newline danger.
        let d = PasteSafetyAnalyzer.analyze("whoami\n")
        XCTAssertTrue(d.contains(.trailingNewline))
        XCTAssertFalse(d.contains(.multiLine))
    }

    func testMultiLineWithTrailingNewlineSetsBoth() {
        let d = PasteSafetyAnalyzer.analyze("echo one\necho two\n")
        XCTAssertTrue(d.contains(.multiLine))
        XCTAssertTrue(d.contains(.trailingNewline))
    }

    func testCRLFTrailingStrippedExactlyOnce() {
        // "a\r\n" is a single line with a CRLF terminator — trailing-newline only, NOT multi-line.
        let d = PasteSafetyAnalyzer.analyze("a\r\n")
        XCTAssertTrue(d.contains(.trailingNewline))
        XCTAssertFalse(d.contains(.multiLine))
    }

    func testInteriorCRIsMultiLine() {
        let d = PasteSafetyAnalyzer.analyze("a\rb")
        XCTAssertTrue(d.contains(.multiLine))
    }

    // MARK: - analyze: sudo / su word-boundary

    func testSudoCommandFlags() {
        XCTAssertTrue(PasteSafetyAnalyzer.analyze("sudo rm -rf /").contains(.sudoOrSu))
    }

    func testSuCommandFlags() {
        XCTAssertTrue(PasteSafetyAnalyzer.analyze("su - root").contains(.sudoOrSu))
    }

    func testSudoAfterShellSeparatorFlags() {
        XCTAssertTrue(PasteSafetyAnalyzer.analyze("cd /etc && sudo vi hosts").contains(.sudoOrSu))
    }

    func testWordContainingSuIsNotFlagged() {
        // "supervisor" / "issue" CONTAIN the letters but are different tokens — a naive
        // `text.contains("su")` would wrongly flag these.
        XCTAssertFalse(PasteSafetyAnalyzer.analyze("supervisor restart nginx").contains(.sudoOrSu))
        XCTAssertFalse(PasteSafetyAnalyzer.analyze("git commit -m \"fix issue\"").contains(.sudoOrSu))
    }

    // MARK: - analyze: control chars

    func testEscControlCharFlags() {
        // An embedded ESC (0x1B) is the terminal-escape-injection vector.
        let d = PasteSafetyAnalyzer.analyze("ls\u{1b}[31mred")
        XCTAssertTrue(d.contains(.controlChars))
    }

    func testTabAndNewlineAreNotControlChars() {
        // TAB / LF / CR are excluded from the control-char danger.
        XCTAssertFalse(PasteSafetyAnalyzer.analyze("col1\tcol2").contains(.controlChars))
        XCTAssertFalse(PasteSafetyAnalyzer.analyze("line1\nline2").contains(.controlChars))
    }

    // MARK: - shouldWarn: skip rules

    private let danger = "sudo rm -rf /\nrm important\n" // multi-line + trailing + sudo

    func testShouldWarnOnDangerousPaste() {
        XCTAssertTrue(PasteSafetyAnalyzer.shouldWarn(
            text: danger,
            protectionOn: true,
            bracketedSafe: false,
            programAdvertisedBracketed: false,
            isAlternateScreen: false,
        ))
    }

    func testProtectionOffNeverWarns() {
        XCTAssertFalse(PasteSafetyAnalyzer.shouldWarn(
            text: danger,
            protectionOn: false,
            bracketedSafe: false,
            programAdvertisedBracketed: false,
            isAlternateScreen: false,
        ))
    }

    func testEmptyNeverWarns() {
        XCTAssertFalse(PasteSafetyAnalyzer.shouldWarn(
            text: "",
            protectionOn: true,
            bracketedSafe: false,
            programAdvertisedBracketed: false,
            isAlternateScreen: false,
        ))
    }

    func testAlternateScreenSkipsEvenDangerousPaste() {
        // Full-screen TUI: without the alt-screen guard this would warn — this is the discriminating
        // assertion for the "skip inside full-screen TUI" rule.
        XCTAssertFalse(PasteSafetyAnalyzer.shouldWarn(
            text: danger,
            protectionOn: true,
            bracketedSafe: false,
            programAdvertisedBracketed: false,
            isAlternateScreen: true,
        ))
    }

    func testBracketedSafeAndAdvertisedSkips() {
        XCTAssertFalse(PasteSafetyAnalyzer.shouldWarn(
            text: danger,
            protectionOn: true,
            bracketedSafe: true,
            programAdvertisedBracketed: true,
            isAlternateScreen: false,
        ))
    }

    func testBracketedSafeButNotAdvertisedStillWarns() {
        // Bracketed-safe is set, but the program did NOT advertise bracketed paste → no inert framing,
        // so the danger still applies.
        XCTAssertTrue(PasteSafetyAnalyzer.shouldWarn(
            text: danger,
            protectionOn: true,
            bracketedSafe: true,
            programAdvertisedBracketed: false,
            isAlternateScreen: false,
        ))
    }

    func testAdvertisedButBracketedSafeOffStillWarns() {
        // The program advertised bracketed paste, but the user disabled "Paste Bracketed Safe" → warn.
        XCTAssertTrue(PasteSafetyAnalyzer.shouldWarn(
            text: danger,
            protectionOn: true,
            bracketedSafe: false,
            programAdvertisedBracketed: true,
            isAlternateScreen: false,
        ))
    }

    func testSafePayloadDoesNotWarn() {
        XCTAssertFalse(PasteSafetyAnalyzer.shouldWarn(
            text: "git status",
            protectionOn: true,
            bracketedSafe: false,
            programAdvertisedBracketed: false,
            isAlternateScreen: false,
        ))
    }

    // MARK: - descriptions

    func testDescriptionsListEachFlaggedDangerInStableOrder() {
        let all: Dangers = [.multiLine, .trailingNewline, .sudoOrSu, .controlChars]
        let lines = PasteSafetyAnalyzer.descriptions(for: all)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].localizedCaseInsensitiveContains("Multiple lines"))
        XCTAssertTrue(lines[1].localizedCaseInsensitiveContains("newline"))
        XCTAssertTrue(lines[2].localizedCaseInsensitiveContains("sudo"))
        XCTAssertTrue(lines[3].localizedCaseInsensitiveContains("control"))
    }

    func testDescriptionsEmptyForNoDangers() {
        XCTAssertEqual(PasteSafetyAnalyzer.descriptions(for: []), [])
    }
}
