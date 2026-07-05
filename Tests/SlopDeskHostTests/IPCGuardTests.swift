import Foundation
import XCTest
@testable import SlopDeskHost

/// E14/K13 — host-side IPC guards on the agent-control ctl socket.
///
/// **No real PTY, no real socket.** The pure ``AgentControlHandler/dispatch`` is driven with an injected
/// `IPCGuards` (and an injected `foregroundName` resolver for the sensitive-session gate) so the guard
/// decisions are exercised WITHOUT a live PTY — the hang-safety rule (no real `AF_UNIX`/PTY in a unit
/// test) still holds. Every assertion reverts-to-confirm-fail: drop the guard at the top of `dispatch`
/// and the "refused" assertions fall through to the verb's "pane not found"/spawn path instead.
final class IPCGuardTests: XCTestCase {
    // A target paneId that never exists on the null server (so a verb that PASSES the guard falls through
    // to "pane not found", proving the guard let it run rather than refusing it).
    private let absentPane = "00000000-0000-0000-0000-000000000000"

    // MARK: Send-keys gate — mutating verbs refused when allowSendKeys == false

    func testWriteRefusedWhenSendKeysDisabled() {
        let resp = dispatchGuarded(
            method: "write",
            params: ["paneId": absentPane, "text": "rm -rf /"],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: true),
        )
        assertRefused(resp, containing: "send-keys disabled")
    }

    func testRunRefusedWhenSendKeysDisabled() {
        let resp = dispatchGuarded(
            method: "run",
            params: ["paneId": absentPane, "text": "echo hi"],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: true),
        )
        assertRefused(resp, containing: "send-keys disabled")
    }

    func testResizeRefusedWhenSendKeysDisabled() {
        let resp = dispatchGuarded(
            method: "resize",
            params: ["paneId": absentPane, "rows": 24, "cols": 80],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: true),
        )
        assertRefused(resp, containing: "send-keys disabled")
    }

    func testKillRefusedWhenSendKeysDisabled() {
        let resp = dispatchGuarded(
            method: "kill",
            params: ["paneId": absentPane],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: true),
        )
        assertRefused(resp, containing: "send-keys disabled")
    }

    /// `spawn` is mutating but names NO target pane — the send-keys gate must still refuse it (and so it
    /// NEVER reaches `spawnStandalonePane`, which would otherwise fork a real shell off the null server).
    func testSpawnRefusedWhenSendKeysDisabled() {
        let resp = dispatchGuarded(
            method: "spawn",
            params: ["cmd": ["/bin/echo", "hi"]],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: false),
        )
        assertRefused(resp, containing: "send-keys disabled")
    }

    // MARK: Send-keys gate — mutating verbs allowed when allowSendKeys == true (fall through to the verb)

    func testWriteAllowedWhenSendKeysEnabled() {
        // allowSensitiveSessions == true so the sensitive gate is a no-op; the verb runs and fails only on
        // the (intentionally) absent pane — proving the gate LET it through (not a "send-keys disabled").
        let resp = dispatchGuarded(
            method: "write",
            params: ["paneId": absentPane, "text": "ls"],
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        let error = obj?["error"] as? String ?? ""
        XCTAssertFalse(error.contains("send-keys disabled"), "send-keys ON must NOT refuse the verb")
        XCTAssertTrue(error.contains("not found"), "the verb ran and failed only on the absent pane")
    }

    func testRunAllowedWhenSendKeysEnabled() {
        let resp = dispatchGuarded(
            method: "run",
            params: ["paneId": absentPane, "text": "ls"],
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertFalse((obj?["error"] as? String ?? "").contains("send-keys disabled"))
        XCTAssertTrue((obj?["error"] as? String ?? "").contains("not found"))
    }

    // MARK: Read-only verbs always allowed (regardless of either guard)

    func testListPanesAlwaysAllowed() {
        let resp = dispatchGuarded(
            method: "list-panes",
            params: [:],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: false),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, true, "list-panes is read-only — always allowed")
    }

    func testReadAlwaysAllowedEvenWhenSendKeysDisabled() {
        let resp = dispatchGuarded(
            method: "read",
            params: ["paneId": absentPane],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: false),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        let error = obj?["error"] as? String ?? ""
        XCTAssertFalse(error.contains("send-keys disabled"), "read is read-only — never send-keys-gated")
        XCTAssertTrue(error.contains("not found"), "the read verb ran (and failed only on the absent pane)")
    }

    func testWaitAlwaysAllowedEvenWhenSendKeysDisabled() {
        let resp = dispatchGuarded(
            method: "wait",
            params: ["paneId": absentPane, "until": "x", "timeoutMs": 10.0],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: false),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertFalse((obj?["error"] as? String ?? "").contains("send-keys disabled"))
        XCTAssertTrue((obj?["error"] as? String ?? "").contains("not found"))
    }

    func testReportAlwaysAllowedEvenWhenSendKeysDisabled() {
        // `report` (an agent self-declaring its supervision state) is classed read-only — the gate never
        // blocks it. It runs and fails only on the absent pane.
        let resp = dispatchGuarded(
            method: "report",
            params: ["paneId": absentPane, "state": "working"],
            guards: IPCGuards(allowSendKeys: false, allowSensitiveSessions: false),
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertFalse((obj?["error"] as? String ?? "").contains("send-keys disabled"))
        XCTAssertTrue((obj?["error"] as? String ?? "").contains("not found"))
    }

    // MARK: Sensitive-session gate

    func testWriteRefusedWhenTargetSensitiveAndSensitiveDisabled() {
        // Send-keys is allowed, but the target pane's foreground is `ssh` and sensitive sessions are OFF →
        // refuse. Inject the foreground resolver so no real PTY probe is needed.
        let resp = dispatchGuarded(
            method: "write",
            params: ["paneId": absentPane, "text": "secret"],
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: false),
            foregroundName: { _, _ in "ssh" },
        )
        assertRefused(resp, containing: "sensitive-session")
    }

    func testResizeRefusedWhenTargetSensitiveAndSensitiveDisabled() {
        let resp = dispatchGuarded(
            method: "resize",
            params: ["paneId": absentPane, "rows": 24, "cols": 80],
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: false),
            foregroundName: { _, _ in "sudo" },
        )
        assertRefused(resp, containing: "sensitive-session")
    }

    func testWriteAllowedWhenSensitiveTargetButSensitiveEnabled() {
        // Sensitive sessions are ENABLED → an `ssh` target passes the sensitive gate; the verb runs and
        // fails only on the absent pane (NOT a sensitive-session refusal).
        let resp = dispatchGuarded(
            method: "write",
            params: ["paneId": absentPane, "text": "x"],
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: true),
            foregroundName: { _, _ in "ssh" },
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertFalse((obj?["error"] as? String ?? "").contains("sensitive-session"))
        XCTAssertTrue((obj?["error"] as? String ?? "").contains("not found"))
    }

    func testWriteAllowedWhenTargetNotSensitive() {
        // Sensitive sessions OFF, but the foreground (`vim`) is not sensitive → the verb runs and fails
        // only on the absent pane.
        let resp = dispatchGuarded(
            method: "write",
            params: ["paneId": absentPane, "text": "x"],
            guards: IPCGuards(allowSendKeys: true, allowSensitiveSessions: false),
            foregroundName: { _, _ in "vim" },
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertFalse((obj?["error"] as? String ?? "").contains("sensitive-session"))
        XCTAssertTrue((obj?["error"] as? String ?? "").contains("not found"))
    }

    // MARK: SensitiveSessionPolicy (pure decision)

    func testSensitivePolicyKnownCommands() {
        for name in ["ssh", "sudo", "su", "login", "doas", "passwd", "gpg", "sshpass"] {
            XCTAssertTrue(SensitiveSessionPolicy.isSensitive(processName: name), "'\(name)' is sensitive")
        }
    }

    func testSensitivePolicyNonSensitiveCommands() {
        for name in ["vim", "git", "bash", "zsh", "node", "python3", "claude"] {
            XCTAssertFalse(SensitiveSessionPolicy.isSensitive(processName: name), "'\(name)' is not sensitive")
        }
    }

    func testSensitivePolicyEmptyIsNotSensitive() {
        XCTAssertFalse(SensitiveSessionPolicy.isSensitive(processName: ""), "an unknown foreground is not sensitive")
    }

    func testSensitivePolicyReducesFullPathToBasename() {
        XCTAssertTrue(SensitiveSessionPolicy.isSensitive(processName: "/usr/bin/ssh"))
        XCTAssertTrue(SensitiveSessionPolicy.isSensitive(processName: "/usr/bin/sudo"))
        XCTAssertFalse(SensitiveSessionPolicy.isSensitive(processName: "/usr/local/bin/vim"))
    }

    func testSensitivePolicyIsCaseSensitive() {
        // Basename match mirrors the host's foreground-process basenames (case-sensitive), so `SSH` (an
        // unusual basename) is NOT one of the known sensitive entries.
        XCTAssertFalse(SensitiveSessionPolicy.isSensitive(processName: "SSH"))
    }

    // MARK: Env resolution (default-OFF idiom, like agentControlEnabled)

    func testIPCGuardEnvDefaultsOffAndRequiresExplicit1() {
        XCTAssertFalse(HostEnvironment.ipcAllowSendKeys(environment: [:]))
        XCTAssertFalse(HostEnvironment.ipcAllowSendKeys(environment: ["SLOPDESK_IPC_ALLOW_SEND_KEYS": "0"]))
        XCTAssertFalse(HostEnvironment.ipcAllowSendKeys(environment: ["SLOPDESK_IPC_ALLOW_SEND_KEYS": "yes"]))
        XCTAssertTrue(HostEnvironment.ipcAllowSendKeys(environment: ["SLOPDESK_IPC_ALLOW_SEND_KEYS": "1"]))

        XCTAssertFalse(HostEnvironment.ipcAllowSensitiveSessions(environment: [:]))
        XCTAssertFalse(HostEnvironment.ipcAllowSensitiveSessions(environment: ["SLOPDESK_IPC_ALLOW_SENSITIVE": "0"]))
        XCTAssertTrue(HostEnvironment.ipcAllowSensitiveSessions(environment: ["SLOPDESK_IPC_ALLOW_SENSITIVE": "1"]))
    }

    func testResolvedGuardsAreOffByDefaultProcessEnv() {
        // The real process env almost never sets these; `resolved()` should therefore default both OFF (the
        // conservative posture). This pins the wiring of `resolved()` → `HostEnvironment` without mutating
        // the process environment.
        let guards = IPCGuards.resolved()
        XCTAssertFalse(guards.allowSendKeys)
        XCTAssertFalse(guards.allowSensitiveSessions)
    }

    // MARK: Helpers

    private func dispatchGuarded(
        method: String,
        params: [String: Any],
        guards: IPCGuards,
        foregroundName: @escaping @Sendable (HostServer, String) -> String = { _, _ in "" },
    ) -> String {
        AgentControlHandler.dispatch(
            id: "t",
            method: method,
            params: params,
            server: HostServer(port: 0),
            guards: guards,
            foregroundName: foregroundName,
        )
    }

    private func assertRefused(_ resp: String, containing needle: String) {
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false, "a refused verb returns ok:false")
        XCTAssertTrue(
            (obj?["error"] as? String ?? "").contains(needle),
            "refusal error should mention '\(needle)' — got: \(obj?["error"] as? String ?? "<none>")",
        )
    }

    private func parseResponseObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
