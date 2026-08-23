import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest

/// The two committed fixtures `slopdesk-guigate launch-restore` seeds, decoded through the SHIPPING
/// Swift types that will read them on a hardware run.
///
/// That gate is the only one that reaches the launch a USER performs: restore `workspace.json`, offer
/// it to the host, silently re-connect to the saved host. The other three all set an autoconnect env
/// var, which makes `hasAutomationEnvironment()` true and takes the app down the automation branch
/// instead — no persistence, a synthetic one-pane layout, no `connectIfSavedTarget()`.
///
/// It takes minutes, needs an unlocked Aqua session and cannot run in CI, so the part of it that IS
/// headlessly checkable is checked here: both fixtures must still decode. Each is silent when it
/// breaks. A layout the persistence reader cannot speak is reset aside and the client restores the
/// ONE-pane default, so the gate fails minutes in with "the client never projected the restored
/// layout" — the one message that does not name the cause. An MRU whose `CodingKey` moved decodes to
/// `[]`, so `connectIfSavedTarget()` returns without dialling and the gate simply hangs.
///
/// Everything ELSE this file used to assert was a text-level read of the shell script this gate used
/// to be — which argv the launch carries, which env it must not set, that the census counts PTYs
/// rather than children, that the watch window is watched rather than sampled. All of that is Rust
/// now, and it is checked where it lives, in `rust/slopdesk-devtools/src/gui/`. What stays here is
/// the half Rust cannot check: that a Swift type still decodes the file.
///
/// The fixtures are the only thing the two languages share, and that is deliberate — neither side
/// reads the other's source. Same discipline as the `*GoldenVectorTests` family over
/// `golden/golden_vectors.json`.
final class LaunchRestoreGateContractTests: XCTestCase {
    private static let layoutFixture = "scripts/fixtures/launch-restore-workspace.json"
    private static let mruFixture = "scripts/fixtures/launch-restore-mru.json"

    /// The pane ids the fixture names, and the gate's assertions quote. Uppercase — `PaneID.raw
    /// .uuidString` is, and the client-control socket answers with it.
    private static let paneIDs = [
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
    ]

    /// `scripts/` sits beside `Tests/` in the package root — walk up from this file rather than
    /// relying on a bundle resource (a fixture here is a working-tree artefact, not a SwiftPM one).
    private func repoURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskWorkspaceCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent(relativePath)
    }

    // MARK: - The layout fixture

    /// The committed layout must still restore, through the REAL launch path, to the shape the gate
    /// asserts: two tabs (so a pane in a tab the window is not showing still has to get a shell) and
    /// a split (so a restored split has to survive), three terminal panes, these ids.
    ///
    /// `loadTree` is the launch reader and the one that can silently substitute a default, so this
    /// is both halves at once: the file is decodable, AND it is what a launch actually gets.
    ///
    /// Without this, a `TreeWorkspace.currentSchemaVersion` bump turns the fixture into an unreadable
    /// file and the gate goes red eight minutes into a hardware run with a message that names the
    /// symptom rather than the cause.
    func testTheCommittedLayoutFixtureStillRestores() throws {
        // Loaded from a COPY. `loadTree` is a repairing reader: a file it cannot speak is moved aside
        // as a `.corrupt` sidecar next to itself — so pointing it straight at the working tree would
        // make this test litter `scripts/fixtures/` on the very run that reports the drift.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-restore-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("workspace.json")
        try FileManager.default.copyItem(at: repoURL(Self.layoutFixture), to: copy)

        let restored = try XCTUnwrap(
            WorkspacePersistence(fileURL: copy).loadTree(),
            "\(Self.layoutFixture) no longer decodes as a TreeWorkspace — most likely "
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

    // MARK: - The saved-host fixture

    /// The MRU the gate injects must still decode as `[ConnectionTarget]`, because that is exactly
    /// what `AppConnection.loadRecentTargets` does with it — and a decode failure there is SILENT:
    /// `recentTargets` becomes `[]`, `connectIfSavedTarget()` returns without dialling, and the gate
    /// hangs until it times out with no hint that a `CodingKey` moved.
    ///
    /// The gate hex-encodes this exact file into `-connection.recentTargets` in the ARGUMENT DOMAIN,
    /// which Cocoa hands back as `Data` — the form `loadRecentTargets` reads. It is the argument
    /// domain rather than the suite for determinism: `CFFIXED_USER_HOME` does not redirect
    /// `UserDefaults` (cfprefsd resolves the account record), and the argument domain outranks both
    /// the persistent domain and the throwaway suite, so this fixture is the only host the gate's
    /// client can dial whichever gate ran last.
    func testTheSavedHostFixtureStillDecodesAsAConnectionTarget() throws {
        let data = try Data(contentsOf: repoURL(Self.mruFixture))
        let targets = try JSONDecoder().decode([ConnectionTarget].self, from: data)
        XCTAssertEqual(targets.count, 1, "the fixture is one saved host")
        XCTAssertEqual(targets.first?.host, "127.0.0.1")
        // The port is the gate's own, and which one that is stays the Rust ledger's business —
        // `gui::port::LAUNCH_RESTORE`, tied to this file by `check_mru_names_this_gates_port`. All
        // that matters here is that a port survived the decode at all: a `CodingKey` rename gives
        // `ConnectionTarget` its default and the client dials the wrong daemon in silence.
        XCTAssertNotNil(targets.first?.port, "the seeded MRU must carry a port through the decode")
        XCTAssertNotEqual(targets.first?.port, 0, "port 0 is what a dropped key decodes to")
    }
}
