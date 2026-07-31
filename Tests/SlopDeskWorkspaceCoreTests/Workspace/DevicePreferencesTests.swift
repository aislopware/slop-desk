import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``DevicePreferences`` — the device-local facts that never cross the workspace document: latched
/// video modes, launch presets / session templates, the per-host connection target, and the
/// follow-session-focus preference. Pins the on-disk round-trip, the decode-failure rule (a corrupt or
/// stale file becomes a FRESH default — never migrated), and the per-platform `followSessionFocus`
/// default, which `scripts/check-ios.sh` cannot catch because it only COMPILES the iOS slice.
@MainActor
final class DevicePreferencesTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-device-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // The @objc XCTestCase override must keep the throwing signature (a non-throwing
    // override of a throwing @objc method does not compile).
    // swiftlint:disable:next unneeded_throws_rethrows
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private var fileURL: URL { directory.appendingPathComponent("device-prefs.json") }

    // MARK: - Round-trip

    /// The load-bearing case: a latched video mode written for a `VideoEndpoint.modesKey` is still there
    /// when a FRESH store reads the same file. Getting this wrong silently resets every immersive /
    /// audio / viewport-lock latch on relaunch.
    func testVideoModesSurviveARoundTrip() throws {
        let writer = DevicePreferencesStore(fileURL: fileURL)
        var prefs = writer.load()
        prefs.videoModesByTarget["display:2"] = VideoPaneModes(immersive: true, fpsCap: 30)
        prefs.videoModesByTarget["app:Safari"] = VideoPaneModes(audioEnabled: true)
        try writer.save(prefs)

        let reader = DevicePreferencesStore(fileURL: fileURL)
        let restored = reader.load()
        XCTAssertEqual(
            restored.videoModesByTarget,
            [
                "display:2": VideoPaneModes(immersive: true, fpsCap: 30),
                "app:Safari": VideoPaneModes(audioEnabled: true),
            ],
        )
    }

    /// The other four collections round-trip too — presets, templates and the per-`host:port` target.
    func testEveryDeviceLocalCollectionRoundTrips() throws {
        let store = DevicePreferencesStore(fileURL: fileURL)
        var prefs = store.load()
        prefs.launchPresets = [LaunchPreset(name: "Mine", command: "ls")]
        prefs.sessionTemplates = [SessionTemplate(name: "Solo", layout: .pane(TemplatePane(title: "X")))]
        let target = ConnectionTarget(host: "studio", port: 7420, mediaPort: 9000, cursorPort: 9001)
        prefs.connectionByHostKey[DevicePreferences.hostKey(for: target)] = target
        prefs.followSessionFocus.toggle()
        try store.save(prefs)

        let restored = DevicePreferencesStore(fileURL: fileURL).load()
        XCTAssertEqual(restored, prefs)
        XCTAssertEqual(restored.connectionByHostKey["studio:7420"], target)
    }

    // MARK: - Decode failure = a fresh default, never a migration

    func testACorruptFileDecodesToDefaultsRatherThanThrowing() throws {
        try Data("{ this is not json ".utf8).write(to: fileURL)

        let prefs = DevicePreferencesStore(fileURL: fileURL).load()

        XCTAssertEqual(prefs, DevicePreferences(), "a corrupt file becomes a FRESH default")
        XCTAssertEqual(prefs.followSessionFocus, DevicePreferences.platformDefaultFollowSessionFocus)
        XCTAssertTrue(prefs.videoModesByTarget.isEmpty)
        XCTAssertTrue(prefs.connectionByHostKey.isEmpty)
    }

    /// A STALE shape (a file whose keys this build no longer understands) is the same case: decode-fail
    /// to a fresh default. No migration step exists, and none may be added.
    func testAStaleShapeDecodesToDefaults() throws {
        try Data(#"{"someRetiredKey": 1}"#.utf8).write(to: fileURL)
        XCTAssertEqual(DevicePreferencesStore(fileURL: fileURL).load(), DevicePreferences())
    }

    /// A missing file is first launch, not corruption.
    func testAMissingFileLoadsDefaults() {
        XCTAssertEqual(DevicePreferencesStore(fileURL: fileURL).load(), DevicePreferences())
    }

    /// An absurd collection count is rejected wholesale rather than allocated — the same ceiling
    /// ``WorkspacePersistence`` applies to the tree.
    func testAnAbsurdCollectionCountResetsToDefaults() throws {
        let store = DevicePreferencesStore(fileURL: fileURL)
        var prefs = store.load()
        prefs.launchPresets = (0...DevicePreferencesStore.maxItems)
            .map { LaunchPreset(name: "p\($0)", command: "true") }
        try store.save(prefs)

        XCTAssertEqual(DevicePreferencesStore(fileURL: fileURL).load(), DevicePreferences())
    }

    // MARK: - followSessionFocus, per platform

    /// macOS follows the host's session focus by default; iOS does not (docs/45 §8.2). A wrong value
    /// here has NO other guard — `scripts/check-ios.sh` only type-checks the iOS slice.
    func testFollowSessionFocusDefaultsOnPerPlatform() {
        #if os(iOS)
        XCTAssertFalse(DevicePreferences().followSessionFocus)
        XCTAssertFalse(DevicePreferences.platformDefaultFollowSessionFocus)
        #else
        XCTAssertTrue(DevicePreferences().followSessionFocus)
        XCTAssertTrue(DevicePreferences.platformDefaultFollowSessionFocus)
        #endif
    }

    // MARK: - No store = no disk

    /// The test seam / automation path: a store nobody injected never touches the filesystem.
    func testAStoreIsOptionalAndTheDefaultIsPure() {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        XCTAssertEqual(store.devicePreferences.launchPresets.map(\.name), LaunchPreset.builtIns.map(\.name))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "no injected store ⇒ nothing was written",
        )
    }
}

// MARK: - The launch connection seed

/// The connect-gate's launch prefill. `Session.connection` is gone, so the seed comes from the
/// ``AppConnection`` MRU — the same list the gate's "recent hosts" menu shows and the only host
/// identity known BEFORE connecting.
@MainActor
final class LaunchConnectionSeedTests: XCTestCase {
    private func scratchDefaults() throws -> UserDefaults {
        let suite = "slopdesk-launch-seed-\(UUID().uuidString)"
        // Removed at process exit, domain and file both: this helper had left 157 plists in the
        // developer's ~/Library/Preferences by the time anybody counted.
        SettingsKey.removeSuiteAtExit(named: suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testLaunchSeedIsTheMostRecentTarget() throws {
        let defaults = try scratchDefaults()
        let recent = [
            ConnectionTarget(host: "studio", port: 7420),
            ConnectionTarget(host: "macbook", port: 7420),
        ]
        try defaults.set(JSONEncoder().encode(recent), forKey: "connection.recentTargets")

        XCTAssertEqual(AppConnection.launchSeedTarget(defaults: defaults), recent[0])
    }

    func testLaunchSeedFallsBackToTheDefaultTargetOnAFreshInstall() throws {
        XCTAssertEqual(try AppConnection.launchSeedTarget(defaults: scratchDefaults()), .default)
    }

    /// The MRU remembers the TERMINAL address; the video ports come back from the per-host file.
    ///
    /// Without this read the map is written on every connect and consulted by nobody, so re-dialling
    /// a host reached on non-default media/cursor ports silently offers 9000/9001 instead.
    func testTheSeedRestoresTheVideoPortsThatHostWasReachedOn() {
        let reached = ConnectionTarget(host: "studio", port: 7420, mediaPort: 9100, cursorPort: 9101)
        var preferences = DevicePreferences()
        preferences.connectionByHostKey[DevicePreferences.hostKey(for: reached)] = reached

        // What the MRU alone can offer: the right host and terminal port, default video ports.
        let fromMRU = ConnectionTarget(host: "studio", port: 7420)
        XCTAssertEqual(preferences.connectionTarget(seededBy: fromMRU), reached)
    }

    /// A host this device has never reached is offered back unchanged — no invented ports.
    func testAnUnknownHostIsSeededUnchanged() {
        let fresh = ConnectionTarget(host: "macbook", port: 7420)
        XCTAssertEqual(DevicePreferences().connectionTarget(seededBy: fresh), fresh)
    }
}
