// L2SnapshotOdiffTests — a HEADLESS snapshot-odiff harness for the L2 chrome (WindowTopBar +
// VerticalTabRail). INFORMATIONAL, NOT A GATE: it renders each view with `ImageRenderer` at scale 1.0,
// writes the PNGs to the scratchpad warp-shots dir, runs `odiff` against the cropped live-Warp reference
// regions, and LOGS the reported diff percentage. It NEVER `XCTFail`s on a pixel delta — pixel parity is
// driven toward in later layers; this just produces the numbers + artifacts so we can iterate.
//
// Hang-safety: it builds a tree-backed `WorkspaceStore` with a dummy session factory (the same pattern as
// RailRowsBuilderTests) — no socket, PTY, Ghostty, VideoToolbox, or Metal is ever instantiated.
//
// The whole body is `#if os(macOS)` + guarded on ImageRenderer + a present odiff binary, and SKIPS
// (never fails) when any precondition is missing, so it stays green in every environment.

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import SwiftUI
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

#if os(macOS)
@MainActor
final class L2SnapshotOdiffTests: XCTestCase {
    // MARK: Output / reference locations (the orchestrator-provided scratchpad)

    private static let shotsDir =
        "/private/tmp/claude-501/-Volumes-Lacie-Workspace-oss-aislopdesk/" +
        "5361f08a-7ef1-47d1-bede-28cb51f4b4eb/scratchpad/warp-shots"
    private static let odiffBinary = "/opt/homebrew/bin/odiff"

    // MARK: Deterministic store (matches the live-Warp screenshot)

    /// A minimal `PaneSessionHandle` so the harness can build a tree-backed store with NO socket, PTY,
    /// Ghostty, or video stack (hang-safety rule).
    private final class DummyPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
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

    /// Build the seeded tree: a single session, single tab, three terminal panes whose
    /// titles/cwds/agent-status mirror the reference screenshot —
    ///   row 1 (ACTIVE):   "✳ Claude Code"           / "~/.config"  · status .working (agent brand)
    ///   row 2:            "..s-Mac-Studio:~/.config" / "~/.config"  · status .none   (plain terminal)
    ///   row 3:            "..s-Mac-Studio:~/.config" / "~/.config"  · status .none
    private func makeSeededStore() -> (WorkspaceStore, [PaneID]) {
        let p1 = PaneID(), p2 = PaneID(), p3 = PaneID()
        func spec(_ title: String, cwd: String) -> PaneSpec {
            PaneSpec(kind: .terminal, title: title, lastKnownCwd: cwd, lastKnownTitle: title)
        }
        let specs: [PaneID: PaneSpec] = [
            p1: spec("✳ Claude Code", cwd: "~/.config"),
            p2: spec("..s-Mac-Studio:~/.config", cwd: "~/.config"),
            p3: spec("..s-Mac-Studio:~/.config", cwd: "~/.config"),
        ]
        // One tab whose tree is the three leaves stacked; p1 is the active pane.
        let tab = Tab(
            root: .split(
                id: SplitNodeID(),
                axis: .vertical,
                children: [
                    WeightedChild(weight: .flex(1), node: .leaf(p1)),
                    WeightedChild(weight: .flex(1), node: .leaf(p2)),
                    WeightedChild(weight: .flex(1), node: .leaf(p3)),
                ],
            ),
            activePane: p1,
        )
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { DummyPaneSession(spec: $0) },
        )
        // Tint row 1 as a working agent so the brand circle + status badge render.
        store.paneAgentStatus[p1] = .working
        return (store, [p1, p2, p3])
    }

    // MARK: Render helpers

    /// Render `view` to a 1× PNG of exactly `size` and write it to `outPath`. Returns false (skip) when
    /// `ImageRenderer` cannot produce a bitmap in this environment.
    private func renderPNG(_ view: some View, size: CGSize, to outPath: String) -> Bool {
        let renderer = ImageRenderer(
            content:
            view
                .environment(\.theme, DesignTokens(theme: WarpTheme()))
                .frame(width: size.width, height: size.height)
                .background(Color.black), // window bg = #000 (so transparent edges match Warp)
        )
        renderer.scale = 1.0
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: size.width, height: size.height)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: outPath)) } catch { return false }
        return true
    }

    /// Run odiff for one (ref, render) pair, returning a human-readable diff summary line, or nil if odiff
    /// could not run / a reference is missing. Always informational — the harness never asserts on it.
    @discardableResult
    private func runOdiff(ref: String, render: String, diffOut: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.odiffBinary) else { return "odiff binary not present" }
        guard fm.fileExists(atPath: ref) else { return "reference missing: \(ref)" }
        guard fm.fileExists(atPath: render) else { return "render missing: \(render)" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.odiffBinary)
        proc.arguments = ["--antialiasing", "--threshold", "0.1", ref, render, diffOut]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return "odiff launch failed: \(error)" }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The two snapshots

    func testSnapshotTopBarAndRailDiffVsWarp() throws {
        Fonts.register()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        let (store, _) = makeSeededStore()

        // --- Top bar: 1280 × 35 (34 bar + 1 border). ---
        let topBar = WindowTopBar(
            sidebarCollapsed: false,
            onToggleSidebar: {},
            onOpenSettings: {},
            onOpenOmnibar: {},
            hasUnread: false,
        )
        let topBarPath = Self.shotsDir + "/render-topbar.png"
        let topBarRendered = renderPNG(topBar, size: CGSize(width: 1280, height: 35), to: topBarPath)
        guard topBarRendered else { throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)") }

        // --- Vertical rail: 248 × 765. ---
        // NOTE: the real `VerticalTabRail` uses a `ScrollView { LazyVStack }` + an interactive `TextField`.
        // `ImageRenderer` (offscreen, no scroll geometry, no first-responder) does NOT materialize the lazy
        // rows and paints the editable `TextField` as a yellow "unavailable" fill. So we render TWO things:
        //   render-rail.png      — the verbatim `VerticalTabRail` (documents the ImageRenderer limitation).
        //   render-rail-rows.png — the SAME real L2 components (`RailControlBarStatic` mirror + real
        //                          `TabRow`s) in an EAGER `VStack`, which IS the representative rail diff.
        let rail = VerticalTabRail(store: store)
        let railPath = Self.shotsDir + "/render-rail.png"
        let railRendered = renderPNG(rail, size: CGSize(width: 248, height: 765), to: railPath)
        XCTAssertTrue(railRendered, "rail render should succeed once the top bar did")

        // Eager, ImageRenderer-friendly mirror of the rail body using the REAL TabRow component.
        let railRows = RailEagerSnapshot(rows: RailRowsBuilder.rows(for: store))
        let railRowsPath = Self.shotsDir + "/render-rail-rows.png"
        _ = renderPNG(railRows, size: CGSize(width: 248, height: 765), to: railRowsPath)

        // --- odiff (informational) ---
        // Top bar: compare against the TRAFFIC-LIGHT-EXCLUDED reference. We crop our render to x≥80 too so
        // both inputs are the same 1200×35 region (our render has no OS traffic lights on the left).
        let topBarNoTL = Self.shotsDir + "/render-topbar-noTL.png"
        cropRight80(src: topBarPath, dst: topBarNoTL, fullWidth: 1280, height: 35)

        let topBarSummary = runOdiff(
            ref: Self.shotsDir + "/ref-topbar-noTL.png",
            render: topBarNoTL,
            diffOut: Self.shotsDir + "/diff-topbar.png",
        )
        let railSummary = runOdiff(
            ref: Self.shotsDir + "/ref-rail.png",
            render: railPath,
            diffOut: Self.shotsDir + "/diff-rail.png",
        )
        let railRowsSummary = runOdiff(
            ref: Self.shotsDir + "/ref-rail.png",
            render: railRowsPath,
            diffOut: Self.shotsDir + "/diff-rail-rows.png",
        )

        // Log the numbers — this is the deliverable, NOT a gate.
        print("=== L2 SNAPSHOT ODIFF (informational) ===")
        print("TOPBAR (ex-trafficlights, 1200x35):       \(topBarSummary ?? "n/a")")
        print("RAIL   verbatim (ImageRenderer limited):  \(railSummary ?? "n/a")")
        print("RAIL   eager rows (representative):        \(railRowsSummary ?? "n/a")")
        print("artifacts in: \(Self.shotsDir)")

        // The test is GREEN as long as the renders were produced — odiff deltas never fail it.
        XCTAssertTrue(fm.fileExists(atPath: topBarPath))
        XCTAssertTrue(fm.fileExists(atPath: railPath))
    }

    /// An EAGER (ImageRenderer-friendly) mirror of `VerticalTabRail.body`: the same panel surface +
    /// a static control-bar row (the interactive `TextField` is shown as static placeholder text so it
    /// doesn't paint the offscreen "unavailable" fill) + the REAL `TabRow` components in a plain `VStack`
    /// (no `LazyVStack`/`ScrollView`, which don't materialize rows offscreen). Everything else — sizing,
    /// padding, surface, the rows themselves — is the production L2 code.
    private struct RailEagerSnapshot: View {
        @Environment(\.theme) private var theme
        let rows: [RailRow]

        var body: some View {
            VStack(spacing: 0) {
                // Static control-bar mirror (search glyph + placeholder + view-options + "+").
                HStack(spacing: WarpSpace.s) {
                    HStack(spacing: WarpSpace.xs + WarpSpace.xs) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12 * 0.85))
                            .foregroundStyle(theme.textSub)
                            .frame(width: 12, height: 12)
                        Text("Search tabs…")
                            .font(WarpType.ui(WarpType.uiSize))
                            .foregroundStyle(theme.textSub)
                        Spacer(minLength: 0)
                    }
                    IconButton(systemName: "line.3.horizontal.decrease", help: "View options", action: {})
                        .frame(width: WarpSize.controlHeightSmall, height: WarpSize.controlHeightSmall)
                    IconButton(systemName: "plus", help: "New tab", action: {})
                        .frame(width: WarpSize.controlHeightSmall, height: WarpSize.controlHeightSmall)
                }
                .padding(.horizontal, WarpSpace.m)
                .padding(.vertical, WarpSpace.s)

                VStack(spacing: WarpSpace.s) {
                    ForEach(rows) { row in
                        TabRow(row: row, onSelect: {}, onClose: {})
                    }
                }
                .padding(.horizontal, WarpSpace.m)
                .padding(.bottom, WarpSpace.m)

                Spacer(minLength: 0)
            }
            .frame(width: WarpSize.railWidth)
            .background(theme.fgOverlay1)
            .background(
                theme.surface1.opacity(0.9),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: WarpRadius.dialog,
                    topTrailingRadius: WarpRadius.dialog,
                ),
            )
        }
    }

    /// Crop the leftmost `keep` (80) px off a PNG, writing the remaining right region. Used to drop the
    /// area where the OS traffic lights sit in the reference (our render has none there).
    private func cropRight80(src: String, dst: String, fullWidth: CGFloat, height: CGFloat) {
        guard let img = NSImage(contentsOfFile: src),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rect = CGRect(x: 80, y: 0, width: fullWidth - 80, height: height)
        guard let sub = cg.cropping(to: rect) else { return }
        let rep = NSBitmapImageRep(cgImage: sub)
        rep.size = NSSize(width: rect.width, height: rect.height)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: dst))
    }
}
#endif
