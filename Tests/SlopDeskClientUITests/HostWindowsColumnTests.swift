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

    // MARK: Streamed derivation — live spec binding (the Stage re-scope)

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    func testStagedRefFindsThePaneAndItsStageOrdinal() throws {
        let store = makeStore()
        _ = store.openWindowInStage(windowID: 41, title: "Mail", appName: "Mail")
        _ = store.openWindowInStage(windowID: 42, title: "Xcode — slop-desk", appName: "Xcode")
        let ref = try XCTUnwrap(store.stagedWindowPane(for: 42))
        XCTAssertEqual(ref.tabOrdinal, 2, "the ordinal is the STAGE tab-strip position, 1-based")
        XCTAssertNil(store.stagedWindowPane(for: 43), "an unstaged id has no ref")
        // The Open Quickly twin entry agrees (one grammar, two surfaces).
        XCTAssertEqual(OpenQuicklyView.streamedPane(for: 42, in: store), ref.paneID)
    }

    // MARK: The row's click verb — idempotent stage open

    func testReopeningAStagedWindowActivatesItsTabInsteadOfDuplicating() throws {
        // The rail row's single-click verb is `openWindowInStage`, idempotent by windowID: a second
        // click on an already-staged window ACTIVATES its tab — the stage is the window's ONE home,
        // so the tab count must not grow (the old ⌘-click duplicate is gone with the tree ingress).
        let store = makeStore()
        let first = try XCTUnwrap(store.openWindowInStage(windowID: 42, title: "t", appName: "Xcode"))
        _ = store.openWindowInStage(windowID: 43, title: "u", appName: "Mail")
        XCTAssertNotEqual(store.activeStagePaneID, first, "precondition: the first window is backgrounded")

        let reopened = store.openWindowInStage(windowID: 42, title: "t", appName: "Xcode")

        XCTAssertEqual(reopened, first, "the existing tab is resolved, never re-minted")
        XCTAssertEqual(store.stagePaneIDs.count, 2, "no duplicate stage tab")
        XCTAssertEqual(store.activeStagePaneID, first, "the click ACTIVATES the existing tab")
    }
}
