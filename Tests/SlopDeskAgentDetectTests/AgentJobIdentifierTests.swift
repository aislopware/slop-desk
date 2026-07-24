import XCTest
@testable import SlopDeskAgentDetect

/// Parity pins for herdr's process identification (`identify_agent_in_job` and the
/// runtime-argv unwrap family). Filesystem symlink resolution is injected.
final class AgentJobIdentifierTests: XCTestCase {
    private let noSymlinks: AgentJobIdentifier.SymlinkResolver = { _ in nil }

    func testAliasTableIdentifiesAgents() {
        XCTAssertEqual(AgentKind.identify(processName: "claude"), .claude)
        XCTAssertEqual(AgentKind.identify(processName: "claude-code"), .claude)
        XCTAssertEqual(AgentKind.identify(processName: "Cursor-Agent"), .cursor)
        XCTAssertEqual(AgentKind.identify(processName: "opencode.exe"), .openCode)
        XCTAssertEqual(AgentKind.identify(processName: "kiro-cli"), .kiro)
        XCTAssertEqual(AgentKind.identify(processName: "ghcs"), .githubCopilot)
        XCTAssertNil(AgentKind.identify(processName: "zsh"))
        XCTAssertNil(AgentKind.identify(processName: "claudefoo"))
    }

    func testScreenManifestAgentsExcludeHookOnlyAgents() {
        XCTAssertEqual(AgentKind.screenManifestAgents.count, 19)
        XCTAssertFalse(AgentKind.screenManifestAgents.contains(.omp))
        XCTAssertFalse(AgentKind.screenManifestAgents.contains(.mastracode))
    }

    func testGroupLeaderFastPathWins() {
        let job = ForegroundJob(processGroupID: 10, processes: [
            ForegroundJobProcess(pid: 10, name: "claude"),
            ForegroundJobProcess(pid: 11, name: "codex"),
        ])
        XCTAssertEqual(AgentJobIdentifier.identify(job: job, resolveSymlink: noSymlinks)?.agent, .claude)
    }

    func testNodeWrappedClaudeUnwrapsFromScriptPath() {
        // The npm shebang case: foreground comm is `node`, argv carries the script path.
        let job = ForegroundJob(processGroupID: 20, processes: [
            ForegroundJobProcess(
                pid: 20,
                name: "node",
                argv0: "node",
                argv: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
            ),
        ])
        // The path token's basename (`cli.js` → `cli`) is not an agent, but a symlink-resolved
        // basename is not needed either — herdr resolves via the direct basename first. This
        // one resolves through the injected resolver.
        let resolver: AgentJobIdentifier.SymlinkResolver = { _ in "claude" }
        XCTAssertEqual(AgentJobIdentifier.identify(job: job, resolveSymlink: resolver)?.agent, .claude)
    }

    func testNodeWrappedAgentBasenameNeedsNoResolver() {
        let job = ForegroundJob(processGroupID: 21, processes: [
            ForegroundJobProcess(pid: 21, name: "node", argv0: "node", argv: ["node", "/opt/bin/codex"]),
        ])
        let result = AgentJobIdentifier.identify(job: job, resolveSymlink: noSymlinks)
        XCTAssertEqual(result?.agent, .codex)
        XCTAssertEqual(result?.name, "codex")
    }

    /// herdr `identify_agent_in_job_ignores_python_c_argument_named_codex`: an eval flag bails
    /// immediately — trailing positional args are never trusted.
    func testPythonDashCBailsEvenWithAgentShapedTrailingArg() {
        let job = ForegroundJob(processGroupID: 30, processes: [
            ForegroundJobProcess(
                pid: 30,
                name: "python3",
                argv0: "python3",
                argv: ["python3", "-c", "print('hi')", "/tmp/codex"],
            ),
        ])
        XCTAssertNil(AgentJobIdentifier.identify(job: job, resolveSymlink: noSymlinks))
    }

    /// herdr `identify_agent_in_job_detects_python_script_named_codex`.
    func testPythonScriptNamedCodexResolves() {
        let job = ForegroundJob(processGroupID: 31, processes: [
            ForegroundJobProcess(
                pid: 31,
                name: "python3",
                argv0: "python3",
                argv: ["python3", "/tmp/codex", "--model", "gpt-5"],
            ),
        ])
        XCTAssertEqual(AgentJobIdentifier.identify(job: job, resolveSymlink: noSymlinks)?.agent, .codex)
    }

    func testShellDashCBails() {
        let job = ForegroundJob(processGroupID: 32, processes: [
            ForegroundJobProcess(pid: 32, name: "zsh", argv0: "zsh", argv: ["zsh", "-c", "claude"]),
        ])
        XCTAssertNil(AgentJobIdentifier.identify(job: job, resolveSymlink: noSymlinks))
    }

    func testKnownPiPackagePathSniffs() {
        let job = ForegroundJob(processGroupID: 40, processes: [
            ForegroundJobProcess(
                pid: 40,
                name: "node",
                argv0: "node",
                argv: ["node", "/repo/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"],
            ),
        ])
        XCTAssertEqual(AgentJobIdentifier.identify(job: job, resolveSymlink: noSymlinks)?.agent, .pi)
    }

    /// Unwrapped (3) beats literal agent comm (2); ties keep the first process.
    func testScoringPrefersUnwrappedOverLiteral() {
        let job = ForegroundJob(processGroupID: 99, processes: [
            ForegroundJobProcess(pid: 50, name: "codex"),
            ForegroundJobProcess(pid: 51, name: "node", argv0: "node", argv: ["node", "/opt/bin/claude"]),
        ])
        XCTAssertEqual(AgentJobIdentifier.identify(job: job, resolveSymlink: noSymlinks)?.agent, .claude)
    }

    func testLoginShellAndUnknownJobYieldNil() {
        let job = ForegroundJob(processGroupID: 60, processes: [
            ForegroundJobProcess(pid: 60, name: "zsh", argv0: "-zsh"),
        ])
        XCTAssertNil(AgentJobIdentifier.identify(job: job, resolveSymlink: noSymlinks))
    }
}
