// Visual-verification harness (L10) — renders a chrome showcase to a PNG via ImageRenderer so the
// palette + component kit can be eyeballed headlessly (no GUI/TCC). Opt-in: INERT unless the env var
// `AISLOPDESK_SNAPSHOT_OUT=<path.png>` is set, so `swift test` / `make check` never write a file. Run on demand:
//   AISLOPDESK_SNAPSHOT_OUT="$PWD/.build/showcase.png" swift test --filter SlateSnapshotRender
// It renders a hand-built mock of the real chrome from the SAME token layer + component kit, so a palette /
// component regression shows up visually. It is NOT a pixel-diff CI gate.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SFSafeSymbols
import SwiftUI
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

final class SlateSnapshotRender: XCTestCase {
    // (The old `testRenderSlateShowcase` — a hand-built mock of the FLAT otty chrome — is deleted with
    // that design; native-chrome migration, 2026-07-03. The remaining renders pin live views.)

    // MARK: - E2 / WI-6: opt-in render of the new overlay panels (palette + cheat sheet)

    /// Renders the live ``PaletteView`` (typed query, fzf-highlighted rows, a ✓ toggled gutter) and the
    /// ``KeyboardCheatSheetView`` (the full grouped binding table) on a dimmed scrim so the E2 overlays can be
    /// eyeballed headlessly — the SAME `ImageRenderer` opt-in idiom as `testRenderSlateShowcase`, NO CI gate.
    /// Opt-in via a directory (not the showcase's single-file `AISLOPDESK_SNAPSHOT_OUT`, which it would otherwise
    /// clobber): `AISLOPDESK_OVERLAY_SNAPSHOT_DIR=<dir>` writes `palette.png` + `cheatsheet.png` into it. Inert
    /// (skipped) otherwise. Built over a headless tree-model store (reusing this target's `MountTestPaneSession`
    /// session double) so it never opens a socket or touches video/Metal (the hang-safety rule).
    @MainActor
    func testRenderOverlayPanels() throws {
        guard let dir = ProcessInfo.processInfo.environment["AISLOPDESK_OVERLAY_SNAPSHOT_DIR"] else {
            throw XCTSkip("set AISLOPDESK_OVERLAY_SNAPSHOT_DIR=<dir> to render the E2 overlay panels")
        }

        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        let overlay = OverlayCoordinator(store: store)
        overlay.openPalette()
        overlay.paletteQuery = "split" // a typed query so the fzf highlight runs render

        // The sidebar row shows its ✓ — exercise the toggled-state gutter the host wires from chrome.
        let palette = PaletteView(
            coordinator: overlay,
            store: store,
            toggledState: { $0.id == "action.toggleSidebar" },
        )
        try render(scrimmed(palette), size: CGSize(width: 920, height: 620), to: dir, named: "palette.png")

        let cheat = KeyboardCheatSheetView(coordinator: overlay)
        try render(scrimmed(cheat), size: CGSize(width: 920, height: 700), to: dir, named: "cheatsheet.png")
    }

    // MARK: - E6 / WI-4: opt-in render of the sidebar tab-row badge states

    /// Renders the fused tab badge in each state (spinner / error / hand / check / accent dot) beside a
    /// native sidebar-style label — the visual lock for the E6 badge states. (The old custom `SlateTabRow`
    /// white-card row is deleted in the native-chrome migration; the sidebar row is a native `List` row
    /// now, so the badge — the surviving custom piece — is what this render pins.) SAME `ImageRenderer`
    /// opt-in idiom as the showcase; inert (skipped) unless `AISLOPDESK_TABROW_SNAPSHOT_DIR=<dir>` is set,
    /// where it writes `tab-row-badges.png`. NO video/Metal — a badge is pure SwiftUI.
    @MainActor
    func testRenderTabRowBadges() throws {
        guard let dir = ProcessInfo.processInfo.environment["AISLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set AISLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the E6 tab-row badge states")
        }
        let panel = VStack(alignment: .leading, spacing: 8) {
            badgeRow("full-release.sh", badge: .running)
            badgeRow("running build task", badge: .error)
            badgeRow("plan next move", badge: .awaitingInput)
            badgeRow("OpenCode", badge: .completed)
            badgeRow("abner@MacBook-AB:…", badge: .finished)
        }
        .padding(8)
        .frame(width: 260)
        try render(panel, size: CGSize(width: 260, height: 220), to: dir, named: "tab-row-badges.png")
    }

    /// A native sidebar-style label carrying one fused badge, for the badge-state showcase.
    @MainActor
    private func badgeRow(_ title: String, badge: TabBadgeKind) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: "terminal")
                .lineLimit(1)
            Spacer(minLength: 4)
            TabBadgeView(kind: badge)
        }
    }

    // MARK: - E6 / WI-5: opt-in render of the grouped NavigatorColumn (search + By-Project sections)

    /// Renders the live ``NavigatorColumn`` over a headless store grouped By-Project — the visual lock for the
    /// E6 WI-5 sidebar: the "TABS" header + sort hamburger, the flat search field, and the tabs bucketed into
    /// `SlateSectionHeader` sections (project basenames) with the per-row `#N` / badge chrome. SAME
    /// `ImageRenderer` opt-in idiom as the badge render; writes `navigator-grouped.png` into
    /// `AISLOPDESK_TABROW_SNAPSHOT_DIR`. Headless: a `.tree` store over `MountTestPaneSession` (no socket / video /
    /// Metal — the hang-safety rule); the project keys come from each pane's `lastKnownCwd`.
    @MainActor
    func testRenderNavigatorGrouped() throws {
        guard let dir = ProcessInfo.processInfo.environment["AISLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set AISLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the E6 grouped navigator")
        }
        let nav = NavigatorColumn(store: makeGroupedNavigatorStore())
        try render(nav, size: CGSize(width: 240, height: 470), to: dir, named: "navigator-grouped.png")
    }

    /// A headless `.tree` store with five single-pane tabs across three project cwds (so By-Project yields
    /// three sections) plus a few seeded badges/process labels for visual variety. Sets the grouping directly
    /// on the store (the `internal(set)` setter via `@testable`) so the render does NOT persist to `Defaults`.
    @MainActor
    private func makeGroupedNavigatorStore() -> WorkspaceStore {
        let rows: [(title: String, cwd: String)] = [
            ("full-release.sh", "/Users/abner/Workplace/herdr"),
            ("running build task", "/Users/abner/Workplace/herdr"),
            ("plan next move", "/Users/abner/Workplace/aislopdesk"),
            ("OpenCode", "/Users/abner/Workplace/aislopdesk"),
            ("abner@MacBook-AB", "/Users/abner/scratch"),
        ]
        // `Tab` is ambiguous here: SwiftUI (macOS 15+) ships its own `Tab`, and this file `@testable
        // import`s `AislopdeskWorkspaceCore`. Qualify to the workspace domain type (same idiom as
        // `SplitContainer.swift`) so the fixture resolves to the tree model.
        var tabs: [AislopdeskWorkspaceCore.Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for row in rows {
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: row.title, lastKnownCwd: row.cwd)
            tabs.append(AislopdeskWorkspaceCore.Tab(title: row.title, root: .leaf(pane), activePane: pane))
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { MountTestPaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
        store.tabGrouping = .byProject // direct (internal) set — render-only, no Defaults write
        let panes = tabs.compactMap(\.activePane)
        if panes.count >= 5 {
            store.setForegroundProcess("zsh", for: panes[0])
            store.setAgentStatus(.working, for: panes[1])
            store.setAgentStatus(.needsPermission, for: panes[2])
            store.setCompletionBadge(.success, for: panes[3])
        }
        return store
    }

    /// Center an overlay panel on the dimmed scrim + window background, the way `OverlayHostView` composes it.
    @MainActor
    private func scrimmed(_ panel: some View) -> some View {
        ZStack {
            Slate.Surface.card // the one canvas surface (flat hairline canvas, 2026-07-04 v2)
            Color.black.opacity(0.25) // the host's dim scrim (native-chrome value)
            panel
        }
    }

    /// Rasterize `content` at @2x and write a PNG into `dir`. Fails (not skips) if the renderer yields nothing —
    /// reaching here means the env opt-in was set, so a nil image is a real regression in the panel's layout.
    @MainActor
    private func render(_ content: some View, size: CGSize, to dir: String, named name: String) throws {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no image for \(name)")
            return
        }
        let out = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try png.write(to: out)
        print("AISLOPDESK_SNAPSHOT_WRITTEN \(out.path)")
    }
}

#endif
