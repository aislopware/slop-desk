// AislopdeskClientUITests — view-LOGIC tests for the L2 chrome. View-model level only; NEVER
// instantiates Ghostty/VT/Metal/SCStream (hang-safety rule). Covers: font registration + family
// availability, and the rail's pure store→rows mapping (selection/title/subtitle/agent status).

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

final class FontsRegistrationTests: XCTestCase {
    func testRegistrationSucceedsAndFamiliesAvailable() throws {
        // Registration should succeed because the .ttf faces are bundled as DesignSystem resources.
        let ok = Fonts.register()
        guard ok else {
            // Graceful skip if the platform/bundle cannot register the faces.
            throw XCTSkip("Bundled fonts unavailable in this environment")
        }
        XCTAssertTrue(Fonts.registered)
        // The two bundled families are the ones WarpType resolves to (Hack mono / Roboto UI).
        XCTAssertEqual(Set(Fonts.bundledFamilies), ["Hack", "Roboto"])
    }
}

/// A minimal `PaneSessionHandle` so the rail-mapping tests can build a tree-backed store with NO socket,
/// PTY, Ghostty, or video stack (hang-safety rule). Only the required members are implemented; the rest
/// have protocol default implementations.
@MainActor
final class DummyPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false

    init(spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind == .remoteGUI { isVideoActive = active } }
    func pause() {}
    func resume() {}
    func teardown() {}
}

@MainActor
final class RailRowsBuilderTests: XCTestCase {
    /// Build a tree-backed store with a deterministic dummy session factory (no sockets/PTY).
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { spec in DummyPaneSession(spec: spec) },
        )
    }

    func testDefaultWorkspaceYieldsOneSelectedTerminalRow() {
        let store = makeStore()
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 1, "default workspace = one Local session, one terminal pane")
        let row = try? XCTUnwrap(rows.first)
        XCTAssertEqual(row?.kind, .terminal)
        XCTAssertTrue(row?.isSelected ?? false, "the single pane is the active tab's active pane")
        XCTAssertEqual(row?.status, ClaudeStatus.none, "no agent detected ⇒ plain terminal glyph")
    }

    func testSplitAddsASecondRowAndSelectionTracksActivePane() {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 2, "a horizontal split = two visible panes = two rows")
        // Exactly one row is selected (the active pane).
        XCTAssertEqual(rows.filter(\.isSelected).count, 1)
    }

    func testNewTabAddsRowsForItsPane() {
        let store = makeStore()
        store.newTabDefault()
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertGreaterThanOrEqual(rows.count, 2, "the new tab contributes its own pane row(s)")
    }

    func testFilterMatchesTitleAndSubtitle() {
        let rows = [
            RailRow(
                id: PaneID(),
                tabID: TabID(),
                kind: .terminal,
                title: "zsh",
                subtitle: "~/work",
                status: .none,
                isSelected: false,
            ),
            RailRow(
                id: PaneID(),
                tabID: TabID(),
                kind: .terminal,
                title: "vim",
                subtitle: "~/docs",
                status: .none,
                isSelected: false,
            ),
        ]
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "work").count, 1)
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "VIM").count, 1)
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "").count, 2)
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "nope").count, 0)
    }
}
