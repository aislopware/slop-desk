import Foundation
import XCTest
@testable import SlopDeskHost

/// The PURE ``AgentInstaller/isInstalled(settingsPath:fileManager:)`` marker read that backs
/// the host's `agentHookStatus` (verb 13) wire reply + the Agents settings card's status row. Proves it
/// is `true` only after a real install, `false` after uninstall, and TOLERANT of a missing / hook-less /
/// corrupt settings file (returns `false`, never traps). Every assertion reverts-to-confirm-fail:
/// a hard-coded `true`/`false` would fail the opposite-state case; trapping on a corrupt file would crash
/// the tolerance test.
final class AgentInstallerStatusTests: XCTestCase {
    /// Makes a fresh, unique temp dir + the settings/script paths under it; cleaned up by the caller.
    private func makePaths() -> (dir: URL, settings: String, script: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slopdesk-installer-status-\(UUID().uuidString)")
        return (
            dir,
            dir.appendingPathComponent("settings.json").path,
            dir.appendingPathComponent("hooks/slopdesk-agent.sh").path,
        )
    }

    func testIsInstalledFalseWhenSettingsFileMissing() {
        let (dir, settings, _) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The file was never created → tolerant false (no trap on a missing file).
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings))
    }

    func testIsInstalledTrueAfterInstallThenFalseAfterUninstall() throws {
        let (dir, settings, script) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings), "not installed before install")

        _ = try AgentInstaller.install(settingsPath: settings, scriptPath: script)
        XCTAssertTrue(AgentInstaller.isInstalled(settingsPath: settings), "installed after install")

        _ = try AgentInstaller.uninstall(settingsPath: settings)
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings), "not installed after uninstall")
    }

    func testIsInstalledFalseWhenOnlyTheUsersOwnHookPresent() throws {
        let (dir, settings, _) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A settings file with a hook that is NOT ours (no marker) → false (we never claim the user's hook).
        try Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify-me"}]}]}}
        """.utf8).write(to: URL(fileURLWithPath: settings))
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings))
    }

    func testIsInstalledTrueWhenOursSitsAlongsideTheUsersHook() throws {
        let (dir, settings, script) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify-me"}]}]}}
        """.utf8).write(to: URL(fileURLWithPath: settings))
        _ = try AgentInstaller.install(settingsPath: settings, scriptPath: script)
        XCTAssertTrue(AgentInstaller.isInstalled(settingsPath: settings), "ours is detected next to the user's hook")
    }

    func testIsInstalledFalseOnCorruptSettingsFile() throws {
        let (dir, settings, _) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Non-JSON garbage → readSettings repairs to an empty root → false, never a trap.
        try Data("this is not json {{{".utf8).write(to: URL(fileURLWithPath: settings))
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings))
    }

    func testIsInstalledFalseWhenHooksKeyAbsent() throws {
        let (dir, settings, _) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Valid settings with NO hooks key at all → false.
        try Data(#"{"theme":"dark"}"#.utf8).write(to: URL(fileURLWithPath: settings))
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings))
    }

    // MARK: - verb-13 flag payload

    /// The exact `[installed][listenerActive]` byte shape of the `agentHookStatus` (13) reply
    /// (docs/20), pinned via the PURE `HostAgentActionPerformer.statusFlags` (no disk — the
    /// disk-touching verbs stay compiled + code-reviewed only). The second byte is the LIVE
    /// listener-bind truth: `[1,0]` is the installed-but-INACTIVE case the Settings card warns on —
    /// a single-byte payload can't distinguish this from a healthy install, which would show a false
    /// green over a dead integration.
    func testAgentHookStatusFlagsPayloadShape() {
        XCTAssertEqual(
            Array(HostAgentActionPerformer.statusFlags(installed: true, listenerActive: true)), [1, 1],
        )
        XCTAssertEqual(
            Array(HostAgentActionPerformer.statusFlags(installed: true, listenerActive: false)), [1, 0],
            "installed with the listener DOWN must be distinguishable on the wire (the false-green fix)",
        )
        XCTAssertEqual(
            Array(HostAgentActionPerformer.statusFlags(installed: false, listenerActive: false)), [0, 0],
        )
        XCTAssertEqual(
            Array(HostAgentActionPerformer.statusFlags(installed: false, listenerActive: true)), [0, 1],
            "a bound listener with no install marker still reports honestly (install missing)",
        )
    }

    /// An un-started ``AgentHookListener`` reports NOT listening — the honest default the status verb
    /// reports when hostd never bound the socket. (Binding a real socket is out of scope here —
    /// hang/IO-safety; the bound case is covered by the HW loopback/manual path.)
    func testAgentHookListenerNotListeningBeforeStart() {
        XCTAssertFalse(AgentHookListener().isListening)
    }
}
