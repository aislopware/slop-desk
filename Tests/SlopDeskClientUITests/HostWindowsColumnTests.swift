import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

/// The Host Windows rail's perf + derivation contracts (docs/45 §7): the section memo rebuilds ONLY
/// on structural change (title ticks are free — the RailRowsMemo discipline), and the streamed-marker
/// derivation reads the LIVE `PaneSpec.video` binding (so `WindowRebind`'s spec update self-corrects
/// the marker across host restarts / windowID recycling). Headless — no NSView, no video module.
@MainActor
final class HostWindowsColumnTests: XCTestCase {
    private func identity(_ id: UInt32, app: String = "Ghostty") -> HostWindowIdentity {
        HostWindowIdentity(windowID: id, bundleID: "com.example.\(app.lowercased())", appName: app)
    }

    // MARK: Memo — structural fingerprint only

    func testTitleOnlyTicksNeverRebuildSections() {
        let memo = HostWindowRowsMemo()
        let structure = [identity(1), identity(2, app: "Safari")]
        _ = memo.sections(structure: structure, titles: [:], query: "")
        XCTAssertEqual(memo.buildCount, 1)
        // A title tick republishes the volatile dict but the STRUCTURE is unchanged — the memo must
        // hit its cache (the left rail's status-tick storm lesson, RailRowsMemo).
        for tick in 0..<50 {
            _ = memo.sections(structure: structure, titles: [1: "tick \(tick)"], query: "")
        }
        XCTAssertEqual(memo.buildCount, 1, "50 title ticks = 0 rebuilds")
    }

    func testStructureOrQueryChangesRebuildOnce() {
        let memo = HostWindowRowsMemo()
        let structure = [identity(1)]
        _ = memo.sections(structure: structure, titles: [:], query: "")
        _ = memo.sections(structure: structure + [identity(2)], titles: [:], query: "")
        XCTAssertEqual(memo.buildCount, 2, "a new window is structural")
        _ = memo.sections(structure: structure + [identity(2)], titles: [:], query: "gho")
        XCTAssertEqual(memo.buildCount, 3, "a query keystroke re-filters")
        _ = memo.sections(structure: structure + [identity(2)], titles: [:], query: "gho")
        XCTAssertEqual(memo.buildCount, 3, "same query + structure = cache hit")
    }

    func testSectionsComeOutAlphabeticalWithFirstSeenRows() {
        let memo = HostWindowRowsMemo()
        let sections = memo.sections(
            structure: [identity(9, app: "zed"), identity(1, app: "Ghostty"), identity(3, app: "zed")],
            titles: [:], query: "",
        )
        XCTAssertEqual(sections.map(\.appName), ["Ghostty", "zed"])
        XCTAssertEqual(sections[1].rows.map(\.windowID), [9, 3], "first-seen order inside a section")
    }

    // MARK: Streamed derivation — live spec binding

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    func testStreamedRefFindsThePaneAndItsTabOrdinal() throws {
        let store = makeStore()
        _ = store.newRemoteWindowTab(windowID: 42, title: "Xcode — slop-desk", appName: "Xcode")
        let ref = try XCTUnwrap(store.streamedWindowPane(for: 42))
        XCTAssertEqual(ref.tabOrdinal, 2, "the remote tab landed after the seed terminal tab")
        XCTAssertNil(store.streamedWindowPane(for: 43), "an unstreamed id has no ref")
        // The Open Quickly twin entry agrees (one grammar, two surfaces).
        XCTAssertEqual(OpenQuicklyView.streamedPane(for: 42, in: store), ref.paneID)
    }

    func testOpenInSplitInsertsBesideTheActivePane() throws {
        // The split-with-spec op (docs/45 Phase 5): the new remoteGUI leaf lands in the ACTIVE tab
        // (not a new one), pre-bound and focused.
        let store = makeStore()
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let paneID = store.newRemoteWindowSplit(windowID: 42, title: "t", appName: "Xcode", axis: .horizontal)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore, "a split never mints a tab")
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, paneID, "the new leaf lands focused")
        let spec = try XCTUnwrap(store.tree.activeSession?.specs[paneID])
        XCTAssertEqual(spec.video?.windowID, 42, "pre-bound like the tab path")
        XCTAssertEqual(
            store.streamedWindowPane(for: 42)?.paneID, paneID,
            "the streamed marker sees a split pane exactly like a tab pane",
        )
    }

    func testEarliestTabWinsForDuplicateStreams() throws {
        // ⌘-click deliberately opens a SECOND pane of the same host window — the marker (and the
        // single-click focus target) stays with the EARLIEST tab, so the rail's geography is stable.
        // (The marker following a REBIND is pinned by RemoteWindowTabLandingTests — `spec.video` is
        // the single source both derivations read.)
        let store = makeStore()
        let first = store.newRemoteWindowTab(windowID: 42, title: "t", appName: "Xcode")
        _ = store.newRemoteWindowTab(windowID: 42, title: "t", appName: "Xcode")
        let ref = try XCTUnwrap(store.streamedWindowPane(for: 42))
        XCTAssertEqual(ref.paneID, first, "the earliest tab keeps the marker")
        XCTAssertEqual(ref.tabOrdinal, 2)
    }

    // MARK: Reveal — the streamed row's click verb

    func testRevealPaneSwitchesToTheOwningBackgroundTabAndFocuses() throws {
        // The window pane lives on a background tab (a later tab is active): reveal must switch the
        // active tab AND focus the pane — the streamed row's single-click contract now that the right
        // rail is the open window's only tracker.
        let store = makeStore()
        let windowPane = store.newRemoteWindowTab(windowID: 42, title: "t", appName: "Xcode")
        store.newTab(kind: .terminal)
        XCTAssertNotEqual(store.tree.activeSession?.activeTab?.activePane, windowPane, "precondition: backgrounded")

        store.revealPaneTree(windowPane)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, windowPane, "focused")
        XCTAssertEqual(
            store.tree.activeSession?.activeTabIndex,
            try XCTUnwrap(store.tree.activeSession?.tabIndex(containing: windowPane)),
            "the owning tab became active",
        )
    }
}
