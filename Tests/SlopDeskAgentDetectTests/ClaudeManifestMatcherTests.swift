import XCTest
@testable import SlopDeskAgentDetect

/// Herdr-style no-hooks fallback: detect whether `claude` is running and a coarse
/// status (working vs waiting-for-input) from recognizable Claude Code TUI cues.
/// CONSERVATIVE — return `nil`/`.none` when unsure; never trap on weird input.
final class ClaudeManifestMatcherTests: XCTestCase {
    private let m = ClaudeManifestMatcher()

    // MARK: Presence via process name / OSC title

    func testRunsClaudeFromProcessName() {
        XCTAssertTrue(m.isClaudeRunning(processName: "claude"))
        XCTAssertTrue(m.isClaudeRunning(processName: "/usr/local/bin/claude"))
        XCTAssertFalse(m.isClaudeRunning(processName: "zsh"))
        XCTAssertFalse(m.isClaudeRunning(processName: "claudefoo"), "exact basename only — no substring false-positive")
        XCTAssertFalse(m.isClaudeRunning(processName: ""))
    }

    func testRunsClaudeFromTitle() {
        XCTAssertTrue(m.isClaudeRunning(title: "Claude: slopdesk"))
        XCTAssertTrue(m.isClaudeRunning(title: "✳ Claude Code"))
        XCTAssertFalse(m.isClaudeRunning(title: "zsh — ~/code"))
        XCTAssertFalse(m.isClaudeRunning(title: ""))
    }

    // MARK: Working cue — the "esc to interrupt" spinner line

    func testEscToInterruptIsWorking() {
        let screen = """
        ✻ Pondering… (12s · esc to interrupt)
        """
        XCTAssertEqual(m.coarseStatus(screen: screen), .working)
    }

    func testActionSpinnerVariantsAreWorking() {
        XCTAssertEqual(m.coarseStatus(screen: "✶ Forging… (esc to interrupt)"), .working)
        XCTAssertEqual(m.coarseStatus(screen: "Running… press esc to interrupt"), .working)
    }

    // MARK: Waiting-for-input cue — the permission / approval prompt

    func testPermissionPromptIsWaiting() {
        let screen = """
        Bash command
          rm -rf build/
        Do you want to proceed?
          ❯ 1. Yes
            2. No, and tell Claude what to do differently
        """
        XCTAssertEqual(m.coarseStatus(screen: screen), .needsPermission)
    }

    func testTrustPromptIsWaiting() {
        let screen = "Do you trust the files in this folder?\n  ❯ 1. Yes, proceed"
        XCTAssertEqual(m.coarseStatus(screen: screen), .needsPermission)
    }

    // MARK: Idle prompt — the empty compose box

    func testIdleComposeBoxIsIdle() {
        // Claude's idle prompt box: a bordered input with the hint line, no spinner.
        let screen = """
        ╭──────────────────────────────────────────────╮
        │ > Try "edit <file>" or ask a question          │
        ╰──────────────────────────────────────────────╯
          ? for shortcuts
        """
        XCTAssertEqual(m.coarseStatus(screen: screen), .idle)
    }

    // MARK: Conservative — unknown / ambiguous → none (NOT a wrong guess)

    func testNonClaudeShellScreenIsNone() {
        let screen = "dev@host ~/code % git status\nOn branch main\nnothing to commit"
        XCTAssertEqual(m.coarseStatus(screen: screen), Optional.none, "plain shell → no verdict")
    }

    func testAmbiguousScreenIsNone() {
        // Random prose that mentions neither a spinner nor an approval UI.
        XCTAssertEqual(m.coarseStatus(screen: "hello world\nthe quick brown fox"), Optional.none)
    }

    func testEmptyScreenIsNone() {
        XCTAssertEqual(m.coarseStatus(screen: ""), Optional.none)
    }

    // MARK: Precedence — a permission prompt outranks a stale spinner line in the buffer

    func testPermissionOutranksLeftoverSpinner() {
        // A scrolled buffer may still contain an old "esc to interrupt"; the live approval
        // UI at the bottom must win (waiting), not the stale spinner.
        let screen = """
        ✻ Working… (8s · esc to interrupt)
        ⎿  Read 200 lines
        Do you want to proceed?
          ❯ 1. Yes
            2. No
        """
        XCTAssertEqual(m.coarseStatus(screen: screen), .needsPermission)
    }

    // MARK: Robustness — never trap on hostile / huge / non-ASCII input

    func testHugeAndUnicodeInputDoesNotCrash() {
        let huge = String(repeating: "🤖 esc to interrupt 漢字\n", count: 50000)
        XCTAssertEqual(m.coarseStatus(screen: huge), .working)
        // Pure garbage bytes decoded as text — no verdict, no crash.
        let garbage = String(repeating: "\u{0007}\u{001B}[2J\u{0000}", count: 1000)
        _ = m.coarseStatus(screen: garbage) // must simply return without trapping
    }

    func testWhitespaceOnlyIsNone() {
        XCTAssertEqual(m.coarseStatus(screen: "   \n\t\n   "), Optional.none)
    }

    // MARK: Wrapper classification (queue-safety fix, 2026-07-02)

    /// The known launcher/runtime basenames that commonly host a wrapped `claude` classify as
    /// wrappers (path or bare basename) — and a wrapper is NOT claude presence.
    func testKnownWrapperBasenamesClassify() {
        for name in ["node", "npx", "bun", "deno", "mise", "/usr/local/bin/node", "/opt/homebrew/bin/mise"] {
            XCTAssertTrue(m.isLikelyWrapper(processName: name), "\(name) is a known wrapper runtime")
            XCTAssertFalse(m.isClaudeRunning(processName: name), "a wrapper is never claude presence")
        }
    }

    /// Shells / editors / claude itself / substring look-alikes are NOT wrappers — the shell
    /// returning to the foreground must stay the "claude exited" signal, and exact-match rules out
    /// `nodemon`-style false positives.
    func testNonWrapperBasenamesDoNotClassify() {
        for name in ["zsh", "bash", "fish", "vim", "claude", "nodemon", "denort", "", "python3"] {
            XCTAssertFalse(m.isLikelyWrapper(processName: name), "\(name) must not classify as a wrapper")
        }
    }
}
