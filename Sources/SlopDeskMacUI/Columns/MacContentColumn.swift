// MacContentColumn — the centre column: the pane canvas with the titlebar band standing over it.
//
// The band is AppKit (``MacTitlebarBand``, docs/56 stage D); the CANVAS under it is still the hosted
// SwiftUI ``ContentColumn``, and that split is the point of this controller. The two used to be one
// SwiftUI view with the band as a full-bleed `.overlay(alignment: .top)`, which cost the band a
// `ZStack` it had to be given hit-testing back through, one modifier at a time. As siblings the band
// simply refuses every point it does not occupy (``MacTitlebarBand/hitTest(_:)``) and the canvas gets
// the rest for free.
//
// THE CANVAS STAYS SWIFTUI ON PURPOSE, and it is the next surface to cross rather than an exception:
// it is `SplitContainer` and the twenty-odd files under it — a whole pane subtree, and docs/56 §3.5's
// rule is that a surface is ported WHOLE. The band is a surface; "the band plus half the panes" is not.
//
// The MODAL POINTER SHIELD is this controller's root and therefore covers BOTH children — the same
// deal the navigator column keeps (``MacModalShield``).

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // Slate + the hosted canvas factory
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

        // The canvas: the pane grid, its island geometry and the collapsed panel's rail — everything
        // that is drawn INSIDE the column's ground.
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

        NSLayoutConstraint.activate([
            canvas.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            band.topAnchor.constraint(equalTo: view.topAnchor),
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        paint()
    }

    /// ONE ISLAND: this column paints GROUND end-to-end and the pane canvas is lifted off it as the
    /// window's single island. The band beside that island is the same ground — the tone the navigator
    /// and the code panel stand on — so the top of the window reads as one field with one card in it.
    private func paint() {
        view.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
    }
}
