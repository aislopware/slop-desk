// ViewportPaletteDiscoverabilityTests — pins `.fitViewportToPane` / `.resetViewportZoom` as REGISTERED,
// chord-less, `.view`-category rows (audit finding #37): before this the footer [fit]/[1×] buttons on a
// live remote-GUI pane had no palette/menu/cheat-sheet row at all, so a keyboard-first user who only
// discovers features via ⌘⇧P could never learn they exist. Mirrors `.toggleViewportLock`'s registration
// shape (registered, active-pane-scoped) and the chord-less idiom already used by `pane.rename` /
// `view.readOnly` (pinned by `E1KeymapParityTests.testCmdShiftRIsFreeAndNewDesktopTabIsOptCmdN`).

import XCTest
@testable import SlopDeskWorkspaceCore

final class ViewportPaletteDiscoverabilityTests: XCTestCase {
    func testFitViewportToPaneIsARegisteredChordLessViewRow() throws {
        let binding = try XCTUnwrap(
            WorkspaceBindingRegistry.binding(for: .fitViewportToPane),
            "Fit to Pane must be a registered binding (palette/menu reachable)",
        )
        XCTAssertNil(binding.chord, "Fit to Pane carries NO default chord (footer-button-only today)")
        XCTAssertEqual(binding.category, .view)
        XCTAssertEqual(binding.title, "Fit to Pane")
    }

    func testResetViewportZoomIsARegisteredChordLessViewRow() throws {
        let binding = try XCTUnwrap(
            WorkspaceBindingRegistry.binding(for: .resetViewportZoom),
            "Actual Size must be a registered binding (palette/menu reachable)",
        )
        XCTAssertNil(binding.chord, "Actual Size carries NO default chord (footer-button-only today)")
        XCTAssertEqual(binding.category, .view)
        XCTAssertEqual(binding.title, "Actual Size")
    }

    /// Both rows target the ACTIVE pane (like `.toggleViewportLock`, `.releaseStuckInput`,
    /// `.pasteAsKeystrokes` — the whole remote-GUI verb family), so the palette can still list them on an
    /// empty shell (mirrors those siblings' `requiresActivePane == true`, "shown but no-ops gracefully").
    func testBothRowsRequireAnActivePaneLikeTheirViewportLockSibling() {
        XCTAssertEqual(
            WorkspaceAction.fitViewportToPane.requiresActivePane,
            WorkspaceAction.toggleViewportLock.requiresActivePane,
        )
        XCTAssertEqual(
            WorkspaceAction.resetViewportZoom.requiresActivePane,
            WorkspaceAction.toggleViewportLock.requiresActivePane,
        )
    }

    /// Both rows are part of the ONE registry table every surface (menu / palette / cheat sheet) reads,
    /// so they show up wherever `groupedForDisplay` is consumed — no separate wiring per surface.
    func testBothRowsAppearInGroupedDisplay() {
        let viewRows = WorkspaceBindingRegistry.groupedForDisplay.first { $0.category == .view }?.bindings ?? []
        XCTAssertTrue(viewRows.contains { $0.action == .fitViewportToPane })
        XCTAssertTrue(viewRows.contains { $0.action == .resetViewportZoom })
    }
}
