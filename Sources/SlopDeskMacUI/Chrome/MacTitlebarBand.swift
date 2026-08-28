// MacTitlebarBand — the full-width titlebar chrome, in AppKit. The window runs `.hiddenTitleBar`, so
// there is NO system unified toolbar: this IS the chrome.
//
//   • LEFT  — the ``MacTabStrip``, collapsed-only: the tab list the hidden sidebar took with it, laid
//     horizontally on the project beds it already had. It starts at
//     ``RailStatusRollupMount/collapsedTrailingEdge`` — past the sidebar toggle's slot AND past the
//     agent rollup that parks beside it while the column is hidden. Neither of those is mounted here
//     (both hang off the window root); the strip only leaves their room.
//   • RIGHT — the CONNECTION ISLAND, collapsed-only, anchored to the strip's trailing corner. It is
//     the SAME island that stands at the navigator's foot while the tabs are vertical: the status
//     follows the tab list's axis, so with the list laid across the band the island lays down beside
//     it, one line on the same bed.
//   • The CENTRE IS EMPTY. With the terminal lifted as an island, the band above it is the island's
//     top moat — a strip of bare ground — and a label floating in it read as chrome the layout no
//     longer has room for. Nothing was lost: split / move / close all carry chords, and the cwd
//     readout with its Copy Path row lives in the command palette's DIRECTORY section.
//
// Everything in the band hangs from ``Slate/Metric/bandControlInset``, the inset that puts a control's
// CENTRE on the traffic lights' centre. The lights meet that centre from the other side —
// `lowerTrafficLightsToTheTopLine` declares the titlebar height AppKit parks them by.
//
// THE BAND IS A PASS-THROUGH. It spans the content column's full width so its two ends can anchor to
// the window's, but its middle is the island's moat and every click there belongs to what is under it.
// ``hitTest(_:)`` therefore refuses to claim anything but a real subview — the one thing an
// `NSHostingView` could not do for the SwiftUI titlebar it replaces, which had to be a full-bleed
// overlay and had to be given `allowsHitTesting` back a layer at a time.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

@MainActor
final class MacTitlebarBand: NSView {
    private let chrome: WorkspaceChromeState

    private let strip: MacTabStrip
    private let island: MacConnectionIsland
    /// The two ends, as one row — so the strip takes whatever width is left and a long tab run scrolls
    /// UNDER the island rather than shoving it off the band.
    private let row = NSStackView()

    private var leading: NSLayoutConstraint?
    private var trailing: NSLayoutConstraint?
    private var visible = false

    init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        onConnect: @escaping () -> Void,
    ) {
        self.chrome = chrome
        strip = MacTabStrip(store: store)
        island = MacConnectionIsland(
            store: store, connection: connection, onConnect: onConnect, layout: .inline,
        )
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(strip)
        row.addArrangedSubview(island)
        // The island keeps its ideal width; the strip is the one that gives.
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        // Both halves TRAVEL as layer transforms (see ``travel(arriving:)``), so both need a layer.
        strip.wantsLayer = true
        island.wantsLayer = true
        strip.layer?.transform = CATransform3DMakeTranslation(-Slate.Metric.heightControl, 0, 0)
        island.layer?.transform = CATransform3DMakeTranslation(Slate.Metric.heightControl, 0, 0)
        strip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        island.setContentHuggingPriority(.required, for: .horizontal)
        island.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.alphaValue = 0
        addSubview(row)

        // ⚠️ The strip begins after EVERYTHING already standing on that band's leading side — the
        // lights, the toggle's slot, and the agent rollup that parks beside the toggle when the column
        // is gone. It used to stop at the toggle, and the marks landed on top of the first tab. ONE
        // sum, owned by ``RailStatusRollupMount``, so the two can never drift apart again.
        let leading = row.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: RailStatusRollupMount.collapsedTrailingEdge,
        )
        // Reserve the trailing slot so a long run of tabs scrolls instead of sliding under the panel's
        // rail (or, with the panel open, off the column's own trailing edge).
        let trailing = trailingAnchor.constraint(equalTo: row.trailingAnchor)
        self.leading = leading
        self.trailing = trailing
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.titlebarHeight),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.bandControlInset),
            leading,
            trailing,
        ])
    }

    // MARK: The collapse

    /// Follow the chrome's two collapse flags. The band's whole content is COLLAPSED-ONLY: with the
    /// navigator open the tabs and the status are in it, and the band is bare ground.
    private func follow() {
        ObservationFollow.arm(self) { band in
            (
                sidebarCollapsed: band.chrome.sidebarCollapsed,
                panelCollapsed: band.chrome.codeSidebarCollapsed,
            )
        } apply: { band, reading in
            band.trailing?.constant = reading.panelCollapsed
                ? Slate.Metric.panelRailWidth
                : Slate.Metric.space2
            guard reading.sidebarCollapsed != band.visible else { return }
            band.visible = reading.sidebarCollapsed
            band.travel(arriving: reading.sidebarCollapsed)
        }
    }

    /// The two halves of the band fill in FROM THEIR OWN EDGES: the tabs wait one control to the
    /// leading side and the island one control out on the trailing side, and both land as the column
    /// finishes leaving — so the band reads as the list coming across with the column rather than as a
    /// layer switching on. The toggle beside them stays perfectly still through all of it, which is
    /// the point of its move to the window root.
    ///
    /// Never RIDE the collapse slide (the column edge travels 80 → 300): the arrival is DELAYED past
    /// most of it rather than timed to it. Leaving is the mirror and must CLEAR first — no delay, and
    /// quick, so the arriving column never catches the strip still on screen.
    /// ⚠️ The travel is a LAYER TRANSFORM, not a frame or a constraint. Both halves live in an
    /// Auto Layout stack whose geometry is re-derived on every pass, so an animated `frame` snaps back
    /// the moment anything else in the band relays out; a transform composes on top of whatever layout
    /// resolved and survives it.
    private func travel(arriving: Bool) {
        let offset = Slate.Metric.heightControl
        let curve = arriving ? Slate.Motion.columnSlide : Slate.Motion.fadeOut
        let settle = { [strip, island, row] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(curve.duration)
            CATransaction.setAnimationTimingFunction(curve.timingFunction)
            strip.layer?.transform = CATransform3DMakeTranslation(arriving ? 0 : -offset, 0, 0)
            island.layer?.transform = CATransform3DMakeTranslation(arriving ? 0 : offset, 0, 0)
            CATransaction.commit()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = curve.duration
                context.timingFunction = curve.timingFunction
                row.animator().alphaValue = arriving ? 1 : 0
            }
        }
        if arriving {
            // The delay tracks `columnSlide`'s own duration rather than a literal, so the window only
            // ever has ONE column gesture running.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Slate.Motion.columnSlide.duration * 0.55,
            ) { MainActor.assumeIsolated(settle) }
        } else {
            settle()
        }
    }

    // MARK: The pass-through

    /// The band claims a point only where a real control stands — see this file's header.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard visible else { return nil }
        let hit = super.hitTest(point)
        return hit === self || hit === row ? nil : hit
    }
}
