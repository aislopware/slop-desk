// VideoPaneModesPersistenceTests — pins the latched video-pane modes' restart survival: the additive
// `PaneSpec.videoModes` codable contract, the store's explicit-toggle → spec persistence wiring, and the
// `LivePaneSession.make` restore seed. The runtime (detach-remount) half — injector `didSet` re-asserts —
// is pinned in `RemoteWindowStreamControlsTests`.

import XCTest
@testable import SlopDeskWorkspaceCore

@MainActor
final class VideoPaneModesPersistenceTests: XCTestCase {
    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private let decoder = JSONDecoder()

    // MARK: - PaneSpec codable (additive)

    func testPaneSpecRoundTripsVideoModes() throws {
        let spec = PaneSpec(
            kind: .remoteGUI,
            title: "Safari",
            video: VideoEndpoint(windowID: 42, title: "Safari", appName: "Safari"),
            videoModes: VideoPaneModes(
                immersive: true, audioEnabled: true, viewportLocked: true,
                fpsCap: 30, bitrateCeilingBps: 10_000_000,
            ),
        )
        let restored = try decoder.decode(PaneSpec.self, from: makeEncoder().encode(spec))
        XCTAssertEqual(restored, spec, "PaneSpec round-trips the latched modes")
        XCTAssertEqual(restored.videoModes?.immersive, true)
        XCTAssertEqual(restored.videoModes?.bitrateCeilingBps, 10_000_000)
    }

    /// A nil / all-default modes value emits NO `videoModes` key (additive-minimal — an untouched
    /// pane's JSON is byte-unchanged from the pre-modes shape).
    func testDefaultModesAreNotEmitted() throws {
        let nilModes = PaneSpec(kind: .remoteGUI, title: "Safari")
        let defaultModes = PaneSpec(kind: .remoteGUI, title: "Safari", videoModes: VideoPaneModes())
        for spec in [nilModes, defaultModes] {
            let json = try XCTUnwrap(String(data: makeEncoder().encode(spec), encoding: .utf8))
            XCTAssertFalse(json.contains("videoModes"), "default modes must not be emitted")
        }
    }

    /// An older file without the key decodes `nil` — never traps (the additive decode contract).
    func testAbsentVideoModesKeyDecodesNil() throws {
        let json = """
        { "kind": "remoteGUI", "title": "Safari",
          "video": { "windowID": 99, "title": "Safari", "appName": "Safari" } }
        """
        let spec = try decoder.decode(PaneSpec.self, from: Data(json.utf8))
        XCTAssertNil(spec.videoModes)
    }

    /// Per-field additive decode + validate-then-default: a partial `videoModes` object (a future/older
    /// build's key set) fills the rest with defaults, and a negative persisted cap is repaired to auto.
    func testPartialAndInvalidModesDecodeToDefaults() throws {
        let json = """
        { "kind": "remoteGUI", "title": "Safari",
          "videoModes": { "audioEnabled": true, "fpsCap": -5 } }
        """
        let spec = try decoder.decode(PaneSpec.self, from: Data(json.utf8))
        let modes = try XCTUnwrap(spec.videoModes)
        XCTAssertTrue(modes.audioEnabled)
        XCTAssertFalse(modes.immersive, "absent field decodes to its default")
        XCTAssertFalse(modes.viewportLocked)
        XCTAssertEqual(modes.fpsCap, 0, "a negative persisted cap is repaired to auto")
        XCTAssertEqual(modes.bitrateCeilingBps, 0)
    }

    // MARK: - Store wiring: explicit toggle → spec, spec → restored session

    /// One real session factory for the store tests. `makeClient` is never called here: a video pane
    /// has no PATH-1 connection, and the default workspace's terminal pane is lazy-connect (no view
    /// ever triggers `connect()` in a headless store test).
    private func makeLiveStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { spec in
            LivePaneSession.make(
                spec,
                makeClient: { _ in fatalError("connect() never runs in this test") },
                makeInspector: { _ in nil },
            )
        })
    }

    /// The end-to-end persistence edge: an explicit audio toggle on a materialized pane's model lands in
    /// the pane's spec (`videoModes`), default-normalized to `nil` when everything is back off.
    func testExplicitToggleLandsInThePaneSpec() throws {
        let store = makeLiveStore()
        let id = try XCTUnwrap(store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari"))
        let session = try XCTUnwrap(store.handle(for: id) as? LivePaneSession)
        let model = try XCTUnwrap(session.remoteWindow)

        model.open()
        model.audioInjector = { _ in }
        model.applyAudioEnabled(true)

        XCTAssertEqual(
            store.tree.spec(for: id)?.videoModes,
            VideoPaneModes(audioEnabled: true),
            "the explicit toggle persists into the pane's spec",
        )

        model.applyAudioEnabled(false)
        XCTAssertNil(
            store.tree.spec(for: id)?.videoModes,
            "all-default modes normalize back to nil (additive-minimal JSON)",
        )
    }

    /// The restore half: `LivePaneSession.make` seeds a fresh model from `spec.videoModes`, so a
    /// relaunch's first session starts with the persisted wishes (which the injector `didSet`s then
    /// re-assert — pinned in `RemoteWindowStreamControlsTests`).
    func testMakeSeedsModelFromPersistedModes() throws {
        let spec = PaneSpec(
            kind: .remoteGUI,
            title: "Safari",
            video: VideoEndpoint(windowID: 42, title: "Safari", appName: "Safari"),
            videoModes: VideoPaneModes(
                immersive: true, audioEnabled: true, viewportLocked: true,
                fpsCap: 60, bitrateCeilingBps: 20_000_000,
            ),
        )
        let session = LivePaneSession.make(
            spec,
            makeClient: { _ in fatalError("unused for a video pane") },
            makeInspector: { _ in nil },
        )
        let model = try XCTUnwrap(session.remoteWindow)
        XCTAssertTrue(model.immersiveDesired)
        XCTAssertTrue(model.audioStreamEnabled)
        XCTAssertTrue(model.viewportLocked)
        XCTAssertEqual(model.streamFpsCap, 60)
        XCTAssertEqual(model.streamBitrateCeilingBps, 20_000_000)
    }

    /// A spec WITHOUT modes seeds nothing — the fresh-pane defaults stand.
    func testMakeWithoutModesLeavesDefaults() throws {
        let spec = PaneSpec(kind: .remoteGUI, title: "Safari")
        let session = LivePaneSession.make(
            spec,
            makeClient: { _ in fatalError("unused for a video pane") },
            makeInspector: { _ in nil },
        )
        let model = try XCTUnwrap(session.remoteWindow)
        XCTAssertFalse(model.immersiveDesired)
        XCTAssertFalse(model.audioStreamEnabled)
        XCTAssertEqual(model.streamFpsCap, 0)
    }
}
