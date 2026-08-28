// MacContentCanvas — the island's whole interior, in AppKit (docs/56 wave R, R12): the active tab's
// pane tree, or the Slate empty state when there is no session/tab, with the island's chip stack
// standing at its foot.
//
// This is the last piece of the centre column to cross. ``MacContentColumn`` held the island, the band
// and the rail from stage F onward and hosted a SwiftUI `ContentColumn` inside it, because a surface is
// ported WHOLE and "the island plus half the panes" is not a surface. R11 wrote the panes
// (``MacSplitCanvasView``); this file is the three things that were around them, and with it the
// hosting factory has nothing left to hand over.
//
// FOUR MODIFIERS BECAME FOUR FACTS, and each is stated because AppKit has no render pass to infer it:
//
//   1. THE SWAP IS ALPHA, NEVER `isHidden` — KEEP-ALL-MOUNTED reaches this level. "No active tab" does
//      not mean "no mounted tabs": the retained sessions' tabs are still mounted, and a hidden subtree
//      does not run `layout()`, where a layer-hosting view sizes its surface and picks its
//      `contentsScale`. So the canvas fades out and stays laid out; only the empty state is mounted
//      and unmounted, because it owns nothing that has to keep breathing.
//   2. THE CHROME MODEL IS PASSED, NOT PUT IN AN ENVIRONMENT. The SwiftUI column injected it so a deep
//      terminal leaf could reveal the code sidebar without threading a reference; the canvas takes it
//      as an initializer argument and hands it down the same way it hands down the store.
//   3. NO GROUND IS PAINTED HERE. The island's layer is what this canvas stands on
//      (``MacContentColumn``), and a second fill would lay chrome cream over the profile's glass — the
//      two tones the one-island law is spent keeping apart.
//   4. NO MODAL POINTER SHIELD. It is the COLUMN's root (``MacModalShield``), which covers this view
//      and the band above it in one, rather than a `.allowsHitTesting` on the canvas alone.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

@MainActor
final class MacContentCanvas: NSView {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    /// Opens the Connect-to-Host editor — the empty state's one next action for two of its four causes.
    private let onConnect: () -> Void

    private let canvas: MacSplitCanvasView
    private let empty = MacSlateEmptyState(frame: .zero)
    private let chips: MacIslandChipStack

    /// Kept because ``teardown()`` must END the following while this controller lives on — the case
    /// ``ObservationFollow/stop()`` exists for.
    private var canvasFollow: ObservationFollow?

    init(
        store: WorkspaceStore,
        connection: AppConnection,
        chrome: WorkspaceChromeState,
        onConnect: @escaping () -> Void,
        paneDrag: PaneDragCoordinator?,
        overlay: OverlayCoordinator?,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.onConnect = onConnect
        canvas = MacSplitCanvasView(
            store: store, paneDrag: paneDrag, overlay: overlay, chrome: chrome,
        )
        chips = MacIslandChipStack(store: store, coordinator: overlay, chrome: chrome)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        addSubview(empty)
        addSubview(chips)

        empty.onAction = { [weak self] cause in
            guard let self else { return }
            switch cause {
            case .neverConnected,
                 .connectFailed: onConnect()
            case .noTabs: store.newTerminalPane(.newTab)
            case .linkDown: break // redials itself; no user action offered
            }
        }

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.topAnchor.constraint(equalTo: topAnchor),
            empty.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor),
            // THE STACK IS CENTRED ON THE ISLAND AND STANDS OFF ITS FOOT — mounted here rather than on
            // the window root so it is centred on the canvas it is talking about (the window's own
            // centre includes the navigator and the code panel) and so its inset is measured from the
            // glass's bottom edge instead of the window's (user-directed 2026-08-09).
            chips.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomAnchor.constraint(
                equalTo: chips.bottomAnchor, constant: Slate.Metric.islandChipInset,
            ),
            chips.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, constant: -Slate.Metric.space4 * 2,
            ),
        ])
    }

    // MARK: - The live read

    /// ONE tracked pass over the two questions this level answers: is there a tab to draw, and — when
    /// there is not — WHY. Everything inside the canvas is that subtree's own tracked read.
    private func follow() {
        canvasFollow = ObservationFollow.arm(self) { view in
            (
                hasActiveTab: view.store.tree.activeSession?.activeTab != nil,
                // Read UNCONDITIONALLY, never inside a branch: a tracked read that only happens on one
                // branch stops observing the connection the moment a tab exists, so the empty state
                // would come back later still saying whatever it said the last time it was on screen.
                cause: PaneEmptyCause.resolve(
                    status: view.connection.status, host: view.connection.target.host,
                ),
            )
        } apply: { view, reading in
            view.apply(hasActiveTab: reading.hasActiveTab, cause: reading.cause)
        }
    }

    private func apply(hasActiveTab: Bool, cause: PaneEmptyCause) {
        empty.apply(cause)
        // Point 1 of the header: the canvas FADES, it never hides. `empty` may hide freely — it holds
        // no renderer, no surface and no socket.
        canvas.alphaValue = hasActiveTab ? 1 : 0
        empty.isHidden = hasActiveTab
    }

    /// The whole interior is closing. Forwarded so every leaf's renderer comes down and no chip's dwell
    /// outlives the window holding it.
    func teardown() {
        canvasFollow?.stop()
        chips.teardown()
        canvas.teardown()
    }
}
