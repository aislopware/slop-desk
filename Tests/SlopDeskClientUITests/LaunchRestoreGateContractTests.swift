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
    /// resolves the real home). `SLOPDESK_DEFAULTS_SUITE` now empties the persistent MRU this launch
    /// can see, and the argument domain outranks a suite exactly as it outranks a bundle domain — so
    /// the fixture stays the only host this client can dial, whichever gate ran last.
    func testTheSavedHostArrivesThroughTheArgumentDomain() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains("-connection.recentTargets \"<${MRU_HEX}>\""),
            "check-launch-restore.sh no longer overrides the MRU in the argument domain, so the "
                + "client dials whatever the persistent domain happens to hold.",
        )
    }

    /// The first-launch flag is the fixture the argument domain CANNOT carry.
    ///
    /// This gate sets no `SLOPDESK_AUTOCONNECT_*` — that is its whole point — so
    /// `FirstLaunchModel.shouldPresent` is `!hasCompleted`, and on an empty domain the guided sheet
    /// opens over the window. It has to be a typed `defaults write -bool` into the run's suite:
    /// `firstLaunch.completed` is read through a `Defaults.Key<Bool>`, and Cocoa parses an argv
    /// `-key YES` pair into `NSArgumentDomain` as the STRING "YES", which a Bool read rejects.
    ///
    /// RED before the fix: the gate carried `-hasCompletedFirstLaunch YES`, which is the Swift
    /// property name rather than the key AND the wrong domain type — two independent reasons it
    /// suppressed nothing. It went unnoticed because the shared persistent domain was the
    /// developer's, and they had dismissed the sheet long ago.
    func testTheFirstLaunchFlagIsSeededWithTheRightKeyAndType() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains("defaults write \"${DEFAULTS_SUITE}\" firstLaunch.completed -bool YES"),
            "check-launch-restore.sh no longer pins the first-launch flag, so the returning user it "
                + "claims to launch as reads as a fresh install and gets the welcome sheet",
        )
        XCTAssertFalse(
            code.contains("-hasCompletedFirstLaunch"),
            "check-launch-restore.sh is back to the argv spelling, which names the Swift property "
                + "instead of the `firstLaunch.completed` key and delivers a String where a Bool is read",
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

    /// The gates that count how many shells the host is running.
    ///
    /// A child of hostd is not the same thing as a shell, which is what makes this rule necessary:
    /// hostd forks helpers too. `TerminfoResolver` runs `/usr/bin/infocmp`, `HostMetadataProbe`
    /// runs `/usr/bin/git` and `/usr/sbin/lsof`, `ShellIntegration` probes `$ZDOTDIR` with a
    /// `--norcs` zsh. Each is a child for as long as it lives, and `${WORK}` sits under this repo —
    /// so a pane's project key resolves to slop-desk and every line a gate appends to its own log
    /// arms `RepoStatusWatcher`'s debounced `git` probe, INSIDE the watch window.
    private static let shellCensusGates = [
        "scripts/check-launch-restore.sh",
        "scripts/check-multiclient.sh",
    ]

    /// A shell census must count PTYs, not children — and there must be exactly ONE place that
    /// enumerates hostd's children, so a second one cannot be added without meeting this rule.
    ///
    /// RED before the fix: `check-launch-restore.sh` was green 6 runs of 8 on a clean tree, and both
    /// reds read `4 live shell(s)` for 3 panes with a diagnostic dump — re-read one line later, after
    /// the helper had exited — listing exactly 3. Under the same stimulus held down (a `date >`
    /// into `.work/` every 0.8 s, which is an FSEvents burst in the watched repo) it was 0 of 3. A
    /// gate that is green half the time and cites a number nothing can corroborate is worse than a
    /// red one, because a single sweep launders a false report.
    ///
    /// The occurrence COUNT is what makes this catch a new site rather than restate the old one: any
    /// fresh `pgrep -P` — a second census, a diagnostic dump, a wait loop — pushes it past one and
    /// names the script. Routing it through the existing `hostd_children` keeps it at one.
    func testEveryShellCensusCountsPTYsRatherThanChildren() throws {
        for script in Self.shellCensusGates {
            let lines = try codeBody(of: script)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { $0.contains("pgrep -P") }
            XCTAssertEqual(
                lines.count, 1,
                "\(script) enumerates hostd's children in \(lines.count) place(s); there must be "
                    + "exactly one, so the PTY discriminator cannot be bypassed. hostd forks git / "
                    + "lsof / infocmp as well as shells, and counting those is a flake nothing can "
                    + "settle out. Offending line(s): "
                    + lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ⏎ "),
            )
            XCTAssertTrue(
                try codeBody(of: script).contains("os.getsid(pid) == pid"),
                "\(script) counts hostd's children without asking which of them are PTYs. A shell is "
                    + "forked with `login_tty` — `setsid()` — so it is a SESSION LEADER; a "
                    + "`Foundation.Process` helper gets its own process GROUP but stays in hostd's "
                    + "session. Filter on `os.getsid(pid) == pid`.",
            )
        }
    }

    /// The census sample and the message that reports it must be the SAME read.
    ///
    /// The helper that inflates the count lives for tens of milliseconds, so a dump that re-reads
    /// prints a different set of children than the count was made from — three reds in a row printed
    /// "4 live shell(s)" above a list of three, and not one of them named the culprit. The gate's own
    /// `hold_steady` already states this rule for the spawn counts ("Read ONCE per sample"); the
    /// child census is the one place that broke it.
    func testTheShellCensusReportsTheSampleItCounted() throws {
        for script in Self.shellCensusGates {
            let code = try codeBody(of: script)
            XCTAssertFalse(
                code.contains("pgrep -P \"${HOSTD_PID}\" -l"),
                "\(script) dumps a FRESH `pgrep -P` when the census goes red, so the list it prints is "
                    + "not the list it counted. Print the sample that failed.",
            )
        }
    }

    /// "One shell per restored pane" has to be checked PER PANE, not as a sum over them.
    ///
    /// A total of three across three panes is equally satisfied by 2 + 1 + 0 — one pane torn down and
    /// re-dialled with its first PTY abandoned, another with no shell at all. That is the exact churn
    /// this gate exists to catch, and the sum check passed it; it then reappeared downstream as
    /// "3 pane(s) in the layout but 2 live shell(s)", a sentence with no cause in it. Proven against a
    /// hand-built log: `spawned_shells` answered 3 and `spawned_shells_are 3` returned true.
    func testTheSpawnCheckIsPerPaneRatherThanASum() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains("one_shell_per_pane"),
            "check-launch-restore.sh no longer checks the spawn count PER PANE, so a pane that was "
                + "re-dialled and a pane that never got a shell cancel out in the total",
        )
        XCTAssertTrue(
            code.contains("dump_spawns_per_pane"),
            "check-launch-restore.sh no longer prints the per-pane spawn breakdown, which is the only "
                + "form of this number that names the pane at fault",
        )
    }

    /// A socket read that FAILED must not be reported as a projection that CHANGED.
    ///
    /// `signature()` yields the empty string when either CLI call errors or when fewer than two JSON
    /// documents come back, so without a guard an unanswered control socket falls into the
    /// projection branch and `hold_steady` prints "the projection left the restored layout <n>s in"
    /// above an EMPTY pane list. That is the wrong sentence for that state and it is unfalsifiable:
    /// nothing about the layout was observed. A red run reporting it sends the reader looking for a
    /// layout bug that the evidence cannot support either way.
    func testAnUnreadableControlSocketIsNotReportedAsAProjectionChange() throws {
        let code = try codeBody(of: Self.gateScript)
        XCTAssertTrue(
            code.contains(#"if [[ -z "${sig}" ]]; then"#),
            "check-launch-restore.sh no longer separates an unreadable control socket from a "
                + "projection that moved, so a failed read prints `the projection left the restored "
                + "layout` over an empty list of panes",
        )
        XCTAssertTrue(
            code.contains("stopped answering its control socket"),
            "check-launch-restore.sh lost the message that names an unanswered control socket",
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
