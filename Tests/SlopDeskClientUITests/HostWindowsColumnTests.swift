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
        let ref = try XCTUnwrap(HostWindowsColumn.streamedRef(for: 42, in: store))
        XCTAssertEqual(ref.tabOrdinal, 2, "the remote tab landed after the seed terminal tab")
        XCTAssertNil(HostWindowsColumn.streamedRef(for: 43, in: store), "an unstreamed id has no ref")
        // The Open Quickly twin derivation agrees (one grammar, two surfaces).
        XCTAssertEqual(OpenQuicklyView.streamedPane(for: 42, in: store), ref.paneID)
    }

    func testEarliestTabWinsForDuplicateStreams() throws {
        // ⌘-click deliberately opens a SECOND pane of the same host window — the marker (and the
        // single-click focus target) stays with the EARLIEST tab, so the rail's geography is stable.
        // (The marker following a REBIND is pinned by RemoteWindowTabLandingTests — `spec.video` is
        // the single source both derivations read.)
        let store = makeStore()
        let first = store.newRemoteWindowTab(windowID: 42, title: "t", appName: "Xcode")
        _ = store.newRemoteWindowTab(windowID: 42, title: "t", appName: "Xcode")
        let ref = try XCTUnwrap(HostWindowsColumn.streamedRef(for: 42, in: store))
        XCTAssertEqual(ref.paneID, first, "the earliest tab keeps the marker")
        XCTAssertEqual(ref.tabOrdinal, 2)
    }
}
