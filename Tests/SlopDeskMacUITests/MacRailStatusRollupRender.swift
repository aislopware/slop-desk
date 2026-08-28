// MacRailStatusRollupRender — the pixel probe for the titlebar band's aggregate cluster
// (``RailStatusRollup``), which moved into `SlopDeskMacUI` with the surface itself (docs/56
// increment 36). It is still a SEPARATE rig from ``MacChromeSnapshotRender`` because the frame it
// photographs is a hand-built SIDEBAR TOP — a drawn search plate, drawn row stand-ins, drawn window
// controls — rather than a shipping view mounted whole.
//
// ⚠️ IT IS A LAYER CAPTURE, AND THE REASON IS NO LONGER `ImageRenderer`. The rig was hosted for one
// finding (docs/56 stage D): `ImageRenderer` rasterizes the SwiftUI display list and drew NOTHING for
// a representable, so the cluster's three marks — `NSView`s since that stage — came out as three
// empty 14pt holes in a sheet that still got written and still looked like a render. That finding is
// history now rather than a constraint: the whole frame here is AppKit, so there is no display list
// and no representable, and the picture is taken the only way an `NSView` tree can be photographed —
// an `NSWindow`, an `NSBitmapImageRep`, and `CALayer.render(in:)`. It is ``MacChromeSnapshotRender``'s
// recipe, and the four hazards marked ⚠️ down in ``render(_:size:to:named:)`` are that recipe's.
//
// ⚠️ THE GROUND is ``Slate/Native/Surface/field`` — the authored cream `#FFFBEB` (ONE ISLAND law 4),
// never `Native.Surface.ground`, which on macOS is the semantic aux-window backdrop (`underPageBackgroundColor`,
// measured `#A1A09F`): a mid grey that appears NOWHERE in the shipping chrome and is the EASIER
// ground. An ink judged against a grey it will never be drawn on is not judged at all. It is PAINTED
// ON THE WINDOW'S OWN CONTENT VIEW, not left to the window backing — that omission is what greyed the
// cream when this rig was first taken off `ImageRenderer`, and it was a property of the harness rather
// than of hosting.
//
// ⚠️ A DRAWN FILL IS STAMPED IN ``DrawnPlate/updateLayer()``, NEVER AT BUILD TIME — the one hazard
// this frame ADDED. Every stand-in surface here used to be a SwiftUI `Color(nsColor:)`, which
// re-resolves inside whatever appearance it is drawn in; an AppKit stand-in is a `CGColor` stamped
// into a `CALayer`, and `NSColor.cgColor` resolves against the CURRENT drawing appearance at the
// moment it is called. Built on a dark-mode Mac and stamped at `init`, every disc, bed and plate
// below would photograph in its DARK variant on the cream — the same illegible sheet the `.aqua` pin
// in `render` exists to prevent, arriving by a second door.
//
// Opt-in and INERT under `swift test` / `just check` — it skips unless `SLOPDESK_TABROW_SNAPSHOT_DIR`
// is set, the same env var the Mac chrome rig reads. Run on demand:
//   SLOPDESK_TABROW_SNAPSHOT_DIR="$PWD/.build/shots" swift test --filter MacRailStatusRollupRender

import AppKit
import SFSafeSymbols
import SlopDeskSlate
import XCTest
@testable import SlopDeskMacUI

@MainActor
final class MacRailStatusRollupRender: XCTestCase {
    // MARK: - Opt-in render of the band's status rollup (the ONE claim only pixels can settle)

    /// Renders the sidebar's TOP — the traffic-light band carrying the marks cluster, the search
    /// plate, and a project island of drawn row stand-ins — twice, once with all three states lit
    /// and once with only the waiting one. Everything this round changed is a claim about PIXELS that
    /// `RailStatusRollupTests` can only pin the arithmetic behind:
    ///
    ///  * **flush right** — the cluster must end on the SAME vertical line as the search plate under
    ///    it (user-reported 2026-08-11: at the rows' mark column, 18pt further in, it read as a
    ///    cluster that had failed to reach the edge). The plate is in the frame for exactly this, and
    ///    it is drawn rather than mounted because ``SlateNativeSearchField`` wants a delegate and a
    ///    live query behind it, and this fixture needs only its GEOMETRY.
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
    func testRenderRailStatusRollup() throws {
        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TABROW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SLOPDESK_TABROW_SNAPSHOT_DIR=<dir> to render the band rollup")
        }
        let width = Slate.Metric.sidebarWidth
        // +300: the captions are wider than the panels they label, and the sheet is pinned to the
        // ground's LEADING edge — so a frame cut to the three panels' sum clips the LAST caption off
        // the right edge rather than dropping a panel. (It centred, and clipped the FIRST caption,
        // while this was a SwiftUI `HStack` overflowing its render frame; the headroom is the same
        // headroom either way.)
        let size = CGSize(width: width * 2 + collapsedBandWidth + 300, height: 300)
        let sheet = NSStackView()
        sheet.orientation = .horizontal
        sheet.alignment = .top
        sheet.spacing = 20
        sheet.addArrangedSubview(captioned("all three lit", bandPanel(active: RailStatusRollup.order)))
        sheet.addArrangedSubview(captioned(
            "only a question waiting — the other two slots unlit", bandPanel(active: [.waiting]),
        ))
        sheet.addArrangedSubview(captioned(
            "collapsed — beside the toggle, tabs begin after it", collapsedBandPanel(),
        ))
        try render(sheet, size: size, to: dir, named: "rail-status-rollup.png")
    }

    /// One sidebar top at its true width, with `active` lit — the band, the search plate, one project
    /// island of rows.
    private func bandPanel(active: [RailStatusRollup.Kind]) -> NSView {
        let width = Slate.Metric.sidebarWidth
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 0
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addArrangedSubview(bandStandIn(
            active: active,
            // ⚠️ Positioned the way the REAL mount positions it — by lead, not by a trailing inset
            // spelled inside the cluster. ``MacRailStatusMarksView`` is intrinsically sized (three
            // footprints, two gaps) and ``RailStatusRollupMount`` owns where that block stands, so a
            // fixture that spelled the inset itself would stop testing the shipped sum.
            lead: RailStatusRollupMount.lead(collapsed: false, navigatorWidth: width),
        ))
        panel.addArrangedSubview(searchPlateStandIn())
        panel.addArrangedSubview(projectIslandStandIn([
            rowStandIn(
                "Claude Code",
                mark: StatusPresentation.statusDot(working: false, badge: .awaitingInput),
            ),
            rowStandIn("api", mark: StatusPresentation.statusDot(working: true, badge: nil)),
            rowStandIn(
                "web",
                mark: StatusPresentation.statusDot(
                    working: false, badge: .finished, agentFinish: true,
                ),
            ),
            rowStandIn("docs", mark: nil),
        ]))
        panel.widthAnchor.constraint(equalToConstant: width).isActive = true
        for child in panel.arrangedSubviews {
            child.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return panel
    }

    /// The traffic-light band with the cluster parked at `lead`.
    ///
    /// ⚠️ BOTH CHILDREN HANG FROM THE BAND'S TOP EDGE. The band's contents are SHORTER than the band,
    /// and centring them slides the whole rung down 4pt, which reads as a band sitting low — the
    /// SwiftUI frame said this with `alignment: .top` and a top anchor says it here. The real mount in
    /// ``MacNavigatorColumn`` top-aligns for the same reason.
    private func bandStandIn(active: [RailStatusRollup.Kind], lead: CGFloat) -> NSView {
        let band = NSView()
        band.translatesAutoresizingMaskIntoConstraints = false
        let lights = trafficLightsStandIn()
        band.addSubview(lights)
        // ⚠️ THE REAL CLUSTER, never a redraw of it. This sheet exists to judge the band's three marks
        // — against each other, against the rows' marks below, and against the plate's trailing edge —
        // so the one thing in frame that must not be a stand-in is the cluster itself.
        //
        // `onPick: nil` is the rig's mode and the cluster is built for it: an unlit slot already
        // refuses the hit, and `MacRailStatusMarkSlot.hitTest(_:)` refuses a lit one too when nobody
        // is listening. Nothing about the DRAWING changes — a slot inks itself from
        // ``RailStatusRollup/style(for:active:)`` either way.
        let cluster = MacRailStatusMarksView()
        cluster.apply(active: active, onPick: nil)
        band.addSubview(cluster)
        NSLayoutConstraint.activate([
            band.heightAnchor.constraint(equalToConstant: Slate.Metric.titlebarHeight),
            lights.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: Self.lightsInset),
            lights.topAnchor.constraint(equalTo: band.topAnchor, constant: Self.lightsInset),
            cluster.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: lead),
            // The band's control rung — the two constraints ``RailStatusRollupMount`` puts on the
            // cluster, so the marks' centres land on the same line as the lights beside them.
            cluster.topAnchor.constraint(
                equalTo: band.topAnchor, constant: Slate.Metric.bandControlInset,
            ),
            cluster.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])
        return band
    }

    /// The three window-control discs, drawn. AppKit owns the real ones and does not hand them out;
    /// what the sheet needs from them is the CENTRE LINE the marks claim to share.
    private func trafficLightsStandIn() -> NSView {
        let lights = NSStackView()
        lights.orientation = .horizontal
        lights.alignment = .centerY
        lights.spacing = Slate.Metric.space2
        lights.translatesAutoresizingMaskIntoConstraints = false
        for ink in [Slate.Native.Status.err, Slate.Native.Status.warn, Slate.Native.Status.ok] {
            let disc = DrawnPlate(fill: ink, radius: Self.lightDiameter / 2)
            lights.addArrangedSubview(disc)
            NSLayoutConstraint.activate([
                disc.widthAnchor.constraint(equalToConstant: Self.lightDiameter),
                disc.heightAnchor.constraint(equalToConstant: Self.lightDiameter),
            ])
        }
        return lights
    }

    /// AppKit's measured inset for the leading light, and the discs' measured diameter. Literals
    /// because the window furniture is the system's and there is no token to read — the app never
    /// draws these, it only stands beside them.
    private static let lightsInset: CGFloat = 13
    private static let lightDiameter: CGFloat = 14

    /// The project BED the row stand-ins sit on, drawn from the tokens ``MacNavigatorColumn`` itself
    /// resolves: ``Slate/Native/ProjectTint/bed(at:)`` at ``Slate/Metric/islandRadiusCompact``,
    /// inseamed by ``Slate/Metric/projectIslandInset`` and standing on the list's own `space2` gutter.
    ///
    /// ⚠️ It reads the NATIVE tint, not the `register[0].opacity(bed)` recipe that stood here while
    /// this rig could still reach the shared view target. Same bed, but this spelling is the one the
    /// shipping column resolves, so a drift between the two would show up in the photograph instead of
    /// being papered over by a fixture that re-derived the colour its own way.
    private func projectIslandStandIn(_ rows: [NSView]) -> NSView {
        let gutter = NSView()
        gutter.translatesAutoresizingMaskIntoConstraints = false
        let bed = DrawnPlate(
            fill: Slate.Native.ProjectTint.bed(at: 0), radius: Slate.Metric.islandRadiusCompact,
        )
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        for row in rows { column.addArrangedSubview(row) }
        bed.addSubview(column)
        gutter.addSubview(bed)
        NSLayoutConstraint.activate([
            // The list's own gutter — the bed ends on the same line the search plate above it does.
            bed.leadingAnchor.constraint(equalTo: gutter.leadingAnchor, constant: Slate.Metric.space2),
            bed.trailingAnchor.constraint(
                equalTo: gutter.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            bed.topAnchor.constraint(equalTo: gutter.topAnchor),
            bed.bottomAnchor.constraint(equalTo: gutter.bottomAnchor),
            column.leadingAnchor.constraint(
                equalTo: bed.leadingAnchor, constant: Slate.Metric.projectIslandInset,
            ),
            column.trailingAnchor.constraint(
                equalTo: bed.trailingAnchor, constant: -Slate.Metric.projectIslandInset,
            ),
            column.topAnchor.constraint(equalTo: bed.topAnchor, constant: Slate.Metric.space2),
            column.bottomAnchor.constraint(equalTo: bed.bottomAnchor, constant: -Slate.Metric.space2),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return gutter
    }

    /// One navigator ROW's footprint, drawn — the real one is `MacSidebarRowView`, which needs a
    /// store behind it and whose own photograph is `MacChromeSnapshotRender`'s job. What this panel
    /// needs from a row is only its GEOMETRY: the island's rail inset, the control height, and the
    /// trailing MARK column the band's cluster above has to line up with. Same reason
    /// ``searchPlateStandIn()`` exists.
    ///
    /// ⚠️ THE MARK IS THE SHIPPING ``MacStatusMarkView``, never a redraw. This sheet's whole job is to
    /// judge the band's marks AGAINST the rows' marks beneath them, and a stand-in painted by anything
    /// other than the renderer the rows themselves use would compare the fixture with the surface —
    /// hiding exactly the drift it is in frame to expose. (It was a `StatusDotView` bridged in through
    /// an `NSViewRepresentable` while the frame was SwiftUI; the bridge is gone, the rule it enforced
    /// is not.)
    private func rowStandIn(_ title: String, mark: StatusDotStyle?) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let text = label(title, size: Slate.Typeface.footnote, ink: Slate.Native.Text.primary)
        text.lineBreakMode = .byTruncatingTail
        row.addSubview(text)
        let slot = markSlot(mark)
        row.addSubview(slot)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Slate.Metric.heightTabRow),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Slate.Metric.islandRail),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: slot.leadingAnchor, constant: -Slate.Metric.space1,
            ),
            slot.trailingAnchor.constraint(
                equalTo: row.trailingAnchor, constant: -Slate.Metric.islandRail,
            ),
            slot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// The row's trailing 14pt column: the real mark, or an empty one of the same width. A row with
    /// nothing to say still holds the column, which is what keeps the titles beside it on one rail —
    /// and that rail is one of the lines the band's cluster is judged against.
    private func markSlot(_ mark: StatusDotStyle?) -> NSView {
        guard let mark else {
            let hole = NSView()
            hole.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hole.widthAnchor.constraint(equalToConstant: StatusDot.footprint),
                hole.heightAnchor.constraint(equalToConstant: StatusDot.footprint),
            ])
            return hole
        }
        // ``MacStatusMarkView`` constrains itself to one footprint square; nothing here restates it.
        let view = MacStatusMarkView()
        view.style = mark
        return view
    }

    /// Wide enough to show the toggle's slot, the parked cluster, and the start of the tab run that
    /// begins after it.
    private var collapsedBandWidth: CGFloat {
        RailStatusRollupMount.collapsedTrailingEdge + 120
    }

    /// The band with NO column under it — the traffic lights, the sidebar toggle's plate, and the
    /// cluster at its collapsed parking spot. The toggle is drawn (not mounted) for the same reason
    /// the search plate is: ``MacPlateIconButton`` would drag a click target and a hover ladder into a
    /// fixture that only needs its FOOTPRINT, which is `Slate.Metric.plate` square on the band's
    /// centre line.
    private func collapsedBandPanel() -> NSView {
        let band = NSView()
        band.translatesAutoresizingMaskIntoConstraints = false
        let lights = trafficLightsStandIn()
        band.addSubview(lights)

        // The plate's FILL is `.clear` at rest (``MacPlateIconButton``) — only its footprint is in
        // play here, and that is what the collapsed lead is measured from. So: a bare container at
        // plate size with the glyph centred in it, and nothing drawn behind.
        let plate = NSView()
        plate.translatesAutoresizingMaskIntoConstraints = false
        let toggle = glyph(
            .sidebarLeft, size: Slate.Typeface.body, weight: .medium, ink: Slate.Native.Text.icon,
        )
        plate.addSubview(toggle)
        band.addSubview(plate)

        let cluster = MacRailStatusMarksView()
        cluster.apply(active: [.waiting, .working], onPick: nil)
        band.addSubview(cluster)

        // ⚠️ The first horizontal tab, stood in for at the inset the band
        // (`SlopDeskMacUI/MacTitlebarBand`) actually spends. This is the collision the round fixed
        // (user-reported 2026-08-11: the strip reserved the TOGGLE's slot only, so the marks were
        // drawn over the first tab's title) — and a collision between two positions is only ever
        // settled by looking.
        let chip = DrawnPlate(
            fill: Slate.Native.ProjectTint.bed(at: 0), radius: Slate.Metric.radiusControl,
        )
        let chipTitle = label(
            "Kiểm tra và lên kế h…", size: Slate.Typeface.footnote, ink: Slate.Native.Text.primary,
        )
        chip.addSubview(chipTitle)
        band.addSubview(chip)

        NSLayoutConstraint.activate([
            band.widthAnchor.constraint(equalToConstant: collapsedBandWidth),
            band.heightAnchor.constraint(equalToConstant: Slate.Metric.titlebarHeight),

            lights.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: Self.lightsInset),
            lights.topAnchor.constraint(equalTo: band.topAnchor, constant: Self.lightsInset),

            plate.leadingAnchor.constraint(
                equalTo: band.leadingAnchor, constant: Slate.Metric.windowControlsLead,
            ),
            plate.topAnchor.constraint(equalTo: band.topAnchor, constant: Slate.Metric.bandControlInset),
            plate.widthAnchor.constraint(equalToConstant: Slate.Metric.plate),
            plate.heightAnchor.constraint(equalToConstant: Slate.Metric.plate),
            toggle.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            toggle.centerYAnchor.constraint(equalTo: plate.centerYAnchor),

            cluster.leadingAnchor.constraint(
                equalTo: band.leadingAnchor, constant: RailStatusRollupMount.collapsedLead,
            ),
            cluster.topAnchor.constraint(
                equalTo: band.topAnchor, constant: Slate.Metric.bandControlInset,
            ),
            cluster.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),

            chip.leadingAnchor.constraint(
                equalTo: band.leadingAnchor, constant: RailStatusRollupMount.collapsedTrailingEdge,
            ),
            chip.topAnchor.constraint(equalTo: band.topAnchor, constant: Slate.Metric.bandControlInset),
            chip.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            chipTitle.leadingAnchor.constraint(
                equalTo: chip.leadingAnchor, constant: Slate.Metric.space2,
            ),
            chipTitle.trailingAnchor.constraint(
                equalTo: chip.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            chipTitle.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
        return band
    }

    /// The search field's PLATE, drawn — the real one is ``SlateNativeSearchField``, which wants a
    /// delegate and a live query behind it. Only its geometry matters here (the plate's height, and
    /// the gutter its trailing edge lands on), and that is copied from ``MacNavigatorColumn``
    /// verbatim, ``RailStatusRollup/trailingInset`` included: the whole point of having it in frame is
    /// that the band above it must end on the same line.
    private func searchPlateStandIn() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let plate = chromeFieldPlate()
        row.addSubview(plate)
        let magnifier = glyph(
            .magnifyingglass, size: Slate.Typeface.footnote, weight: .regular,
            ink: Slate.Native.Text.icon,
        )
        let placeholder = label(
            "Search tabs", size: Slate.Typeface.footnote, ink: Slate.Native.Text.tertiary,
        )
        plate.addSubview(magnifier)
        plate.addSubview(placeholder)
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(
                equalTo: row.leadingAnchor, constant: RailStatusRollup.trailingInset,
            ),
            plate.trailingAnchor.constraint(
                equalTo: row.trailingAnchor, constant: -RailStatusRollup.trailingInset,
            ),
            plate.topAnchor.constraint(equalTo: row.topAnchor),
            plate.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            // The band between the field and the first project island, exactly as the column spends
            // it — a bed starting just under the plate reads as part of the field.
            plate.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Slate.Metric.space3),

            magnifier.leadingAnchor.constraint(
                equalTo: plate.leadingAnchor, constant: Slate.Metric.space2,
            ),
            magnifier.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            placeholder.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: Slate.Metric.space1,
            ),
            placeholder.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        return row
    }

    /// The field plate's MATERIAL, spelled the way ``MacNavigatorColumn`` spells it on its own
    /// `plate` layer: ``Slate/Native/State/hover`` inside a ``Slate/Metric/hairline`` of
    /// ``Slate/Native/Line/field``, at ``Slate/Metric/radiusControl`` on a continuous curve.
    ///
    /// ⚠️ Same ⚠️ as ``projectIslandStandIn(_:)``: it reads the NATIVE tokens rather than the
    /// `slateChromeFieldPlate()` modifier that stood here while this rig could reach the shared view
    /// target. The plate is in frame so the band's cluster can be judged against its trailing edge,
    /// and a fixture that re-derived the material its own way would hide a drift between the two
    /// spellings instead of showing it.
    private func chromeFieldPlate() -> DrawnPlate {
        DrawnPlate(
            fill: Slate.Native.State.hover, radius: Slate.Metric.radiusControl,
            edge: Slate.Native.Line.field,
        )
    }

    // MARK: - The rig

    private func captioned(_ caption: String, _ content: NSView) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(
            label(caption, size: Slate.Typeface.footnote, ink: Slate.Native.Text.tertiary),
        )
        column.addArrangedSubview(content)
        return column
    }

    /// One caption or title. An `NSTextField`'s `textColor` re-resolves per appearance on its own, so
    /// unlike a layer's fill this needs no repaint hook — see ``DrawnPlate``.
    private func label(_ text: String, size: CGFloat, ink: SlateNativeColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = ink
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// One system symbol at its stated rung.
    ///
    /// ⚠️ `contentTintColor`, NOT a palette configuration baked into the `NSImage`. A baked palette
    /// freezes the ink at the appearance the image was built in — the same trap ``DrawnPlate`` exists
    /// for — while an image view's tint is re-resolved for it.
    private func glyph(
        _ symbol: SFSymbol, size: CGFloat, weight: NSFont.Weight, ink: SlateNativeColor,
    ) -> NSImageView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleNone
        view.setAccessibilityElement(false)
        view.image = NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
        view.contentTintColor = ink
        return view
    }

    /// Rasterize `view` at @2x on the cream ground and write a PNG into `dir`. FAILS (does not skip)
    /// when no bitmap can be made — reaching here means the env opt-in was set, so nothing rendered is
    /// a real regression in the panel's layout.
    ///
    /// This is ``MacChromeSnapshotRender``'s capture path, hazards and all: an `NSWindow` to give the
    /// tree an appearance and a backing store, `CALayer.render(in:)` to take the picture, and the four
    /// ⚠️s below, each of which cost a wrong image before it was written down.
    private func render(_ view: NSView, size: CGSize, to dir: String, named name: String) throws {
        let scale: CGFloat = 2
        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        ground.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: ground.topAnchor),
            view.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
        ])

        let window = NSWindow(
            contentRect: ground.frame, styleMask: [.borderless], backing: .buffered, defer: false,
        )
        // ⚠️ `.aqua`, and NOT `Slate.glassColorScheme` — the app pins LIGHT app-wide
        // (``SlateAppearancePin``) because the ground is the cream; `glassColorScheme` is the
        // TERMINAL GLASS's local opt-out and names the dark side. A harness that followed it put the
        // window in darkAqua, every dynamic `Slate.Native.Text.*` resolved near-white, and the sheet
        // came out illegible on the cream — which is the exact failure the app-level pin prevents.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = ground
        window.orderFront(nil)
        ground.layoutSubtreeIfNeeded()
        // ⚠️ THE GROUND IS PAINTED ON THE WINDOW'S OWN CONTENT VIEW — see the file header. Leaving it
        // to the window backing is what greyed the cream, and an ink judged against the wrong ground
        // is not judged at all. There is exactly ONE ground now: the SwiftUI frame also carried a
        // `.background(...)` on the sheet, because a sheet smaller than its render frame left the
        // margin unpainted, and the two had to be kept identical or the seam between them would read
        // as a panel edge no surface draws. That duality is gone with the sheet.
        ground.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        if let layer = ground.layer { Self.pinContentsScale(layer, scale) }
        // ⚠️ ONE TURN OF THE RUN LOOP before the shutter, and it buys three things: the spinner's
        // first display-link frame exists, every layer has redrawn at the scale just asked for, and
        // each ``DrawnPlate`` has had the display pass in which its `updateLayer()` stamps its fill.
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

    /// Raise the whole layer tree's backing resolution before the shutter. ⚠️ `CALayer.render(in:)`
    /// REPLAYS CACHED CONTENTS, so a sublayer left at 1× stays 1× however far the context is scaled —
    /// the sheet then comes out sharp wherever the context did the drawing and soft in every view that
    /// cached its own.
    private static func pinContentsScale(_ layer: CALayer, _ scale: CGFloat) {
        layer.contentsScale = scale
        layer.rasterizationScale = scale
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { pinContentsScale($0, scale) }
    }
}

/// One drawn stand-in surface: a fill, an optional hairline edge, one continuous corner radius. The
/// discs, the project bed, the field plate and the collapsed band's tab chip are all this view.
///
/// ⚠️ THE FILL IS STAMPED IN ``updateLayer()``, NEVER AT INIT — the hazard this frame added when it
/// stopped being SwiftUI, and the file header states it in full. `NSColor.cgColor` resolves against
/// the CURRENT drawing appearance at the moment it is called; a fill stamped while the view is still
/// parentless takes whatever appearance the test process happened to be in, which on a dark-mode Mac
/// is the dark variant painted onto the cream. `updateLayer()` runs inside the view's own effective
/// appearance — the aqua the window is pinned to — so the ink is resolved against the ground it is
/// actually drawn on. It fires only on a layer-backed view, which is why `wantsLayer` is set here and
/// not left to the caller.
@MainActor
private final class DrawnPlate: NSView {
    private let fill: SlateNativeColor
    private let edge: SlateNativeColor?

    init(fill: SlateNativeColor, radius: CGFloat, edge: SlateNativeColor? = nil) {
        self.fill = fill
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        if edge != nil { layer?.borderWidth = Slate.Metric.hairline }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = edge?.cgColor
        }
    }
}
