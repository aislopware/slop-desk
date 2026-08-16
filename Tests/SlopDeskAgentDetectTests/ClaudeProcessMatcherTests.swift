import XCTest
@testable import SlopDeskAgentDetect

/// Who holds the PTY foreground: `claude` itself, or a runtime that commonly wraps one.
/// Exact basenames only, and never a trap on weird input.
///
/// (The screen-cue half of this type is gone — the rule ladder in `rust/slopdesk-screend` covers
/// nineteen agents with upstream's own rules and a differential harness proving it, and two screen
/// matchers is exactly what this tree does not keep. Those cases moved with the code.)
final class ClaudeProcessMatcherTests: XCTestCase {
    private let m = ClaudeProcessMatcher()

    // MARK: Presence via process name

    func testRunsClaudeFromProcessName() {
        XCTAssertTrue(m.isClaudeRunning(processName: "claude"))
        XCTAssertTrue(m.isClaudeRunning(processName: "/usr/local/bin/claude"))
        XCTAssertFalse(m.isClaudeRunning(processName: "zsh"))
        XCTAssertFalse(m.isClaudeRunning(processName: "claudefoo"), "exact basename only — no substring false-positive")
        XCTAssertFalse(m.isClaudeRunning(processName: ""))
    }

    // MARK: Robustness — never trap on hostile / huge / non-ASCII input

    func testHugeAndUnicodeInputDoesNotCrash() {
        let huge = String(repeating: "🤖 claude 漢字/", count: 50000)
        XCTAssertFalse(m.isClaudeRunning(processName: huge))
        XCTAssertFalse(m.isLikelyWrapper(processName: huge))
        // Control bytes decoded as text — a verdict, never a crash.
        let garbage = String(repeating: "\u{0007}\u{001B}[2J\u{0000}", count: 1000)
        XCTAssertFalse(m.isClaudeRunning(processName: garbage))
        XCTAssertFalse(m.isLikelyWrapper(processName: garbage))
    }

    /// A path whose last non-empty component IS `claude` counts however deep it is, or however
    /// untidily it is spelled; a path with no component at all matches nothing.
    func testPathShapesAtTheEdges() {
        XCTAssertTrue(m.isClaudeRunning(processName: "/a/b/c/d/e/claude"))
        XCTAssertTrue(m.isClaudeRunning(processName: "/usr/local/bin/claude/"), "empty components are skipped")
        XCTAssertFalse(m.isClaudeRunning(processName: "/"))
        XCTAssertFalse(m.isClaudeRunning(processName: "/usr/local/bin/claude/wrapper"))
    }

    // MARK: Wrapper classification (queue-safety)

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
