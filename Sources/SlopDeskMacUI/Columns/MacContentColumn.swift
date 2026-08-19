// MacContentColumn — the centre column: the pane canvas, with the titlebar band standing over it and
// the collapsed panel's rail standing at its trailing corner.
//
// The band and the rail are AppKit (``MacTitlebarBand``, ``MacPanelRail``, docs/56 stage D); the
// CANVAS between them is still the hosted SwiftUI ``ContentColumn``, and that split is the point of
// this controller. The band used to be a full-bleed `.overlay(alignment: .top)` inside that one
// SwiftUI view, which cost it a `ZStack` it had to be given hit-testing back through, one modifier at
// a time. As siblings each simply refuses every point it does not occupy
// (``MacTitlebarBand/hitTest(_:)``, ``MacPanelRail/hitTest(_:)``) and the canvas gets the rest free.
//
// THE CANVAS STAYS SWIFTUI ON PURPOSE, and it is the next surface to cross rather than an exception:
// it is `SplitContainer` and the twenty-odd files under it — a whole pane subtree, and docs/56 §3.5's
// rule is that a surface is ported WHOLE. The band is a surface; "the band plus half the panes" is not.
//
// The MODAL POINTER SHIELD is this controller's root and therefore covers BOTH children — the same
// deal the navigator column keeps (``MacModalShield``).

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // the hosted canvas factory + the pane drag coordinator
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

        // The canvas: the pane grid and its island geometry — everything that is drawn INSIDE the
        // column's ground. It keeps the rail's WIDTH reserved (its own trailing padding) even though
        // the rail itself is no longer its child, because the moat is measured inside what is left.
        let canvas = WorkspaceColumnHosts.content(
            store: store, connection: connection, chrome: chrome, onConnect: onConnect,
            paneDrag: paneDrag, overlay: overlay,
        )
        addChild(canvas)
        canvas.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas.view)

        let band = MacTitlebarBand(
            store: store, connection: connection, chrome: chrome, onConnect: onConnect,
        )
        view.addSubview(band)
        view.addSubview(rail)

        NSLayoutConstraint.activate([
            canvas.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            band.topAnchor.constraint(equalTo: view.topAnchor),
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The rail hangs from the column's TOP TRAILING corner and is as tall as what it carries
            // — no bottom anchor, so the canvas keeps every point below it.
            rail.topAnchor.constraint(equalTo: view.topAnchor),
            rail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        followRail()
        paint()
    }

    /// What the collapsed panel leaves behind. Mounted at ALL times and travelling in and out, because
    /// mounting it on the flag put a turned rail on top of a terminal that had not yet made room for
    /// it (user-reported 2026-08-09) — see ``MacPanelRail/travel(railed:animated:)``.
    private lazy var rail = MacPanelRail(chrome: chrome)

    /// The rail arrives when the panel collapses. `animated` is false only for the first read, which
    /// is the launch state rather than a gesture: a window that opens with the panel already collapsed
    /// should not play the arrival.
    private func followRail() {
        var railed = false
        withObservationTracking {
            railed = chrome.codeSidebarCollapsed
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followRail() }
            }
        }
        rail.travel(railed: railed, animated: settled)
        settled = true
    }

    private var settled = false

    /// ONE ISLAND: this column paints GROUND end-to-end and the pane canvas is lifted off it as the
    /// window's single island. The band beside that island is the same ground — the tone the navigator
    /// and the code panel stand on — so the top of the window reads as one field with one card in it.
    private func paint() {
        view.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
    }
}
