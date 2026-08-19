// MacContentColumn — the centre column: the pane canvas ON THE ISLAND, with the titlebar band
// standing over it and the collapsed panel's rail standing at its trailing corner.
//
// The band and the rail are AppKit (``MacTitlebarBand``, ``MacPanelRail``, docs/56 stage D); the
// CANVAS between them is still the hosted SwiftUI ``ContentColumn``, and that split is the point of
// this controller. The band used to be a full-bleed `.overlay(alignment: .top)` inside that one
// SwiftUI view, which cost it a `ZStack` it had to be given hit-testing back through, one modifier at
// a time. As siblings each simply refuses every point it does not occupy
// (``MacTitlebarBand/hitTest(_:)``, ``MacPanelRail/hitTest(_:)``) and the canvas gets the rest free.
//
// AND THE ISLAND IS THIS CONTROLLER'S NOW (docs/56 stage F, P5). The moat, the window-scale corner,
// the glass and its rim were a SwiftUI modifier on the hosted column (`slateIsland(clearingBand:)`)
// plus a trailing padding for the rail. Moving them up is not tidying: it makes the hosted view's
// frame and the canvas THE SAME RECT, and that difference — "the compositor rect differs from the
// hosting view's frame by the island moat" — was the entire reason `DropTargetFrameReader` existed.
// With the difference at zero the canvas's drop-target registration is the three lines
// ``MacNavigatorColumn`` already spends on the sidebar list, and the reader is DELETED rather than
// ported (see ``registerCanvas(_:)`` for the one thing the two halves genuinely answer differently).
//
// THE CANVAS INSIDE THE ISLAND STAYS SWIFTUI ON PURPOSE, and it is the next surface to cross rather
// than an exception: it is `SplitContainer` and the twenty-odd files under it — a whole pane subtree,
// and docs/56 §3.5's rule is that a surface is ported WHOLE. The band is a surface; the island is a
// surface; "the island plus half the panes" is not.
//
// The MODAL POINTER SHIELD is this controller's root and therefore covers BOTH children — the same
// deal the navigator column keeps (``MacModalShield``).

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // the hosted canvas factory
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

@MainActor
final class MacContentColumn: NSViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    private let onConnect: () -> Void
    private let paneDrag: PaneDragCoordinator?
    private let overlay: OverlayCoordinator?

    /// The island's two travelling sides — the only two moat measurements that are not constant. Held
    /// so ``moveMoat(clearingBand:railed:animated:)`` can compare the measurement it is about to write
    /// against the one standing, which is what keeps an unrelated chrome change out of the animation.
    private var islandTop: NSLayoutConstraint?
    private var islandTrailing: NSLayoutConstraint?

    init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        onConnect: @escaping () -> Void, paneDrag: PaneDragCoordinator?,
        overlay: OverlayCoordinator?,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.onConnect = onConnect
        self.paneDrag = paneDrag
        self.overlay = overlay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let root = MacModalShield(overlay: overlay)
        root.onAppearanceChange = { [weak self] in self?.paint() }
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // The canvas: the pane grid and nothing around it. It fills the island edge to edge, so the
        // hosted view's frame is the canvas's rect exactly — see ``registerCanvas(_:)``.
        let canvas = WorkspaceColumnHosts.content(
            store: store, connection: connection, chrome: chrome, onConnect: onConnect,
            paneDrag: paneDrag, overlay: overlay,
        )
        addChild(canvas)
        canvas.view.translatesAutoresizingMaskIntoConstraints = false
        island.addSubview(canvas.view)
        view.addSubview(island)

        let band = MacTitlebarBand(
            store: store, connection: connection, chrome: chrome, onConnect: onConnect,
        )
        view.addSubview(band)
        view.addSubview(rail)

        let top = island.topAnchor.constraint(
            equalTo: view.topAnchor, constant: Slate.Metric.bandInset,
        )
        let trailing = view.trailingAnchor.constraint(
            equalTo: island.trailingAnchor, constant: Slate.Metric.islandInset,
        )
        islandTop = top
        islandTrailing = trailing

        NSLayoutConstraint.activate([
            canvas.view.topAnchor.constraint(equalTo: island.topAnchor),
            canvas.view.bottomAnchor.constraint(equalTo: island.bottomAnchor),
            canvas.view.leadingAnchor.constraint(equalTo: island.leadingAnchor),
            canvas.view.trailingAnchor.constraint(equalTo: island.trailingAnchor),
            top,
            trailing,
            island.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Slate.Metric.islandInset,
            ),
            view.bottomAnchor.constraint(
                equalTo: island.bottomAnchor, constant: Slate.Metric.islandInset,
            ),
            band.topAnchor.constraint(equalTo: view.topAnchor),
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The rail hangs from the column's TOP TRAILING corner and is as tall as what it carries
            // — no bottom anchor, so the canvas keeps every point below it.
            rail.topAnchor.constraint(equalTo: view.topAnchor),
            rail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        registerCanvas(canvas.view)
        followChrome()
        paint()
    }

    /// THE ISLAND — the one lifted surface in the window (Slate law 1), and the hosted canvas's
    /// container. Its fill, its corner and its rim are one layer's three properties, which is the
    /// same "law 1 lives in ONE place" the SwiftUI modifier this replaces was written for: a second
    /// island anywhere is the many-islands mistake coming back, and there is no second call site to
    /// make one from.
    private let island = MacPaneIsland()

    /// What the collapsed panel leaves behind. Mounted at ALL times and travelling in and out, because
    /// mounting it on the flag put a turned rail on top of a terminal that had not yet made room for
    /// it (user-reported 2026-08-09) — see ``MacPanelRail/travel(railed:animated:)``.
    private lazy var rail = MacPanelRail(chrome: chrome)

    /// Register the canvas's SCREEN rect (and, through it, the main window's frame — the tear-off
    /// boundary) with the pane-drag rendezvous, so a sidebar-row or satellite-window drag can
    /// hit-test this canvas from another hosting view. The three lines are ``MacNavigatorColumn``'s
    /// for `.sidebarList`, verbatim; there is no second idiom for "where is this view on screen".
    ///
    /// ⚠️ THIS PUBLISHES THE MODEL FRAME, AND THAT IS THE DECISION (docs/56 stage F, risk 1). The
    /// SwiftUI reader this replaces was mounted in a `GeometryReader`, so it published the
    /// INTERPOLATED rect every frame; `convert(bounds, to: nil)` reports the model frame, which jumps
    /// to the final value the instant the moat's animation opens. During the island settle a drop
    /// therefore resolves against where the canvas WILL be — and that is the right answer, because a
    /// drop resolves into a layout that is committing anyway. The alternative is `layer.presentation()`,
    /// which is nil outside an animation and, inside one, answers with a rect the pointer has already
    /// left. This is the ONE place the two halves genuinely disagree, and nothing fails if it
    /// regresses, which is why it is written down here instead of pinned by a test.
    private func registerCanvas(_ canvas: NSView) {
        guard let paneDrag else { return }
        paneDrag.register(.canvas) { [weak canvas] in
            guard let canvas, let window = canvas.window else { return nil }
            return window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
        }
        paneDrag.mainWindowFrame = { [weak canvas] in canvas?.window?.frame }
    }

    /// The two chrome flags the island's moat and the rail both travel on, read in ONE tracked pass:
    /// a collapse changes what the band covers AND what the panel leaves behind, and two separate
    /// observers would have raced each other into two column gestures.
    ///
    /// `animated` is false only for the first read, which is the launch state rather than a gesture: a
    /// window that opens with the navigator or the panel already collapsed should not play the arrival.
    private func followChrome() {
        var clearingBand = false
        var railed = false
        withObservationTracking {
            clearingBand = chrome.sidebarCollapsed
            railed = chrome.codeSidebarCollapsed
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followChrome() }
            }
        }
        moveMoat(clearingBand: clearingBand, railed: railed, animated: settled)
        rail.travel(railed: railed, animated: settled)
        settled = true
    }

    private var settled = false

    /// THE MOAT, and the two states that widen it.
    ///
    /// It is UNIFORM at rest (user-directed 2026-08-09): the island rises to ``Slate/Metric/bandInset``
    /// on the top side exactly as it insets on the other three, so it reaches INTO the band rather
    /// than starting a row under it — the three columns open together instead of the middle one
    /// beginning low. With the moat at 8 the island's top edge coincides with the y every plate in the
    /// band hangs from, so the glass's top edge, the sidebar toggle and the panel's surface tabs all
    /// start on ONE line. Hanging the island BELOW the whole band was tried in two band heights and
    /// rejected both times.
    ///
    /// `clearingBand` is the one state that cannot have it: with the navigator collapsed this column
    /// holds the window's left edge and the band above it fills with the lights, the toggle and the
    /// horizontal tab strip — cream chips and tinted project beds that cannot stand on the glass. The
    /// top side opens to the full ``Slate/Metric/bandHeight`` so the band keeps its ground. The
    /// collapsed PANEL needs no such exception: it leaves a RAIL of ground beside the island instead
    /// of parking a plate on the glass, and this column gives that width back on the trailing side so
    /// the moat is measured inside what is left.
    ///
    /// ⚠️ KEYED ON THE MEASUREMENT, NOT ON THE FLAG. Only a moat that actually changes size may
    /// animate, so no other chrome change can drag the island's geometry into a transaction — and the
    /// widening is a step of most of the band, which must never be instant: collapsing the navigator
    /// animates the column's width, so the moat opens on the same curve and duration and the island
    /// widens leftward and shortens downward as one move.
    private func moveMoat(clearingBand: Bool, railed: Bool, animated: Bool) {
        let top = clearingBand ? Slate.Metric.bandHeight : Slate.Metric.bandInset
        let trailing = railed
            ? Slate.Metric.islandInset + Slate.Metric.panelRailWidth
            : Slate.Metric.islandInset
        guard islandTop?.constant != top || islandTrailing?.constant != trailing else { return }
        islandTop?.constant = top
        islandTrailing?.constant = trailing
        guard animated else {
            view.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.columnSlide.duration
            context.timingFunction = Slate.Motion.columnSlide.timingFunction
            context.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        }
    }

    /// ONE ISLAND: this column paints GROUND end-to-end and the pane canvas is lifted off it as the
    /// window's single island. The band beside that island is the same ground — the tone the navigator
    /// and the code panel stand on — so the top of the window reads as one field with one card in it.
    private func paint() {
        view.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
    }
}

/// The island's own layer: the profile's GLASS, the FRAME's corner and the GLASS's rim.
///
/// Each of the three is the rule stated once. The fill is ``Slate/Native/Surface/island`` — the
/// profile's own glass, never a chrome tone. The corner is ``Slate/Metric/islandRadius``, the window's
/// own, so the glass never rounds harder than the frame holding it. And the rim is
/// ``Slate/Native/Terminal/edge``, the GLASS's own selection tone rather than the chrome separator
/// (user-directed 2026-08-10): under one appearance the separator resolves near-black at a tenth and
/// draws nothing at all, which left the island's whole boundary on loan from the ground's tone step.
/// A step LIGHTER than the glass is the platform idiom for a lifted dark surface, and it is the same
/// line the panes inside are parted by — one line vocabulary, inside and out.
///
/// `masksToBounds` is what makes the hosted canvas take the corner: the border draws over its
/// sublayers, so the rim never changes the island's size to draw itself.
@MainActor
private final class MacPaneIsland: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.islandRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = Slate.Metric.hairline
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    /// Re-resolved on every appearance change: a `CGColor` is flat and does not follow a theme flip.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.island.cgColor
            layer?.borderColor = Slate.Native.Terminal.edge.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
