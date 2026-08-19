// Visual-verification harness — renders a chrome showcase to a PNG via ImageRenderer so the
// palette + component kit can be eyeballed headlessly (no GUI/TCC). Opt-in: INERT unless the env var
// `SLOPDESK_SNAPSHOT_OUT=<path.png>` is set, so `swift test` / `make check` never write a file. Run on demand:
//   SLOPDESK_SNAPSHOT_OUT="$PWD/.build/showcase.png" swift test --filter SlateSnapshotRender
// It renders a hand-built mock of the real chrome from the SAME token layer + component kit, so a palette /
// component regression shows up visually. It is NOT a pixel-diff CI gate.
//
// ⚠️⚠️ EVERY FIXTURE HERE STANDS ON ``Slate/Surface/field`` — THE GROUND, the authored cream
// `#FFFBEB` every column of this app paints (ONE ISLAND law 4). NOT `Surface.ground`, which on macOS
// is the SEMANTIC aux-window backdrop (`underPageBackgroundColor`, measured `#A1A09F`): a mid grey
// that appears NOWHERE in the shipping chrome. Every render in this file used to stand on that grey
// (fixed 2026-08-11), which quietly voided the one job the harness has — an ink judged against a
// grey it will never be drawn on is not judged at all, and the cream is the harder ground (the
// status ramp measures ~2.05–2.12 as ink on it, see `design-ink`). If a future render comes out
// grey, this is the line it crossed.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SFSafeSymbols
import SlopDeskSlate
import SlopDeskTerminal
import SlopDeskWorkspaceModel
import SwiftUI
import XCTest
@testable import SlopDeskClientCore
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

    // MARK: - Opt-in render of the status marks

    /// Renders the WHOLE mark vocabulary at true size and magnified (`status-marks.png`) — the only
    /// way to check the transcription of otty's artwork, since a mistyped coordinate parses happily
    /// and is invisible in the values.
    ///
    /// ⚠️ Rendered through an offscreen WINDOW rather than `ImageRenderer` — an inherited constraint
    /// that no longer binds this sheet (the working mark used to be an AppKit `NSProgressIndicator`,
    /// which `ImageRenderer` substitutes an unavailable-placeholder tile for and which never animates
    /// without a window; the drawn cell is pure SwiftUI). Kept because the other tiles here are still
    /// AppKit-backed and one rasterizer for the whole sheet is one set of pixels to trust.
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
        try renderHosted(sheet, size: CGSize(width: 900, height: 940), to: dir, named: "status-marks.png")
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
        try renderHosted(mock, size: CGSize(width: 520, height: 300), to: dir, named: "island-chips.png")
        try renderHosted(
            mock.frame(width: 520, height: 300).scaleEffect(3, anchor: .bottom),
            size: CGSize(width: 520, height: 300), to: dir, named: "island-chips-3x.png",
        )
        // A NATIVE-scale close-up beside the magnified one: the 3× raster above is an interpolation, so an
        // edge artefact seen only there proves nothing. This is where the `Capsule()` edge ticks were
        // confirmed as real geometry and the `RoundedRectangle` spelling was chosen (2026-08-11).
        try renderHosted(
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

    // MARK: - Opt-in render of the band's status rollup (the ONE claim only pixels can settle)

    /// Renders the sidebar's TOP — the traffic-light band carrying ``RailStatusMarks``, the search
    /// plate, and a project island of drawn row stand-ins — twice, once with all three states lit
    /// and once with only the waiting one. Everything this round changed is a claim about PIXELS that
    /// `RailStatusRollupTests` can only pin the arithmetic behind:
    ///
    ///  * **flush right** — the cluster must end on the SAME vertical line as the search plate under
    ///    it (user-reported 2026-08-11: at the rows' mark column, 18pt further in, it read as a
    ///    cluster that had failed to reach the edge). The plate is in the frame for exactly this, and
    ///    it is drawn here rather than mounted, because the real field is AppKit-backed and the
    ///    hosted path greys the cream (see the file header's ⚠️).
    ///  * **the unlit slots** — three fixed slots means the resting cluster is now the LOUDEST thing
    ///    this band ever draws when nothing is happening. The second column is the check: the two
    ///    unlit marks must sit under the lit one AND under the row titles beside them.
    ///  * **the rung** — the marks share the band's centre line (`bandControlInset` + half a control
    ///    = 20) with the lights, instead of hanging from the island's top edge the way four earlier
    ///    band rounds did. The three discs standing in for the window controls are drawn HERE only;
    ///    AppKit owns the real ones.
    ///  * **the gap** — `markGap` went `space1` → `space2` because at 4pt the three read as one
    ///    object and the pointer missed (user-reported 2026-08-11). Whether they now read as three
    ///    clickable things is exactly the judgement no arithmetic can make.
    ///  * **the collapsed parking spot** — the third panel is the cluster where it lands once the
    ///    column is gone: one gap right of the sidebar toggle's plate, still on the band's centre
    ///    line. Both ends of the travel in one frame, because the claim is that it arrives somewhere
    ///    deliberate rather than merely somewhere.
    ///
    /// SAME opt-in idiom; writes `rail-status-rollup.png` into `SLOPDESK_TABROW_SNAPSHOT_DIR`.
    @MainActor
    func testRenderRailStatusRollup() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the band rollup")
        }
        let width = Slate.Metric.sidebarWidth
        // +300: the captions are wider than the panels they label, and an HStack that overflows
        // its render frame centres — which clipped the FIRST caption off the left edge.
        let size = CGSize(width: width * 2 + collapsedBandWidth + 300, height: 300)
        let sheet = HStack(alignment: .top, spacing: 20) {
            captioned("all three lit") { self.bandPanel(active: RailStatusRollup.order) }
            captioned("only a question waiting — the other two slots unlit") {
                self.bandPanel(active: [.waiting])
            }
            captioned("collapsed — beside the toggle, tabs begin after it") { self.collapsedBandPanel }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // ⚠️ The ground goes on OUTSIDE the render frame's own size, or the strip `render`'s
        // `.frame` adds beyond the content stays UNPAINTED and photographs black.
        .background(Slate.Surface.field) // THE GROUND — see the file header's ⚠️
        // `render`, not `renderHosted`: every part of this frame is pure SwiftUI (the marks, the
        // spinner, the rows, the drawn search plate), and the hosted path composites through a window
        // whose backing greys the authored cream — which would make the one thing this image exists
        // to judge, the GROUND the marks stand on, a lie.
        try render(sheet, size: size, to: dir, named: "rail-status-rollup.png")
    }

    /// One sidebar top at its true width, with `active` lit.
    @MainActor
    private func bandPanel(active: [RailStatusRollup.Kind]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: Slate.Metric.space2) {
                    ForEach([Slate.Status.err, Slate.Status.warn, Slate.Status.ok], id: \.self) {
                        Circle().fill($0).frame(width: 14, height: 14)
                    }
                }
                .padding(.leading, 13) // AppKit's measured light inset (docs: windowControlsInset)
                .padding(.top, 13)
                // ⚠️ Positioned the way the REAL mount positions it — by lead, not by a trailing
                // padding inside the cluster. `RailStatusMarks` is intrinsically sized (three
                // footprints, two gaps) and ``RailStatusRollupMount`` owns where that block stands,
                // so a fixture that spelled the inset itself would stop testing the shipped sum.
                RailStatusMarks(active: active)
                    .padding(.leading, RailStatusRollupMount.lead(
                        collapsed: false, navigatorWidth: Slate.Metric.sidebarWidth,
                    ))
            }
            // ⚠️ `alignment: .top` — the band's contents are SHORTER than the band, and a centring
            // frame slides them down 4pt, which reads as the whole rung sitting low. The real mount
            // in ``NavigatorColumn`` top-aligns for the same reason.
            .frame(height: Slate.Metric.titlebarHeight, alignment: .top)
            searchPlateStandIn
            SlateProjectIsland(tint: Slate.ProjectTint.register[0].opacity(Slate.Opacity.bed)) {
                VStack(alignment: .leading, spacing: 2) {
                    self.rowStandIn(
                        "Claude Code",
                        mark: StatusPresentation.statusDot(working: false, badge: .awaitingInput),
                    )
                    self.rowStandIn("api", mark: StatusPresentation.statusDot(working: true, badge: nil))
                    self.rowStandIn(
                        "web",
                        mark: StatusPresentation.statusDot(
                            working: false, badge: .finished, agentFinish: true,
                        ),
                    )
                    self.rowStandIn("docs", mark: nil)
                }
            }
            .padding(.horizontal, Slate.Metric.space2) // the list's LazyVStack gutter
        }
        .frame(width: Slate.Metric.sidebarWidth)
    }

    /// One navigator ROW's footprint, drawn — the real one is `MacSidebarRowView` (AppKit), which
    /// cannot mount inside a SwiftUI `ImageRenderer` frame, and photographing it is
    /// `MacChromeSnapshotRender`'s job. What this panel needs from a row is only its GEOMETRY: the
    /// island's rail inset, the control height, and the trailing MARK column the band's cluster above
    /// has to line up with. Same reason `searchPlateStandIn` exists.
    @MainActor
    private func rowStandIn(_ title: String, mark: StatusDotStyle?) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(title)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let mark {
                StatusDotView(style: mark)
            } else {
                Color.clear.frame(width: StatusDot.footprint, height: StatusDot.footprint)
            }
        }
        .padding(.horizontal, Slate.Metric.islandRail)
        .frame(height: Slate.Metric.heightTabRow)
    }

    /// Wide enough to show the toggle's slot, the parked cluster, and the start of the tab run that
    /// begins after it.
    @MainActor
    private var collapsedBandWidth: CGFloat {
        RailStatusRollupMount.collapsedTrailingEdge + 120
    }

    /// The band with NO column under it — the traffic lights, the sidebar toggle's plate, and the
    /// cluster at its collapsed parking spot. The toggle is drawn (not mounted) for the same reason
    /// the search plate is: `PlateIconButton` would drag a store-shaped dependency into a fixture
    /// that only needs its FOOTPRINT, which is `Slate.Metric.plate` square on the band's centre line.
    @MainActor
    private var collapsedBandPanel: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: Slate.Metric.space2) {
                ForEach([Slate.Status.err, Slate.Status.warn, Slate.Status.ok], id: \.self) {
                    Circle().fill($0).frame(width: 14, height: 14)
                }
            }
            .padding(.leading, 13)
            .padding(.top, 13)
            Image(systemSymbol: .sidebarLeft)
                .font(.system(size: Slate.Typeface.body, weight: .medium))
                .foregroundStyle(Slate.Text.icon)
                // The plate's FILL is `.clear` at rest (``SlatePlateStyle``) — only its footprint
                // is in play here, and that is what the collapsed lead is measured from.
                .frame(width: Slate.Metric.plate, height: Slate.Metric.plate)
                .padding(.leading, Slate.Metric.windowControlsLead)
                .padding(.top, Slate.Metric.bandControlInset)
            RailStatusMarks(active: [.waiting, .working])
                .padding(.leading, RailStatusRollupMount.collapsedLead)
            // ⚠️ The first horizontal tab, stood in for at the inset the band
            // (`SlopDeskMacUI/MacTitlebarBand`) actually spends. This is the collision the round fixed (user-reported 2026-08-11: the strip
            // reserved the TOGGLE's slot only, so the marks were drawn over the first tab's title)
            // — and a collision between two positions is only ever settled by looking.
            Text("Kiểm tra và lên kế h…")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.primary)
                .padding(.horizontal, Slate.Metric.space2)
                .frame(height: Slate.Metric.heightControl)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .fill(Slate.ProjectTint.register[0].opacity(Slate.Opacity.bed)),
                )
                .padding(.leading, RailStatusRollupMount.collapsedTrailingEdge)
                .padding(.top, Slate.Metric.bandControlInset)
        }
        .frame(width: collapsedBandWidth, height: Slate.Metric.titlebarHeight, alignment: .topLeading)
    }

    /// The search field's PLATE, drawn — the real one wraps `SlateSearchField`, which is
    /// AppKit-backed and would force the hosted path. Only its geometry matters here (the plate's
    /// height, and the gutter its trailing edge lands on), and that is copied from
    /// ``NavigatorColumn`` verbatim, ``RailStatusRollup/trailingInset`` included: the whole point of
    /// having it in frame is that the band above it must end on the same line.
    @MainActor
    private var searchPlateStandIn: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.icon)
            Text("Search tabs")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightControl)
        .slateChromeFieldPlate()
        .padding(.horizontal, RailStatusRollup.trailingInset)
        .padding(.bottom, Slate.Metric.space3)
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

#endif
