import AislopdeskCLICore
import AislopdeskProtocol
import XCTest

// Hang-safe tests for the user-facing `aislopdesk` CLI's pure core (otty-clone E20, WI-1).
//
// No socket, no GUI, no subprocess. The `AislopdeskCLICore` library (global-flag parsing, the
// `version` summary builder, the per-shell completion generator) is driven directly. The
// `aislopdesk` executable's socket I/O + GUI launch live in `main.swift` and are compiled +
// code-reviewed only (hang-safety rule).

// MARK: - CLIArgs

final class CLIArgsTests: XCTestCase {
    func testBareInvocationLaunchesGUI() {
        guard case let .success(inv) = CLIArgs.parse(["aislopdesk"]) else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(inv.subcommand, "")
        XCTAssertTrue(inv.launchGUI)
        XCTAssertFalse(inv.wantsHelp)
    }

    /// M8-dash-e-noop: `-e` is NOT a recognised flag — an aislopdesk pane is a remote PTY with no local
    /// shell to exec into, so otty's `-e <cmd>` had no faithful mapping and was a silent no-op (it launched
    /// the GUI and dropped the command). It is de-advertised: passing `-e` before a subcommand is an
    /// unknown-flag error, never a silent GUI launch. Revert-to-confirm-fail: the pre-fix parser returned
    /// `.success` (launchGUI, execCommand=["vim",...]); this now demands `.failure(.unknownFlag("-e"))`.
    func testExecFlagIsAnUnknownFlagError() {
        guard case let .failure(err) = CLIArgs.parse(["aislopdesk", "-e", "vim", "file.txt"]) else {
            XCTFail("expected -e to be an unknown-flag error, not a GUI launch")
            return
        }
        XCTAssertEqual(err, .unknownFlag("-e"))
    }

    func testVersionSubcommandIsNotAGUILaunch() {
        guard case let .success(inv) = CLIArgs.parse(["aislopdesk", "version"]) else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(inv.subcommand, "version")
        XCTAssertFalse(inv.launchGUI)
    }

    func testJsonFlag() {
        guard case let .success(inv) = CLIArgs.parse(["aislopdesk", "panes", "--json"]) else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(inv.subcommand, "panes")
        XCTAssertEqual(inv.format, .json)
    }

    func testFormatJsonEquivalentToJsonFlag() {
        guard case let .success(viaFormat) = CLIArgs.parse(["aislopdesk", "panes", "--format", "json"]),
              case let .success(viaJson) = CLIArgs.parse(["aislopdesk", "panes", "--json"])
        else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(viaFormat.format, .json)
        XCTAssertEqual(viaFormat, viaJson)
    }

    func testFormatTextSelectsText() {
        guard case let .success(inv) = CLIArgs.parse(["aislopdesk", "panes", "--format", "text"]) else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(inv.format, .text)
    }

    func testFormatRejectsUnknownValue() {
        guard case let .failure(err) = CLIArgs.parse(["aislopdesk", "panes", "--format", "yaml"]) else {
            XCTFail("expected failure")
            return
        }
        XCTAssertEqual(err, .invalidValue(flag: "--format", value: "yaml"))
    }

    func testNoHeadersSocketConfigFileTimeoutYes() {
        let args = [
            "aislopdesk", "panes",
            "--no-headers",
            "--socket", "/tmp/x.sock",
            "--config-file", "/tmp/c.toml",
            "--timeout", "5000",
            "--yes",
        ]
        guard case let .success(inv) = CLIArgs.parse(args) else {
            XCTFail("expected success")
            return
        }
        XCTAssertTrue(inv.noHeaders)
        XCTAssertEqual(inv.socketPath, "/tmp/x.sock")
        XCTAssertEqual(inv.configFile, "/tmp/c.toml")
        XCTAssertEqual(inv.timeoutMs, 5000)
        XCTAssertTrue(inv.assumeYes)
    }

    func testTimeoutDefault() {
        guard case let .success(inv) = CLIArgs.parse(["aislopdesk", "panes"]) else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(inv.timeoutMs, CLIArgs.defaultTimeoutMs)
        XCTAssertEqual(inv.timeoutMs, 3000)
    }

    func testTimeoutRejectsNonInteger() {
        guard case let .failure(err) = CLIArgs.parse(["aislopdesk", "panes", "--timeout", "soon"]) else {
            XCTFail("expected failure")
            return
        }
        XCTAssertEqual(err, .invalidValue(flag: "--timeout", value: "soon"))
    }

    func testShortYesFlag() {
        guard case let .success(inv) = CLIArgs.parse(["aislopdesk", "close", "-y"]) else {
            XCTFail("expected success")
            return
        }
        XCTAssertTrue(inv.assumeYes)
    }

    func testHelpFlagsSetWantsHelpNotGUI() {
        for flag in ["-h", "--help"] {
            guard case let .success(inv) = CLIArgs.parse(["aislopdesk", flag]) else {
                XCTFail("expected success for \(flag)")
                return
            }
            XCTAssertTrue(inv.wantsHelp, "\(flag) should set wantsHelp")
            XCTAssertFalse(inv.launchGUI, "\(flag) should not launch the GUI")
        }
    }

    func testUnknownFlagBeforeSubcommandIsError() {
        guard case let .failure(err) = CLIArgs.parse(["aislopdesk", "--bogus"]) else {
            XCTFail("expected failure")
            return
        }
        XCTAssertEqual(err, .unknownFlag("--bogus"))
    }

    func testUnknownFlagAfterSubcommandPassesThrough() {
        // Subcommand-specific flags (e.g. `pane send-keys --pane 2`) are not global flags; they
        // must survive into `rest` for the per-subcommand parser.
        guard case let .success(inv) = CLIArgs.parse(["aislopdesk", "pane", "--pane", "2"]) else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(inv.subcommand, "pane")
        XCTAssertEqual(inv.rest, ["--pane", "2"])
    }

    func testGlobalFlagAfterSubcommandIsConsumed() {
        guard case let .success(inv) = CLIArgs.parse(["aislopdesk", "panes", "--socket", "/x"]) else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(inv.subcommand, "panes")
        XCTAssertEqual(inv.socketPath, "/x")
        XCTAssertTrue(inv.rest.isEmpty)
    }

    func testEndOfOptionsPassesRemainderVerbatim() {
        // After a bare `--`, even global-flag-looking tokens are literal operands (so `send-keys`
        // can carry `--socket` as literal text without it being consumed as a global flag).
        let args = ["aislopdesk", "pane", "send-keys", "--pane", "2", "--", "--socket", "literal"]
        guard case let .success(inv) = CLIArgs.parse(args) else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(inv.subcommand, "pane")
        XCTAssertEqual(inv.rest, ["send-keys", "--pane", "2", "--", "--socket", "literal"])
        // The post-`--` `--socket` is NOT consumed as a global flag.
        XCTAssertNil(inv.socketPath)
    }

    func testMissingValueForSocket() {
        guard case let .failure(err) = CLIArgs.parse(["aislopdesk", "--socket"]) else {
            XCTFail("expected failure")
            return
        }
        XCTAssertEqual(err, .missingValue("--socket"))
    }
}

// MARK: - CLIVersion

final class CLIVersionTests: XCTestCase {
    func testSummaryContainsNameAndVersion() {
        let summary = CLIVersion.versionSummary(environment: [:])
        XCTAssertTrue(summary.contains("aislopdesk"))
        XCTAssertTrue(summary.contains("0.1.0"))
    }

    func testSummaryContainsProtocolVersion() {
        let summary = CLIVersion.versionSummary(environment: [:])
        XCTAssertTrue(summary.contains("protocol"))
        XCTAssertTrue(summary.contains("v1"), "expected wire-protocol v1 in: \(summary)")
    }

    func testBuildHashShownWhenSet() {
        let summary = CLIVersion.versionSummary(environment: [CLIVersion.buildHashEnvKey: "abc1234"])
        XCTAssertTrue(summary.contains("abc1234"), "expected build hash in: \(summary)")
    }

    func testBuildHashOmittedWhenUnset() {
        let summary = CLIVersion.versionSummary(environment: [:])
        // No build parenthetical on the head line when the env var is absent.
        let firstLine = summary.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "aislopdesk 0.1.0")
    }

    func testEmptyBuildHashTreatedAsUnset() {
        let summary = CLIVersion.versionSummary(environment: [CLIVersion.buildHashEnvKey: ""])
        let firstLine = summary.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "aislopdesk 0.1.0")
    }
}

// MARK: - CLICompletions

final class CLICompletionsTests: XCTestCase {
    /// Independently-authored golden of the Claude-only subcommand surface. Authored here (not
    /// derived from `CLICompletions.subcommands`) so a silent change to the surface — in particular
    /// an accidental `codex`/`opencode` entry — FAILS this test.
    private let expectedSurface = [
        "open", "view", "edit",
        "config", "font", "theme", "keybind",
        "window", "windows", "tab", "tabs", "pane", "panes",
        "watch", "watch:claude",
        "jump", "learn", "ignore",
        "import", "export", "features",
        "completions", "version",
        "state:claude", "ipc", "help",
    ]

    func testSubcommandSurfaceMatchesGolden() {
        XCTAssertEqual(CLICompletions.subcommands, expectedSurface)
    }

    func testSurfaceIsClaudeOnly() {
        XCTAssertTrue(CLICompletions.subcommands.contains("watch:claude"))
        XCTAssertTrue(CLICompletions.subcommands.contains("state:claude"))
        for sub in CLICompletions.subcommands {
            XCTAssertFalse(sub.contains("codex"), "unexpected codex token: \(sub)")
            XCTAssertFalse(sub.contains("opencode"), "unexpected opencode token: \(sub)")
        }
    }

    func testEveryShellIsNonEmptyAndClaudeOnly() {
        for shell in CLICompletions.Shell.allCases {
            let script = CLICompletions.completionScript(for: shell).lowercased()
            XCTAssertFalse(script.isEmpty, "\(shell) produced an empty script")
            XCTAssertTrue(script.contains("watch:claude"), "\(shell) missing watch:claude")
            // The headline exclusion: no non-Claude agent ever appears in completions.
            XCTAssertFalse(script.contains("codex"), "\(shell) leaked codex")
            XCTAssertFalse(script.contains("opencode"), "\(shell) leaked opencode")
        }
    }

    func testEveryShellMentionsEverySubcommand() {
        for shell in CLICompletions.Shell.allCases {
            let script = CLICompletions.completionScript(for: shell)
            for sub in CLICompletions.subcommands {
                XCTAssertTrue(script.contains(sub), "\(shell) script omits '\(sub)'")
            }
        }
    }

    func testShellSpecificMarkers() {
        let bash = CLICompletions.completionScript(for: .bash)
        XCTAssertTrue(bash.contains("complete -F _aislopdesk aislopdesk"))
        let zsh = CLICompletions.completionScript(for: .zsh)
        XCTAssertTrue(zsh.contains("#compdef aislopdesk"))
        let fish = CLICompletions.completionScript(for: .fish)
        XCTAssertTrue(fish.contains("complete -c aislopdesk"))
        let elvish = CLICompletions.completionScript(for: .elvish)
        XCTAssertTrue(elvish.contains("edit:completion:arg-completer[aislopdesk]"))
        let powershell = CLICompletions.completionScript(for: .powershell)
        XCTAssertTrue(powershell.contains("Register-ArgumentCompleter"))
    }

    /// Per-shell golden for bash: pins the rendered structure + the embedded space-joined surface
    /// (built from the independently-authored `expectedSurface`, not from the impl's own list) so a
    /// renderer refactor cannot silently change the emitted script. The single trailing newline is
    /// pinned by `hasSuffix`.
    func testBashGolden() {
        let bash = CLICompletions.completionScript(for: .bash)
        XCTAssertTrue(bash.hasPrefix("# aislopdesk bash completion"))
        XCTAssertTrue(bash.contains("_aislopdesk() {"))
        XCTAssertTrue(bash.contains(#"COMPREPLY=( $(compgen -W "${subcommands}" -- "${cur}") )"#))
        XCTAssertTrue(bash.contains("local subcommands=\"\(expectedSurface.joined(separator: " "))\""))
        XCTAssertTrue(bash.hasSuffix("complete -F _aislopdesk aislopdesk\n"))
    }

    func testShellArgumentParsing() {
        XCTAssertEqual(CLICompletions.Shell(argument: "bash"), .bash)
        XCTAssertEqual(CLICompletions.Shell(argument: "ZSH"), .zsh)
        XCTAssertEqual(CLICompletions.Shell(argument: "fish"), .fish)
        XCTAssertEqual(CLICompletions.Shell(argument: "elvish"), .elvish)
        XCTAssertEqual(CLICompletions.Shell(argument: "powershell"), .powershell)
        XCTAssertEqual(CLICompletions.Shell(argument: "pwsh"), .powershell)
        XCTAssertNil(CLICompletions.Shell(argument: "tcsh"))
    }
}

// MARK: - WatchProgress (E20 WI-7)

/// Tests for the `aislopdesk watch` byte vocabulary. The EXPECTED byte strings are authored
/// independently here (literal `ESC ] 9 ; 4 ; <state> BEL` / `ESC ] 9 ; <body> BEL`), not derived
/// from `WatchProgress`'s own output, so a silent change to the emitted bytes FAILS these tests
/// (revert-to-confirm-fail). A cross-check feeds the emitted progress bytes through the INDEPENDENT
/// host-side `ProgressOSCParser` to prove the host will decode them into the intended state.
final class WatchProgressTests: XCTestCase {
    /// `ESC ] 9 ; 4 ; <state> BEL` literal, byte for byte.
    private func progressLiteral(_ stateDigit: Character) -> [UInt8] {
        Array("\u{1B}]9;4;\(stateDigit)\u{07}".utf8)
    }

    func testSpinnerBytesAreIndeterminateProgress() {
        XCTAssertEqual(WatchProgress.spinnerBytes, progressLiteral("3"))
        // Exhaustive byte pin so a reordered/reterminated builder can't slip through.
        XCTAssertEqual(WatchProgress.spinnerBytes, [0x1B, 0x5D, 0x39, 0x3B, 0x34, 0x3B, 0x33, 0x07])
    }

    func testFinishBytesSuccessClearsTheIndicator() {
        XCTAssertEqual(WatchProgress.finishBytes(exitCode: 0), progressLiteral("0"))
    }

    func testFinishBytesFailureHoldsTheErrorBadge() {
        // Every non-zero exit (incl. signal-shaped 130 and 255) maps to the SAME error badge.
        let failures: [Int32] = [1, 2, 127, 130, 255]
        for exit in failures {
            XCTAssertEqual(
                WatchProgress.finishBytes(exitCode: exit), progressLiteral("2"),
                "exit \(exit) should emit the error (2) progress badge",
            )
        }
    }

    func testExitToProgressMapping() {
        XCTAssertEqual(WatchProgress.exitToProgress(0), .clear)
        XCTAssertEqual(WatchProgress.exitToProgress(1), .error)
        XCTAssertEqual(WatchProgress.exitToProgress(2), .error)
        XCTAssertEqual(WatchProgress.exitToProgress(127), .error)
        XCTAssertEqual(WatchProgress.exitToProgress(255), .error)
    }

    /// The emitted progress bytes must be decodable by the host's own parser — strip the
    /// `ESC ] 9 ;` framing + trailing `BEL`, hand the remainder to `ProgressOSCParser`, and confirm
    /// it lands on the intended `ProgressState`. This couples the builder to the REAL host contract,
    /// not to its own derivation.
    func testEmittedBytesParseBackViaHostParser() {
        func body(of bytes: [UInt8]) -> String {
            // bytes are ESC ] 9 ; <body> BEL — drop the 3-byte ESC]9 + ';' prefix and the BEL.
            let prefix = Array("\u{1B}]9;".utf8)
            XCTAssertTrue(bytes.starts(with: prefix), "missing OSC 9 prefix")
            XCTAssertEqual(bytes.last, 0x07, "missing BEL terminator")
            let inner = bytes.dropFirst(prefix.count).dropLast()
            return String(bytes: inner, encoding: .utf8) ?? ""
        }
        XCTAssertEqual(ProgressOSCParser.parse(body(of: WatchProgress.spinnerBytes))?.state, .indeterminate)
        XCTAssertEqual(ProgressOSCParser.parse(body(of: WatchProgress.finishBytes(exitCode: 0)))?.state, .clear)
        XCTAssertEqual(ProgressOSCParser.parse(body(of: WatchProgress.finishBytes(exitCode: 3)))?.state, .error)
    }

    func testNotificationBytesWrapMessageAsFreeTextOSC9() {
        XCTAssertEqual(
            WatchProgress.notificationBytes(message: "watch: make finished"),
            Array("\u{1B}]9;watch: make finished\u{07}".utf8),
        )
    }

    func testNotificationBytesEmptyMessageEmitsNothing() {
        XCTAssertTrue(WatchProgress.notificationBytes(message: "").isEmpty)
    }

    /// M8-watch-notify-toggle: the watch-FINISH banner must NOT use the generic free-text OSC-9 form (which
    /// the host routes to `.explicitOSC` / the master switch). It rides OSC 777 carrying the private
    /// `WatchNotificationMarker` sentinel in the TITLE field, so the client routes it to `.watchFinish`
    /// (gated by Notify on Watch Finish). Revert-to-confirm-fail: swapping this back to `notificationBytes`
    /// (the OSC-9 form) drops the marker and the 777 framing, failing this pin.
    func testWatchFinishNotificationBytesCarryMarkerOnOSC777() {
        let message = "watch: make finished"
        XCTAssertEqual(
            WatchProgress.watchFinishNotificationBytes(message: message),
            Array("\u{1B}]777;notify;\(WatchNotificationMarker.title);\(message)\u{07}".utf8),
        )
        // The marker is ';'-free so the OSC-777 split preserves it as a single title field.
        XCTAssertFalse(WatchNotificationMarker.title.contains(";"))
    }

    func testWatchFinishNotificationBytesEmptyMessageEmitsNothing() {
        XCTAssertTrue(WatchProgress.watchFinishNotificationBytes(message: "").isEmpty)
    }

    func testFinishMessageSuccessAndFailureText() {
        XCTAssertEqual(WatchProgress.finishMessage(command: ["make"], exitCode: 0), "watch: make finished")
        XCTAssertEqual(
            WatchProgress.finishMessage(command: ["npm", "run", "build"], exitCode: 2),
            "watch: npm run build failed (exit 2)",
        )
    }

    /// The watch-finish notification body must NEVER begin with the `4;`/`4` progress subtype the
    /// host carves out of free-text OSC 9 (else the banner would be silently swallowed as progress).
    /// The `watch: ` prefix guarantees this even for a command literally named `4`.
    func testFinishMessageNeverCollidesWithProgressSubtype() {
        let exitCases: [Int32] = [0, 1]
        for command in [["make"], ["4"], ["4;something"], []] {
            for exit in exitCases {
                let message = WatchProgress.finishMessage(command: command, exitCode: exit)
                XCTAssertTrue(message.hasPrefix("watch: "), "message must be labelled: \(message)")
                XCTAssertFalse(message.hasPrefix("4;"), "message must not be a 9;4 subtype: \(message)")
                XCTAssertNotEqual(message, "4")
            }
        }
    }
}
