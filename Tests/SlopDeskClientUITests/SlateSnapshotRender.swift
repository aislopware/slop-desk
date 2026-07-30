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
import SlopDeskWorkspaceModel
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

        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
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

    /// Renders `SlateTabRow` in each fused badge state — the neutral title beside the trailing
    /// STATUS MARK column (one dashed ring: accent for the agent tier, muted for a busy command,
    /// green/amber/red for the attention states, nothing at rest) plus the resting shell-label slot
    /// and the active white card — the visual lock for the sidebar row. SAME `ImageRenderer` opt-in idiom
    /// as the showcase; inert (skipped) unless `SLOPDESK_TABROW_SNAPSHOT_DIR=<dir>` is set, where
    /// it writes `tab-row-badges.png`. NO video/Metal — a badge is pure SwiftUI.
    @MainActor
    func testRenderTabRowBadges() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the tab-row badge states")
        }
        let panel = VStack(alignment: .leading, spacing: 2) {
            // The AGENT's alphabet — the ring. Dashed while the work is open, CLOSED once the turn
            // ended; the hue names which open state it is.
            badgeRow("full-release.sh", badge: .running, agent: true)
            badgeRow("plan next move", badge: .awaitingInput, agent: true)
            badgeRow("OpenCode", badge: .completed, agentFinish: true, agent: true)
            badgeRow("refactor the reassembler", badge: .finished, agentFinish: true, agent: true)
            // A COMMAND's alphabet — the outcome dot, on the SAME two inks, in the same column.
            badgeRow("running build task", badge: .error, process: "make")
            badgeRow("swift test", badge: .finished, process: "swift")
            // …and the states that mark nothing at all: a running command and a resting shell.
            badgeRow("swift build", badge: .commandBusy, process: "swift")
            SlateTabRow(
                title: "abner@MacBook-AB:…",
                active: true,
                processLabel: "zsh",
                onSelect: {},
                onClose: {},
            )
        }
        .padding(8)
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.Surface.ground)
        try renderHosted(
            panel, size: CGSize(width: Slate.Metric.sidebarWidth, height: 260),
            to: dir, named: "tab-row-badges.png",
        )
    }

    /// A resting (non-active) tab row carrying one fused badge, for the badge-state showcase. `agent`
    /// wears the `✳` title marker (and leaves the slot bare, as the real rail does); `agentFinish`
    /// says a finish badge is the AGENT's turn ending, which is what closes its ring.
    @MainActor
    private func badgeRow(
        _ title: String, badge: TabBadgeKind, agentFinish: Bool = false, agent: Bool = false,
        process: String? = nil,
    ) -> some View {
        SlateTabRow(
            title: title, active: false, agentMarker: agent, badge: badge,
            agentFinish: agentFinish, processLabel: process, onSelect: {}, onClose: {},
        )
    }

    // MARK: - Opt-in render of the status marks

    /// Renders the WHOLE mark vocabulary at true size and magnified (`status-marks.png`) — the only
    /// way to check the transcription of otty's artwork, since a mistyped coordinate parses happily
    /// and is invisible in the values.
    ///
    /// ⚠️ Rendered through an offscreen WINDOW, not `ImageRenderer`: the working mark is the
    /// platform's own indeterminate indicator, and `ImageRenderer` cannot rasterize an AppKit-backed
    /// view at all — it substitutes the unavailable-placeholder tile. `cacheDisplay(in:to:)` on a
    /// hosted view draws what the app draws, and the window is what makes the indicator animate at
    /// all (an `NSProgressIndicator` with no window never starts).
    ///
    /// SAME opt-in idiom as the other renders; inert unless `SLOPDESK_TABROW_SNAPSHOT_DIR=<dir>`.
    /// Pure SwiftUI — no video/Metal (the hang-safety rule).
    @MainActor
    func testRenderStatusMarks() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the status marks")
        }
        let marks: [(String, StatusDotStyle)] = [
            ("thinking", StatusPresentation.thinkingMark),
            ("resting", StatusDotStyle(ink: Slate.Text.secondary)),
            ("question", StatusDotStyle(ink: Slate.Status.warn, mark: .awaiting)),
            ("agent finish", StatusDotStyle(ink: Slate.Status.ok, mark: .agentFinish)),
            ("cmd finish", StatusDotStyle(ink: Slate.Status.ok, mark: .commandFinish)),
            ("failure", StatusDotStyle(ink: Slate.Status.err, mark: .failure)),
        ]
        let sheet = VStack(alignment: .leading, spacing: 16) {
            captioned("true size — the rail's own 14pt column") {
                HStack(spacing: 10) { ForEach(marks.indices, id: \.self) { self.still(marks[$0].1) } }
            }
            captioned("8× — \(marks.map(\.0).joined(separator: " · "))") {
                HStack(spacing: 16) {
                    ForEach(marks.indices, id: \.self) { self.still(marks[$0].1, zoom: 8) }
                }
            }
            captioned("the privilege slot — sudo · caffeinate (true size, then 8×)") {
                HStack(spacing: 16) {
                    TabBadgeView(kind: .sudo)
                    TabBadgeView(kind: .caffeinate)
                    self.zoomed(TabBadgeView(kind: .sudo), side: TabBadgeView.side, zoom: 8)
                    self.zoomed(TabBadgeView(kind: .caffeinate), side: TabBadgeView.side, zoom: 8)
                }
            }
        }
        .padding(20)
        .frame(width: 780, alignment: .leading)
        .background(Slate.Surface.ground)
        try renderHosted(sheet, size: CGSize(width: 780, height: 420), to: dir, named: "status-marks.png")
    }

    /// A settled mark at the same scale, for the side-by-side that proves the shimmer can't be
    /// mistaken for one of them.
    @MainActor
    private func still(_ style: StatusDotStyle, zoom: CGFloat = 1) -> some View {
        zoomed(StatusDotView(style: style), side: StatusDot.footprint, zoom: zoom)
    }

    /// Magnify a mark WITHOUT resampling its geometry — `scaleEffect` on the vector, so an 8× frame
    /// shows the shape the rasterizer would draw, not a blown-up 14pt bitmap.
    @MainActor
    private func zoomed(_ content: some View, side: CGFloat, zoom: CGFloat) -> some View {
        content
            .scaleEffect(zoom)
            .frame(width: side * zoom, height: side * zoom)
    }

    @MainActor
    private func captioned(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.tertiary)
            content()
        }
    }

    /// Rasterize each view as one GIF frame and write a looping animation. Same @2x scale as the PNG
    /// renders, so the GIF and the filmstrip show the same pixels.
    @MainActor
    private func renderGIF(
        _ frames: [some View], size: CGSize, delay: Double, to dir: String, named name: String,
    ) {
        let out = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            out as CFURL, "com.compuserve.gif" as CFString, frames.count, nil,
        ) else {
            XCTFail("could not create a GIF destination at \(out.path)")
            return
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for frame in frames {
            let renderer = ImageRenderer(content: frame.frame(width: size.width, height: size.height))
            renderer.scale = 2
            guard let cg = renderer.cgImage else {
                XCTFail("ImageRenderer produced no frame for \(name)")
                return
            }
            CGImageDestinationAddImage(dest, cg, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest), "GIF finalize failed for \(name)")
        print("SLOPDESK_SNAPSHOT_WRITTEN \(out.path)")
    }

    // MARK: - Opt-in render of one By-Project sidebar section (header + single-line rows)

    /// Renders the REAL ``SidebarSectionHeaderRow`` (the gutter-chevron + NAME header on the rows'
    /// shared left rail — one git-lined group, one bare-named group, one collapsed showing its
    /// hidden-row count in the attention roll-up ink) over a seeded headless store, above
    /// representative ``SlateTabRow`` states at the true sidebar width: title (with the `✳` agent
    /// marker where due) + one trailing slot (shell label / badge). SAME opt-in idiom; writes
    /// `sidebar-section.png` into `SLOPDESK_TABROW_SNAPSHOT_DIR`.
    @MainActor
    func testRenderSidebarSection() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the sidebar section")
        }
        let key = "/Volumes/Lacie/Workspace/oss/slop-desk"
        let store = makeSectionStore(key: key)
        let panel = VStack(alignment: .leading, spacing: 2) {
            SidebarSectionHeaderRow(store: store, title: "slop-desk", projectKey: key, count: 3)
            // A WORKING agent row: the trailing slot carries the accent dashed ring.
            SlateTabRow(
                title: "Claude Code", active: false, agentMarker: true,
                workingLabel: "Agent working",
                onSelect: {}, onClose: {},
            )
            SlateTabRow(
                title: "Claude Code", active: true, agentMarker: true, badge: .awaitingInput,
                onSelect: {}, onClose: {},
            )
            SlateTabRow(
                title: "api", active: false, badge: .error,
                onSelect: {}, onClose: {},
            )
            SidebarSectionHeaderRow(
                store: store, title: "Workspace", projectKey: "/Users/abner/Workspace", count: 2,
            )
            // Settled rows: the trailing slot carries the shell label — the otty resting look —
            // and only the states that say something mount the mark beside it.
            SlateTabRow(
                title: "Terminal", active: false, badge: .finished,
                onSelect: {}, onClose: {},
            )
            // A busy SHELL row: the command title stands still beside the muted dashed ring.
            SlateTabRow(
                title: "swift build", active: false, badge: .commandBusy, processLabel: "swift",
                onSelect: {}, onClose: {},
            )
            SlateTabRow(title: "Terminal", active: false, processLabel: "zsh", onSelect: {}, onClose: {})
            // Collapsed with the store's rows threaded in: one hides a needs-permission pane, so
            // the count wears the amber roll-up ink.
            SidebarSectionHeaderRow(
                store: store, title: "api", projectKey: "/Users/abner/w/api", collapsed: true, count: 2,
                rows: RailRowsBuilder.rows(for: store),
            )
        }
        .padding(8) // the sidebar list's LazyVStack inset
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.Surface.ground)
        try render(
            panel, size: CGSize(width: Slate.Metric.sidebarWidth, height: 360),
            to: dir, named: "sidebar-section.png",
        )
    }

    // MARK: - Opt-in render of the sidebar connection footer (every ink state)

    /// Renders the REAL ``ConnectionRailFooter`` (link line: hostname leading, metric trailing —
    /// plus the host-pulse line when the machine has reported) in every ink state — healthy,
    /// degraded, bad, dialing, dimmed offline, memory pressure, plus a long hostname proving the host
    /// is the row's truncator — at the true sidebar width, so the ink steps and BOTH rail alignments
    /// can be eyeballed headlessly. SAME opt-in idiom; writes `sidebar-footer.png` into
    /// `SLOPDESK_TABROW_SNAPSHOT_DIR`.
    @MainActor
    func testRenderSidebarFooter() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the sidebar footer")
        }
        let idle = HostPulse(cpuPercent: 6, memoryPercent: 43, memoryPressure: .normal, diskFreeMiB: 245_760)
        let busy = HostPulse(cpuPercent: 97, memoryPercent: 74, memoryPressure: .normal, diskFreeMiB: 43008)
        // Disk running out: an amber middle run, with the two rails still calm.
        let filling = HostPulse(cpuPercent: 21, memoryPercent: 51, memoryPressure: .normal, diskFreeMiB: 9012)
        let squeezed = HostPulse(cpuPercent: 64, memoryPercent: 92, memoryPressure: .warn, diskFreeMiB: 2048)
        let thrashing = HostPulse(cpuPercent: 100, memoryPercent: 98, memoryPressure: .critical, diskFreeMiB: 820)
        // The volume could not be read: the middle run is absent, the line still reports.
        let blindDisk = HostPulse(cpuPercent: 12, memoryPercent: 49, memoryPressure: .normal)
        let panel = VStack(alignment: .leading, spacing: 0) {
            // Connected, healthy link — the pulse line rides beneath on the same two rails.
            footerRow(host: "mac-studio", led: .good, detail: ("12 ms", true), pulse: idle)
            footerRow(host: "mac-studio", led: .good, detail: ("12 ms", true), pulse: busy)
            footerRow(host: "mac-studio", led: .good, detail: ("12 ms", true), pulse: filling)
            // The host's memory is under pressure: the MEM run alone takes the hue — cpu never does.
            footerRow(host: "mac-studio", led: .good, detail: ("12 ms", true), pulse: squeezed)
            footerRow(host: "mac-studio", led: .slow, detail: ("141 ms", true), pulse: thrashing)
            footerRow(host: "mac-studio", led: .good, detail: ("12 ms", true), pulse: blindDisk)
            // A long hostname still truncates before the ping does.
            footerRow(host: "congs-macbook-pro-16-inch", led: .good, detail: ("12 ms", true), pulse: idle)
            // Connected but the host has not reported yet → ONE line, no dashes.
            footerRow(host: "mac-studio", led: .bad, detail: ("312 ms", true), pulse: nil)
            footerRow(host: "mac-studio", led: .dialing, detail: ("reconnecting 3/20", false), pulse: nil)
            footerRow(host: "mac-studio", led: .dim, detail: ("disconnected", false), pulse: nil)
        }
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.Surface.ground)
        try render(
            panel, size: CGSize(width: Slate.Metric.sidebarWidth, height: 650),
            to: dir, named: "sidebar-footer.png",
        )
    }

    /// One footer mount, composed the way the sidebar does it (no rule above it — the sidebar
    /// separates its bands by air).
    @MainActor
    private func footerRow(
        host: String, led: ConnectionCluster.LedState, detail: (String, Bool), pulse: HostPulse?,
    ) -> some View {
        ConnectionRailFooter(displayHost: host, led: led, detail: detail, pulse: pulse)
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.top, Slate.Metric.space3)
            .padding(.bottom, Slate.Metric.space2)
    }

    /// A headless `.tree` store whose panes all live AT `key` (the project root), one blocked and one
    /// failed. The project's git summary is seeded directly (`internal(set)` via `@testable`) so the
    /// header's hover tooltip carries a real git line.
    @MainActor
    private func makeSectionStore(key: String) -> WorkspaceStore {
        var tabs: [SlopDeskWorkspaceModel.Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        var paneCwds: [PaneID: String] = [:]
        for _ in 0..<3 {
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: "")
            paneCwds[pane] = key
            tabs.append(SlopDeskWorkspaceModel.Tab(title: "", root: .leaf(pane), activePane: pane))
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { seed in MountTestPaneSession(seed.spec) },
            liveVideoCap: 2,
            persistence: nil,
        )
        store.attachLoopbackWorkspaceDocument()
        for (pane, cwd) in paneCwds { store.setLastKnownCwd(cwd, for: pane) }
        store.projectGitSummary[key] = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 1, changedCount: 4, staged: 1, modified: 3,
            untracked: 5, conflicted: 2, stash: 1,
        )
        let panes = tabs.compactMap(\.activePane)
        store.setForegroundProcess("claude", for: panes[0])
        store.setAgentStatus(.needsPermission, for: panes[1])
        store.setCompletionBadge(.failure, for: panes[2])
        return store
    }

    // MARK: - Opt-in render of the grouped NavigatorColumn (search + By-Project sections)

    /// Renders the live ``NavigatorColumn`` over a headless store grouped By-Project — the visual lock for the
    /// sidebar: the "TABS" header + sort hamburger, the flat search field, and the tabs bucketed into
    /// `SlateSectionHeader` sections (project basenames) with the per-row `#N` / badge chrome. SAME
    /// `ImageRenderer` opt-in idiom as the badge render; writes `navigator-grouped.png` into
    /// `SLOPDESK_TABROW_SNAPSHOT_DIR`. Headless: a `.tree` store over `MountTestPaneSession` (no socket / video /
    /// Metal — the hang-safety rule); the project keys come from each pane's `pane/cwd`.
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
        var tabs: [SlopDeskWorkspaceModel.Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        var paneCwds: [PaneID: String] = [:]
        for row in rows {
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: row.title)
            paneCwds[pane] = row.cwd
            tabs.append(SlopDeskWorkspaceModel.Tab(title: row.title, root: .leaf(pane), activePane: pane))
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { seed in MountTestPaneSession(seed.spec) },
            liveVideoCap: 2,
            persistence: nil,
        )
        store.attachLoopbackWorkspaceDocument()
        for (pane, cwd) in paneCwds { store.setLastKnownCwd(cwd, for: pane) }
        let panes = tabs.compactMap(\.activePane)
        if panes.count >= 5 {
            store.setForegroundProcess("zsh", for: panes[0])
            store.setAgentStatus(.working, for: panes[1])
            store.setAgentStatus(.needsPermission, for: panes[2])
            store.setCompletionBadge(.success, for: panes[3])
        }
        return store
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

    /// Rasterize through a real (offscreen) window instead of `ImageRenderer`.
    ///
    /// ⚠️ `ImageRenderer` silently refuses AppKit-backed views — a `ProgressView`, an
    /// `NSViewRepresentable` — and draws the yellow unavailable placeholder in their place. Hosting
    /// the view and calling `cacheDisplay(in:to:)` draws what the app draws. The WINDOW is not
    /// optional: an `NSProgressIndicator` outside one never starts animating, so it would rasterize
    /// blank.
    @MainActor
    private func renderHosted(
        _ content: some View, size: CGSize, to dir: String, named name: String,
    ) throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false,
        )
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // One turn of the run loop so the indicator's first frame exists before we photograph it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("no bitmap rep for \(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("no PNG for \(name)")
            return
        }
        let out = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try png.write(to: out)
        print("SLOPDESK_SNAPSHOT_WRITTEN \(out.path)")
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
            // The otty panel label — caps, system face, the measured 0.6 tracking.
            Text("TABS")
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .tracking(Slate.Typeface.capsTracking)
                .foregroundStyle(Slate.State.header)
                .padding(.horizontal, Slate.Metric.space2)
                .padding(.bottom, Slate.Metric.space1)
            SlateTabRow(title: "~/slopdesk", active: true, processLabel: "zsh", onSelect: {}, onClose: {})
            SlateTabRow(title: "build", active: false, processLabel: "zsh", onSelect: {}, onClose: {})
            SlateTabRow(title: "Remote window", active: false, onSelect: {}, onClose: {})
            Spacer()
        }
        .padding(Slate.Metric.space2)
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.Surface.ground)
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
