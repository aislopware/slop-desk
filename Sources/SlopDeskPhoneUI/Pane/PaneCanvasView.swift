// PaneCanvasView — the content column's whole interior, in UIKit (docs/62 stage E): the active tab's
// pane tree, or the Slate empty state when there is no session/tab, with the chip stack standing at its
// foot.
//
// FOUR MODIFIERS BECAME FOUR FACTS, and each is stated because UIKit has no render pass to infer it:
//
//   1. THE SWAP IS OPACITY, NEVER `isHidden` — KEEP-ALL-MOUNTED reaches this level. "No active tab"
//      does not mean "no mounted tabs": the retained sessions' tabs are still mounted, and a hidden
//      subtree does not run `layoutSubviews`, where a layer-hosting view sizes its surface and picks
//      its `contentsScale`. So the canvas fades out and stays laid out; only the empty state is
//      mounted and unmounted, because it owns nothing that has to keep breathing.
//   2. THE CHROME MODEL IS PASSED, NOT PUT IN AN ENVIRONMENT. The deleted SwiftUI column injected it so
//      a deep terminal leaf could reveal the code sidebar without threading a reference; this view
//      takes it as an initializer argument and hands it down the same way it hands down the store —
//      docs/62 stage B, "injection replaces the environment".
//   3. NO GROUND IS PAINTED HERE. ``ContentColumnViewController``'s view is what this canvas stands
//      on, and a second fill would lay chrome cream over the profile's glass — the two tones the
//      one-island law is spent keeping apart.
//   4. NO MODAL TOUCH SHIELD. It is the COLUMN's, which covers this view and the navigation bar above
//      it in one, rather than a flag on the canvas alone.
//
// ⚠️ THERE IS NO LIFTED ISLAND ON THIS PLATFORM, and that is why this file is not a straight mirror of
// `MacContentCanvas`. The Mac draws the canvas inside a glass island with a moat, a rim and a radius;
// `SlateIsland.swift` on the phone holds only the project bed, because docs/56 stage F moved the whole
// of the terminal island up into `MacContentColumn`. `slopdesk-invariants`'
// `ui_seams::canvas-registration` rule pins that: the five island measurements may not be spelled under
// `Sources/SlopDeskPhoneUI` at all. So the canvas runs edge to edge and the chip stack's clearance is
// measured from the SAFE AREA — which the Mac has no equivalent of.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PaneCanvasView: UIView {
    /// The canvas cluster's whole injection list, in one value — see ``PaneCanvasDeps``.
    private let deps: PaneCanvasDeps
    /// NOT part of ``PaneCanvasDeps``: a satellite pane content has no connection to read a cause from,
    /// so this is the content canvas's own dependency rather than the cluster's.
    private let connection: AppConnection
    /// Opens the Connect-to-Host editor — the empty state's one next action for two of its four causes.
    private let onConnect: () -> Void

    private let canvas: SplitCanvasView
    private let empty = SlateEmptyStateView()
    private let chips: IslandChipStackView

    private var generation = 0

    init(deps: PaneCanvasDeps, connection: AppConnection, onConnect: @escaping () -> Void) {
        self.deps = deps
        self.connection = connection
        self.onConnect = onConnect
        canvas = SplitCanvasView(deps: deps)
        chips = IslandChipStackView(store: deps.store, coordinator: deps.overlay, chrome: deps.chrome)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        for view in [canvas, empty] as [UIView] {
            addSubview(view)
            NSLayoutConstraint.activate(view.slateEdges(of: self))
        }
        // The deed behind the empty state's one button is the CAUSE's (``PaneEmptyCause/act(store:onConnect:)``),
        // the same way its label already was. Captured by value rather than through `self`: nothing in
        // it is this view's, so there is no cycle to weaken and no `guard let self` to write.
        empty.onAction = { [store = deps.store, onConnect] cause in
            cause.act(store: store, onConnect: onConnect)
        }
        addSubview(chips)
        NSLayoutConstraint.activate([
            // THE STACK IS CENTRED ON THE CANVAS AND STANDS OFF ITS FOOT — mounted here rather than on
            // the scene root so it is centred on the panes it is talking about (the window's own centre
            // includes the navigator and the code panel) and so its inset is measured from the pane
            // area's bottom edge instead of the window's (user-directed 2026-08-09).
            //
            // ⚠️ THE SAFE AREA, not `bottomAnchor`, and that is the phone's own half of the rule: the
            // home indicator sits in the last few points of this view, so a chip inset from the raw
            // bottom edge lands under it. `MacContentCanvas` pins to the island's real foot because a
            // Mac window has no such reservation.
            safeAreaLayoutGuide.bottomAnchor.constraint(
                equalTo: chips.bottomAnchor, constant: Slate.Metric.islandChipInset,
            ),
            chips.centerXAnchor.constraint(equalTo: centerXAnchor),
            chips.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, constant: -Slate.Metric.space4 * 2,
            ),
        ])
    }

    // MARK: - The live read

    /// ONE tracked pass over the two questions this level answers: is there a tab to draw, and — when
    /// there is not — WHY. Everything inside the canvas is that subtree's own tracked read.
    private func follow() {
        generation &+= 1
        let generation = generation

        var hasActiveTab = false
        var cause: PaneEmptyCause = .neverConnected

        withObservationTracking {
            hasActiveTab = deps.store.tree.activeSession?.activeTab != nil
            // Read UNCONDITIONALLY, not inside the `if`: a tracked read that only happens on one branch
            // stops observing the connection the moment a tab exists, so the empty state would come
            // back later still saying whatever it said the last time it was on screen.
            cause = PaneEmptyCause.resolve(
                status: connection.status, host: connection.target.host,
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        apply(hasActiveTab: hasActiveTab, cause: cause)
    }

    private func apply(hasActiveTab: Bool, cause: PaneEmptyCause) {
        // A PROPERTY, not a method — ``SlateEmptyStateView`` re-composes on assignment, and its own
        // `didSet` is the whole of `MacSlateEmptyState.apply(_:)`.
        empty.cause = cause
        // Point 1 of the header: the canvas FADES, it never hides. `empty` may hide freely — it holds
        // no renderer, no surface and no socket.
        canvas.layer.opacity = hasActiveTab ? 1 : 0
        canvas.isUserInteractionEnabled = hasActiveTab
        empty.isHidden = hasActiveTab
    }

    /// The whole interior is closing. Forwarded so every leaf's renderer comes down and no chip's dwell
    /// outlives the scene holding it.
    func teardown() {
        generation &+= 1
        chips.teardown()
        canvas.teardown()
    }
}
#endif
