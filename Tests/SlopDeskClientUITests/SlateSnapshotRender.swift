// Visual-verification harness — renders a chrome showcase to a PNG via ImageRenderer so the
// palette + component kit can be eyeballed headlessly (no GUI/TCC). Opt-in: INERT unless the env var
// `SLOPDESK_SNAPSHOT_OUT=<path.png>` is set, so `swift test` / `make check` never write a file. Run on demand:
//   SLOPDESK_SNAPSHOT_OUT="$PWD/.build/showcase.png" swift test --filter SlateSnapshotRender
// It renders a hand-built mock of the real chrome from the SAME token layer + component kit, so a palette /
// component regression shows up visually. It is NOT a pixel-diff CI gate.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SFSafeSymbols
import SlopDeskTerminal
import SlopDeskTransport
import SwiftUI
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

final class SlateSnapshotRender: XCTestCase {
    @MainActor
    func testRenderSlateShowcase() throws {
        // Opt-in only: inert under `swift test` / `make check` unless an output path is requested.
        guard let out = ProcessInfo.processInfo.environment["SLOPDESK_SNAPSHOT_OUT"] else {
            throw XCTSkip("set SLOPDESK_SNAPSHOT_OUT=<path.png> to render the showcase")
        }
        let renderer = ImageRenderer(content: SlateShowcase().frame(width: 920, height: 560))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no image")
            return
        }
        try png.write(to: URL(fileURLWithPath: out))
        print("SLOPDESK_SNAPSHOT_WRITTEN \(out)")
    }

    // MARK: - Opt-in render of the overlay panels (palette + cheat sheet)

    /// Renders the live ``PaletteView`` (typed query, fzf-highlighted rows, a ✓ toggled gutter) and the
    /// ``KeyboardCheatSheetView`` (the full grouped binding table) on a dimmed scrim so the overlays can be
    /// eyeballed headlessly — the SAME `ImageRenderer` opt-in idiom as `testRenderSlateShowcase`, NO CI gate.
    /// Opt-in via a directory (not the showcase's single-file `SLOPDESK_SNAPSHOT_OUT`, which it would otherwise
    /// clobber): `SLOPDESK_OVERLAY_SNAPSHOT_DIR=<dir>` writes `palette.png` + `cheatsheet.png` into it. Inert
    /// (skipped) otherwise. Built over a headless tree-model store (reusing this target's `MountTestPaneSession`
    /// session double) so it never opens a socket or touches video/Metal (the hang-safety rule).
    @MainActor
    func testRenderOverlayPanels() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_OVERLAY_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_OVERLAY_SNAPSHOT_DIR=<dir> to render the overlay panels")
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

    // MARK: - Opt-in render of the sidebar tab-row badge states

    /// Renders `SlateTabRow` in each badge state (spinner / error / hand / check / accent dot) plus the active
    /// white card with a subtitle + process label — the visual lock for the sidebar row. SAME
    /// `ImageRenderer` opt-in idiom as the showcase; inert (skipped) unless `SLOPDESK_TABROW_SNAPSHOT_DIR=<dir>`
    /// is set, where it writes `tab-row-badges.png`. NO video/Metal — a badge is pure SwiftUI.
    @MainActor
    func testRenderTabRowBadges() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the tab-row badge states")
        }
        let panel = VStack(alignment: .leading, spacing: 2) {
            badgeRow("full-release.sh", badge: .running)
            badgeRow("brew upgrade", badge: .commandRunning)
            badgeRow("make check", badge: .commandBusy)
            badgeRow("running build task", badge: .error)
            badgeRow("plan next move", badge: .awaitingInput)
            badgeRow("OpenCode", badge: .completed)
            badgeRow("abner@MacBook-AB:…", badge: .finished)
            SlateTabRow(
                title: "slopdesk",
                active: true,
                subtitle: "main · 3 changed",
                processLabel: "npm run dev",
                onSelect: {},
                onClose: {},
            )
        }
        .padding(8)
        .frame(width: 260)
        .background(Slate.Surface.ground)
        try render(panel, size: CGSize(width: 260, height: 340), to: dir, named: "tab-row-badges.png")
    }

    /// A resting (non-active) tab row carrying one fused badge, for the badge-state showcase.
    @MainActor
    private func badgeRow(_ title: String, badge: TabBadgeKind) -> some View {
        SlateTabRow(title: title, active: false, badge: badge, onSelect: {}, onClose: {})
    }

    // MARK: - Opt-in render of the grouped NavigatorColumn (search + By-Project sections)

    /// Renders the live ``NavigatorColumn`` over a headless store grouped By-Project — the visual lock for the
    /// sidebar: the "TABS" header + sort hamburger, the flat search field, and the tabs bucketed into
    /// `SlateSectionHeader` sections (project basenames) with the per-row `#N` / badge chrome. SAME
    /// `ImageRenderer` opt-in idiom as the badge render; writes `navigator-grouped.png` into
    /// `SLOPDESK_TABROW_SNAPSHOT_DIR`. Headless: a `.tree` store over `MountTestPaneSession` (no socket / video /
    /// Metal — the hang-safety rule); the project keys come from each pane's `lastKnownCwd`.
    @MainActor
    func testRenderNavigatorGrouped() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the grouped navigator")
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
            ("plan next move", "/Users/abner/Workplace/slopdesk"),
            ("OpenCode", "/Users/abner/Workplace/slopdesk"),
            ("abner@MacBook-AB", "/Users/abner/scratch"),
        ]
        // `Tab` is ambiguous here: SwiftUI (macOS 15+) ships its own `Tab`, and this file `@testable
        // import`s `SlopDeskWorkspaceCore`. Qualify to the workspace domain type (same idiom as
        // `SplitContainer.swift`) so the fixture resolves to the tree model.
        var tabs: [SlopDeskWorkspaceCore.Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for row in rows {
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: row.title, lastKnownCwd: row.cwd)
            tabs.append(SlopDeskWorkspaceCore.Tab(title: row.title, root: .leaf(pane), activePane: pane))
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
        let panes = tabs.compactMap(\.activePane)
        if panes.count >= 5 {
            store.setForegroundProcess("zsh", for: panes[0])
            store.setAgentStatus(.working, for: panes[1])
            store.setAgentStatus(.needsPermission, for: panes[2])
            store.setCompletionBadge(.success, for: panes[3])
        }
        return store
    }

    // MARK: - Titlebar attention dot + the title menu's NEEDS-ATTENTION section (opt-in render)

    /// Renders the LIVE ``SlateTitlebar`` (the bell-style unseen-attention dot next to the centre title)
    /// and the LIVE ``TitlePaneMenu`` (the NEEDS ATTENTION section listing the waiting panes, blocked
    /// first) over a headless seeded store — the visual lock for the titlebar dot feature. SAME
    /// `ImageRenderer` opt-in idiom as the showcase; inert (skipped) unless
    /// `SLOPDESK_TITLEBAR_SNAPSHOT_DIR=<dir>` is set, where it writes `titlebar-dot.png` +
    /// `title-menu-attention.png`. Headless (`MountTestPaneSession`) — no socket / video / Metal.
    @MainActor
    func testRenderTitlebarAttention() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TITLEBAR_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TITLEBAR_SNAPSHOT_DIR=<dir> to render the titlebar attention chrome")
        }
        let (store, focused) = makeAttentionStore()

        // The titlebar strip in situ: mock traffic lights at the fixed 80pt lead the real chrome clears,
        // the centre title carrying the dot, and a slice of the paper content region below the hairline.
        let strip = VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                SlateTitlebar(store: store, chrome: WorkspaceChromeState())
                trafficLights.padding(.leading, 20).padding(.top, 9)
            }
            Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
            Slate.Surface.face
        }
        .background(Slate.Surface.ground)
        try render(strip, size: CGSize(width: 920, height: 96), to: dir, named: "titlebar-dot.png")

        // The REAL title menu (the popover content), on a popover-like panel so the section reads in place.
        let menu = TitlePaneMenu(store: store, activePane: focused)
            .background(Slate.Surface.face)
            .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .stroke(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
            )
            .padding(24)
        try render(
            scrimmed(menu), size: CGSize(width: 340, height: 420), to: dir, named: "title-menu-attention.png",
        )
    }

    /// The three macOS traffic lights, mocked for the strip render (the real ones are window chrome and
    /// never render under `ImageRenderer`).
    private var trafficLights: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: .systemRed)).frame(width: 12, height: 12)
            Circle().fill(Color(nsColor: .systemYellow)).frame(width: 12, height: 12)
            Circle().fill(Color(nsColor: .systemGreen)).frame(width: 12, height: 12)
        }
    }

    /// A headless `.tree` store with four single-pane tabs: the FOCUSED `slopdesk` pane plus three
    /// background panes in every attention class — a blocked agent (`herdr`), a failed command (`api`),
    /// and an unread agent finish (`docs`) — so the dot lights and the menu section lists all three,
    /// blocked first.
    @MainActor
    private func makeAttentionStore() -> (store: WorkspaceStore, focused: PaneID) {
        let rows: [(title: String, cwd: String)] = [
            ("slopdesk", "/Users/abner/Workplace/slopdesk"),
            ("herdr", "/Users/abner/Workplace/herdr"),
            ("api", "/Users/abner/Workplace/api"),
            ("docs", "/Users/abner/Workplace/docs"),
        ]
        var tabs: [SlopDeskWorkspaceCore.Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for row in rows {
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: row.title, lastKnownCwd: row.cwd)
            tabs.append(SlopDeskWorkspaceCore.Tab(title: row.title, root: .leaf(pane), activePane: pane))
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
        let panes = tabs.compactMap(\.activePane)
        let now = Date()
        // herdr — blocked 4 minutes ago, with the host's blocking question as the label.
        store.setAgentLabel("Allow Bash(npm run deploy)?", for: panes[1])
        store.setAgentStatus(.needsPermission, for: panes[1], at: now.addingTimeInterval(-240))
        // api — failed command 12 minutes ago (no label → the "Failed" caption).
        store.setCompletionBadge(.failure, for: panes[2], at: now.addingTimeInterval(-720))
        // docs — agent finished an hour ago, its last line as the label.
        store.setAgentLabel("Docs regenerated — 3 files changed", for: panes[3])
        store.setAgentStatus(.done, for: panes[3], at: now.addingTimeInterval(-3900))
        return (store, panes[0])
    }

    // MARK: - Opt-in render of the vi copy-mode surfaces (block cursor + responsive hint bar)

    /// Renders the REAL ``ViCursorOverlay`` over a hand-built cell-exact terminal mock (every glyph
    /// framed in its own cell box, so glyph↔block alignment is true by construction) — the visual
    /// lock for the copy-mode block cursor (sharp, glyph-width, translucent) on an ASCII glyph AND
    /// on a wide CJK glyph (2-cell block) — plus the ``ViKeyHintBar`` at three pane widths to
    /// eyeball the `ViewThatFits` reflow (3-col → 2-col → 1-col). SAME opt-in idiom as the other
    /// renders; writes `vi-cursor.png` + `vi-hint-bar.png` into `SLOPDESK_VIMODE_SNAPSHOT_DIR`.
    /// Headless: a stub surface (no socket / video / Metal — the hang-safety rule).
    @MainActor
    func testRenderViCopyModeSurfaces() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_VIMODE_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_VIMODE_SNAPSHOT_DIR=<dir> to render the vi copy-mode surfaces")
        }
        let rows = [
            "❯ rg --files Sources | head",
            "Sources/SlopDeskTerminal/TerminalSurface.swift",
            "Sources/SlopDeskWorkspaceCore/Terminal/ViLineMotion.swift",
            "xin chào 世界 — wide glyphs",
            "❯ make check",
        ]
        // The model's `surface` is WEAK — the stubs must outlive the render, so they are owned here.
        let ascii = ViSnapshotSurface(rows: rows, cursor: TerminalScreenPoint(col: 8, row: 2))
        let wide = ViSnapshotSurface(rows: rows, cursor: TerminalScreenPoint(col: 9, row: 3))
        let panels = VStack(alignment: .leading, spacing: 12) {
            cursorPanel(surface: ascii, rows: rows)
            cursorPanel(surface: wide, rows: rows)
        }
        .padding(12)
        .background(Slate.Surface.ground)
        try withExtendedLifetime((ascii, wide)) {
            try render(panels, size: CGSize(width: 560, height: 260), to: dir, named: "vi-cursor.png")
        }

        let bars = VStack(alignment: .leading, spacing: 16) {
            ViKeyHintBar().frame(width: 760, alignment: .leading)
            ViKeyHintBar().frame(width: 470, alignment: .leading)
            ViKeyHintBar().frame(width: 300, alignment: .leading)
        }
        .padding(16)
        .background(Slate.Surface.ground)
        try render(bars, size: CGSize(width: 800, height: 980), to: dir, named: "vi-hint-bar.png")
    }

    /// One terminal-mock panel with the live cursor overlay: a ``TerminalViewModel`` over the stub
    /// surface enters copy-mode (seeding the vi cursor at the staged terminal cursor) and the real
    /// ``ViCursorOverlay`` draws over the cell grid.
    @MainActor
    private func cursorPanel(surface: ViSnapshotSurface, rows: [String]) -> some View {
        let model = TerminalViewModel(surface: surface)
        model.enterCopyMode()
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                    self.fakeTerminalRow(line)
                }
            }
            ViCursorOverlay(model: model)
        }
        .padding(8)
        .background(Slate.Surface.face)
    }

    /// One cell-exact mock terminal row: each glyph in its own fixed cell box (wide glyphs 2 cells),
    /// matching ``ViSnapshotSurface``'s staged metrics so the block cursor can be judged for
    /// alignment honestly.
    @MainActor
    private func fakeTerminalRow(_ line: String) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(line.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Slate.Text.primary)
                    .frame(
                        width: 8 * CGFloat(max(1, TerminalLinkDetector.displayCellWidth(of: ch))),
                        height: 17,
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(height: 17)
    }

    /// Center an overlay panel on the dimmed scrim + window background, the way `OverlayHostView` composes it.
    @MainActor
    private func scrimmed(_ panel: some View) -> some View {
        ZStack {
            Slate.Surface.ground
            Slate.State.shadow // the host's dim scrim role
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
        print("SLOPDESK_SNAPSHOT_WRITTEN \(out.path)")
    }
}

/// A static mock of the chrome, built from the real token layer + component kit. Mirrors the resting
/// window: a "TABS" sidebar (raised-card active tab via the shared `SlateListRow` shell + a hamburger
/// `SlateSectionHeader` accessory) beside a FLUSH, borderless two-pane terminal on paper — NO floating
/// card, NO accent ring, NO per-pane header bar, NO cwd pill and NO right inspector. Green appears ONLY on
/// the prompt `❯` glyph (accent rationing), never as chrome.
private struct SlateShowcase: View {
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(width: 920, height: 560)
        .background(Slate.Surface.ground)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            SlateSectionHeader("Tabs") {
                Image(systemSymbol: .line3Horizontal)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Slate.Text.icon)
            }
            showcaseRow(title: "~/slopdesk", badge: "zsh", active: true)
            showcaseRow(title: "build", badge: "zsh", active: false)
            showcaseRow(title: "Remote window", badge: nil, active: false)
            Spacer()
        }
        .padding(Slate.Metric.space2)
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.Surface.ground)
    }

    /// One showcase tab row on the shared ``SlateListRow`` shell (the same anatomy `SlateTabRow` rides).
    private func showcaseRow(title: String, badge: String?, active: Bool) -> some View {
        SlateListRow(
            active: active,
            title: {
                Text(title)
                    .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
            },
            titleTrailing: { _ in
                if let badge {
                    Text(badge)
                        .font(Slate.Typeface.instrument(Slate.Typeface.small))
                        .foregroundStyle(Slate.Text.secondary)
                }
            },
            subtitleTrailing: { _ in EmptyView() },
            trailingOverlay: { _ in EmptyView() },
        )
    }

    private var content: some View {
        VStack(spacing: 0) {
            // The active path lives in the window titlebar, centered + muted — not a per-pane header bar.
            Text("~/slopdesk")
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(Slate.Text.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Slate.Metric.paneHeaderHeight)
            // Two flush, borderless terminal panes separated by a single hairline divider.
            HStack(spacing: 0) {
                terminalPane(
                    promptPath: "~",
                    command: "swift build",
                )
                Rectangle().fill(Slate.Line.divider).frame(width: Slate.Metric.hairline)
                terminalPane(
                    promptPath: "~/slopdesk",
                    command: nil,
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Slate.Surface.face) // flush paper terminal surface (#FCFBF9), not a brighter-white card
    }

    private func terminalPane(promptPath: String, command: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text("\(promptPath) ").foregroundStyle(Slate.Status.info)
                + Text("via ").foregroundStyle(Slate.Text.secondary)
                + Text("🥭 jmango").foregroundStyle(Slate.Status.ok))
                .font(.system(size: 13, design: .monospaced))
            (Text("/\\ - τ -▽ ").foregroundStyle(Slate.Text.secondary)
                + Text("❯ ").foregroundStyle(Slate.State.accent) // the ONLY green — accent rationing
                + Text(command ?? "").foregroundStyle(Slate.Text.primary))
                .font(.system(size: 13, design: .monospaced))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Slate.Metric.space3)
    }
}

/// The vi-cursor render's stub surface: stages a viewport whose extent equals the mock rows and a
/// terminal cursor for copy-mode to seed at. Selection calls are accepted and dropped (the render
/// judges the CURSOR; the selection band is libghostty's to paint in the real app).
private final class ViSnapshotSurface: TerminalSurface, TerminalViewportSnapshotting, TerminalSelectionControl,
    @unchecked Sendable
{
    private let rows: [String]
    private let cursor: TerminalScreenPoint

    init(rows: [String], cursor: TerminalScreenPoint) {
        self.rows = rows
        self.cursor = cursor
    }

    // TerminalSurface (inert)
    func feed(_: Data) {}
    func setSize(cols _: UInt16, rows _: UInt16) {}
    func handleInput(_: Data) {}
    var onWrite: ((Data) -> Void)?

    // TerminalViewportSnapshotting — the staged cell geometry `fakeTerminalRow` mirrors (8×17pt).
    func viewportTextRows() -> [String] { rows }
    func cellMetrics() -> TerminalCellMetrics? {
        TerminalCellMetrics(cellWidth: 8, cellHeight: 17, cols: 64, rows: rows.count)
    }

    // TerminalSelectionControl — one static readback; the render is a single frame.
    func viewportInfo() -> TerminalViewportInfo? {
        TerminalViewportInfo(
            viewportTopRow: 0,
            viewportRows: rows.count,
            cols: 64,
            totalRows: rows.count,
            cursor: cursor,
        )
    }

    @discardableResult
    func setSelection(anchor _: TerminalScreenPoint, head _: TerminalScreenPoint, rectangle _: Bool) -> Bool { true }
    func clearSelection() {}
    func readScreenRow(_ row: Int) -> String? { rows.indices.contains(row) ? rows[row] : nil }
    func lineRange(_ screenRow: Int) -> ClosedRange<Int>? { screenRow...screenRow } // no wrap staged
}
#endif
