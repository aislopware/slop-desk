// MacNavigatorSnapshotRender — the navigator's visual-verification harness, in AppKit.
//
// The four probes here moved out of `SlateSnapshotRender` with the column itself (docs/56 stage D):
// the row's badge alphabet, one By-Project section, the git line's squeeze ladder, and the whole
// grouped column. They mount the REAL `NSView`s — `MacSidebarRowView`, `MacSidebarHeaderView`,
// `MacSidebarIslandView`, `MacNavigatorColumn` — so what is photographed is what ships, not a
// hand-built mock of it.
//
// EVERY STATE IS SEEDED THROUGH THE STORE, never poked into a row view. The AppKit row reads its
// whole appearance from ``SidebarRowPresentation/reading(for:store:fallbackTitle:)``, so a fixture
// that set the view's fields directly would be photographing the harness. The badge alphabet below
// therefore drives the real chain — agent status, completion badge, foreground process — and what
// comes out is what the resolver says.
//
// Opt-in and INERT under `swift test` / `make check`: every probe skips unless
// `SLOPDESK_TABROW_SNAPSHOT_DIR=<dir>` is set. Run on demand:
//   SLOPDESK_TABROW_SNAPSHOT_DIR="$PWD/.build/shots" swift test --filter MacNavigatorSnapshotRender
// It is NOT a pixel-diff CI gate — it is the recipe for judging a design claim arithmetic cannot
// settle.
//
// ⚠️ EVERY FIXTURE STANDS ON ``Slate/Native/Surface/field`` — THE GROUND, the authored cream every
// column of this app paints (ONE ISLAND law 4). NOT `Surface.ground`, which on macOS is the semantic
// aux-window backdrop (`underPageBackgroundColor`, measured `#A1A09F`): a mid grey that appears
// NOWHERE in the shipping chrome, and the EASIER ground — the status ramp measures ~2.05–2.12 as ink
// on the cream. An ink judged against a grey it will never be drawn on is not judged at all. If a
// future render comes out grey, this is the line it crossed.
//
// ⚠️ The capture pins the layer tree to @2x and turns the run loop before photographing. `CALayer
// .render(in:)` REPLAYS CACHED CONTENTS, so a sublayer left at 1× stays 1× however far the context
// is scaled — and the spinner's first frame does not exist until a display link has ticked.

import AppKit
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskClientUI
@testable import SlopDeskMacUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class MacNavigatorSnapshotRender: XCTestCase {
    // MARK: - The row's badge alphabet

    /// Renders a real ``MacSidebarRowView`` in each fused state — the title beside its trailing status
    /// mark (the spinner while the agent thinks, the hand for a question, the closed check once the
    /// turn ended; nothing at rest for a plain command) and the trailing SLOT (a resting process
    /// label, or a finished command's receipt — a bare tick, or its name in red).
    ///
    /// ⚠️ Read the two check marks in this image against each other — the agent's filled green circle
    /// and the receipt's plain tick are the round-25/26 gap, and the render is the only place it can be
    /// judged. Writes `tab-row-badges.png`.
    func testRenderTabRowBadges() throws {
        let dir = try outputDirectory()
        let store = makeStore(seeds: Self.badgeSeeds, activeIndex: Self.badgeSeeds.count - 1)
        // ⚠️ Mounted inside a HEADERLESS island rather than as bare rows. The island owns the
        // travelling selection plate, and the ACTIVE row's ink is authored FOR that plate (the row
        // flips its own appearance so the ink resolves on dark glass) — a bare active row is
        // near-white on the cream, which is the fixture's fault and not the row's. A headerless
        // section draws no bed, so nothing else is added to the frame.
        let island = MacSidebarIslandView(store: store, paneDrag: nil, preventSleep: nil)
        island.apply(
            section: SidebarSection(
                id: "badges", header: nil, projectKey: nil, rows: RailRowsBuilder.rows(for: store),
            ),
            bed: nil, collapsed: false,
        )
        let column = stack()
        column.addArrangedSubview(island)
        island.widthAnchor.constraint(
            equalToConstant: Slate.Metric.sidebarWidth - 16,
        ).isActive = true
        try render(column, width: Slate.Metric.sidebarWidth, to: dir, named: "tab-row-badges.png")
    }

    // MARK: - One By-Project section

    /// Renders the REAL ``MacSidebarHeaderView`` (the gutter-chevron + NAME header on the rows' shared
    /// left rail, its git line beneath) above the section's rows, inside the real
    /// ``MacSidebarIslandView`` so the project BED and the travelling selection plate are in frame —
    /// then the SAME group folded shut, where the git line gives way to the hidden-row count wearing
    /// the strongest attention ink of the rows it hides. Folding must never mute a waiting agent.
    /// Writes `sidebar-section.png`.
    func testRenderSidebarSection() throws {
        let dir = try outputDirectory()
        let key = "/Volumes/Lacie/Workspace/oss/slop-desk"
        let store = makeStore(
            seeds: Self.badgeSeeds.map { (title: $0.title, cwd: key, seed: $0.seed) }, activeIndex: 0,
        )
        seedGit(store, at: key)
        let rows = RailRowsBuilder.rows(for: store)
        let column = stack()
        for (index, collapsed) in [false, true].enumerated() {
            let island = MacSidebarIslandView(store: store, paneDrag: nil, preventSleep: nil)
            island.apply(
                section: SidebarSection(
                    id: "\(index)", header: "slop-desk", projectKey: key, rows: rows,
                ),
                bed: index, collapsed: collapsed,
            )
            column.addArrangedSubview(island)
            island.widthAnchor.constraint(
                equalToConstant: Slate.Metric.sidebarWidth - 16,
            ).isActive = true
        }
        try render(column, width: Slate.Metric.sidebarWidth, to: dir, named: "sidebar-section.png")
    }

    // MARK: - The git line's squeeze ladder

    /// Renders ONE busy repo's header at a sweep of sidebar widths, so the shed ladder is visible AS a
    /// ladder: the numbers go first (sigils fold, pinned right), then the readout gives up `$` stash,
    /// then `↑↓` divergence, then `?` untracked — the branch keeping its characters the whole way — and
    /// only at the end does the name itself truncate beside the surviving worktree core.
    ///
    /// The sweep is FINE around the shed rungs: one sigil is ~8 pt wide, so each rung owns a band about
    /// that narrow, and a coarse sweep steps straight over it and reads as "the ladder does not fire".
    /// Writes `git-line-squeeze.png`.
    func testRenderGitLineSqueezeLadder() throws {
        let dir = try outputDirectory()
        let key = "/Volumes/Lacie/Workspace/oss/slop-desk"
        let store = makeStore(seeds: [(title: "terminal", cwd: key, seed: .shell("zsh"))], activeIndex: 0)
        store.projectGitSummary[key] = PaneGitSummary(
            hasRepo: true, branch: "feature/shed-ladder", ahead: 12, behind: 3, changedCount: 9,
            staged: 30, modified: 4, untracked: 5, conflicted: 6, stash: 7,
        )
        let rows = RailRowsBuilder.rows(for: store)
        let column = stack()
        for width in [Slate.Metric.sidebarWidth, 214, 206, 198, 190, 168, 148, 128] as [CGFloat] {
            let header = MacSidebarHeaderView(
                store: store, title: "slop-desk", projectKey: key, rows: rows, collapsed: false,
            )
            column.addArrangedSubview(header)
            header.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        try render(
            column, width: Slate.Metric.sidebarWidth + 16, to: dir, named: "git-line-squeeze.png",
        )
    }

    // MARK: - The whole grouped column

    /// Renders the live ``MacNavigatorColumn`` over a headless store grouped By-Project — the visual
    /// lock for the sidebar: the traffic-light strip, the search plate on the column's own gutter, and
    /// the tabs bucketed into bedded project islands with their per-row chrome. Headless: a `.tree`
    /// store over `MountTestPaneSession` (no socket / video / Metal — the hang-safety rule); the
    /// project keys come from each pane's `pane/cwd`. Writes `navigator-grouped.png`.
    func testRenderNavigatorGrouped() throws {
        let dir = try outputDirectory()
        let store = makeStore(seeds: Self.groupedSeeds, activeIndex: 0)
        let column = MacNavigatorColumn(
            store: store, connection: Self.headlessConnection, onConnect: {}, preferences: nil,
            paneDrag: nil, overlay: nil,
        )
        try render(column.view, width: 240, height: 470, to: dir, named: "navigator-grouped.png")
    }

    // MARK: - The fixtures

    /// A connection whose registry always refuses — the column's foot island then draws its DISCONNECTED
    /// ink, which is the resting state the sidebar ships in. No socket is ever opened (the hang-safety
    /// rule).
    private static let headlessConnection = AppConnection(
        registry: ConnectionRegistry { _, _ in
            throw SlopDeskTransportError.timedOut("snapshot: no host")
        },
    )

    /// What a seeded pane is DOING — every one of these travels through the real store setters and out
    /// through the real resolver, so the render shows the badge the app would show, not one named here.
    private enum PaneState {
        /// A live agent turn — the spinner.
        case agentWorking
        /// A blocked agent — the hand.
        case agentBlocked
        /// A finished agent turn — the closed check.
        case agentDone
        /// A finished COMMAND — the trailing slot's receipt (a tick, or the name in red).
        case commandFinished(String, ok: Bool)
        /// A plain resting pane — its process label in the slot, nothing in the mark column.
        case shell(String)
    }

    private typealias Seed = (title: String, cwd: String, seed: PaneState)

    /// The row alphabet: three AGENT states, two COMMAND receipts, and the two quiet rungs.
    private static let badgeSeeds: [Seed] = [
        ("full-release.sh", "/Users/abner/Workplace/herdr", .agentWorking),
        ("plan next move", "/Users/abner/Workplace/herdr", .agentBlocked),
        ("OpenCode", "/Users/abner/Workplace/herdr", .agentDone),
        ("running build task", "/Users/abner/Workplace/herdr", .commandFinished("make", ok: false)),
        ("swift test", "/Users/abner/Workplace/herdr", .commandFinished("swift", ok: true)),
        ("vim Package.swift", "/Users/abner/Workplace/herdr", .shell("vim")),
        ("abner@MacBook-AB:…", "/Users/abner/Workplace/herdr", .shell("zsh")),
    ]

    /// Five single-pane tabs across three project cwds, so By-Project yields three sections.
    private static let groupedSeeds: [Seed] = [
        ("full-release.sh", "/Users/abner/Workplace/herdr", .shell("zsh")),
        ("running build task", "/Users/abner/Workplace/herdr", .agentWorking),
        ("plan next move", "/Users/abner/Workplace/slopdesk", .agentBlocked),
        ("OpenCode", "/Users/abner/Workplace/slopdesk", .agentDone),
        ("abner@MacBook-AB", "/Users/abner/scratch", .shell("zsh")),
    ]

    /// A headless `.tree` store — one single-pane tab per seed, each parked at its cwd and driven into
    /// its state through the store's own setters.
    private func makeStore(seeds: [Seed], activeIndex: Int) -> WorkspaceStore {
        // `Tab` is ambiguous here: SwiftUI (macOS 15+) ships its own, and this file `@testable
        // import`s `SlopDeskWorkspaceCore`. Qualify to the workspace domain type.
        var tabs: [SlopDeskWorkspaceModel.Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for seed in seeds {
            let pane = PaneID()
            // `userRenamed` so the seeded title WINS the rail's title precedence: without it an
            // at-root terminal titles by program, and every row in the sheet reads "Terminal".
            var spec = PaneSpec(kind: .terminal, title: seed.title)
            spec.userRenamed = true
            specs[pane] = spec
            tabs.append(
                SlopDeskWorkspaceModel.Tab(title: seed.title, root: .leaf(pane), activePane: pane),
            )
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: activeIndex, specs: specs)
        let store = WorkspaceStore(
            restoringTree: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            makeSession: { seed in MountTestPaneSession(seed.spec) },
            liveVideoCap: 2,
            persistence: nil,
        )
        store.attachLoopbackWorkspaceDocument()
        for (index, seed) in seeds.enumerated() {
            guard let pane = tabs[index].activePane else { continue }
            store.setLastKnownCwd(seed.cwd, for: pane)
            switch seed.seed {
            case .agentWorking:
                store.setAgentStatus(.working, for: pane)
            case .agentBlocked:
                store.setAgentStatus(.needsPermission, for: pane)
            case .agentDone:
                store.setAgentStatus(.done, for: pane)
            case let .commandFinished(name, ok):
                // The receipt's NAME falls back to the foreground process when no OSC-133 block can
                // name the command — which is exactly the headless case here.
                store.setForegroundProcess(name, for: pane)
                store.setCompletionBadge(ok ? .success : .failure, for: pane)
            case let .shell(name):
                store.setForegroundProcess(name, for: pane)
            }
        }
        return store
    }

    /// A busy-but-ordinary repo, so the header's git line has every run to spend width on.
    private func seedGit(_ store: WorkspaceStore, at key: String) {
        store.projectGitSummary[key] = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 1, changedCount: 4, staged: 1,
            modified: 3, untracked: 5, conflicted: 2, stash: 1,
        )
    }

    private func rowView(_ row: RailRow, store: WorkspaceStore) -> MacSidebarRowView {
        MacSidebarRowView(
            row: row, store: store, paneDrag: nil, preventSleep: nil,
            fallbackTitle: PaneChooserRegistry.option(for: row.kind).title,
        )
    }

    // MARK: - The rig

    private func outputDirectory() throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the navigator surfaces")
        }
        return dir
    }

    private func stack() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Slate.Metric.space2
        column.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        return column
    }

    /// Rasterize `view` at @2x on the cream ground and write a PNG. FAILS (does not skip) on a nil
    /// bitmap — reaching here means the env opt-in was set, so nothing rendered is a real regression.
    private func render(
        _ view: NSView, width: CGFloat, height: CGFloat? = nil, to dir: String, named name: String,
        scale: CGFloat = 2,
    ) throws {
        let ground = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height ?? 100))
        ground.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: ground.topAnchor),
            view.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        if let height {
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
        }

        let window = NSWindow(
            contentRect: ground.frame, styleMask: [.borderless], backing: .buffered, defer: false,
        )
        // ⚠️ `.aqua`, and NOT `Slate.glassColorScheme`. The app pins LIGHT app-wide
        // (``SlateAppearancePin``) because the ground is the cream; `glassColorScheme` is the
        // TERMINAL GLASS's local opt-out and names the dark side. A harness that followed it put the
        // window in darkAqua, every dynamic `Slate.Native.Text.*` resolved near-white, and the sheet
        // came out with only the fixed-hue attention runs legible on the cream — which is the exact
        // white-on-cream failure the app-level pin exists to prevent.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = ground
        window.orderFront(nil)
        ground.layoutSubtreeIfNeeded()
        // Auto Layout has settled by here, so the intrinsic height is knowable; grow the window to it
        // when the caller did not name one, then lay out again on the final frame.
        if height == nil {
            window.setContentSize(NSSize(width: width, height: view.fittingSize.height))
            ground.layoutSubtreeIfNeeded()
        }
        ground.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        if let layer = ground.layer { Self.pinContentsScale(layer, scale) }
        // One turn of the run loop so the spinner's first frame exists and every layer has redrawn at
        // the scale just asked for, before anything is photographed.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let size = ground.bounds.size
        guard size.width > 0, size.height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            XCTFail("no bitmap context for \(name)")
            return
        }
        rep.size = size
        // ⚠️ NO y-flip. `NSGraphicsContext(bitmapImageRep:)` already hands back a context whose CTM
        // is top-left-down, which is the space `CALayer.render(in:)` draws in — adding the usual
        // `translate + scale(1, -1)` on top of it photographs the whole sheet upside down (and every
        // glyph mirrored), which is exactly what the first cut of this rig produced.
        context.cgContext.scaleBy(x: scale, y: scale)
        ground.layer?.render(in: context.cgContext)
        window.orderOut(nil)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("no PNG for \(name)")
            return
        }
        let out = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try png.write(to: out)
        print("SLOPDESK_SNAPSHOT_WRITTEN \(out.path)")
    }

    /// Raise the whole layer tree's backing resolution — see this file's header.
    private static func pinContentsScale(_ layer: CALayer, _ scale: CGFloat) {
        layer.contentsScale = scale
        layer.rasterizationScale = scale
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { pinContentsScale($0, scale) }
    }
}
