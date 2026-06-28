import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

// MARK: - RemoteGUIFirstClassPeerTests (E21 WI-1 — the audit-as-tests peer-enumeration suite)

/// **ES-E21-4 — every kind-generic surface treats `.remoteGUI` as a first-class peer of a terminal pane.**
///
/// E21 is an AUDIT → FILL-GENUINE-GAPS epic (carry-overs §0): `.remoteGUI` (a real host window streamed over
/// the PATH-2 UDP video path) must be a first-class peer in *every* clone surface E1–E20 shipped. There is no
/// otty analog / no screenshot — the standard is the existing aislopdesk surfaces. This suite is the
/// developer-facing peer-enumeration pin: it asserts the model entry points the per-WI fixes ride on
/// (`newRemoteWindowTab`, `OpenQuicklyModel.openedItems`, `StatusBarContent.make`/`paneKindLabel`,
/// `WorkspaceTreeOps.toggleFloating`, `WorkspaceTreeOps.splitPane`, `WorkspaceStore.isReadOnly`) all ADMIT /
/// HANDLE `.remoteGUI` with no kind-dropping `switch`/guard.
///
/// ### Most cases pass immediately (confirming reuse); ONE drives WI-2.
/// The machinery is overwhelmingly kind-generic, so most assertions are GREEN on un-fixed code — they pin the
/// reuse so a later refactor that silently drops `.remoteGUI` from an enumeration is caught. The exception is
/// ``testOpenedItemsDifferentiatesTheRemoteWindowRow``: the Open-Quickly row for a video pane is currently
/// undifferentiated (badge "Pane" / the split glyph / no subtitle). That assertion is RED until WI-2 threads a
/// `paneKind:` through `paneItem`/`openedItems` and maps `.remoteGUI` → a window glyph (`display`) + badge
/// "Window" + a host/window subtitle. It is written FIRST here (revert-to-confirm-fail) so WI-2 has a failing
/// test to turn green.
///
/// ### Out of scope here (own WI / own file — would not compile against un-fixed code)
/// - The read-only INPUT gate on the video seam (`RemotePaneContext.inputEnabled`) is WI-3 and lands its own
///   `ReadOnlyStoreTests`/`PaletteReadOnlyTests` cases once the additive field exists (referencing it now
///   would be a compile error, not a runtime failure). This suite pins only the kind-generic
///   `isReadOnly`/`setPaneReadOnly` flip on a `.remoteGUI` pane (already convergent).
/// - The status-bar STRIP mount + the floating-pane RENDERER are app-target view code (`GuiLeafView` /
///   `FloatingPaneCard`), compiled + code-reviewed, never unit-instantiated (hang-safety, carry-overs §3).
///   This suite covers only the pure models behind them.
///
/// Hang-safety: NO `SCStream`/`VTCompression`/`VTDecompression`/Metal/`NSWindow` is instantiated — the store
/// uses the spec-only ``FakePaneSession`` seam, and the tree ops are pure value transforms.
@MainActor
final class RemoteGUIFirstClassPeerTests: XCTestCase {
    // MARK: - Fixtures

    /// The floating-overlay viewport the pure float ops clamp into.
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    /// A spec-only `.tree`-live store (no terminal model / renderer / socket) — the same seam
    /// ``RemoteWindowTabLandingTests`` uses to drive `newRemoteWindowTab`.
    private func makeFakeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
    }

    /// A pure two-tab tree carrying a `.terminal` pane and a `.remoteGUI` (video) pane in one session, so the
    /// kind-generic enumeration surfaces (Open-Quickly) can be asserted to include BOTH. The video pane mirrors
    /// what ``WorkspaceStore/newRemoteWindowTab(windowID:title:appName:)`` mints: a `.remoteGUI` spec carrying a
    /// pre-bound ``VideoEndpoint`` and no shell cwd.
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
        let videoTab = Tab(title: "V", root: .leaf(videoID), activePane: videoID)
        let session = Session(name: "s", tabs: [termTab, videoTab], specs: [termID: termSpec, videoID: videoSpec])
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        return (tree, termID, videoID)
    }

    /// A pure single-tab tree with a `.terminal` leaf split alongside a `.remoteGUI` SIBLING (two tiled leaves
    /// in one tab) — the fixture for the kind-generic float/split peer assertions (a tab needs ≥2 tiled leaves
    /// before one can float without emptying the tree).
    private func makeSplitWithVideoSibling() -> (tree: TreeWorkspace, terminal: PaneID, video: PaneID) {
        let ws0 = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "term"))
        let term = ws0.allPaneIDs()[0]
        let videoSpec = PaneSpec(
            kind: .remoteGUI,
            title: "Safari",
            video: VideoEndpoint(windowID: 9, title: "Safari", appName: "Safari"),
        )
        let (ws, video) = WorkspaceTreeOps.splitPane(term, axis: .horizontal, newSpec: videoSpec, in: ws0)
        return (ws, term, video)
    }

    // MARK: - ES-E21-1 — the picker → `.remoteGUI` pane path lands a reachable first-class peer

    /// `newRemoteWindowTab` mints a `.remoteGUI` leaf bound to the picked host window, reachable BOTH in the
    /// live tree AND as a first-class Open-Quickly "Opened" row (the picker → pane → switcher round trip). Pins
    /// ES-E21-1 (audit only — the picker/connect overlay already mounts and mints the spec; this guards the
    /// end-to-end reachability against a regression). Passes on un-fixed code (the path is kind-generic).
    func testNewRemoteWindowTabMintsReachableRemoteGUIPeer() throws {
        let store = makeFakeStore()

        let id = store.newRemoteWindowTab(windowID: 42, title: "Apple", appName: "Safari")

        // 1) the minted spec is a `.remoteGUI` pre-bound to the picked window
        let spec = try XCTUnwrap(store.tree.activeSession?.specs[id])
        XCTAssertEqual(spec.kind, .remoteGUI, "the picked window mints a remote-GUI video pane")
        XCTAssertEqual(spec.video?.windowID, 42, "the spec is pre-bound to the chosen host window")

        // 2) it is a live leaf of the tree …
        XCTAssertTrue(store.tree.allPaneIDs().contains(id), "the picked window lands as a live pane")

        // 3) … and a first-class peer in the kind-generic Open-Quickly "Opened" enumeration
        let opened = OpenQuicklyModel.openedItems(from: store.tree)
        XCTAssertTrue(
            opened.contains { $0.act == .focusPane(id) },
            "the remote-window pane is a first-class peer in Open-Quickly's Opened list",
        )
    }

    // MARK: - ES-E21-2 / WI-2 — Open-Quickly admits the video pane (inclusion vs differentiation)

    /// `openedItems` is kind-AGNOSTIC: it already emits one row per live pane, INCLUDING the `.remoteGUI` pane
    /// (the carry-over's "absent" was stale). Passes on un-fixed code — pins the inclusion so a refactor can't
    /// silently drop the video pane from the switcher.
    func testOpenedItemsIncludesTheRemoteWindowPane() {
        let (tree, terminal, video) = makeMixedTree()

        let items = OpenQuicklyModel.openedItems(from: tree)

        XCTAssertEqual(items.count, 2, "one Opened row per live pane — the terminal AND the remote window")
        XCTAssertTrue(
            items.contains { $0.act == .focusPane(terminal) },
            "the terminal pane is enumerated",
        )
        XCTAssertTrue(
            items.contains { $0.act == .focusPane(video) },
            "the `.remoteGUI` pane is enumerated as a first-class Opened row",
        )
    }

    /// **DRIVES WI-2 — RED until the Open-Quickly differentiation lands.** The video pane's row must read as a
    /// WINDOW, not an undifferentiated pane: a window glyph (`display`), a "Window" badge, and a non-nil
    /// host/window subtitle (a video pane has no cwd). On un-fixed code the row is built with `kind == .pane`
    /// (badge "Pane", the split glyph, nil subtitle) so every assertion below fails — exactly the
    /// revert-to-confirm-fail signal WI-2 turns green by threading `paneKind:` through `paneItem`/`openedItems`.
    func testOpenedItemsDifferentiatesTheRemoteWindowRow() throws {
        let (tree, _, video) = makeMixedTree()

        let items = OpenQuicklyModel.openedItems(from: tree)
        let videoRow = try XCTUnwrap(
            items.first { $0.act == .focusPane(video) },
            "the video pane must be enumerated before it can be differentiated",
        )

        XCTAssertEqual(videoRow.badge, "Window", "WI-2: a remote window is badged 'Window', not 'Pane'")
        XCTAssertEqual(videoRow.symbol, "display", "WI-2: a remote window uses the window glyph, not the split glyph")
        XCTAssertNotNil(videoRow.subtitle, "WI-2: a video row carries a host/window subtitle (it has no cwd)")
    }

    // MARK: - ES-E21-2 / WI-4 — the status-bar model labels the video pane

    /// `StatusBarContent.make`/`paneKindLabel` already handle `.remoteGUI` correctly: the right-edge label is
    /// "remote", there is no shell-exit badge (`.none`), and the cwd field is empty (a video pane reports no
    /// working directory). Passes on un-fixed code — the WI-4 gap is purely that the strip is not MOUNTED on a
    /// video leaf (a `GuiLeafView` view concern, code-reviewed), not that the model mis-handles the kind.
    func testStatusBarModelLabelsTheRemoteWindowPane() {
        let content = StatusBarContent.make(cwd: nil, lastCommand: nil, kind: .remoteGUI, host: "mac-studio")
        XCTAssertEqual(content.paneKind, "remote", "a focused `.remoteGUI` pane labels as 'remote'")
        XCTAssertEqual(content.exit, .none, "a video pane has no shell-exit concept")
        XCTAssertEqual(content.cwdDisplay, "", "a video pane reports no cwd")
        XCTAssertEqual(content.host, "mac-studio")
        // The auto system-dialog video pane is labelled too (kind-generic, total mapping).
        XCTAssertEqual(StatusBarContent.paneKindLabel(.systemDialog), "dialog")
    }

    // MARK: - ES-E21-2 / WI-3 — read-only is kind-generic on the video pane

    /// `setPaneReadOnly`/`isReadOnly(for:)` are kind-generic — they record a `.remoteGUI` pane in the
    /// convergent `paneReadOnly` set even though it has no live terminal model (the set-only path). Passes on
    /// un-fixed code; pins the policy the pill `🔒 READ ONLY ×` + the sidebar lock read. The downstream video-
    /// input GATE (`RemotePaneContext.inputEnabled`) is WI-3's additive seam, tested where that field lands.
    func testReadOnlyFlipsOnARemoteWindowPane() {
        let store = makeFakeStore()
        let video = store.newRemoteWindowTab(windowID: 21, title: "Xcode", appName: "Xcode")

        XCTAssertFalse(store.isReadOnly(for: video), "a fresh remote window is writable")

        store.setPaneReadOnly(video, true)
        XCTAssertTrue(store.isReadOnly(for: video), "read-only records a `.remoteGUI` pane (kind-generic)")
        XCTAssertTrue(store.paneReadOnly.contains(video), "and lands in the convergent source of truth")

        store.setPaneReadOnly(video, false)
        XCTAssertFalse(store.isReadOnly(for: video), "and clears it")
    }

    // MARK: - ES-E21-2 / WI-5 — the sidebar rail reads a `.remoteGUI` pane as a labelled window

    /// **DRIVES WI-5 — the sidebar-row SUBTITLE policy** (the kind-generic ``PaneSpec/railSubtitle`` the native
    /// rail ``RailRowsBuilder`` binds its second line to). A `.remoteGUI` pane has no shell cwd, so the
    /// pre-WI-5 `spec?.lastKnownCwd` subtitle was always `nil` (a bare single-line window row). WI-5 stands the
    /// host-side window's owning APP name in its place, so a remote window reads as a *labelled window* (its
    /// window title on line 1, the host app on line 2) — a first-class peer of a terminal's cwd row. A terminal
    /// keeps its cwd. Pins specific expected strings (not the output's own derivation), so a regression to a
    /// nil video subtitle is visible.
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

    /// The video-subtitle fallback ladder + the never-blank guarantee (carry-overs §0 — no kind dropped, no
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

    // MARK: - ES-E21-3 / WI-6 — float is kind-generic for the video pane

    /// `WorkspaceTreeOps.toggleFloating` floats a `.remoteGUI` active pane with NO kind guard — it leaves the
    /// tiled tree, joins `tab.floatingPanes`, and stamps `spec.floatingFrame`, exactly like a terminal. Passes
    /// on un-fixed code (the float DOMAIN is kind-generic); the NEW surface is the `FloatingPaneCard` RENDERER
    /// (WI-6), which composes a kind-generic `PaneContainer` so `.remoteGUI` floats visibly for free.
    func testToggleFloatingFloatsARemoteWindowPane() throws {
        let (ws, terminal, video) = makeSplitWithVideoSibling()
        let frame = CGRect(x: 80, y: 80, width: 420, height: 320)

        let after = WorkspaceTreeOps.toggleFloating(video, defaultFrame: frame, bounds: bounds, in: ws)
        let tab = try XCTUnwrap(after.activeSession?.activeTab)

        XCTAssertTrue(tab.floatingPanes.contains(video), "a `.remoteGUI` pane floats — no kind guard")
        XCTAssertFalse(tab.root.contains(video), "the floated video pane leaves the tiled tree")
        XCTAssertTrue(tab.root.contains(terminal), "the terminal sibling stays tiled")
        XCTAssertEqual(after.spec(for: video)?.floatingFrame, frame, "the spec records the (clamped) frame")
        XCTAssertEqual(after.spec(for: video)?.kind, .remoteGUI, "it is still a video pane after floating")
        XCTAssertTrue(after.isInvariantHeld(), "specs==leafIDs invariant holds (floating layer counts)")
    }

    // MARK: - ES-E21-2 / WI-7 — split admits a video sibling + no drop-to-create a remote window

    /// `WorkspaceTreeOps.splitPane` is kind-generic on `PaneID`/rects — splitting a terminal with a `.remoteGUI`
    /// sibling yields a tab with BOTH leaves tiled and the invariant intact. Passes on un-fixed code; pins the
    /// drag-drop/split exclusion (carry-overs §4 — a remote window comes from the picker, never a file/URL
    /// drop, but it splits and tiles as a first-class peer once minted).
    func testSplitAdmitsARemoteWindowSibling() {
        let (ws, terminal, video) = makeSplitWithVideoSibling()

        let ids = ws.allPaneIDs()
        XCTAssertTrue(ids.contains(terminal), "the terminal leaf survives the split")
        XCTAssertTrue(ids.contains(video), "the `.remoteGUI` sibling is a tiled first-class leaf")
        XCTAssertEqual(ws.spec(for: video)?.kind, .remoteGUI, "the split sibling keeps its video kind")
        XCTAssertTrue(ws.isInvariantHeld(), "specs==leafIDs invariant holds across a mixed-kind split")
    }

    /// **The drag-drop exclusion pin (carry-overs §4 / E21 plan §1 — "no drop-to-create a remote window").** A
    /// `.remoteGUI` pane (a host window streamed over the PATH-2 video path) is minted ONLY by the picker
    /// (`newRemoteWindowTab`); there is intentionally NO drop-to-create arm. ``DropAction`` — the pure output of
    /// ``DropActionResolver`` — carries terminal/web cases only, so NO `(zone × content)` cell in the whole
    /// policy table can spawn a video pane. This walks the FULL table (every ``DropZone`` × each
    /// ``DroppedContent`` variant) and asserts every resolved action targets a terminal or web pane, never a
    /// remote window. The ``createsRemoteWindow(_:)`` classifier is an EXHAUSTIVE switch, so a future refactor
    /// that adds a remote-window `DropAction` case is forced to classify it HERE (compile-time) and any resolver
    /// arm returning it trips the assertion — the exclusion can't erode silently. A doc-only WI, so this is a
    /// regression pin (no behavioral change to revert), not a revert-to-confirm-fail driver.
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
                    "no drop cell may spawn a `.remoteGUI` pane — remote windows come from the picker (\(zone), \(content))",
                )
            }
        }
        XCTAssertTrue(resolvedAny, "sanity: the policy table resolves at least one cell (guards a vacuous pass)")
    }

    /// Whether a resolved ``DropAction`` would create / target a remote-window (`.remoteGUI`) pane. An EXHAUSTIVE
    /// switch over today's terminal/web-only actions — all `false`, hand-classified (not derived from the
    /// action's own value, so no tautology). A future drop-to-create-remote-window refactor would add a
    /// `DropAction` case and force a `true` branch HERE, which then trips ``testDropPolicyNeverCreatesARemoteWindow``.
    private static func createsRemoteWindow(_ action: DropAction) -> Bool {
        switch action {
        case .injectText,
             .newTabCd,
             .hostOpen,
             .splitInjectPath,
             .splitWeb,
             .openWeb:
            false
        }
    }
}
