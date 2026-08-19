// MacRailStatusRollupRender — the pixel probe for the titlebar band's aggregate cluster
// (``RailStatusRollup``), which moved into `SlopDeskMacUI` with the surface itself (docs/56
// increment 36). It stayed a SEPARATE rig from ``MacChromeSnapshotRender`` for one reason: that one
// photographs REAL `NSView`s through `CALayer.render(in:)`, and every part of this frame is pure
// SwiftUI. `ImageRenderer` is what can capture it, and the hosted path composites through a window
// whose backing greys the authored cream — which would make the one thing this image exists to
// judge, the GROUND the marks stand on, a lie.
//
// ⚠️ THE GROUND is ``Slate/Surface/field`` — the authored cream `#FFFBEB` (ONE ISLAND law 4), never
// `Surface.ground`, which on macOS is the semantic aux-window backdrop (`underPageBackgroundColor`,
// measured `#A1A09F`): a mid grey that appears NOWHERE in the shipping chrome and is the EASIER
// ground. An ink judged against a grey it will never be drawn on is not judged at all.
//
// Opt-in and INERT under `swift test` / `make check` — it skips unless `SLOPDESK_TABROW_SNAPSHOT_DIR`
// is set, the same env var the Mac chrome rig reads. Run on demand:
//   SLOPDESK_TABROW_SNAPSHOT_DIR="$PWD/.build/shots" swift test --filter MacRailStatusRollupRender

import AppKit
import SFSafeSymbols
import SlopDeskSlate
import SwiftUI
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskClientUI
@testable import SlopDeskMacUI

@MainActor
final class MacRailStatusRollupRender: XCTestCase {
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

    // MARK: - The rig

    @MainActor
    private func captioned(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.tertiary)
            content()
        }
    }

    /// Rasterize `content` at @2x and write a PNG into `dir`. Fails (not skips) if the renderer yields
    /// nothing — reaching here means the env opt-in was set, so a nil image is a real regression in
    /// the panel's layout.
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
