import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - RemoteGUIFirstClassPeerTests (the audit-as-tests peer-enumeration suite)

/// **Every kind-generic surface treats `.remoteGUI` as a first-class peer — as a STAGE tab.**
///
/// Under the Stage re-scope the split tree is TERMINAL-ONLY: a `.remoteGUI` pane (a real host window
/// streamed over the PATH-2 UDP video path) lives in its session's STAGE. First-class-ness now means
/// the kind-generic enumeration/policy surfaces still ADMIT the staged pane with no kind-dropping
/// switch/guard: the stage ingress mints a reachable pane, Open Quickly's Opened list includes and
/// DIFFERENTIATES it, read-only records it, the rail-subtitle policy labels it, and a LEGACY persisted
/// file that still carries a video leaf in its tree migrates it into the stage instead of dropping it.
///
/// Hang-safety: NO `SCStream`/`VTCompression`/`VTDecompression`/Metal/`NSWindow` is instantiated — the store
/// uses the spec-only ``FakePaneSession`` seam, and the tree ops are pure value transforms.
@MainActor
final class RemoteGUIFirstClassPeerTests: XCTestCase {
    // MARK: - Fixtures

    /// A spec-only `.tree`-live store (no terminal model / renderer / socket).
    private func makeFakeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
    }

    /// A pure tree carrying a `.terminal` tree pane and a `.remoteGUI` STAGE pane in one session, so
    /// the kind-generic enumeration surfaces (Open-Quickly) can be asserted to include BOTH zones. The
    /// stage pane mirrors what ``WorkspaceStore/openWindowInStage(windowID:title:appName:)`` mints: a
    /// `.remoteGUI` spec carrying a pre-bound ``VideoEndpoint`` and no shell cwd.
    private func makeMixedTree() -> (tree: TreeWorkspace, terminal: PaneID, video: PaneID) {
        let termID = PaneID()
        let videoID = PaneID()
        var termSpec = PaneSpec(kind: .terminal, title: "zsh")
        termSpec.lastKnownCwd = "/work/proj"
        let videoSpec = PaneSpec(
            kind: .remoteGUI,
            title: "Safari — GitHub",
            video: VideoEndpoint(windowID: 5, title: "Safari — GitHub", appName: "Safari"),
        )
        let termTab = Tab(title: "T", root: .leaf(termID), activePane: termID)
        let session = Session(
            name: "s", tabs: [termTab],
            specs: [termID: termSpec, videoID: videoSpec],
            stagePanes: [videoID], activeStagePane: videoID,
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        return (tree, termID, videoID)
    }

    // MARK: - the picker → stage path lands a reachable first-class peer

    /// `openWindowInStage` mints a `.remoteGUI` stage tab bound to the picked host window, reachable BOTH
    /// in the live stage AND as a first-class Open-Quickly "Opened" row (the picker → stage → switcher
    /// round trip).
    func testOpenWindowInStageMintsReachableRemoteGUIPeer() throws {
        let store = makeFakeStore()

        let id = try XCTUnwrap(store.openWindowInStage(windowID: 42, title: "Apple", appName: "Safari"))

        // 1) the minted spec is a `.remoteGUI` pre-bound to the picked window
        let spec = try XCTUnwrap(store.tree.activeSession?.specs[id])
        XCTAssertEqual(spec.kind, .remoteGUI, "the picked window mints a remote-GUI video pane")
        XCTAssertEqual(spec.video?.windowID, 42, "the spec is pre-bound to the chosen host window")

        // 2) it is a live STAGE pane (never a tree leaf — the tree is terminal-only) …
        XCTAssertTrue(store.stagePaneIDs.contains(id), "the picked window lands as a stage tab")
        XCTAssertFalse(store.tree.allPaneIDs().contains(id), "and never as a split-tree leaf")

        // 3) … and a first-class peer in the kind-generic Open-Quickly "Opened" enumeration
        let opened = OpenQuicklyModel.openedItems(from: store.tree)
        XCTAssertTrue(
            opened.contains { $0.act == .focusPane(id) },
            "the staged window is a first-class peer in Open-Quickly's Opened list",
        )
    }

    // MARK: - Open-Quickly admits the staged pane (inclusion vs differentiation)

    /// `openedItems` enumerates BOTH zones: one row per tree pane AND per stage tab.
    func testOpenedItemsIncludesTheStagedWindowPane() {
        let (tree, terminal, video) = makeMixedTree()

        let items = OpenQuicklyModel.openedItems(from: tree)

        XCTAssertEqual(items.count, 2, "one Opened row per live pane — the terminal AND the staged window")
        XCTAssertTrue(
            items.contains { $0.act == .focusPane(terminal) },
            "the terminal pane is enumerated",
        )
        XCTAssertTrue(
            items.contains { $0.act == .focusPane(video) },
            "the staged `.remoteGUI` pane is enumerated as a first-class Opened row",
        )
    }

    /// The staged window's row reads as a WINDOW, not an undifferentiated pane: a window glyph
    /// (`display`), a "Window" badge, and the host-app subtitle (a video pane has no cwd).
    func testOpenedItemsDifferentiatesTheStagedWindowRow() throws {
        let (tree, _, video) = makeMixedTree()

        let items = OpenQuicklyModel.openedItems(from: tree)
        let videoRow = try XCTUnwrap(
            items.first { $0.act == .focusPane(video) },
            "the staged pane must be enumerated before it can be differentiated",
        )

        XCTAssertEqual(videoRow.badge, "Window", "WI-2: a remote window is badged 'Window', not 'Pane'")
        XCTAssertEqual(videoRow.symbol, "display", "WI-2: a remote window uses the window glyph, not the split glyph")
        XCTAssertNotNil(videoRow.subtitle, "WI-2: a video row carries a host/window subtitle (it has no cwd)")
        XCTAssertEqual(
            videoRow.subtitle, "Safari",
            "F2: a remote-window subtitle is the host app name (the rail's `railSubtitle` source), not the title",
        )
        XCTAssertNotEqual(
            videoRow.subtitle, videoRow.title,
            "F2: the subtitle must not echo the title — the Opened row reads window-title / host-app, two lines",
        )
    }

    // MARK: - read-only is kind-generic on the staged pane

    /// `setPaneReadOnly`/`isReadOnly(for:)` are kind-generic — they record a staged `.remoteGUI` pane in
    /// the convergent `paneReadOnly` set even though it has no live terminal model (the set-only path).
    func testReadOnlyFlipsOnAStagedWindowPane() throws {
        let store = makeFakeStore()
        let video = try XCTUnwrap(store.openWindowInStage(windowID: 21, title: "Xcode", appName: "Xcode"))

        XCTAssertFalse(store.isReadOnly(for: video), "a fresh remote window is writable")

        store.setPaneReadOnly(video, true)
        XCTAssertTrue(store.isReadOnly(for: video), "read-only records a staged `.remoteGUI` pane (kind-generic)")
        XCTAssertTrue(store.paneReadOnly.contains(video), "and lands in the convergent source of truth")

        store.setPaneReadOnly(video, false)
        XCTAssertFalse(store.isReadOnly(for: video), "and clears it")
    }

    // MARK: - the sidebar rail reads a `.remoteGUI` pane as a labelled window

    /// **The sidebar-row SUBTITLE policy** (the kind-generic ``PaneSpec/railSubtitle``). A `.remoteGUI`
    /// pane has no shell cwd, so the host-side window's owning APP name stands in — a remote window reads
    /// as a *labelled window* (its window title on line 1, the host app on line 2). A terminal keeps its cwd.
    func testRailSubtitlePrefersHostAppForARemoteWindowPane() throws {
        let (tree, terminal, video) = makeMixedTree()
        let termSpec = try XCTUnwrap(tree.spec(for: terminal))
        let videoSpec = try XCTUnwrap(tree.spec(for: video))

        XCTAssertEqual(termSpec.railSubtitle, "/work/proj", "a terminal row's subtitle is its working directory")
        XCTAssertEqual(
            videoSpec.railSubtitle, "Safari",
            "a remote-window row's subtitle is the host-side app name (line 1 carries the window title)",
        )
    }

    /// The video-subtitle fallback ladder + the never-blank guarantee (no kind dropped, no
    /// blank line). A manual-id binding (no app name) labels the row with the window title rather than going
    /// blank; a binding with neither app name nor window title yields no subtitle (a clean single-line row);
    /// the auto `.systemDialog` kind is folded in identically (kind-generic, not just `.remoteGUI`); and a
    /// terminal with an unknown cwd is single-line too — never a blank second line.
    func testRailSubtitleFallsBackToWindowTitleThenNil() {
        let manual = PaneSpec(
            kind: .remoteGUI, title: "win 7",
            video: VideoEndpoint(windowID: 7, title: "Window 7", appName: "   "),
        )
        XCTAssertEqual(manual.railSubtitle, "Window 7", "a blank app name falls back to the window title")

        let bare = PaneSpec(
            kind: .remoteGUI, title: "win 8",
            video: VideoEndpoint(windowID: 8, title: "", appName: ""),
        )
        XCTAssertNil(bare.railSubtitle, "neither app nor window title ⇒ a single-line row, never a blank line")

        let dialog = PaneSpec(
            kind: .systemDialog, title: "SecurityAgent",
            video: VideoEndpoint(windowID: 9, title: "Authenticate", appName: "SecurityAgent"),
        )
        XCTAssertEqual(dialog.railSubtitle, "SecurityAgent", "the auto system-dialog video pane labels too")

        XCTAssertNil(
            PaneSpec(kind: .terminal, title: "zsh").railSubtitle,
            "a terminal with an unknown cwd is single-line, never blank",
        )
    }

    /// **EMPTY HOST-TITLE PARITY (both the rail + the Open-Quickly lines).** A remote window
    /// whose streamed window has NO title has its label collapsed to the app name by the ingress spec, so
    /// line 1 (`lastKnownTitle ?? title`) AND the streamed window title are both just the app name. The host
    /// app must then show on ONE line only — not the app name on both.
    func testEmptyHostTitleShowsTheAppNameOnOneLineOnly() throws {
        let store = makeFakeStore()
        let id = try XCTUnwrap(store.openWindowInStage(windowID: 88, title: "", appName: "Safari"))
        let spec = try XCTUnwrap(store.tree.activeSession?.specs[id])

        // Line 1 fell back to the app name (the window had no title).
        XCTAssertEqual(spec.title, "Safari", "an empty window title makes line 1 fall back to the app name")
        // Rail line 2 must be nil — a single line, not the app name twice.
        XCTAssertNil(spec.railSubtitle, "empty host title ⇒ the rail shows the app name once, not on both lines")

        // Open-Quickly row: same one-line discipline (subtitle nil, never an echo of the title).
        let row = try XCTUnwrap(OpenQuicklyModel.openedItems(from: store.tree).first { $0.act == .focusPane(id) })
        XCTAssertEqual(row.title, "Safari", "the Opened row title is the app name (the empty-title fallback)")
        XCTAssertNil(row.subtitle, "empty host title ⇒ the Open-Quickly row is a single line, no app-name echo")
    }

    /// GUARD the non-empty case is UNCHANGED by the item-4 collapse: a window WITH a real title keeps the host
    /// app on line 2 (a labelled window — window title on line 1, host app on line 2), on BOTH surfaces.
    func testPresentHostTitleKeepsTheHostAppSubtitle() throws {
        let store = makeFakeStore()
        let id = try XCTUnwrap(store.openWindowInStage(windowID: 89, title: "GitHub", appName: "Safari"))
        let spec = try XCTUnwrap(store.tree.activeSession?.specs[id])

        XCTAssertEqual(spec.title, "GitHub", "a present window title is line 1")
        XCTAssertEqual(spec.railSubtitle, "Safari", "a present window title keeps the host app on the rail's line 2")

        let row = try XCTUnwrap(OpenQuicklyModel.openedItems(from: store.tree).first { $0.act == .focusPane(id) })
        XCTAssertEqual(row.subtitle, "Safari", "the Open-Quickly row keeps the host app on line 2 too")
    }

    // MARK: - a LEGACY tree carrying video leaves migrates them into the stage

    /// A pre-Stage persisted file can still hold `.remoteGUI` leaves in its split tree. `normalized()`
    /// (the load path) must MOVE them to the stage — never drop a bound window across the update — and
    /// leave the tree terminal-only with the invariant intact. A tab the move empties is dropped.
    func testNormalizedMigratesLegacyVideoLeavesIntoTheStage() throws {
        let termID = PaneID()
        let videoID = PaneID()
        let videoSpec = PaneSpec(
            kind: .remoteGUI, title: "Safari",
            video: VideoEndpoint(windowID: 5, title: "Safari", appName: "Safari"),
        )
        let session = Session(
            name: "s",
            tabs: [
                Tab(title: "T", root: .leaf(termID), activePane: termID),
                Tab(title: "V", root: .leaf(videoID), activePane: videoID), // the legacy whole-tab window
            ],
            specs: [termID: PaneSpec(kind: .terminal, title: "zsh"), videoID: videoSpec],
        )
        let legacy = TreeWorkspace(sessions: [session], activeSessionID: session.id)

        let migrated = legacy.normalized()

        let s = try XCTUnwrap(migrated.sessions.first)
        XCTAssertEqual(s.stagePanes, [videoID], "the legacy video leaf moved to the stage")
        XCTAssertEqual(s.activeStagePane, videoID, "the first mover becomes the stage selection")
        XCTAssertEqual(s.tabs.count, 1, "the emptied window tab is dropped")
        XCTAssertFalse(migrated.allPaneIDs().contains(videoID), "the tree is terminal-only after the repair")
        XCTAssertEqual(s.specs[videoID]?.video?.windowID, 5, "the binding survives the move (rebind identity)")
        XCTAssertTrue(migrated.isInvariantHeld())
    }

    // MARK: - no drop-to-create a remote window

    /// **The drag-drop exclusion pin — "no drop-to-create a remote window".** A
    /// `.remoteGUI` pane is minted ONLY by the stage ingress (`openWindowInStage`); there is intentionally
    /// NO drop-to-create arm. ``DropAction`` — the pure output of ``DropActionResolver`` — carries terminal
    /// cases only, so NO `(zone × content)` cell in the whole policy table can spawn a video pane. The
    /// ``createsRemoteWindow(_:)`` classifier is an EXHAUSTIVE switch, so a future refactor that adds a
    /// remote-window `DropAction` case is forced to classify it HERE (compile-time) and any resolver
    /// arm returning it trips the assertion — the exclusion can't erode silently.
    func testDropPolicyNeverCreatesARemoteWindow() {
        let contents: [DroppedContent] = [
            .folder("/work/proj"),
            .file("/work/proj/README.md"),
            .url("https://example.com"),
            .text("echo hi"),
        ]

        var resolvedAny = false
        for zone in DropZone.allCases {
            for content in contents {
                guard let action = DropActionResolver.resolve(zone: zone, content: content) else { continue }
                resolvedAny = true
                XCTAssertFalse(
                    Self.createsRemoteWindow(action),
                    "no drop cell may spawn a `.remoteGUI` pane — remote windows come from the stage ingress (\(zone), \(content))",
                )
            }
        }
        XCTAssertTrue(resolvedAny, "sanity: the policy table resolves at least one cell (guards a vacuous pass)")
    }

    /// Whether a resolved ``DropAction`` would create / target a remote-window (`.remoteGUI`) pane. An EXHAUSTIVE
    /// switch over today's terminal-only actions — all `false`, hand-classified (not derived from the
    /// action's own value, so no tautology). A future drop-to-create-remote-window refactor would add a
    /// `DropAction` case and force a `true` branch HERE, which then trips ``testDropPolicyNeverCreatesARemoteWindow``.
    private static func createsRemoteWindow(_ action: DropAction) -> Bool {
        switch action {
        case .injectText,
             .newTabCd,
             .hostOpen,
             .splitInjectPath:
            false
        }
    }
}
