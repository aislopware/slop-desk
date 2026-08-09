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
            // A COMMAND's alphabet — no mark at all: the slot names what finished, bold on the
            // primary ink for a clean exit and bold on red for a failure.
            badgeRow(
                "running build task", badge: .error, process: "make",
                receipt: .init(name: "make", outcome: .failed),
            )
            badgeRow(
                "swift test", badge: .finished, process: "swift",
                receipt: .init(name: "swift", outcome: .succeeded),
            )
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
    /// says a finish badge is the AGENT's turn ending, which is what closes its ring; `receipt` is a
    /// finished COMMAND's outcome, which takes the slot as text instead of a mark.
    @MainActor
    private func badgeRow(
        _ title: String, badge: TabBadgeKind, agentFinish: Bool = false, agent: Bool = false,
        process: String? = nil, receipt: RailRowsBuilder.CommandReceipt? = nil,
    ) -> some View {
        SlateTabRow(
            title: title, active: false, agentMarker: agent, badge: badge,
            agentFinish: agentFinish, processLabel: process, commandReceipt: receipt,
            onSelect: {}, onClose: {},
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

    // MARK: - Opt-in render of the command ladder in its gutter

    /// Renders the command LADDER exactly as a pane mounts it — a glass pane, the terminal surface
    /// held off its sides by the pane's own `paneGutter`, and the rail standing in the TRAILING
    /// GUTTER that padding opens (`command-ladder.png`, plus an 8× tile so the marks can be read).
    ///
    /// This is the check the round exists for: the rail must be inside the gutter — no mark and no
    /// hit area over a cell — and the ticks must be the GLASS's own green / red / accent rather than
    /// the system status palette. Both are measurable off the PNG: sample the columns either side of
    /// the gutter's inner edge. Mock "cells" stand in for libghostty (no Metal in a test — the
    /// hang-safety rule), drawn right up to the surface's own edge so an intruding tick would land on
    /// one.
    ///
    /// SAME opt-in idiom as the other renders; inert unless `SLOPDESK_LADDER_SNAPSHOT_DIR=<dir>`.
    @MainActor
    func testRenderCommandLadder() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_LADDER_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_LADDER_SNAPSHOT_DIR=<dir> to render the command ladder")
        }
        let model = TerminalViewModel()
        // A run with every outcome in it: clean, failed, a mid-stream join with no ordinal (inert),
        // and the newest one still running.
        let script: [(String, Int32?, Bool)] = [
            ("swift build", 0, true), ("make lint", 0, true), ("swift test", 1, true),
            ("git status", 0, true), ("make test-touched", 0, true), ("ls -la", 0, true),
            ("cargo check", 127, true), ("git log", 0, true), ("scripts/check-macos.sh", 0, true),
            ("swift build -c release", 0, false), ("make test", nil, true),
        ]
        for (offset, entry) in script.enumerated() {
            model.blocks.upsert(
                index: UInt32(offset), commandText: entry.0, exitCode: entry.1,
                durationMS: entry.1 == nil ? nil : 240, complete: entry.1 != nil, outputLen: 0,
                // The one ordinal-less block is the mid-stream join — it must render dim and inert.
                promptOrdinal: entry.2 ? UInt32(offset + 1) : 0,
            )
        }
        let pane = LadderPaneMock(model: model)
        try renderHosted(
            pane, size: CGSize(width: 280, height: 220), to: dir, named: "command-ladder.png",
        )
        try renderHosted(
            pane.frame(width: 280, height: 220).scaleEffect(4, anchor: .bottomTrailing),
            size: CGSize(width: 280, height: 220), to: dir, named: "command-ladder-4x.png",
        )
        try renderHosted(
            LadderPeekMock(), size: CGSize(width: 700, height: 470), to: dir,
            named: "command-ladder-peek.png",
        )
    }

    /// One mark at the column's true size, or magnified.
    ///
    /// ⚠️ A system symbol is REDRAWN at the larger point size rather than scaled: `Image(systemName:)`
    /// rasterizes at its point size, so a `scaleEffect` tile is a blown-up 12pt bitmap and reads as
    /// a blurry mark that is nothing like what the rail draws. The symbol and its size come from
    /// ``StatusMark/systemSymbol``, the same source the shipping view reads, so the magnified tile
    /// can never show a different glyph.
    @MainActor
    @ViewBuilder
    private func still(_ style: StatusDotStyle, zoom: CGFloat = 1) -> some View {
        if zoom > 1, let system = style.mark.systemSymbol {
            Image(systemSymbol: system.symbol)
                .font(.system(size: system.size * zoom, weight: StatusDot.symbolWeight))
                .foregroundStyle(style.ink)
                .frame(width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom)
        } else {
            zoomed(StatusDotView(style: style), side: StatusDot.footprint, zoom: zoom)
        }
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
            // The two squeeze cases: a long branch WITH a readout (name truncates, sigils fold and pin
            // right) and the same branch with nothing to report (name truncates alone).
            SidebarSectionHeaderRow(
                store: store, title: "long-branch", projectKey: "/Users/abner/w/long", count: 1,
            )
            SidebarSectionHeaderRow(
                store: store, title: "clean-long-branch", projectKey: "/Users/abner/w/clean", count: 1,
            )
        }
        .padding(8) // the sidebar list's LazyVStack inset
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.Surface.ground)
        try render(
            panel, size: CGSize(width: Slate.Metric.sidebarWidth, height: 440),
            to: dir, named: "sidebar-section.png",
        )
    }

    // MARK: - Opt-in render of the sidebar connection footer (every ink state)

    /// Renders the REAL ``ConnectionStatusIsland`` (link line: hostname leading, metric trailing —
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
        ConnectionStatusIsland(displayHost: host, led: led, detail: detail, pulse: pulse)
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
        // The squeeze case: a branch name far wider than the sidebar, with a full readout behind it —
        // the header has to truncate the NAME and fold the counts to their sigils, flush right.
        store.projectGitSummary["/Users/abner/w/long"] = PaneGitSummary(
            hasRepo: true, branch: "feature/rail-git-line-truncation-behaviour", ahead: 12, behind: 3,
            changedCount: 9, staged: 30, modified: 4, untracked: 5, conflicted: 6, stash: 7,
        )
        // Same long branch, NOTHING to report — the line is the branch alone, truncating with no
        // readout pinned beside it.
        store.projectGitSummary["/Users/abner/w/clean"] = PaneGitSummary(
            hasRepo: true, branch: "feature/rail-git-line-truncation-behaviour", ahead: 0, behind: 0,
            changedCount: 0,
        )
        let panes = tabs.compactMap(\.activePane)
        store.setForegroundProcess("claude", for: panes[0])
        store.setAgentStatus(.needsPermission, for: panes[1])
        store.setCompletionBadge(.failure, for: panes[2])
        return store
    }

    // MARK: - Opt-in render of the git line's squeeze ladder (one repo, narrowing widths)

    /// Renders ONE busy repo's header at a sweep of sidebar widths, so the shed ladder is visible as a
    /// ladder: the numbers go first (sigils fold, pinned right), then the readout gives up `$` stash, then
    /// `↑↓` divergence, then `?` untracked — the branch name keeping its characters the whole way — and
    /// only at the end does the name itself truncate beside the surviving worktree core. Opt-in like the
    /// rest; writes `git-line-squeeze.png` into `SLOPDESK_TABROW_SNAPSHOT_DIR`.
    @MainActor
    func testRenderGitLineSqueezeLadder() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the git squeeze ladder")
        }
        let key = "/Volumes/Lacie/Workspace/oss/slop-desk"
        let store = makeSectionStore(key: key)
        store.projectGitSummary[key] = PaneGitSummary(
            hasRepo: true, branch: "feature/shed-ladder", ahead: 12, behind: 3, changedCount: 9,
            staged: 30, modified: 4, untracked: 5, conflicted: 6, stash: 7,
        )
        // Descending, and FINE around the shed rungs: one sigil is ~8 pt wide, so each rung of the ladder
        // owns a band about that narrow — a coarse sweep steps straight over it and reads as "the ladder
        // does not fire".
        let widths: [CGFloat] = [Slate.Metric.sidebarWidth, 214, 206, 198, 190, 168, 148, 128]
        let panel = VStack(alignment: .leading, spacing: 10) {
            ForEach(widths, id: \.self) { width in
                self.captioned("\(Int(width)) pt") {
                    SidebarSectionHeaderRow(store: store, title: "slop-desk", projectKey: key, count: 3)
                        .frame(width: width)
                        .background(Slate.Surface.ground)
                }
            }
        }
        .padding(8)
        .frame(width: Slate.Metric.sidebarWidth + 16, alignment: .leading)
        .background(Slate.Surface.ground)
        try render(
            panel, size: CGSize(width: Slate.Metric.sidebarWidth + 16, height: 460),
            to: dir, named: "git-line-squeeze.png",
        )
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
    /// the view draws what the app draws. Three details are all load-bearing:
    ///
    ///  * the WINDOW is not optional: an `NSProgressIndicator` outside one never starts animating.
    ///  * the window's `NSAppearance` is pinned to the theme, EXACTLY as
    ///    `SlopDeskSplitViewController.pinWindowAppearance()` does it. Without that an offscreen
    ///    window is Aqua whatever the tokens say, and every system-drawn control — the spinner
    ///    above all — comes out in its LIGHT-mode ink on the dark ground. That is a lie about the
    ///    app, not a fact about the mark.
    ///  * the capture is @2x, driven by the layer's `contentsScale`. An offscreen window backs at
    ///    1×, and at 1× a magnified tile is a blown-up 14pt bitmap rather than the vector redrawn.
    @MainActor
    private func renderHosted(
        _ content: some View, size: CGSize, to dir: String, named name: String, scale: CGFloat = 2,
    ) throws {
        guard let rep = hostedBitmap(content, size: size, scale: scale),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("no PNG for \(name)")
            return
        }
        let out = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try png.write(to: out)
        print("SLOPDESK_SNAPSHOT_WRITTEN \(out.path)")
    }

    /// One hosted rasterization — the shared body of ``renderHosted`` and the hosted GIF frames.
    @MainActor
    private func hostedBitmap(
        _ content: some View, size: CGSize, scale: CGFloat,
    ) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false,
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        if let layer = host.layer { Self.pinContentsScale(layer, scale) }
        // One turn of the run loop so the indicator's first frame exists, and the layers have
        // redrawn at the scale we just asked for, before we photograph any of it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            XCTFail("no bitmap context")
            return nil
        }
        rep.size = size
        // `CALayer.render(in:)` draws top-left-down; an `NSBitmapImageRep` context is bottom-left-up.
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        host.layer?.render(in: context.cgContext)
        window.orderOut(nil)
        return rep
    }

    /// Raise the whole layer tree's backing resolution — `CALayer.render(in:)` replays cached
    /// contents, so a sublayer left at 1× stays 1× however far the context is scaled.
    private static func pinContentsScale(_ layer: CALayer, _ scale: CGFloat) {
        layer.contentsScale = scale
        layer.rasterizationScale = scale
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { pinContentsScale($0, scale) }
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
        .background(Slate.Surface.face) // flush theme terminal surface (`face`), not a brighter-white card
    }

    private func terminalPane(promptPath: String, command: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text.spliced([
                Text("\(promptPath) ").foregroundStyle(Slate.Status.info),
                Text("via ").foregroundStyle(Slate.Text.secondary),
                Text("🥭 jmango").foregroundStyle(Slate.Status.ok),
            ])
            .font(.system(size: 13, design: .monospaced))
            Text.spliced([
                Text("/\\ - τ -▽ ").foregroundStyle(Slate.Text.secondary),
                Text("❯ ").foregroundStyle(Slate.State.accent), // the ONLY green — accent rationing
                Text(command ?? "").foregroundStyle(Slate.Text.primary),
            ])
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

/// A pane MOCK for the command-ladder render: the same three ingredients ``TerminalLeafView``
/// assembles — the glass, the terminal surface held off its edges by the pane's own `space2`, and
/// the ladder mounted OUTSIDE that padding on the trailing side, so it stands in the gutter rather
/// than on the terminal. The "cells" are a stand-in for libghostty (no Metal in a test): they run
/// right up to the surface's edge, which is what makes an intruding tick visible in the PNG.
@MainActor
private struct LadderPaneMock: View {
    let model: TerminalViewModel

    var body: some View {
        VStack(spacing: 0) {
            cells
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, Slate.Metric.space2)
                .padding(.horizontal, Slate.Metric.paneGutter)
                .overlay(alignment: .trailing) {
                    CommandLadderOverlay(model: model, onJump: { _ in }, onJumpToLivePrompt: {})
                }
        }
        .background(Slate.Surface.terminal)
        .environment(\.colorScheme, Slate.glassColorScheme)
    }

    /// Stand-in cells — full-bleed rows of the terminal's own ink, so the surface's right edge is
    /// unmistakable in the render.
    private var cells: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<18, id: \.self) { row in
                Rectangle()
                    .fill(Slate.Terminal.ink2)
                    .frame(height: Slate.Metric.hairline * 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, row.isMultiple(of: 3) ? Slate.Metric.space4 : 0)
                    .opacity(Slate.Opacity.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The PEEK card in every state it can be read in, on the glass it is drawn over — the true-size
/// check for the hover preview (the real card is opened by a dwell, which no static render performs).
private struct LadderPeekMock: View {
    var body: some View {
        HStack(alignment: .top, spacing: Slate.Metric.space4) {
            VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                card(block(0, "make test-touched", exit: 0), .ready(clean))
                card(block(1, "cargo check", exit: 101), .ready(failure))
            }
            VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                card(block(2, "git status", exit: 0), .ready(short))
                card(block(3, "true", exit: 0), .ready(BlockOutputPreview(
                    lines: [], hiddenCount: 0, fromTail: false,
                )))
                card(block(4, "swift build --very-long-command-line-that-must-truncate", exit: 0), .loading)
                card(block(5, "make test", exit: nil), .unavailable)
            }
        }
        .padding(Slate.Metric.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Slate.Surface.terminal)
        .environment(\.colorScheme, Slate.glassColorScheme)
    }

    private func card(_ block: CommandBlock, _ entry: CommandLadderPeekEntry) -> some View {
        CommandLadderPeekCard(block: block, entry: entry)
    }

    private func block(_ index: UInt32, _ text: String, exit code: Int32?) -> CommandBlock {
        CommandBlock(
            index: index, commandText: text, exitCode: code,
            durationMS: code == nil ? nil : 12400, complete: code != nil, outputLen: 4096,
            promptOrdinal: index + 1,
        )
    }

    /// Each string parsed on its own — one line in, one line of styled runs out, so the mock feeds
    /// the card exactly what the wire path feeds it (``AnsiStyledParser``), escapes and all.
    private func styled(_ raw: [String]) -> [[AnsiRun]] {
        raw.map { AnsiStyledParser.lines(from: Data($0.utf8))[0] }
    }

    /// A clean run read from the TOP, with more below. Carries a nerd-font glyph (U+E0A0, the branch
    /// mark) so the render also says whether the resolved face has the private-use area.
    private var clean: BlockOutputPreview {
        BlockOutputPreview(
            lines: styled([
                "\u{1B}[1mBuilding for debugging...\u{1B}[0m",
                "[1/1103] Compiling SlopDeskClientUI CommandLadderOverlay.swift",
                "[2/1103] Compiling SlopDeskWorkspaceCore BlockOutputPreview.swift",
                "\u{1B}[2mTest Suite 'All tests' started at 2026-08-09 18:04:11.882\u{1B}[0m",
                "\u{1B}[32m✓\u{1B}[0m Test Case '-[CommandLadderLayoutTests testFewTicksKeep]' \u{1B}[32mpassed\u{1B}[0m",
                "\u{1B}[38;5;208m\u{E0A0} main\u{1B}[0m \u{1B}[36m12 files changed\u{1B}[0m",
                "\u{1B}[1;32mExecuted 1103 tests, with 0 failures\u{1B}[0m (0 unexpected) in 12.401s",
                "",
            ]),
            hiddenCount: 214, fromTail: false,
        )
    }

    /// A failure read from the BOTTOM — the whole reason the excerpt follows the outcome.
    private var failure: BlockOutputPreview {
        BlockOutputPreview(
            lines: styled([
                "   \u{1B}[1;32mCompiling\u{1B}[0m slopdesk v0.1.0 (/Volumes/Lacie/Workspace/oss/slop-desk)",
                "\u{1B}[1;31merror[E0433]\u{1B}[0m\u{1B}[1m: failed to resolve: use of undeclared crate\u{1B}[0m",
                "  \u{1B}[1;34m-->\u{1B}[0m src/main.rs:42:9",
                "   \u{1B}[1;34m|\u{1B}[0m",
                "\u{1B}[1;34m42 |\u{1B}[0m         foo::bar();",
                "   \u{1B}[1;34m|\u{1B}[0m         \u{1B}[1;31m^^^ use of undeclared crate `foo`\u{1B}[0m",
                "",
                "\u{1B}[1;31merror\u{1B}[0m\u{1B}[1m: could not compile `slopdesk` due to 1 error\u{1B}[0m",
            ]),
            hiddenCount: 214, fromTail: true,
        )
    }

    private var short: BlockOutputPreview {
        BlockOutputPreview(
            lines: styled([
                "On branch \u{1B}[32mmain\u{1B}[0m",
                "\u{1B}[7m nothing to commit \u{1B}[0m, working tree clean",
            ]),
            hiddenCount: 0, fromTail: false,
        )
    }
}

#endif
