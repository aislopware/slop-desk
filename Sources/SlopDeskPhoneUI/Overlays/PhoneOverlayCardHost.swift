// PhoneOverlayCardHost — the SUMMONED cards' one presentation seam, in UIKit (docs/62 stage F).
//
// The UIKit half of the deleted `OverlayHostView`'s modal layer: a hit-catching floor and, centred over
// it, whichever of the four summoned surfaces the coordinator currently has up. ONE host so every one of
// them shares one presentation point — the coordinator drives one flag at a time (`run()` closes then
// opens; the `open*` methods are the only writers), so a single resolved ``PhoneOverlaySheet`` can never
// race two chained presentations, and a dismissal routes back through ``closeActiveSheet()`` to the
// matching `close*()`.
//
// ⚠️ IN-WINDOW, NOT PRESENTED, and that is the decision this whole file rests on. UIKit DROPS a second
// `present()` while one is up — a console line, no error, no queue — and the shell already spends its one
// presentation slot on the panel/cheat-sheet pair. A card presented from here would silently not appear
// whenever the panel happened to be up. It is also the only way the card can look like the rest of the
// family: a presented sheet is a separate window, so it paints its own ground across the whole frame
// (a pale flash on open, a halo once the card is inset for its shadow), clips the corner to the SYSTEM's
// radius instead of the family's, and drops its shadow on nothing the user can see. In-window the cast
// falls on the island and the ground, exactly as the island's own does.
//
// ⚠️ THE FLOOR DOES NOT DIM. These are surfaces you summon over your work and dismiss in a second, and
// the workspace behind is the context you summoned them about — the pane switcher makes the same call,
// and the system sheet these replaced did not dim either. It is not invisible-by-alpha either: UIKit
// drops a view at `alpha == 0` (or hidden, or interaction-disabled) out of the hit-test walk entirely,
// and catching the tap that dismisses the card is the floor's whole job. Clear is not transparent.
//
// ⚠️ GLOBAL SEARCH IS THE ONE NON-MODAL MEMBER and gets NO floor. It is deliberately excluded from
// ``OverlayCoordinator/anyModalVisible`` because it must not swallow taps over the workspace, so this
// host disables the floor for it and lets everything outside the card fall through.
//
// ⚠️ TEARING A CARD DOWN HANDS THE KEYBOARD BACK. The card's field is the window's first responder while
// it is up, and simply removing it leaves the WINDOW holding the responder — so the pane the user was
// working in goes deaf and has to be tapped before it will take a keystroke again. The deleted half spent
// an `.onDisappear` on exactly this; nothing else fires here, because the pane's own reclaim paths all
// gate on a focus TRANSITION or a tap and the workspace focus never changed.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit

/// Which summoned surface is up, resolved from the coordinator's flags in a FIXED priority order.
///
/// ⚠️ CONNECT IS IN THIS ENUM WITHOUT BEING A CARD, and it is here to stop a LOCKUP rather than to draw
/// anything. `connectVisible` is one of ``OverlayCoordinator/anyModalVisible``'s five, and
/// ``ContentColumnViewController`` disables the whole canvas while that is true — so the empty state's
/// "Connect" button (which routes to `openConnect()`) would set a flag with no surface behind it and
/// leave the workspace permanently deaf, with no card and no floor to dismiss. It is listed so the host
/// can see it and CLOSE it; the real Connect surface is ``ConnectHostViewController``, a form the
/// platform's own modal is for (user-directed 2026-08-08), and presenting one belongs to the shell that
/// owns the presentation slot.
///
/// ⚠️ DELETE THIS CASE in the same change that wires that controller into ``WorkspaceRootViewController``.
/// Two readers of one flag is a race with an obvious winner: this valve closes on the frame the flag is
/// set, so the sheet would be slammed shut in the frame it opened and Connect would never appear.
enum PhoneOverlaySheet: CaseIterable {
    case palette
    case openQuickly
    case peekReply
    case globalSearch
    case connect
}

@MainActor
final class PhoneOverlayCardHostView: UIView {
    /// Whether a palette row currently shows its ✓ (toggled-on) gutter.
    ///
    /// ⚠️ IT ARRIVES FROM OUTSIDE AND NOTHING BINDS IT YET. The answer is
    /// ``PalettePresentation/toggledState(chrome:store:)``, which needs the live ``WorkspaceChromeState``
    /// — and the layer this host hangs in is constructed with the store, the connection and the
    /// coordinator only. So the closure is a property the SHELL sets, the way it already sets
    /// `onJumpToPane`, and until it does the gutter reads "nothing toggled" rather than lying: the three
    /// chrome rows simply show no ✓. That is a one-line wiring seam in the shell's file, not a defect
    /// here — see this cluster's report.
    var toggledState: @MainActor (PaletteItem) -> Bool = { _ in false }

    private let store: WorkspaceStore
    private let overlay: OverlayCoordinator

    /// The dismiss floor. A `UIControl`, never a tap gesture: a recogniser competes with the card's own
    /// controls and would need a delegate to stay out of their way.
    private lazy var floor = SlateClickTargetView { [weak self] in self?.closeActiveSheet() }
    /// The mounted card, and which surface it draws. `nil` at rest, which is what makes this host inert.
    private var card: UIView?
    private var shown: PhoneOverlaySheet?
    private var generation = 0

    init(store: WorkspaceStore, overlay: OverlayCoordinator) {
        self.store = store
        self.overlay = overlay
        super.init(frame: .zero)
        backgroundColor = .clear
        floor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(floor)
        NSLayoutConstraint.activate([
            floor.topAnchor.constraint(equalTo: topAnchor),
            floor.bottomAnchor.constraint(equalTo: bottomAnchor),
            floor.leadingAnchor.constraint(equalTo: leadingAnchor),
            floor.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Passthrough at rest: with no card up the floor is interaction-disabled, so `super.hitTest` walks
    /// past it and answers with `self` — which must become `nil`, or an always-mounted host takes every
    /// touch away from the workspace it floats over.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    // MARK: - The live read

    /// The one tracked read. ``withObservationTracking(_:onChange:)`` fires ONCE, so the re-arm IS the
    /// subscription, and every tracked read must happen INSIDE the closure.
    ///
    /// ⚠️ ALL FOUR FLAGS ARE READ UNCONDITIONALLY, and the priority is resolved afterwards. Resolving
    /// inside the tracked block — `if paletteVisible { return .palette }` — would SHORT-CIRCUIT past the
    /// other three, and the arm would then hold a dependency on one flag only: a chord that opened Global
    /// Search while the palette was up changes a property nobody is watching, and the host never wakes.
    private func follow() {
        generation &+= 1
        let generation = generation

        var palette = false
        var openQuickly = false
        var peekReply = false
        var globalSearch = false
        var connect = false
        withObservationTracking {
            palette = overlay.paletteVisible
            openQuickly = overlay.openQuicklyVisible
            peekReply = overlay.peekReplyVisible
            globalSearch = overlay.globalSearchVisible
            connect = overlay.connectVisible
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        let active: PhoneOverlaySheet? =
            if palette { .palette }
            else if openQuickly { .openQuickly }
            else if peekReply { .peekReply }
            else if globalSearch { .globalSearch }
            else if connect { .connect }
            else { nil }
        reconcile(active)
    }

    private func reconcile(_ active: PhoneOverlaySheet?) {
        guard active != shown else { return }
        shown = active

        if let outgoing = card {
            card = nil
            outgoing.removeFromSuperview()
            // See the file header: the window keeps the responder otherwise and the pane goes deaf.
            store.reclaimKeyboardFocusInActivePane()
        }

        guard let active else {
            floor.isUserInteractionEnabled = false
            return
        }
        guard let made = make(active) else {
            // ⚠️ A FLAG WITH NOTHING TO DRAW IS CLOSED AT ONCE, and this is a safety valve rather than a
            // feature. Three of the four surfaces have not been rebuilt in UIKit yet, and leaving one of
            // their flags SET would be far worse than doing nothing: `anyModalVisible` is what
            // ``ContentColumnViewController`` shields the canvas on, so a ⌘⇧O with no picker behind it
            // would disable the whole workspace with no card and no floor to dismiss. Closing turns "not
            // ported" into a chord that does nothing, which is recoverable.
            floor.isUserInteractionEnabled = false
            shown = nil
            close(active)
            return
        }

        // Global Search is non-modal — see the file header.
        floor.isUserInteractionEnabled = active != .globalSearch
        card = made
        made.translatesAutoresizingMaskIntoConstraints = false
        addSubview(made)
        // Centred, on the margin the card must never run out of, and capped at the family's own panel
        // width so an iPad does not stretch the keycap column a screen away from the titles.
        let width = made.widthAnchor.constraint(
            lessThanOrEqualToConstant: CGFloat(PaletteMetrics.panelWidth),
        )
        let full = made.widthAnchor.constraint(
            equalTo: safeAreaLayoutGuide.widthAnchor, constant: -2 * Slate.Metric.space4,
        )
        full.priority = .defaultHigh
        NSLayoutConstraint.activate([
            made.centerXAnchor.constraint(equalTo: centerXAnchor),
            made.centerYAnchor.constraint(equalTo: centerYAnchor),
            width, full,
            made.topAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: Slate.Metric.space4,
            ),
            made.bottomAnchor.constraint(
                lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -Slate.Metric.space4,
            ),
        ])
        // The card arrives by fading in. Seeded at zero FIRST — ``PaneFade`` guards on the opacity it
        // finds, so an already-opaque view would simply never animate.
        made.layer.opacity = 0
        PaneFade.set(made, shown: true, curve: Slate.Motion.smallFade)
    }

    /// Builds the card for `sheet`, or `nil` while that surface is still SwiftUI-shaped — see the
    /// safety valve above for what `nil` costs.
    private func make(_ sheet: PhoneOverlaySheet) -> UIView? {
        switch sheet {
        case .palette: PhonePaletteCardView(store: store, overlay: overlay, toggledState: toggledState)
        case .openQuickly,
             .peekReply,
             .globalSearch,
             .connect: nil
        }
    }

    // MARK: - Closing

    /// The floor's tap, and the card's own Esc. Mirrors the priority order above so a dismissal always
    /// lands on the surface that is actually up.
    func closeActiveSheet() {
        guard let shown else { return }
        close(shown)
    }

    private func close(_ sheet: PhoneOverlaySheet) {
        switch sheet {
        case .palette: overlay.closePalette()
        case .openQuickly: overlay.closeOpenQuickly()
        case .peekReply: overlay.closePeekReply()
        case .globalSearch: overlay.closeGlobalSearch()
        // Closing also bumps `connectGeneration`, which invalidates any in-flight connect Task exactly
        // as Cancel would — so this is the same exit the form's own Cancel takes, not a back door.
        case .connect: overlay.closeConnect()
        }
    }
}
#endif
