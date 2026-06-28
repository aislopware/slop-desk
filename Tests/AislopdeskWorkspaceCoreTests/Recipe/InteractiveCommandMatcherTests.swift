import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins WI-5 of E16 (matcher half): the pure ``InteractiveCommandMatcher`` shell-handoff recognizer. It
/// matches the PROGRAM WORD (basename, leading env-assignments skipped), so `ssh host` / `tmux attach` /
/// `docker exec -it` / `su` are interactive while `echo ssh` / `git ssh-add` are not. The positive/negative
/// pairs are word-boundary aware — a naive `contains("ssh")` substring matcher would FAIL the negatives
/// (revert-to-confirm-fail). Fully headless — no process spawn, no I/O.
final class InteractiveCommandMatcherTests: XCTestCase {
    private let matcher = InteractiveCommandMatcher.default

    // MARK: - positive: interactive programs

    func testPlainInteractivePrograms() {
        let commands = [
            "ssh host", "ssh user@host", "mosh box", "su", "su -", "su root",
            "vim file.txt", "nvim", "vi /etc/hosts", "nano notes", "less log",
            "top", "htop", "man ls", "sftp host",
        ]
        for command in commands {
            XCTAssertTrue(matcher.isInteractive(command), "\(command) hands off to an interactive program")
        }
    }

    func testTmuxAttachVariants() {
        XCTAssertTrue(matcher.isInteractive("tmux attach"))
        XCTAssertTrue(matcher.isInteractive("tmux attach-session -t work"))
        XCTAssertTrue(matcher.isInteractive("tmux a"))
        // tmux WITHOUT an attach subcommand is not a handoff.
        XCTAssertFalse(matcher.isInteractive("tmux ls"), "tmux ls just lists sessions")
        XCTAssertFalse(matcher.isInteractive("tmux kill-server"))
    }

    func testDockerKubectlExecWithTTY() {
        XCTAssertTrue(matcher.isInteractive("docker exec -it container sh"))
        XCTAssertTrue(matcher.isInteractive("docker exec -ti container bash"))
        XCTAssertTrue(matcher.isInteractive("docker run -it ubuntu bash"))
        XCTAssertTrue(matcher.isInteractive("docker attach mycontainer"))
        XCTAssertTrue(matcher.isInteractive("kubectl exec -it pod -- sh"))
        XCTAssertTrue(matcher.isInteractive("docker exec -i -t container sh"), "separate -i -t allocate a tty")
    }

    func testDockerExecWithoutTTYIsNotInteractive() {
        // exec/run WITHOUT a tty flag is a one-shot, non-interactive command.
        XCTAssertFalse(matcher.isInteractive("docker exec container ls"))
        XCTAssertFalse(matcher.isInteractive("docker run ubuntu echo hi"))
        XCTAssertFalse(matcher.isInteractive("docker exec -i container cat"), "-i without -t is a pipe, not a tty")
    }

    // MARK: - leading env-assignments ignored

    func testLeadingEnvAssignmentsIgnored() {
        XCTAssertTrue(matcher.isInteractive("FOO=1 ssh host"), "a leading env-assignment is skipped")
        XCTAssertTrue(matcher.isInteractive("FOO=1 BAR=2 ssh host"))
        XCTAssertTrue(matcher.isInteractive("env FOO=1 ssh host"), "a bare leading env launcher is skipped")
        XCTAssertTrue(matcher.isInteractive("FOO='a b' ssh host"), "a quoted env value stays one token")
        // The assignment itself must not be mistaken for the program word.
        XCTAssertFalse(matcher.isInteractive("FOO=ssh echo hi"), "FOO=ssh is an assignment; the program is echo")
    }

    // MARK: - negative: word-boundary aware (revert-to-confirm-fail vs a substring matcher)

    func testNonInteractiveCommands() {
        let commands = [
            "echo ssh", "git ssh-add", "ssh-add", "ls -la", "cat file", "pwd",
            "git commit -m wip", "npm run dev", "docker ps", "docker build .",
            "grep top file", "echo vim",
        ]
        for command in commands {
            XCTAssertFalse(matcher.isInteractive(command), "\(command) is NOT a handoff to an interactive program")
        }
    }

    // MARK: - program path basename

    func testProgramPathIsMatchedByBasename() {
        XCTAssertTrue(matcher.isInteractive("/usr/bin/ssh host"))
        XCTAssertTrue(matcher.isInteractive("/usr/local/bin/vim file"))
        XCTAssertFalse(matcher.isInteractive("/bin/echo ssh"))
    }

    // MARK: - pipelines + sequences (any interactive segment wins)

    func testPipelinesAndSequences() {
        XCTAssertTrue(matcher.isInteractive("git log | less"), "the pager segment is interactive")
        XCTAssertTrue(matcher.isInteractive("cd /srv && ssh host"))
        XCTAssertTrue(matcher.isInteractive("make build; vim out.log"))
        XCTAssertFalse(matcher.isInteractive("echo done; echo ssh"), "no segment is interactive")
        XCTAssertFalse(matcher.isInteractive("sleep 1 &"), "a backgrounded sleep is not interactive")
    }

    // MARK: - empty / whitespace

    func testEmptyAndWhitespaceAreNotInteractive() {
        XCTAssertFalse(matcher.isInteractive(""))
        XCTAssertFalse(matcher.isInteractive("   "))
        XCTAssertFalse(matcher.isInteractive("env"), "a bare env launcher with no program is not interactive")
    }

    // MARK: - configurable set

    func testConfigurableProgramSet() {
        // A custom matcher swaps the whole interactive set: its program is interactive, ssh is not.
        let custom = InteractiveCommandMatcher(interactivePrograms: ["myrepl"], subcommandRules: [])
        XCTAssertTrue(custom.isInteractive("myrepl --connect"))
        XCTAssertFalse(custom.isInteractive("ssh host"), "ssh is not in the custom set")
        // The default keeps ssh interactive — proving the set, not a hardcode, drives the decision.
        XCTAssertTrue(InteractiveCommandMatcher.default.isInteractive("ssh host"))
    }

    func testStaticConvenienceMatchesDefaultInstance() {
        XCTAssertTrue(InteractiveCommandMatcher.isInteractive("ssh host"))
        XCTAssertFalse(InteractiveCommandMatcher.isInteractive("echo ssh"))
    }
}
