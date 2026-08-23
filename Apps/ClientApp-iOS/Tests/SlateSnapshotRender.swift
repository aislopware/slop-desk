// Visual-verification harness — renders a chrome showcase to a PNG via ImageRenderer so the
// palette + component kit can be eyeballed headlessly (no GUI/TCC). Opt-in: INERT unless the env var
// `SLOPDESK_SNAPSHOT_OUT=<path.png>` is set, so the suite / `make check` never write a file. Run on demand:
//   SIMCTL_CHILD_SLOPDESK_SNAPSHOT_OUT="$PWD/.build/showcase.png" slopdesk-gate ios-tests
// It renders a hand-built mock of the real chrome from the SAME token layer + component kit, so a palette /
// component regression shows up visually. It is NOT a pixel-diff CI gate.
//
// docs/56 F4c: this is the PHONE's rig, in the iOS-triple bundle, because the views it photographs
// (``StatusDotView``, ``AgentSpinnerView``, ``TabBadgeView``, the island chips, ``ViCursorOverlay``) are
// `SlopDeskPhoneUI` — `#if os(iOS)` end to end, compiled by nothing else. The Mac photographs its own
// AppKit chrome in `Tests/SlopDeskMacUITests/MacChromeSnapshotRender` / `MacRailStatusRollupRender`.
// The `SIMCTL_CHILD_` prefix above is `simctl`'s: it forwards the variable into the process spawned inside
// the simulator with the prefix stripped, so the tests read the bare `SLOPDESK_*` names they always read,
// and the PNGs land on the HOST filesystem (the `xctest` agent is not app-sandboxed). `Slate` is
// `@testable`-imported below for its `package` design floor: this bundle is an Xcode target OUTSIDE the
// SwiftPM package, so a plain `import` cannot see `Slate.Surface` / `Slate.Metric` / `Slate.Native` at all.
//
// ⚠️⚠️ EVERY FIXTURE HERE STANDS ON ``Slate/Surface/field`` — THE GROUND, the authored cream
// `#FFFBEB` every column of this app paints (ONE ISLAND law 4). NOT `Surface.ground`, which is the
// SEMANTIC system backdrop (`secondarySystemBackground` here, `underPageBackgroundColor` and a measured
// `#A1A09F` on the Mac): a tone that appears NOWHERE in the shipping chrome. Every render in this file
// used to stand on that grey (fixed 2026-08-11), which quietly voided the one job the harness has — an
// ink judged against a ground it will never be drawn on is not judged at all, and the cream is the
// harder one (the status ramp measures ~2.05–2.12 as ink on it, see `design-ink`). If a future render
// comes out grey, this is the line it crossed.

import SFSafeSymbols
import SlopDeskTerminal
import SlopDeskWorkspaceModel
import SwiftUI
import UIKit
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskPhoneUI
@testable import SlopDeskSlate
@testable import SlopDeskWorkspaceCore

final class SlateSnapshotRender: XCTestCase {
    @MainActor
    func testRenderSlateShowcase() throws {
        // Opt-in only: inert under `make check-ios-tests` / `make check` unless an output path is requested.
        guard let out = ProcessInfo.processInfo.environment["SLOPDESK_SNAPSHOT_OUT"] else {
            throw XCTSkip("set SLOPDESK_SNAPSHOT_OUT=<path.png> to render the showcase")
        }
        let renderer = ImageRenderer(content: SlateShowcase().frame(width: 920, height: 560))
        renderer.scale = 2
        guard let png = renderer.uiImage?.pngData() else {
            XCTFail("ImageRenderer produced no image")
            return
        }
        try png.write(to: URL(fileURLWithPath: out))
        print("SLOPDESK_SNAPSHOT_WRITTEN \(out)")
    }

    // MARK: - Opt-in render of the status marks

    /// Renders the WHOLE mark vocabulary at true size and magnified (`status-marks.png`) — the only
    /// way to check the transcription of otty's artwork, since a mistyped coordinate parses happily
    /// and is invisible in the values.
    ///
    /// ⚠️ Rasterized by `ImageRenderer`, like every other sheet here. The Mac's copy of this rig goes
    /// through an offscreen `NSWindow` because its tiles are `NSView`s (`MacRailStatusMarksView`) and
    /// `ImageRenderer` draws an unavailable-placeholder tile for a representable — a constraint that does
    /// not exist on the phone, where the mark, the spinner cell and the privilege badge are all pure
    /// SwiftUI. If a tile in this sheet ever becomes a `UIViewRepresentable`, this render starts lying
    /// (an empty box in a PNG that still gets written), and the fix is a hosted capture, not a caption.
    ///
    /// ⚠️ The working mark is PINNED to a phase list here. A still of a wall-clock spinner catches
    /// whatever moment the shutter lands on, which tells a reviewer nothing about the shape of the
    /// motion — the filmstrip is one lap laid out flat.
    ///
    /// SAME opt-in idiom as the other renders; inert unless `SLOPDESK_TABROW_SNAPSHOT_DIR=<dir>`.
    /// Pure SwiftUI — no video/Metal (the hang-safety rule).
    @MainActor
    func testRenderStatusMarks() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the status marks")
        }
        let marks: [(String, StatusDotStyle)] = [
            ("resting", StatusDotStyle(ink: Slate.Text.secondary)),
            ("question", StatusDotStyle(ink: Slate.StatusInk.warn, mark: .awaiting)),
            ("agent finish", StatusDotStyle(ink: Slate.StatusInk.ok, mark: .agentFinish)),
        ]
        // The ink candidates for the thinking cell, so the choice is settled on pixels rather
        // than on the argument for each one. `warn` — herdr's own yellow — is the shipping answer.
        // ⚠️ systemYellow is in the list because it SHIPPED for half a day on 2026-08-11 and was
        // reverted on hardware: it separates the cell from the hand's amber, and measures 1.46 on
        // the cream doing it — under the band rollup's own DISABLED slot.
        let cellInk = Slate.StatusInk.warn
        let inks: [(String, Color)] = [
            ("StatusInk.warn — herdr's yellow (shipping)", Slate.StatusInk.warn),
            ("StatusInk.notice — a rung louder, if yellow reads flat", Slate.StatusInk.notice),
            ("systemYellow — tried 2026-08-11, reverted at 1.46 on the cream", Slate.Status.warn),
        ]
        let phases: [Double] = (0..<8).map { Double($0) / 8 }
        let sheet = VStack(alignment: .leading, spacing: 16) {
            let low = Int(StatusDot.lapPeriodRange.lowerBound * 1000)
            let high = Int(StatusDot.lapPeriodRange.upperBound * 1000)
            captioned("one lap, flattened — true size, then 4× (the tempo wanders \(low)–\(high)ms/lap)") {
                VStack(alignment: .leading, spacing: 8) {
                    self.strip(phases, ink: cellInk, zoom: 1, spacing: 10)
                    self.strip(phases, ink: cellInk, zoom: 4, spacing: 8)
                }
            }
            captioned("the WANDER — 16 frames 250ms apart, so the hole covers uneven ground per step") {
                self.strip(Self.wanderFrames(), ink: cellInk, zoom: 3, spacing: 8)
            }
            ForEach(inks.indices, id: \.self) { index in
                self.captioned("cell ink — \(inks[index].0)") {
                    HStack(spacing: 16) {
                        self.strip([0.875, 0, 0.125], ink: inks[index].1, zoom: 1, spacing: 8)
                        self.cell(ink: inks[index].1, phase: 0.05, zoom: 6)
                        // Beside the marks it has to coexist with, at true size.
                        HStack(spacing: 10) {
                            ForEach(marks.indices, id: \.self) { self.still(marks[$0].1) }
                        }
                    }
                }
            }
            captioned("the settled marks at 8× — \(marks.map(\.0).joined(separator: " · "))") {
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
        .frame(width: 900, alignment: .leading)
        .background(Slate.Surface.field)
        try render(sheet, size: CGSize(width: 900, height: 940), to: dir, named: "status-marks.png")
    }

    /// The mark sampled at EQUAL wall-clock steps, off the shipping phase function — so the strip
    /// shows the one thing a per-lap filmstrip cannot: the hole covering different ground each
    /// quarter-second, because the tempo wanders (``StatusDot/tempoSwells``). Read as spacing, not as
    /// shape: even steps here would mean the wander has been flattened back to a constant tempo.
    @MainActor
    private static func wanderFrames() -> [Double] {
        (0..<16).map { AgentSpinner.phase(at: Date(timeIntervalSinceReferenceDate: Double($0) / 4)) }
    }

    /// One lap laid out flat — the same view the rail mounts, held at each of the EIGHT points the
    /// braille set itself has, so the strip reads as `⣾⣽⣻⢿⡿⣟⣯⣷` and can be compared to it directly.
    @MainActor
    private func strip(
        _ phases: [Double], ink: Color, zoom: CGFloat, spacing: CGFloat,
    ) -> some View {
        HStack(spacing: spacing) {
            ForEach(phases.indices, id: \.self) { index in
                self.cell(ink: ink, phase: phases[index], zoom: zoom)
            }
        }
    }

    /// One pinned cell, DRAWN at the magnified size rather than `scaleEffect`-ed to it — feeding
    /// the zoom in keeps the geometry vector all the way down, where a scaled tile is a blown-up
    /// 14pt bitmap and reads as a smudge that is nothing like what the rail draws.
    @MainActor
    private func cell(ink: Color, phase: Double, zoom: CGFloat) -> some View {
        AgentSpinnerView(ink: ink, zoom: zoom, pinnedPhase: phase)
    }

    // MARK: - Opt-in render of the island chip stack

    /// Renders the chip family at the FOOT OF THE ISLAND, over the glass they actually stand on —
    /// the check this round exists for. The chips previously drew in the light-pinned semantic tiers
    /// (`Slate.Text` / `Slate.Surface`) while mounted on the window root, which never enters the glass
    /// colour scope: dark ink on a fill that barely registered over `#22212C`. Legibility is a PIXEL
    /// question, so it gets a PNG — sample the chip's ink against the plate and the plate against the
    /// glass. The mock mirrors ``ContentColumn``'s mount exactly (bottom-aligned overlay over the
    /// glass-scoped canvas, `Metric/islandChipInset` of clearance) so the standoff is measurable too.
    ///
    /// SAME opt-in idiom as the other renders; inert unless `SLOPDESK_CHIP_SNAPSHOT_DIR=<dir>`.
    @MainActor
    func testRenderIslandChips() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_CHIP_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_CHIP_SNAPSHOT_DIR=<dir> to render the island chip stack")
        }
        let mock = IslandChipMock()
        try render(mock, size: CGSize(width: 520, height: 300), to: dir, named: "island-chips.png")
        try render(
            mock.frame(width: 520, height: 300).scaleEffect(3, anchor: .bottom),
            size: CGSize(width: 520, height: 300), to: dir, named: "island-chips-3x.png",
        )
        // A NATIVE-scale close-up beside the magnified one: the 3× raster above is an interpolation, so an
        // edge artefact seen only there proves nothing. This is where the `Capsule()` edge ticks were
        // confirmed as real geometry and the `RoundedRectangle` spelling was chosen (2026-08-11).
        try render(
            mock.frame(width: 260, height: 300), size: CGSize(width: 260, height: 300), to: dir,
            named: "island-chips-native.png", scale: 6,
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

    // MARK: - Opt-in render of the identity BEDS (the one surface no other render covers)

    /// Renders every bed in ``Slate/ProjectTint`` — the five identity sources plus the keyless
    /// neutral the connection island wears — on the AUTHORED cream ground, each carrying a git line
    /// so the two things that have to stay in balance are in one frame: how much colour the bed
    /// spends, and how far the status runs standing on it rise off it.
    ///
    /// It exists because the bed is mounted only by the Mac's `MacSidebarIslandView` / `MacTabStrip`
    /// / `MacConnectionIsland`, so every render in this file draws the rail with NO bed under it —
    /// `Opacity.bed` could move and nothing here would show it. SAME opt-in idiom; writes
    /// `project-beds.png` into `SLOPDESK_TABROW_SNAPSHOT_DIR`.
    @MainActor
    func testRenderProjectBeds() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the identity beds")
        }
        let dirt = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 2, behind: 1, changedCount: 9, staged: 3,
            modified: 4, untracked: 5, conflicted: 1, stash: 2,
        )
        let beds: [(String, Color)] = (0..<Slate.ProjectTint.registerCount).map {
            ("bed \($0)", Slate.ProjectTint.register[$0].opacity(Slate.Opacity.bed))
        } + [("neutral (connection island)", Slate.ProjectTint.neutralBed)]
        let panel = VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            ForEach(beds, id: \.0) { name, tint in
                SlateProjectIsland(tint: tint) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                            .foregroundStyle(Slate.Text.secondary)
                        // The dialect itself lives in ``SidebarGitLine`` (ClientCore) and its shipping
                        // renderer is AppKit's `MacGitLineView`; what this bed panel needs is the
                        // status runs' INK standing on the tint, so the segments are spelled straight
                        // into `Text` here rather than mirroring the header's layout.
                        self.gitDetailLine(SidebarGitLine.segments(dirt))
                            .font(Slate.Typeface.instrument(Slate.Typeface.small))
                        // The quiet rung is the one this alpha is priced in — see `Text.tertiary`.
                        Text("zsh · the quiet rung on this bed")
                            .font(Slate.Typeface.instrument(Slate.Typeface.small))
                            .foregroundStyle(Slate.Text.tertiary)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.theme.ground) // the AUTHORED cream, not the system semantic
        try render(
            panel, size: CGSize(width: Slate.Metric.sidebarWidth, height: 400),
            to: dir, named: "project-beds.png",
        )
    }

    /// The git runs, each in its own role's ink, joined by a space — see the call site.
    @MainActor
    private func gitDetailLine(_ segments: [GitSegment]) -> Text {
        segments.enumerated().reduce(Text("")) { line, pair in
            let run = Text(pair.element.text)
                .foregroundColor(Color(slateNative: Slate.Native.gitInk(pair.element.ink)))
            return pair.offset == 0 ? run : line + Text(" ") + run
        }
    }

    // MARK: - Opt-in render of the status INK set on all three grounds

    /// Renders ``Slate/StatusInk``'s six roles as the thing they actually are — 10pt instrument text
    /// and a small mark — on EVERY ground the set was solved against: the plain cream, the deepest
    /// project bed (the worst ground a rail run ever stands on), and the glass face the compact island
    /// flips to. Each row carries ``Slate/Text/tertiary`` beside it, because the complaint that started
    /// this was never absolute — it was that the quiet rung out-read the loud one (2.05 vs 5.16).
    ///
    /// The dark block is the only place the dark half of the pair can be seen headlessly: nothing else
    /// in this file flips `colorScheme`, so that side could drift with the whole suite green.
    /// Writes `status-ink.png` into `SLOPDESK_TABROW_SNAPSHOT_DIR`.
    @MainActor
    func testRenderStatusInk() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the status ink set")
        }
        let roles: [(String, Color)] = [
            ("ok  +staged", Slate.StatusInk.ok),
            ("warn  !modified", Slate.StatusInk.warn),
            ("notice  ?untracked", Slate.StatusInk.notice),
            ("err  ~conflicted", Slate.StatusInk.err),
            ("info  up/down", Slate.StatusInk.info),
            ("aside  $stash", Slate.StatusInk.aside),
        ]
        @MainActor
        func block(_ title: String, ground: Color, bed: Color? = nil, dark: Bool) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                ForEach(roles, id: \.0) { name, ink in
                    HStack(spacing: 6) {
                        Circle().fill(ink).frame(width: 7, height: 7)
                        Text(name)
                            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                            .foregroundStyle(ink)
                        Text("· quiet")
                            .font(Slate.Typeface.instrument(Slate.Typeface.small))
                            .foregroundStyle(Slate.Text.tertiary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The bed is a WASH over the ground, exactly as the island composites it — the light
                // side of the set is solved on that composite, not on either layer alone.
                ZStack {
                    ground
                    if let bed { bed }
                }
            }
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        let panel = VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            block("on the cream", ground: Slate.theme.ground, dark: false)
            block(
                "on the deepest bed",
                ground: Slate.theme.ground,
                // Index 2 is the register's indigo — the darkest composite of the five.
                bed: Slate.ProjectTint.register[2].opacity(Slate.Opacity.bed),
                dark: false,
            )
            block("on the glass face", ground: Slate.Surface.terminal, dark: true)
        }
        .padding(8)
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.theme.ground)
        try render(
            panel, size: CGSize(width: Slate.Metric.sidebarWidth, height: 420),
            to: dir, named: "status-ink.png",
        )
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
        .background(Slate.Surface.field)
        try withExtendedLifetime((ascii, wide)) {
            try render(panels, size: CGSize(width: 560, height: 260), to: dir, named: "vi-cursor.png")
        }

        let bars = VStack(alignment: .leading, spacing: 16) {
            ViKeyHintBar().frame(width: 760, alignment: .leading)
            ViKeyHintBar().frame(width: 470, alignment: .leading)
            ViKeyHintBar().frame(width: 300, alignment: .leading)
        }
        .padding(16)
        .background(Slate.Surface.field)
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

    /// Rasterize `content` and write a PNG into `dir`. Fails (not skips) if the renderer yields nothing —
    /// reaching here means the env opt-in was set, so a nil image is a real regression in the panel's layout.
    ///
    /// ONE rasterizer for every sheet in this file, which is only honest because every tile it draws is
    /// pure SwiftUI. `ImageRenderer` refuses a representable and paints an unavailable placeholder where
    /// it should be, so the Mac's rig hosts its `NSView` marks in an offscreen window instead
    /// (`MacChromeSnapshotRender`); nothing on the phone side needs that, and carrying the window,
    /// the appearance pin and the `contentsScale` walk over here would be machinery for a constraint
    /// this bundle does not have.
    ///
    /// `scale` is the render scale, not a `scaleEffect`: at 1× a magnified tile would be a blown-up 14pt
    /// bitmap rather than the vector redrawn, which is the whole point of the zoomed strips above.
    @MainActor
    private func render(
        _ content: some View, size: CGSize, to dir: String, named name: String, scale: CGFloat = 2,
    ) throws {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let png = renderer.uiImage?.pngData() else {
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
        .background(Slate.Surface.field)
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
            // The rows are DRAWN, not mounted: the shipping navigator row is AppKit
            // (`MacSidebarRowView`), and this showcase is a token/geometry mock rather than a mount of
            // the real column — `MacChromeSnapshotRender` photographs that.
            showcaseRow("~/slopdesk", active: true, slot: "zsh")
            showcaseRow("build", active: false, slot: "zsh")
            showcaseRow("Remote window", active: false, slot: nil)
            Spacer()
        }
        .padding(Slate.Metric.space2)
        .frame(width: Slate.Metric.sidebarWidth)
        .background(Slate.Surface.field)
    }

    /// One navigator row's chrome at showcase fidelity — the title, the trailing metadata slot, and
    /// the selected row's card.
    private func showcaseRow(_ title: String, active: Bool, slot: String?) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(title)
                .font(.system(size: Slate.Typeface.footnote, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Slate.Text.primary : Slate.Text.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let slot {
                Text(slot)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
            }
        }
        .padding(.horizontal, Slate.Metric.islandRail)
        .frame(height: Slate.Metric.heightTabRow)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.islandRadiusCompact)
                .fill(active ? Slate.Surface.island : .clear),
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

/// A pane MOCK for the island-chip render: the glass canvas under a bottom-aligned chip stack, exactly
/// as ``ContentColumn``'s `paneArea` composes it — the same overlay alignment, the same
/// `Metric/islandChipInset` clearance, the same glass colour scope. The chips are the REAL views (no
/// store / coordinator is needed to draw one), so what the PNG shows is what the app draws: the
/// question the render answers is whether their ink survives the glass, and where the stack sits
/// relative to the island's foot. Stand-in "cells" run to the canvas's bottom edge so a chip parked on
/// the live prompt line would be unmistakable.
@MainActor
private struct IslandChipMock: View {
    var body: some View {
        cells
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Slate.Metric.space2)
            .background(Slate.Surface.terminal)
            .overlay(alignment: .bottom) {
                VStack(spacing: Slate.Metric.space2) {
                    CopyReceiptChip(receipt: CopyReceipt(text: sampleCopy, epoch: 1), onExpire: {})
                    // The keycap notice and the plain one side by side: the pair is what pins the two
                    // emphasis rules against each other (a cap takes the hero rung and kills the dot;
                    // without one the detail takes it back).
                    NoticeChip(
                        notice: ChipNotice(
                            label: "Tab closed", keycap: "⇧⌘T", detail: "reopens", epoch: 1,
                            dwell: .seconds(3),
                        ),
                        onExpire: {},
                    )
                    NoticeChip(
                        notice: ChipNotice(
                            label: "Jumped", detail: "hostd · logs", epoch: 1, dwell: .seconds(3),
                        ),
                        onExpire: {},
                    )
                    ConnectionAlertChip(
                        alert: WorkspaceConnectionAlert(count: 1, worst: .reconnecting, worstPane: PaneID()),
                        onTap: {},
                    )
                    ConnectionAlertChip(
                        alert: WorkspaceConnectionAlert(count: 2, worst: .unreachable, worstPane: PaneID()),
                        onTap: {},
                    )
                }
                .padding(.bottom, Slate.Metric.islandChipInset)
            }
            .environment(\.colorScheme, Slate.glassColorScheme)
    }

    /// Enough text for a plural receipt (`Copied · N lines`), assembled rather than counted by hand.
    private var sampleCopy: String {
        String(repeating: "swift build\n", count: 100)
    }

    /// Stand-in cells — full-bleed rows of the terminal's own ink, so the canvas's bottom edge (and any
    /// chip sitting on it) is unmistakable in the render.
    private var cells: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<14, id: \.self) { row in
                Rectangle()
                    .fill(Slate.Terminal.ink2)
                    .frame(height: Slate.Metric.hairline * 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, row.isMultiple(of: 3) ? Slate.Metric.space4 : 0)
                    .opacity(Slate.Opacity.muted)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
