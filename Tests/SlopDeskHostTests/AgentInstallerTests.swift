import SlopDeskInspector
import XCTest
@testable import SlopDeskHost

/// W10 — the PURE ``AgentInstaller`` merge / unmerge logic (no disk; the thin
/// `install`/`uninstall` file shim is exercised via a tmp dir at the end). Proves the three
/// invariants the installer must hold: idempotent merge, preserve-existing, and removable.
final class AgentInstallerTests: XCTestCase {
    private let command = "\"/Users/dev/.claude/hooks/slopdesk-agent.sh\""

    private func decode(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    // MARK: merge installs every event

    func testMergeInstallsAllEvents() {
        let merged = AgentInstaller.merge(into: .object([:]), command: command)
        guard case let .object(obj) = merged, case let .object(hooks)? = obj["hooks"] else {
            XCTFail("expected a hooks object")
            return
        }
        for event in AgentInstaller.installedEvents {
            XCTAssertNotNil(hooks[event], "event \(event) must be installed")
        }
    }

    // MARK: idempotency — re-running does not duplicate

    func testMergeIsIdempotent() {
        let once = AgentInstaller.merge(into: .object([:]), command: command)
        let twice = AgentInstaller.merge(into: once, command: command)
        XCTAssertEqual(once, twice, "re-running the merge must not duplicate our entries")

        // Concretely: exactly ONE of our blocks per event after two merges.
        guard case let .object(obj) = twice, case let .object(hooks)? = obj["hooks"],
              case let .array(stopEntries)? = hooks["Stop"]
        else { XCTFail("expected Stop entries")
            return
        }
        let ours = stopEntries.filter { AgentInstaller.entryIsOurs($0) }
        XCTAssertEqual(ours.count, 1, "exactly one of our Stop entries after two merges")
    }

    // MARK: preserve existing unrelated settings + hooks

    func testMergePreservesUnrelatedTopLevelSettings() {
        let existing = decode(#"{"theme":"dark","permissions":{"allow":["Bash"]}}"#)
        let merged = AgentInstaller.merge(into: existing, command: command)
        guard case let .object(obj) = merged else { XCTFail("expected object")
            return
        }
        XCTAssertEqual(obj["theme"], .string("dark"), "unrelated top-level setting preserved")
        XCTAssertEqual(obj["permissions"], decode(#"{"allow":["Bash"]}"#), "permissions block preserved")
        XCTAssertNotNil(obj["hooks"], "hooks added")
    }

    func testMergePreservesTheUsersOwnHookForTheSameEvent() {
        // The user already has a Stop hook of their own (no marker).
        let existing = decode("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify-me"}]}]}}
        """)
        let merged = AgentInstaller.merge(into: existing, command: command)
        guard case let .object(obj) = merged, case let .object(hooks)? = obj["hooks"],
              case let .array(stop)? = hooks["Stop"]
        else { XCTFail("expected Stop array")
            return
        }
        let theirs = stop.filter { !AgentInstaller.entryIsOurs($0) }
        let ours = stop.filter { AgentInstaller.entryIsOurs($0) }
        XCTAssertEqual(theirs.count, 1, "the user's own Stop hook is preserved")
        XCTAssertEqual(ours.count, 1, "our Stop hook is appended alongside it")
    }

    // MARK: removability — strip exactly ours

    func testRemoveStripsOnlyOurEntries() {
        let existing = decode("""
        {"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify-me"}]}]}}
        """)
        let merged = AgentInstaller.merge(into: existing, command: command)
        let removed = AgentInstaller.remove(from: merged)
        guard case let .object(obj) = removed, case let .object(hooks)? = obj["hooks"],
              case let .array(stop)? = hooks["Stop"]
        else { XCTFail("expected Stop array after removal")
            return
        }
        XCTAssertEqual(stop.count, 1, "only the user's own Stop hook remains")
        XCTAssertFalse(AgentInstaller.entryIsOurs(stop[0]), "the remaining entry is the user's, not ours")
        // Events that had only our entries are dropped.
        XCTAssertNil(hooks["SessionStart"], "an event with only our entries is removed")
        XCTAssertEqual(obj["theme"], .string("dark"), "unrelated settings still preserved")
    }

    func testRemoveOnFreshInstallEmptiesHooksEntirely() {
        let merged = AgentInstaller.merge(into: decode(#"{"theme":"dark"}"#), command: command)
        let removed = AgentInstaller.remove(from: merged)
        guard case let .object(obj) = removed else { XCTFail("expected object")
            return
        }
        XCTAssertNil(obj["hooks"], "an all-ours hooks map is removed entirely on uninstall")
        XCTAssertEqual(obj["theme"], .string("dark"))
    }

    func testRoundTripMergeThenRemoveRestoresOriginal() {
        let original = decode(#"{"theme":"dark","permissions":{"allow":["Bash"]}}"#)
        let merged = AgentInstaller.merge(into: original, command: command)
        let restored = AgentInstaller.remove(from: merged)
        XCTAssertEqual(restored, original, "merge then remove restores the original settings exactly")
    }

    // MARK: corrupt / non-object root (validate-then-repair)

    func testMergeOnNonObjectRootBuildsFreshHooks() {
        let merged = AgentInstaller.merge(into: .string("garbage"), command: command)
        guard case let .object(obj) = merged, case .object? = obj["hooks"] else {
            XCTFail("a corrupt root must be repaired into a valid hooks object")
            return
        }
    }

    // MARK: hook script + command text

    func testHookScriptIsRecognizedExecutableShellAndReferencesSocketEnv() {
        let script = AgentInstaller.hookScript()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"), "the hook script is a POSIX-sh script")
        XCTAssertTrue(script.contains("SLOPDESK_SOCKET_PATH"), "it reads the host's socket path from env")
        XCTAssertTrue(script.contains("nc -U"), "it POSTs over the Unix socket (Muxy transport)")
    }

    func testCommandCarriesTheMarkerViaScriptPath() {
        let cmd = AgentInstaller.hookCommand(scriptPath: "/Users/dev/.claude/hooks/slopdesk-agent.sh")
        XCTAssertTrue(cmd.contains(AgentInstaller.hookMarker), "the command path carries the merge marker")
    }

    func testDefaultPathsHonorClaudeConfigDir() {
        let env = ["CLAUDE_CONFIG_DIR": "/tmp/cfg"]
        XCTAssertEqual(
            AgentInstaller.defaultSettingsPath(environment: env, home: "/Users/dev"),
            "/tmp/cfg/settings.json",
        )
        XCTAssertEqual(
            AgentInstaller.defaultScriptPath(environment: env, home: "/Users/dev"),
            "/tmp/cfg/hooks/slopdesk-agent.sh",
        )
        // Without the override → ~/.claude.
        XCTAssertEqual(
            AgentInstaller.defaultSettingsPath(environment: [:], home: "/Users/dev"),
            "/Users/dev/.claude/settings.json",
        )
    }

    // MARK: the thin disk shim (tmp dir) — install/uninstall round-trip on the file system

    func testInstallThenUninstallOnDiskIsIdempotentAndRemovable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slopdesk-installer-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsPath = dir.appendingPathComponent("settings.json").path
        let scriptPath = dir.appendingPathComponent("hooks/slopdesk-agent.sh").path

        // Pre-seed an existing user setting so we can prove preservation across disk I/O.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: URL(fileURLWithPath: settingsPath))

        // Install twice (idempotency over the disk shim).
        _ = try AgentInstaller.install(settingsPath: settingsPath, scriptPath: scriptPath)
        let secondInstall = try AgentInstaller.install(settingsPath: settingsPath, scriptPath: scriptPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath), "the hook script is written")
        // The script is executable.
        let perms = try FileManager.default.attributesOfItem(atPath: scriptPath)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o755, "the hook script is chmod +x")

        let afterTwo = try JSONDecoder().decode(JSONValue.self, from: Data(secondInstall.utf8))
        guard case let .object(obj2) = afterTwo, case let .object(hooks2)? = obj2["hooks"],
              case let .array(stop2)? = hooks2["Stop"]
        else { XCTFail("expected Stop after two installs")
            return
        }
        XCTAssertEqual(stop2.count(where: { AgentInstaller.entryIsOurs($0) }), 1, "no duplication across two installs")
        XCTAssertEqual(obj2["theme"], .string("dark"), "the user's setting survived the disk round-trip")

        // Uninstall → our entries gone, the user setting intact.
        let afterUninstall = try AgentInstaller.uninstall(settingsPath: settingsPath)
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(afterUninstall.utf8))
        guard case let .object(obj3) = root else { XCTFail("expected object")
            return
        }
        XCTAssertNil(obj3["hooks"], "uninstall removes our (all-ours) hooks")
        XCTAssertEqual(obj3["theme"], .string("dark"), "uninstall preserves the user's settings")
    }
}
