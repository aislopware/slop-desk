import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest

/// The contract `scripts/check-launch-restore.sh` runs on, pinned where it can be read in seconds.
///
/// That gate is the only one that reaches the launch a USER performs: restore `workspace.json`, offer
/// it to the host, silently re-connect to the saved host. The other three all set an autoconnect env
/// var, which makes `hasAutomationEnvironment()` true and takes the app down the automation branch
/// instead — no persistence, a synthetic one-pane layout, no `connectIfSavedTarget()`.
///
/// A GUI gate takes minutes, needs an unlocked Aqua session and cannot run in CI, so everything about
/// it that IS headlessly checkable is checked here: the committed layout fixture must still decode
/// through the shipping persistence path, the MRU fixture must still decode through the shipping
/// connection path, and the script must still be driving the shipping launch rather than the
/// automation one. The same discipline as ``GuiGateLaunchContractTests`` reading the gate scripts.
final class LaunchRestoreGateContractTests: XCTestCase {
    private static let gateScript = "scripts/check-launch-restore.sh"
    private static let fixture = "scripts/fixtures/launch-restore-workspace.json"

    /// The pane ids the fixture names, and the gate's assertions quote. Uppercase — `PaneID.raw
    /// .uuidString` is, and the client-control socket answers with it.
    private static let paneIDs = [
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
    ]

    /// `scripts/` sits beside `Tests/` in the package root — walk up from this file rather than
    /// relying on a bundle resource (a script is a working-tree artefact, not a SwiftPM resource).
    private func repoURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskClientUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent(relativePath)
    }

    /// The script with every comment line dropped — what it DOES, never what it says about itself.
    /// Load-bearing: this gate's header discusses `SLOPDESK_AUTOCONNECT_HOST` at length to explain
    /// why it must NOT be set, so a whole-file search would find the prose and pass.
    private func codeBody(of script: String) throws -> String {
        try String(contentsOf: repoURL(script), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    // MARK: - The layout fixture

    /// The committed layout must still restore, through the REAL launch path, to the shape the gate
    /// asserts: two tabs (so a pane in a tab the window is not showing still has to get a shell) and
    /// a split (so a restored split has to survive), three terminal panes, these ids.
    ///
    /// Without this, a `TreeWorkspace.currentSchemaVersion` bump silently turns the fixture into an
    /// unreadable file: `launchTree` resets it aside, the client restores the ONE-pane default, and
    /// the gate fails minutes into a hardware run with "the client never projected the restored
    /// layout" — the one message that does not name the cause.
    func testTheCommittedLayoutFixtureStillRestores() throws {
        // Loaded from a COPY. `loadTree` is a repairing reader: a file it cannot speak is moved aside
        // as a `.corrupt` sidecar next to itself — so pointing it straight at the working tree would
        // make this test litter `scripts/fixtures/` on the very run that reports the drift.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-restore-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("workspace.json")
        try FileManager.default.copyItem(at: repoURL(Self.fixture), to: copy)

        let restored = try XCTUnwrap(
            WorkspacePersistence(fileURL: copy).loadTree(),
            "\(Self.fixture) no longer decodes as a TreeWorkspace — most likely "
                + "`TreeWorkspace.currentSchemaVersion` moved (it is \(TreeWorkspace.currentSchemaVersion) "
                + "now). Regenerate the fixture with the real encoder; do NOT hand-patch the version.",
        )
        XCTAssertEqual(restored.sessions.count, 1, "the fixture is one session")
        let session = try XCTUnwrap(restored.sessions.first)
        XCTAssertEqual(session.tabs.count, 2, "the fixture is two tabs")
        XCTAssertEqual(session.tabs.first?.allPaneIDs().count, 2, "the first tab is a two-leaf split")
        XCTAssertEqual(session.tabs.last?.allPaneIDs().count, 1, "the second tab is a lone leaf")
        XCTAssertEqual(
            restored.allPaneIDs().map(\.raw.uuidString), Self.paneIDs,
            "the fixture's pane ids are quoted by the gate's assertions and must not move",
        )
        for pane in restored.allPaneIDs() {
            XCTAssertEqual(session.specs[pane]?.kind, .terminal, "every restored pane is a terminal")
        }
    }

    /// `loadTree` is the launch reader, and it is the one that can silently substitute a default.
    /// This is the same claim from the other side: the file the gate copies into the client's
    /// container is not merely decodable, it is what a launch actually gets.
    func testTheGateSeedsTheFileTheLaunchPathReads() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains("Library/Application Support/SlopDesk/workspace.json"),
            "check-launch-restore.sh no longer seeds the path `WorkspacePersistence.defaultFileURL` "
                + "resolves to, so the client restores an empty default and the gate proves nothing",
        )
        XCTAssertTrue(
            code.contains("CFFIXED_USER_HOME=\"${CONTAINER}\""),
            "check-launch-restore.sh no longer redirects the client's container, so it would read and "
                + "OVERWRITE the developer's real workspace.json",
        )
    }

    // MARK: - The saved-host fixture

    /// The MRU the gate injects must still decode as `[ConnectionTarget]`, because that is exactly
    /// what `AppConnection.loadRecentTargets` does with it — and a decode failure there is SILENT:
    /// `recentTargets` becomes `[]`, `connectIfSavedTarget()` returns without dialling, and the gate
    /// hangs until it times out with no hint that a `CodingKey` moved.
    func testTheSavedHostFixtureStillDecodesAsAConnectionTarget() throws {
        let code = try codeBody(of: Self.gateScript)
        let port = try XCTUnwrap(
            Self.shellAssignment("CONNECT_PORT", in: code),
            "check-launch-restore.sh lost its CONNECT_PORT assignment",
        )
        let raw = try XCTUnwrap(
            Self.shellAssignment("MRU_JSON", in: code),
            "check-launch-restore.sh no longer builds an MRU fixture, so nothing tells the shipping "
                + "auto-reconnect which host to dial",
        )
        // The script writes it as a double-quoted shell string, so its inner quotes are backslashed
        // and the port is a `${CONNECT_PORT}` expansion. Undo exactly those two things.
        let json = raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "${CONNECT_PORT}", with: port)
        let targets = try JSONDecoder().decode(
            [ConnectionTarget].self, from: Data(json.utf8),
        )
        XCTAssertEqual(targets.count, 1, "the fixture is one saved host")
        XCTAssertEqual(targets.first?.host, "127.0.0.1")
        XCTAssertEqual(
            targets.first?.port, UInt16(port),
            "the seeded MRU must name the port the gate's daemon binds, or the client dials elsewhere",
        )
    }

    /// The MRU has to arrive through the ARGUMENT DOMAIN, and that is a determinism requirement
    /// rather than a stylistic one. `CFFIXED_USER_HOME` does not redirect `UserDefaults` (cfprefsd
    /// resolves the real home), so the persistent MRU is shared with the developer's own app and with
    /// the other three gates — each of which leaves its loopback port in it on every successful run.
    /// Reading whatever is persisted would make this gate dial whichever gate ran last.
    func testTheSavedHostArrivesThroughTheArgumentDomain() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains("-connection.recentTargets \"<${MRU_HEX}>\""),
            "check-launch-restore.sh no longer overrides the MRU in the argument domain. The "
                + "persistent domain is SHARED with the developer's app and with the other gates "
                + "(47420/47421/47422 are all in it), so the client would dial whichever ran last.",
        )
        XCTAssertTrue(
            code.contains("-hasCompletedFirstLaunch YES"),
            "check-launch-restore.sh no longer pins the first-launch flag, so whether the guided sheet "
                + "presents depends on the developer's own defaults",
        )
    }

    // MARK: - It must stay the SHIPPING path

    /// The one thing that would quietly destroy this gate: adding an autoconnect env var to make it
    /// "connect faster". That flips `hasAutomationEnvironment()`, and with it the app drops
    /// persistence entirely, replaces the restored tree with a synthetic one-pane layout, clears
    /// `pendingLaunchAdopt` and skips `connectIfSavedTarget()` — every single thing this gate exists
    /// to exercise. It would still pass its socket check and still screenshot a window.
    func testTheGateNeverForcesTheAutomationBootstrap() throws {
        let code = try codeBody(of: Self.gateScript)
        for key in ["SLOPDESK_AUTOCONNECT_HOST", "SLOPDESK_VIDEO_AUTOCONNECT_HOST"] {
            XCTAssertFalse(
                code.contains(key),
                "check-launch-restore.sh sets \(key), so `hasAutomationEnvironment()` is true and the "
                    + "app takes the AUTOMATION branch: no workspace.json, a synthetic one-pane tree, "
                    + "no auto-reconnect. The gate would then be a duplicate of check-macos.sh.",
            )
        }
        XCTAssertFalse(
            code.contains("SLOPDESK_SKIP_AUTO_RECONNECT"),
            "check-launch-restore.sh disables the auto-reconnect it exists to drive",
        )
    }

    /// Conversely, the assertions that make it a gate rather than a launcher. Each of these is a
    /// distinct failure the path has actually shipped: a projection that drifts off the restored
    /// layout, a pane torn down and re-dialled (its PTY abandoned on the host), an autosave that
    /// keeps the shape but replaces the ids, a relaunch that respawns instead of reattaching, and a
    /// relaunch that dials pane ids host truth has never carried.
    func testTheGateAssertsEveryHalfOfTheClaim() throws {
        let code = try codeBody(of: Self.gateScript)
        for expected in [
            "the projection left the restored layout", // it kept projecting what it restored
            "a restored pane was torn down and re-dialled", // no churn, at any second of the watch
            "restored panes but", // pane count == live shell count
            "the autosaved layout no longer names restored pane", // identity survived the launch
            "the relaunch did not keep the SAME shells", // reattach, never respawn
            "an id that is not in any layout on", // phase C: the divergent ids never reached the host
            "shell(s) in total for", // …and the whole-log spawn count, which is what went to six
        ] {
            XCTAssertTrue(
                code.contains(expected),
                "check-launch-restore.sh lost its `\(expected)` assertion",
            )
        }
    }

    /// Phase C's divergent layout is DERIVED from the committed fixture, and the two properties that
    /// make it mean anything are asserted in the script itself: the ids must be disjoint from the
    /// fixture's, and there must be the same number of panes.
    ///
    /// A derivation that quietly produced the fixture's own ids would leave phase C green while
    /// testing phase B a second time — the failure mode a second committed file has too, in slower
    /// motion, the day one of them is edited and the other is not.
    func testThePhaseCLayoutIsDerivedAndProvenDivergent() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains("uuid5"),
            "check-launch-restore.sh no longer DERIVES its divergent layout from the fixture — a "
                + "hand-written second file drifts the day only one of the two is updated",
        )
        XCTAssertTrue(
            code.contains("shares a pane id with the fixture"),
            "check-launch-restore.sh no longer proves the divergent ids are actually divergent",
        )
        XCTAssertTrue(
            code.contains("same ${PANE_COUNT} panes as the fixture"),
            "check-launch-restore.sh no longer proves the divergent layout is the same SHAPE",
        )
    }

    /// The daemon's HOME is reset alongside its workspace dir. The scrollback journal lives under
    /// `<Application Support>`, resolved off HOME, and the fixture pins the pane ids — so without
    /// this, run N+1 inherits run N's transcripts and phase A's "cold launch against a pristine host"
    /// replays bytes from a session it never had. It is the one input that can differ between two
    /// otherwise identical runs, and one of them went red.
    func testTheGateStartsItsDaemonFromAFullyFreshState() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains(#"rm -rf "${HOSTD_WORKSPACE}" "${HOSTD_HOME}""#),
            "check-launch-restore.sh no longer wipes the daemon's HOME — a stale scrollback journal "
                + "makes phase A's cold launch replay a session it never had",
        )
    }

    /// The invariant is WATCHED, not settled for. The churn this gate exists to catch is one wire
    /// round trip wide and lands AFTER the panes are up and looking correct, so a check that samples
    /// once — at any delay — is a coin toss. This repo has already shipped a gate that was green four
    /// runs in a row over a two-in-nine race.
    func testTheGateWatchesRatherThanSettles() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains("hold_steady \"phase A\"") && code.contains("hold_steady \"phase B\"")
                && code.contains("hold_steady \"phase C\""),
            "check-launch-restore.sh no longer holds the invariant across a watch window in every "
                + "phase — a late replacement would land after the assertion and never be seen",
        )
        let watch = try XCTUnwrap(
            Self.shellAssignment("WATCH_SECONDS", in: code).flatMap(Int.init),
            "check-launch-restore.sh lost its WATCH_SECONDS bound",
        )
        XCTAssertGreaterThanOrEqual(
            watch, 30,
            "the watch window is the only thing standing between this gate and a race it cannot see",
        )
    }

    /// Two gates on one port is a flake with no relation to either claim: whichever binds second
    /// fails, or worse, the second gate's client dials the first gate's daemon.
    func testTheGateOwnsItsOwnPort() throws {
        let mine = try XCTUnwrap(Self.shellAssignment("CONNECT_PORT", in: codeBody(of: Self.gateScript)))
        for other in ["scripts/check-macos.sh", "scripts/check-video.sh", "scripts/check-multiclient.sh"] {
            let theirs = try Self.shellAssignment("CONNECT_PORT", in: codeBody(of: other))
            XCTAssertNotEqual(
                theirs, mine,
                "\(other) binds :\(mine) too — two gates on one port cannot run back to back",
            )
        }
    }

    /// The value of `NAME=…` in a shell script, or `nil`. Trailing `# comment` is stripped (comment
    /// LINES are already gone; a trailing one is not) and surrounding quotes are dropped.
    private static func shellAssignment(_ name: String, in code: String) -> String? {
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(name)=") else { continue }
            var value = String(trimmed.dropFirst(name.count + 1))
            if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}
