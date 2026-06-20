import Foundation
import XCTest
@testable import AislopdeskClientUI

/// The pure launch-preset model + expansion (docs/42 W14 #9, Warp launch-configuration parity): a preset
/// → the pane spec(s) + the keystrokes to type after each pane connects, including the `cd` prefix, the
/// optional split, and the shipped built-ins. No store, no transport.
final class LaunchPresetEngineTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { String(bytes: bytes, encoding: .utf8) ?? "" }

    // MARK: Single-pane expansion

    func testSimpleCommandPreset() {
        let preset = LaunchPreset(name: "htop", command: "htop")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertNil(plan.splitAxis)
        XCTAssertEqual(plan.panes.count, 1)
        XCTAssertEqual(plan.panes[0].spec.kind, .terminal)
        XCTAssertEqual(plan.panes[0].spec.title, "htop")
        XCTAssertEqual(text(plan.panes[0].keystrokes), "htop\n")
    }

    func testEmptyCommandSendsNoKeystrokes() {
        let preset = LaunchPreset(name: "Shell", command: "")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.panes.count, 1)
        XCTAssertTrue(plan.panes[0].keystrokes.isEmpty)
    }

    func testWorkingDirectoryEmitsCdPrefix() {
        let preset = LaunchPreset(name: "Build", command: "make", workingDirectory: "/Users/me/proj")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "cd '/Users/me/proj'\nmake\n")
    }

    func testWorkingDirectoryWithSpacesIsQuoted() {
        let preset = LaunchPreset(name: "X", command: "ls", workingDirectory: "/a b/c")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "cd '/a b/c'\nls\n")
    }

    func testWorkingDirectoryWithSingleQuoteIsEscaped() {
        let preset = LaunchPreset(name: "X", command: "ls", workingDirectory: "/it's/here")
        let plan = LaunchPresetEngine.plan(for: preset)
        // POSIX single-quote escape: ' -> '\''
        XCTAssertEqual(text(plan.panes[0].keystrokes), "cd '/it'\\''s/here'\nls\n")
    }

    func testEmptyCwdAndCommandIsPlainShell() {
        let preset = LaunchPreset(name: "Shell", command: "  ", workingDirectory: "")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertTrue(plan.panes[0].keystrokes.isEmpty)
    }

    // MARK: SECURITY — cwd command injection (the cwd is a PATH, never SendKeysParser input)

    /// REGRESSION (was a command-injection hole): a cwd containing a `SendKeysParser` token like
    /// `<Enter>` must NOT inject a 0x0D/0x0A inside the quoted `cd` path. On the un-fixed code the cwd
    /// was run through `SendKeysParser.encode`, which turned `<Enter>` into a literal newline mid-path,
    /// breaking out of `cd '…'` so the remainder ran as a SEPARATE shell command.
    func testCwdWithSendKeysTokenDoesNotInjectNewline() {
        let preset = LaunchPreset(
            name: "X", command: "ls",
            workingDirectory: "/tmp/proj<Enter>rm -rf important",
        )
        let plan = LaunchPresetEngine.plan(for: preset)
        let bytes = plan.panes[0].keystrokes
        // The `cd` line is everything up to (and excluding) the FIRST real newline.
        let firstNL = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
        let cdLine = Array(bytes[bytes.startIndex..<firstNL])
        // No raw CR/LF may appear inside that `cd` line — the `<Enter>` token stayed LITERAL in the path.
        XCTAssertFalse(cdLine.contains(0x0D), "0x0D injected inside the cd path")
        XCTAssertFalse(cdLine.contains(0x0A), "0x0A injected inside the cd path")
        // The literal token survives verbatim inside the single-quoted path.
        XCTAssertEqual(text(cdLine), "cd '/tmp/proj<Enter>rm -rf important'")
        // Exactly one `cd` line + the command line: two newlines total, no injected third command.
        XCTAssertEqual(bytes.count(where: { $0 == 0x0A }), 2)
        XCTAssertEqual(text(bytes), "cd '/tmp/proj<Enter>rm -rf important'\nls\n")
    }

    /// The COMMAND field, by contrast, legitimately resolves `SendKeysParser` tokens (intended shell
    /// input — a snippet-style `<Enter>` in a command IS meant to send a newline).
    func testCommandWithSendKeysTokenResolves() {
        let preset = LaunchPreset(name: "X", command: "echo hi<Enter>echo bye")
        let plan = LaunchPresetEngine.plan(for: preset)
        // <Enter> → 0x0D (CR) between the two echoes, then the trailing 0x0A from the line.
        XCTAssertEqual(plan.panes[0].keystrokes, Array("echo hi".utf8) + [0x0D] + Array("echo bye".utf8) + [0x0A])
    }

    /// P4 #12: a preset with BOTH a token-bearing command AND a token-bearing cwd — the cwd token stays
    /// LITERAL inside the quoted `cd` (security), while the command token resolves (intended input).
    func testCommandAndCwdBothWithTokens() {
        let preset = LaunchPreset(
            name: "X", command: "echo hi<Enter>echo bye",
            workingDirectory: "/tmp/p<Enter>j",
        )
        let plan = LaunchPresetEngine.plan(for: preset)
        let bytes = plan.panes[0].keystrokes
        // cd line: the cwd <Enter> is literal (no injected newline in the path).
        let firstNL = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
        XCTAssertEqual(text(Array(bytes[bytes.startIndex..<firstNL])), "cd '/tmp/p<Enter>j'")
        // command line: the command <Enter> resolves to a CR; whole stream as expected.
        let expected = Array("cd '/tmp/p<Enter>j'".utf8) + [0x0A]
            + Array("echo hi".utf8) + [0x0D] + Array("echo bye".utf8) + [0x0A]
        XCTAssertEqual(bytes, expected)
    }

    // MARK: Two-pane (split) expansion

    func testSplitPresetMakesTwoPanesAndCarriesAxis() {
        let preset = LaunchPreset(
            name: "Dev", command: "nvim .",
            split: .init(axis: .horizontal, secondaryCommand: "npm run watch"),
        )
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.splitAxis, .horizontal)
        XCTAssertEqual(plan.panes.count, 2)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "nvim .\n")
        XCTAssertEqual(text(plan.panes[1].keystrokes), "npm run watch\n")
    }

    func testSplitSecondPaneInheritsWorkingDirectory() {
        let preset = LaunchPreset(
            name: "Dev", command: "nvim .", workingDirectory: "/proj",
            split: .init(axis: .vertical, secondaryCommand: "ls"),
        )
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.splitAxis, .vertical)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "cd '/proj'\nnvim .\n")
        XCTAssertEqual(text(plan.panes[1].keystrokes), "cd '/proj'\nls\n")
    }

    // MARK: Built-ins

    func testBuiltInsArePresentAndStable() {
        let names = LaunchPreset.builtIns.map(\.name)
        XCTAssertEqual(names, ["Claude Code", "htop", "Git log"])
        XCTAssertTrue(LaunchPreset.builtIns.allSatisfy(\.isBuiltIn))
        // P4 #11: PIN the stable ids (not a self-comparison) — a re-seed / settings-reset matches the
        // SAME row by id (idempotent, no duplicate). These literals must never drift, or a reset would
        // duplicate built-ins on an existing workspace. The ids are the compile-time-constant literals in
        // `LaunchPreset.builtIns`.
        XCTAssertEqual(
            LaunchPreset.builtIns.map { $0.id.uuidString.lowercased() },
            [
                "11111111-0000-4000-8000-000000000001",
                "11111111-0000-4000-8000-000000000002",
                "11111111-0000-4000-8000-000000000003",
            ],
            "built-in launch-preset UUIDs are frozen for idempotent re-seed",
        )
    }

    func testClaudeCodeBuiltInRunsClaude() throws {
        let claude = try XCTUnwrap(LaunchPreset.builtIns.first { $0.name == "Claude Code" })
        let plan = LaunchPresetEngine.plan(for: claude)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "claude\n")
        XCTAssertNil(plan.splitAxis)
    }

    func testGitLogBuiltInExpands() throws {
        let gitLog = try XCTUnwrap(LaunchPreset.builtIns.first { $0.name == "Git log" })
        let plan = LaunchPresetEngine.plan(for: gitLog)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "git log --oneline --graph --decorate -30\n")
    }

    // MARK: Codable round-trip (it persists on the workspace like LayoutPreset/Snippet)

    func testCodableRoundTrip() throws {
        let preset = LaunchPreset(
            name: "Dev", command: "nvim .", workingDirectory: "/proj",
            split: .init(axis: .horizontal, secondaryCommand: "watch"), symbol: "hammer",
        )
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(LaunchPreset.self, from: data)
        XCTAssertEqual(preset, back)
    }
}
