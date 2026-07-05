import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The pure launch-preset model + expansion (docs/42 W14 #9, Warp launch-configuration parity): a preset
/// → the pane spec(s) + the keystrokes to type after each pane connects. The working directory lives on
/// the pane spec for host-side spawn cwd; only commands become keystrokes. No store, no transport.
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

    func testWorkingDirectoryStampsPaneSpecAndDoesNotEmitCdPrefix() {
        let preset = LaunchPreset(name: "Build", command: "make", workingDirectory: "/Users/me/proj")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.panes[0].spec.lastKnownCwd, "/Users/me/proj")
        XCTAssertEqual(text(plan.panes[0].keystrokes), "make\n")
    }

    func testWorkingDirectoryWithSpacesStampsPaneSpec() {
        let preset = LaunchPreset(name: "X", command: "ls", workingDirectory: "/a b/c")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.panes[0].spec.lastKnownCwd, "/a b/c")
        XCTAssertEqual(text(plan.panes[0].keystrokes), "ls\n")
    }

    func testWorkingDirectoryWithSingleQuoteStampsPaneSpec() {
        let preset = LaunchPreset(name: "X", command: "ls", workingDirectory: "/it's/here")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.panes[0].spec.lastKnownCwd, "/it's/here")
        XCTAssertEqual(text(plan.panes[0].keystrokes), "ls\n")
    }

    func testEmptyCwdAndCommandIsPlainShell() {
        let preset = LaunchPreset(name: "Shell", command: "  ", workingDirectory: "")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertTrue(plan.panes[0].keystrokes.isEmpty)
    }

    // MARK: SECURITY — cwd never enters SendKeysParser

    /// A cwd containing a `SendKeysParser` token like `<Enter>` is stored as a path string only. It must not
    /// contribute CR/LF bytes to the startup keystrokes.
    func testCwdWithSendKeysTokenDoesNotInjectNewline() {
        let preset = LaunchPreset(
            name: "X", command: "ls",
            workingDirectory: "/tmp/proj<Enter>rm -rf important",
        )
        let plan = LaunchPresetEngine.plan(for: preset)
        let bytes = plan.panes[0].keystrokes
        XCTAssertEqual(plan.panes[0].spec.lastKnownCwd, "/tmp/proj<Enter>rm -rf important")
        XCTAssertFalse(bytes.contains(0x0D), "cwd token injected CR into startup keystrokes")
        XCTAssertEqual(bytes.count(where: { $0 == 0x0A }), 1)
        XCTAssertEqual(text(bytes), "ls\n")
    }

    /// The COMMAND field, by contrast, legitimately resolves `SendKeysParser` tokens (intended shell
    /// input — a send-keys-style `<Enter>` in a command IS meant to send a newline).
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
        XCTAssertEqual(plan.panes[0].spec.lastKnownCwd, "/tmp/p<Enter>j")
        XCTAssertEqual(bytes, Array("echo hi".utf8) + [0x0D] + Array("echo bye".utf8) + [0x0A])
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
        XCTAssertEqual(plan.panes[0].spec.lastKnownCwd, "/proj")
        XCTAssertEqual(plan.panes[1].spec.lastKnownCwd, "/proj")
        XCTAssertEqual(text(plan.panes[0].keystrokes), "nvim .\n")
        XCTAssertEqual(text(plan.panes[1].keystrokes), "ls\n")
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

    // MARK: Codable round-trip (it persists on the workspace like LayoutPreset)

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
