// MacRailStatusRollupRender — the pixel probe for the titlebar band's aggregate cluster
// (``RailStatusRollup``), which moved into `SlopDeskMacUI` with the surface itself (docs/56
// increment 36). It is still a SEPARATE rig from ``MacChromeSnapshotRender`` because the frame it
// photographs is a hand-built SIDEBAR TOP — a drawn search plate, drawn row stand-ins, drawn window
// controls — rather than a shipping view mounted whole.
//
// ⚠️ IT IS A HOSTED CAPTURE, NOT `ImageRenderer` (docs/56 stage D). `ImageRenderer` rasterizes the
// SwiftUI display list and draws NOTHING for a representable, and the cluster's three marks are
// `NSView`s now (``MacRailStatusMarksView``) — so the one thing this image exists to judge would
// have come out as three empty 14pt holes, in a sheet that still got written and still looked like a
// render. The frame is therefore mounted in an `NSHostingView` and photographed off the layer, which
// is ``MacChromeSnapshotRender``'s recipe.
//
// ⚠️ THE GROUND is ``Slate/Surface/field`` — the authored cream `#FFFBEB` (ONE ISLAND law 4), never
// `Surface.ground`, which on macOS is the semantic aux-window backdrop (`underPageBackgroundColor`,
// measured `#A1A09F`): a mid grey that appears NOWHERE in the shipping chrome and is the EASIER
// ground. An ink judged against a grey it will never be drawn on is not judged at all. It is PAINTED
// ON THE WINDOW'S OWN CONTENT VIEW here, not left to the window backing — that omission is what made
// the old hosted path grey the cream, and it was a property of the harness rather than of hosting.
//
// Opt-in and INERT under `swift test` / `make check` — it skips unless `SLOPDESK_TABROW_SNAPSHOT_DIR`
// is set, the same env var the Mac chrome rig reads. Run on demand:
//   SLOPDESK_TABROW_SNAPSHOT_DIR="$PWD/.build/shots" swift test --filter MacRailStatusRollupRender

import AppKit
import SFSafeSymbols
import SlopDeskSlate
import SwiftUI
import XCTest
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
        // `.frame` adds beyond the content stays unpainted by the SHEET. It is the same cream the
        // rig paints on the ground view beneath — belt and braces, and the two must never diverge:
        // a seam between them would read as a panel edge that no surface actually draws.
        .background(Slate.Surface.field) // THE GROUND — see the file header's ⚠️
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
            // in ``MacNavigatorColumn`` top-aligns for the same reason.
            .frame(height: Slate.Metric.titlebarHeight, alignment: .top)
            searchPlateStandIn
            projectIslandStandIn {
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

    /// The project BED the row stand-ins sit on, drawn from the tokens ``MacNavigatorColumn`` itself
    /// resolves: ``Slate/Native/ProjectTint/bed(at:)`` at ``Slate/Metric/islandRadiusCompact``,
    /// inseamed by ``Slate/Metric/projectIslandInset``.
    ///
    /// ⚠️ It reads the NATIVE tint, not the SwiftUI `register[0].opacity(bed)` recipe that stood
    /// here while this rig could still reach `SlopDeskClientUI`. Same bed, but this spelling is the
    /// one the shipping column resolves, so a drift between the two would show up in the photograph
    /// instead of being papered over by a fixture that re-derived the colour its own way.
    @MainActor
    private func projectIslandStandIn(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, Slate.Metric.projectIslandInset)
            .padding(.vertical, Slate.Metric.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: Slate.Native.ProjectTint.bed(at: 0)),
                in: .rect(cornerRadius: Slate.Metric.islandRadiusCompact, style: .continuous),
            )
    }

    /// One navigator ROW's footprint, drawn — the real one is `MacSidebarRowView`, which needs a
    /// store behind it and whose own photograph is `MacChromeSnapshotRender`'s job. What this panel
    /// needs from a row is only its GEOMETRY: the island's rail inset, the control height, and the
    /// trailing MARK column the band's cluster above has to line up with. Same reason
    /// `searchPlateStandIn` exists.
    ///
    /// ⚠️ The MARK is the shipping ``MacStatusMarkView``, never the SwiftUI `StatusDotView` that
    /// stood here while the rig was an `ImageRenderer` frame. This sheet's whole job is to judge the
    /// band's marks AGAINST the rows' marks beneath them, and a stand-in drawn by the other half's
    /// renderer would compare the two halves instead of the two surfaces — hiding exactly the drift
    /// it is in frame to expose.
    @MainActor
    private func rowStandIn(_ title: String, mark: StatusDotStyle?) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(title)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let mark {
                NativeMark(style: mark)
                    .frame(width: StatusDot.footprint, height: StatusDot.footprint)
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

    /// The search field's PLATE, drawn — the real one is ``SlateNativeSearchField``, an
    /// `NSTextField` that draws nothing a hosted SwiftUI frame can photograph. Only its geometry matters here (the plate's
    /// height, and the gutter its trailing edge lands on), and that is copied from
    /// ``MacNavigatorColumn`` verbatim, ``RailStatusRollup/trailingInset`` included: the whole point of
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
        .background(chromeFieldPlate)
        .padding(.horizontal, RailStatusRollup.trailingInset)
        .padding(.bottom, Slate.Metric.space3)
    }

    /// The field plate's MATERIAL, spelled the way ``MacNavigatorColumn`` spells it on its own
    /// `plate` layer: ``Slate/Native/State/hover`` inside a ``Slate/Metric/hairline`` of
    /// ``Slate/Native/Line/field``, at ``Slate/Metric/radiusControl`` on a continuous curve.
    ///
    /// ⚠️ Same ⚠️ as ``projectIslandStandIn``: it reads the NATIVE tokens rather than the SwiftUI
    /// `slateChromeFieldPlate()` modifier that stood here while this rig could reach
    /// `SlopDeskClientUI`. The plate is in frame so the band's cluster can be judged against its
    /// trailing edge, and a fixture that re-derived the material its own way would hide a drift
    /// between the two spellings instead of showing it.
    @MainActor
    private var chromeFieldPlate: some View {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusControl, style: .continuous)
            .fill(Color(nsColor: Slate.Native.State.hover))
            .overlay {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: Slate.Native.Line.field), lineWidth: Slate.Metric.hairline,
                    )
            }
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

    /// Rasterize `content` at @2x and write a PNG into `dir`. FAILS (does not skip) when no bitmap can
    /// be made — reaching here means the env opt-in was set, so nothing rendered is a real regression
    /// in the panel's layout.
    ///
    /// HOSTED and photographed off the LAYER — see the file header's first ⚠️ for why this is not
    /// `ImageRenderer` any more. The cream is painted on the ground view the hosting view sits in,
    /// so the authored colour is what the marks are judged against rather than the window's backing.
    @MainActor
    private func render(_ content: some View, size: CGSize, to dir: String, named name: String) throws {
        let scale: CGFloat = 2
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let ground = NSView(frame: host.frame)
        ground.wantsLayer = true
        ground.addSubview(host)

        let window = NSWindow(
            contentRect: ground.frame, styleMask: [.borderless], backing: .buffered, defer: false,
        )
        // ⚠️ `.aqua`, and NOT `Slate.glassColorScheme` — the app pins LIGHT app-wide
        // (``SlateAppearancePin``) because the ground is the cream; `glassColorScheme` is the
        // TERMINAL GLASS's local opt-out. A harness that followed it resolves every dynamic
        // `Slate.Text.*` near-white on that cream, which is the failure the app-level pin prevents.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = ground
        window.orderFront(nil)
        ground.layoutSubtreeIfNeeded()
        ground.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        if let layer = ground.layer { Self.pinContentsScale(layer, scale) }
        // One turn of the run loop so the spinner's first display-link frame exists and every layer
        // has redrawn at the scale just asked for, before anything is photographed.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let rep = NSBitmapImageRep(
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
        // is top-left-down, which is the space `CALayer.render(in:)` draws in — the usual
        // `translate + scale(1, -1)` on top of it photographs the sheet upside down.
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

    /// Raise the whole layer tree's backing resolution before the shutter. ⚠️ `CALayer.render(in:)`
    /// REPLAYS CACHED CONTENTS, so a sublayer left at 1× stays 1× however far the context is scaled —
    /// the sheet then comes out sharp in its SwiftUI half and soft in every `NSView` in it.
    private static func pinContentsScale(_ layer: CALayer, _ scale: CGFloat) {
        layer.contentsScale = scale
        layer.rasterizationScale = scale
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { pinContentsScale($0, scale) }
    }
}

/// One shipping ``MacStatusMarkView``, mounted in the SwiftUI sheet — the rig's only way to draw a
/// ROW's mark with the renderer the rows actually use. It exists here and not in the shipping target
/// because nothing in the app hosts a bare mark: the band's cluster carries its own three
/// (``MacRailStatusMarksView``) and every other mark is a subview of an AppKit row or chip.
private struct NativeMark: NSViewRepresentable {
    let style: StatusDotStyle

    func makeNSView(context _: Context) -> MacStatusMarkView { MacStatusMarkView() }

    func updateNSView(_ view: MacStatusMarkView, context _: Context) { view.style = style }
}
