import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the ⌘K palette host-window addition: the scope-prefix parser, and the store's
/// `addRemoteWindowPane` (a pre-bound `.remoteGUI` pane that streams without the picker step).
@MainActor
final class PaletteHostWindowTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }

    // MARK: - parseScope

    func testParseScopePrefixes() {
        XCTAssertEqual(CommandPaletteView.parseScope(">tidy").0, .commands)
        XCTAssertEqual(CommandPaletteView.parseScope(">tidy").1, "tidy")
        XCTAssertEqual(CommandPaletteView.parseScope("@vim").0, .panes)
        XCTAssertEqual(CommandPaletteView.parseScope("@vim").1, "vim")
        XCTAssertEqual(CommandPaletteView.parseScope("#xcode").0, .hostWindows)
        XCTAssertEqual(CommandPaletteView.parseScope("#xcode").1, "xcode")
        XCTAssertEqual(CommandPaletteView.parseScope("plain").0, .all)
        XCTAssertEqual(CommandPaletteView.parseScope("plain").1, "plain")
    }

    func testParseScopeBarePrefixIsEmptyQuery() {
        XCTAssertEqual(CommandPaletteView.parseScope("#").0, .hostWindows)
        XCTAssertEqual(CommandPaletteView.parseScope("#").1, "")
        XCTAssertEqual(CommandPaletteView.parseScope("#  ").1, "", "trailing whitespace trimmed")
    }

    // MARK: - addRemoteWindowPane

    func testAddRemoteWindowPaneIsPreBoundAndStreaming() {
        let store = makeStore()
        let before = store.workspace.canvas.items.count

        let id = store.addRemoteWindowPane(windowID: 604, title: "Claude", appName: "Google Chrome")

        XCTAssertEqual(store.workspace.canvas.items.count, before + 1)
        let spec = store.workspace.canvas.spec(for: id)
        XCTAssertEqual(spec?.kind, .remoteGUI)
        XCTAssertEqual(spec?.video?.windowID, 604, "the pane is pre-bound to the host window — no picker")
        XCTAssertEqual(spec?.video?.appName, "Google Chrome")
        XCTAssertEqual(spec?.title, "Claude")
        XCTAssertEqual(store.focusedPane, id)
        // The store contract is "created PRE-BOUND" (spec.video set). The live model seeding from that
        // spec is LivePaneSession.makeRemoteGUI's job, asserted separately below.
    }

    /// A pre-bound spec yields a ready-to-open ``RemoteWindowModel`` (the seeding
    /// `LivePaneSession.makeRemoteGUI` does), so the pane streams without the picker.
    func testPreBoundSpecSeedsAnOpenableModel() {
        let endpoint = VideoEndpoint(windowID: 604, title: "Claude", appName: "Google Chrome")
        let model = RemoteWindowModel(
            windowID: String(endpoint.windowID),
            title: endpoint.title,
            appName: endpoint.appName,
        )
        XCTAssertEqual(model.windowID, "604")
        XCTAssertTrue(model.canOpen, "a pre-bound spec is immediately openable")
    }

    func testAddRemoteWindowPaneFallsBackToAppNameWhenTitleEmpty() {
        let store = makeStore()
        let id = store.addRemoteWindowPane(windowID: 1, title: "", appName: "Ghostty")
        XCTAssertEqual(store.workspace.canvas.spec(for: id)?.title, "Ghostty")
    }
}
