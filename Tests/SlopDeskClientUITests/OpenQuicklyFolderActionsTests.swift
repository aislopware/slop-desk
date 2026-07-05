// OpenQuicklyFolderActionsTests — Batch-4 item 9: the Open-Quickly Folder ⌘K action set gains "Split Right"
// and "Split Down" alongside the existing folder actions. Headless: the action TABLE is built by the pure
// `OpenQuicklyView.folderRowActions` static seam (no SwiftUI view instantiated, `model`/`folders` = nil), so
// the titles are asserted without a render. Revert-to-confirm-fail: before the fix the folder action set had
// no Split rows.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class OpenQuicklyFolderActionsTests: XCTestCase {
    func testFolderActionsIncludeSplitRightAndDown() {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })

        let titles = OpenQuicklyView.folderRowActions(
            path: "/Users/me/proj", store: store, model: nil, folders: nil,
        ).map(\.title)

        XCTAssertTrue(titles.contains("Split Right"), "the Folder ⌘K set adds Split Right (open-quickly.png)")
        XCTAssertTrue(titles.contains("Split Down"), "the Folder ⌘K set adds Split Down (open-quickly.png)")
        // The Split rows are ADDITIVE — the existing folder actions remain present.
        XCTAssertTrue(titles.contains("Change Directory Here"), "Change Directory Here remains")
        XCTAssertTrue(titles.contains("Reveal in Finder"), "Reveal in Finder remains")
        XCTAssertTrue(titles.contains("Copy Path"), "Copy Path remains")
    }
}
#endif
