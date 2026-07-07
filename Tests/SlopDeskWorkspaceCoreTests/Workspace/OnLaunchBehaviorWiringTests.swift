import XCTest
@testable import SlopDeskWorkspaceCore

/// O1 — the `On Launch` general setting is a LIVE control, not a dead accessor. Before this wiring the
/// General → On Launch picker persisted ``OnLaunchBehavior`` but NO launch path read it, so picking "New
/// Window" was a silent no-op (`SlopDeskClientApp.init` always restored the persisted tree via
/// `loadTree()`). The fix routes the app's store-construction site through
/// ``WorkspacePersistence/launchTree(behavior:persistence:)``; these pins prove the launch branch picks
/// fresh-vs-restore based on the persisted key, headlessly — against a temp-file persistence seam, with no
/// window / store / UI / SCStream / VT / Metal constructed (the hang-safety rule).
final class OnLaunchBehaviorWiringTests: XCTestCase {
    /// A temp-file persistence holding a tree distinguishable from a fresh `defaultWorkspace()` (its active
    /// session is renamed to a marker), plus the temp dir to clean up.
    private func makeMarkedPersistence(
        marker: String,
    ) throws -> (persistence: WorkspacePersistence, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-onlaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let persistence = WorkspacePersistence(fileURL: dir.appendingPathComponent("workspace.json"))

        var tree = TreeWorkspace.defaultWorkspace().normalized()
        // Rename the active session so the restored tree is NOT byte-identical to a fresh default — this is
        // the marker the restore branch must surface and the fresh branch must NOT.
        tree.sessions[0].name = marker
        try persistence.save(tree)
        return (persistence, dir)
    }

    /// `.restoreLastSession` (the default) restores the persisted tree, while `.newWindow` returns `nil` so
    /// the store seeds `TreeWorkspace.defaultWorkspace()` — proven with the SAME persistence handle so the
    /// ONLY thing flipping the outcome is the persisted ``OnLaunchBehavior``. (Revert-to-confirm-fail: before
    /// the wiring there was no `launchTree`, and the app's `persistence?.loadTree()` returned the marked tree
    /// for BOTH values — this test could not have been written, let alone pass.)
    func testLaunchTreeBranchesOnBehavior() throws {
        let marker = "Restored-Marker"
        let (persistence, dir) = try makeMarkedPersistence(marker: marker)
        defer { try? FileManager.default.removeItem(at: dir) }

        // restoreLastSession → the persisted (marked) tree.
        let restored = WorkspacePersistence.launchTree(
            behavior: .restoreLastSession, persistence: persistence,
        )
        XCTAssertEqual(
            restored?.activeSession?.name, marker,
            ".restoreLastSession must restore the persisted tree",
        )

        // newWindow → nil (the store then seeds a fresh single-pane defaultWorkspace), NOT the marked tree —
        // even though the very same persistence handle could have restored it.
        let fresh = WorkspacePersistence.launchTree(behavior: .newWindow, persistence: persistence)
        XCTAssertNil(fresh, ".newWindow must NOT restore the persisted tree (store seeds defaultWorkspace)")

        // The fresh default the store would seed is genuinely distinct from the persisted session.
        XCTAssertNotEqual(
            TreeWorkspace.defaultWorkspace().activeSession?.name, marker,
            "a fresh default session is not the persisted (marked) session",
        )
    }

    /// The launch path reads the PERSISTED key end-to-end: setting `general.onLaunch` in `UserDefaults` (the
    /// store the `@Default(.onLaunch)` picker binds) flips the resolved tree exactly as the app does
    /// (`launchTree(behavior: SettingsKey.onLaunch, persistence:)`). This is the proof the dead accessor is
    /// now wired: the persisted choice — not a hardcoded restore — drives the branch.
    func testPersistedKeyDrivesLaunchBranch() throws {
        let marker = "Persisted-Key-Marker"
        let (persistence, dir) = try makeMarkedPersistence(marker: marker)
        let key = SettingsKey.onLaunchKey
        let prior = SettingsKey.store.string(forKey: key)
        defer {
            try? FileManager.default.removeItem(at: dir)
            if let prior { SettingsKey.store.set(prior, forKey: key) }
            else { SettingsKey.store.removeObject(forKey: key) }
        }

        // Persisted "new-window" → the app-shaped read resolves to a fresh window (nil tree).
        SettingsKey.store.set("new-window", forKey: key)
        XCTAssertEqual(SettingsKey.onLaunch, .newWindow)
        XCTAssertNil(
            WorkspacePersistence.launchTree(behavior: SettingsKey.onLaunch, persistence: persistence),
            "a persisted new-window key must seed a fresh window",
        )

        // Persisted "restore-last-session" → the app-shaped read restores the marked tree.
        SettingsKey.store.set("restore-last-session", forKey: key)
        XCTAssertEqual(SettingsKey.onLaunch, .restoreLastSession)
        XCTAssertEqual(
            WorkspacePersistence.launchTree(behavior: SettingsKey.onLaunch, persistence: persistence)?
                .activeSession?.name,
            marker,
            "a persisted restore-last-session key must restore the persisted tree",
        )
    }

    /// With NO persistence handle (the automation shape — the store is built without one so a throwaway
    /// autoconnect tree can't clobber the real `workspace.json`), the default `.restoreLastSession` resolves
    /// to `nil` exactly as the pre-wiring `persistence?.loadTree()` did, so automation launch is unchanged.
    func testNoPersistenceIsNilRegardlessOfBehavior() {
        XCTAssertNil(WorkspacePersistence.launchTree(behavior: .restoreLastSession, persistence: nil))
        XCTAssertNil(WorkspacePersistence.launchTree(behavior: .newWindow, persistence: nil))
    }

    /// DATA-LOSS FOOTGUN GUARD: a `.newWindow` launch must NOT silently + permanently destroy the user's last
    /// saved session. The store keeps the live persistence handle, so its first debounced `save()` overwrites
    /// `workspace.json` with the fresh default tree; `launchTree(.newWindow)` therefore snapshots the existing
    /// `workspace.json` aside to the `.previous` sidecar FIRST, so the prior session stays recoverable.
    ///
    /// This test simulates the full sequence the way the app actually runs it — persist a marked tree, persist
    /// `general.onLaunch = new-window`, drive the SAME app-shaped launch read
    /// (`launchTree(behavior: SettingsKey.onLaunch, persistence:)`, exactly the call in `SlopDeskClientApp`),
    /// then emulate the store's first autosave overwriting `workspace.json` with a fresh default — and asserts
    /// the marked session is STILL recoverable. The proof is non-tautological: it writes the would-be-fresh
    /// snapshot THROUGH the live persistence handle (the real destructive write) and re-reads from disk, rather
    /// than asserting `launchTree`'s pure return value.
    ///
    /// Revert-to-confirm-fail: with the old `case .newWindow: nil` (no `snapshotPreviousSession()`), no sidecar
    /// is written, so the overwrite leaves the marked tree unrecoverable and BOTH disk assertions below FAIL.
    func testNewWindowLaunchPreservesPriorSessionInSidecar() throws {
        let marker = "Doomed-Session-Marker"
        let (persistence, dir) = try makeMarkedPersistence(marker: marker)
        let key = SettingsKey.onLaunchKey
        let prior = SettingsKey.store.string(forKey: key)
        defer {
            try? FileManager.default.removeItem(at: dir)
            if let prior { SettingsKey.store.set(prior, forKey: key) }
            else { SettingsKey.store.removeObject(forKey: key) }
        }

        // Drive the launch off the PERSISTED key — the real app shape (`launchTree(behavior: SettingsKey.onLaunch,
        // persistence:)`). A persisted "new-window" choice resolves to a fresh window (nil → store seeds a fresh
        // default) and must FIRST snapshot the saved session aside.
        SettingsKey.store.set("new-window", forKey: key)
        XCTAssertEqual(SettingsKey.onLaunch, .newWindow)
        XCTAssertNil(
            WorkspacePersistence.launchTree(behavior: SettingsKey.onLaunch, persistence: persistence),
            "a persisted new-window key seeds a fresh window (nil tree)",
        )

        // Emulate the store's first debounced autosave: the live handle overwrites `workspace.json` with the
        // fresh default tree — exactly the write that, pre-fix, PERMANENTLY destroyed the saved session.
        try persistence.save(TreeWorkspace.defaultWorkspace().normalized())

        // `workspace.json` now holds the fresh default — the marker is gone from the primary file (this is the
        // data-loss the sidecar must offset; assert it so the recovery below isn't trivially satisfied by the
        // primary file).
        XCTAssertNotEqual(
            persistence.loadTree().activeSession?.name, marker,
            "the autosave must have overwritten the primary workspace.json with the fresh default",
        )

        // The prior (marked) session must still be recoverable from the `.previous` sidecar.
        let sidecar = persistence.previousSessionURL
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecar.path),
            ".newWindow must snapshot the saved session aside before the store autosaves over it",
        )
        let recovered = WorkspacePersistence(fileURL: sidecar).loadTree()
        XCTAssertEqual(
            recovered.activeSession?.name, marker,
            "the previously-persisted session must be recoverable from the sidecar after a .newWindow launch",
        )
    }

    /// ROBUSTNESS — repeated `.newWindow` launches must NOT clobber the preserved real session. A PERSISTENT
    /// `On Launch = New Window` setting fires `snapshotPreviousSession()` on EVERY launch, so a naive
    /// always-overwrite snapshot loses data permanently across the sequence: launch 1 snapshots the REAL session
    /// into `.previous`, the store autosaves a fresh DEFAULT over `workspace.json`; launch 2 would then snapshot
    /// that throwaway default over `.previous`, destroying the real-session backup with no recovery. The
    /// idempotency guard skips re-snapshotting when `workspace.json` is already a fresh default, so the
    /// most-recent NON-DEFAULT session stays recoverable across any number of new-window launches.
    ///
    /// Revert-to-confirm-fail: with the old always-overwrite `snapshotPreviousSession()`, launch 2 copies the
    /// default tree over `.previous`, so the recovered session name is the default "Local", NOT the marker — the
    /// final assertion FAILS. With the guard the marker survives and it PASSES.
    func testRepeatedNewWindowLaunchesPreserveRealSessionInSidecar() throws {
        let marker = "Survivor-Session-Marker"
        let (persistence, dir) = try makeMarkedPersistence(marker: marker)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Launch 1: `.newWindow` snapshots the REAL (marked) session aside, then the store autosaves a fresh
        // default over `workspace.json`.
        XCTAssertNil(WorkspacePersistence.launchTree(behavior: .newWindow, persistence: persistence))
        try persistence.save(TreeWorkspace.defaultWorkspace().normalized())

        // After launch 1: the sidecar holds the real session, `workspace.json` holds the throwaway default.
        XCTAssertEqual(
            WorkspacePersistence(fileURL: persistence.previousSessionURL).loadTree().activeSession?.name,
            marker,
            "after launch 1 the sidecar must hold the real session",
        )
        XCTAssertNotEqual(
            persistence.loadTree().activeSession?.name, marker,
            "after launch 1 the primary file is the throwaway default, not the real session",
        )

        // Launch 2: `.newWindow` again. The idempotency guard must SKIP re-snapshotting (the primary file is a
        // fresh default), so the real session in the sidecar is NOT overwritten by the default. The store then
        // autosaves the fresh default once more.
        XCTAssertNil(WorkspacePersistence.launchTree(behavior: .newWindow, persistence: persistence))
        try persistence.save(TreeWorkspace.defaultWorkspace().normalized())

        // The REAL session must STILL be recoverable from the sidecar after the second new-window launch.
        let recovered = WorkspacePersistence(fileURL: persistence.previousSessionURL).loadTree()
        XCTAssertEqual(
            recovered.activeSession?.name, marker,
            "a persistent On Launch = New Window must not clobber the real-session backup across launches",
        )
    }

    /// REGRESSION — a REAL single-un-renamed-terminal session is NOT the throwaway default merely because it
    /// shares the default's STRUCTURAL shape. The most common real workspace is one un-renamed terminal in a
    /// project dir: its leaf spec carries a `lastKnownCwd` (the subtitle hint) and, for a detached host session,
    /// a `resumeSessionID` reattach handle — while its `title` is still "Terminal" (the raw-decode idempotency
    /// guard runs BEFORE the load-time `lastKnownTitle → title` promotion). A `.newWindow` launch must snapshot it
    /// aside before the store autosaves the fresh default over `workspace.json`, exactly as it does a renamed
    /// session, or the cwd/resume hints are PERMANENTLY lost.
    ///
    /// Revert-to-confirm-fail: with the old shape-only `isDefaultTreeShape` (no additive-field check), this tree
    /// matches the default ⇒ `snapshotPreviousSession()` SKIPS the copy ⇒ no sidecar, and the recovery assertions
    /// below FAIL. With the tightened guard the session is preserved aside and they PASS.
    func testNewWindowPreservesRealSingleTerminalWithCwdHint() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-onlaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = WorkspacePersistence(fileURL: dir.appendingPathComponent("workspace.json"))

        // A tree that is STRUCTURALLY the default shape (one "Local" session, one tab, one "Terminal" leaf) but is
        // a REAL connected session — its leaf carries a `lastKnownCwd` subtitle hint. The title stays "Terminal"
        // because the raw-decode guard runs before the load-time `lastKnownTitle → title` promotion.
        var tree = TreeWorkspace.defaultWorkspace().normalized()
        let leaf = try XCTUnwrap(tree.allPaneIDs().first)
        let cwd = "/Users/me/project-with-unsaved-context"
        tree.sessions[0].specs[leaf]?.lastKnownCwd = cwd
        try persistence.save(tree)

        // Direct contract pin: a cwd-bearing real session is NOT default-shaped, while the pure re-seedable
        // default still IS (so the repeated-launch idempotency win survives the tightening).
        XCTAssertFalse(
            WorkspacePersistence.isDefaultTreeShape(tree),
            "a real single terminal with a lastKnownCwd hint must not be classified as the throwaway default",
        )
        XCTAssertTrue(
            WorkspacePersistence.isDefaultTreeShape(TreeWorkspace.defaultWorkspace().normalized()),
            "the pure all-nil default must still be classified as the re-seedable default (idempotency win)",
        )

        // `.newWindow` must snapshot this real session aside (it is NOT the throwaway default).
        XCTAssertNil(WorkspacePersistence.launchTree(behavior: .newWindow, persistence: persistence))

        // Emulate the store's first autosave overwriting the primary file with a fresh default.
        try persistence.save(TreeWorkspace.defaultWorkspace().normalized())
        let primaryLeaf = try XCTUnwrap(persistence.loadTree().allPaneIDs().first)
        XCTAssertNil(
            persistence.loadTree().spec(for: primaryLeaf)?.lastKnownCwd,
            "the autosave overwrote the primary workspace.json with the fresh default (no cwd hint)",
        )

        // The real session's cwd hint must still be recoverable from the `.previous` sidecar.
        let recovered = WorkspacePersistence(fileURL: persistence.previousSessionURL).loadTree()
        let recoveredLeaf = try XCTUnwrap(recovered.allPaneIDs().first)
        XCTAssertEqual(
            recovered.spec(for: recoveredLeaf)?.lastKnownCwd, cwd,
            "a real single-un-renamed-terminal session must be preserved aside on a .newWindow launch",
        )
    }

    /// A genuine first launch (no `workspace.json` yet) writes NO sidecar — there is nothing to preserve, and
    /// `snapshotPreviousSession()` must not fabricate an empty/garbage `.previous` file.
    func testNewWindowFirstLaunchWritesNoSidecar() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-onlaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = WorkspacePersistence(fileURL: dir.appendingPathComponent("workspace.json"))

        XCTAssertNil(WorkspacePersistence.launchTree(behavior: .newWindow, persistence: persistence))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: persistence.previousSessionURL.path),
            "a first launch (no saved file) must not write a sidecar",
        )
    }
}
