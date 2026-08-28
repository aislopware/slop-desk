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
// ⚠️ GLOBAL SEARCH IS THE ONE MEMBER OUTSIDE ``OverlayCoordinator/anyModalVisible``, and that buys it
// exactly one thing: ``ContentColumnViewController`` does not disable the canvas underneath while it is
// up. It still gets the floor, like every sibling — both shipped halves gave it one (the deleted
// `OverlayHostView` mounted it on the same hit-catching backdrop as the other three, and the Mac's rides
// a `MacOverlayPanelController` whose content view IS a dismiss floor), and without one the surface has
// no touch dismissal at all: it carries no ✕ by design and its Esc needs a hardware keyboard.
// (The coordinator's own comment on `globalSearchVisible` still describes a host that mounts it without a
// backdrop. That host is deleted and never behaved that way — see this cluster's report.)
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

    /// Whether the card takes the WHOLE sheet rather than hugging its content.
    ///
    /// Global search alone, and ``GlobalSearchMetrics`` is where that is decided rather than here: the
    /// Mac's panel is a fixed size because the workspace behind it is the context every hit jumps into,
    /// and the phone "takes the whole sheet instead" because on a screen with no *behind* there is
    /// nothing to leave uncovered. It is also the only one of the five whose content cannot answer a
    /// height question — see ``PhoneOverlayCardHostView/fill(_:)``.
    var fills: Bool { self == .globalSearch }
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
            // feature. One surface — Connect, which has a CONTROLLER of its own and is waiting only on
            // the shell to present it — is not drawn here, and leaving its flag SET would be far worse
            // than doing nothing: `anyModalVisible` is what
            // ``ContentColumnViewController`` shields the canvas on, so a ⌘⇧O with no picker behind it
            // would disable the whole workspace with no card and no floor to dismiss. Closing turns "not
            // ported" into a chord that does nothing, which is recoverable.
            floor.isUserInteractionEnabled = false
            shown = nil
            close(active)
            return
        }

        // Every surface gets the floor, Global Search included — see the file header.
        floor.isUserInteractionEnabled = true
        card = made
        made.translatesAutoresizingMaskIntoConstraints = false
        addSubview(made)
        NSLayoutConstraint.activate(active.fills ? fill(made) : hug(made))
        // The card arrives by fading in. Seeded at zero FIRST — ``PaneFade`` guards on the opacity it
        // finds, so an already-opaque view would simply never animate.
        made.layer.opacity = 0
        PaneFade.set(made, shown: true, curve: Slate.Motion.smallFade)
    }

    /// Builds the card for `sheet`, or `nil` for the one surface this layer does not draw — see the
    /// safety valve above for what `nil` costs.
    ///
    /// ⚠️ `.connect` IS THE `nil`, AND THIS CASE MUST GO when the shell wires it up. It is a
    /// ``ConnectHostViewController``, a real presentation with system chrome, so it belongs to whatever
    /// PRESENTS the panel/cheat-sheet pair and must queue behind them — not to an in-window layer that
    /// would draw it a second time.
    private func make(_ sheet: PhoneOverlaySheet) -> UIView? {
        switch sheet {
        case .palette: PhonePaletteCardView(store: store, overlay: overlay, toggledState: toggledState)
        case .globalSearch: PhoneGlobalSearchCardView(store: store, overlay: overlay)
        case .openQuickly: PhoneOpenQuicklyCardView(store: store, overlay: overlay)
        case .peekReply: PhonePeekReplyCardView(store: store, overlay: overlay)
        case .connect: nil
        }
    }

    // MARK: - The two sizings

    /// The family's own: CENTRED, on the margin the card must never run out of, and capped at the panel
    /// width so an iPad does not stretch the keycap column a screen away from the titles. A card sized
    /// this way HUGS — it is as tall as its content, and its content is what decides.
    ///
    /// The CENTRE is only a preference here (``UILayoutPriority/defaultHigh``), and that is the software
    /// keyboard's doing: every surface in this family opens by taking first responder, so the keyboard is
    /// up before the card has drawn once, and a REQUIRED centre plus a keyboard-aware floor is
    /// unsatisfiable for any card taller than the half-screen that leaves. Broken deliberately, the
    /// solver parks the card as near centred as the two caps permit — which is against the keyboard.
    private func hug(_ card: UIView) -> [NSLayoutConstraint] {
        let width = card.widthAnchor.constraint(
            lessThanOrEqualToConstant: CGFloat(PaletteMetrics.panelWidth),
        )
        let full = card.widthAnchor.constraint(
            equalTo: safeAreaLayoutGuide.widthAnchor, constant: -2 * Slate.Metric.space4,
        )
        full.priority = .defaultHigh
        let centre = card.centerYAnchor.constraint(equalTo: centerYAnchor)
        centre.priority = .defaultHigh
        return [
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            centre,
            width, full,
            card.topAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: Slate.Metric.space4,
            ),
        ] + floors(card)
    }

    /// The whole sheet, on the same margin. Four sides PINNED, where the recipe above has two caps and a
    /// hug — which is the difference, not a tweak to it: a filling card is told its height instead of
    /// being asked for one, and a table view (which has no intrinsic size at all) can only be given one
    /// that way. Asked, it answers zero, and the card would collapse to its query bar.
    ///
    /// The bottom is the ONE exception to "pinned", for the reason in ``floors(_:)``: it is the two caps
    /// plus a low-priority reach for the safe area, so the card is as tall as the space it is left rather
    /// than a fixed height that the keyboard then covers.
    private func fill(_ card: UIView) -> [NSLayoutConstraint] {
        let tall = card.bottomAnchor.constraint(
            equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Slate.Metric.space4,
        )
        tall.priority = .defaultLow
        return [
            card.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor, constant: Slate.Metric.space4,
            ),
            tall,
            card.leadingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Slate.Metric.space4,
            ),
            card.trailingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Slate.Metric.space4,
            ),
        ] + floors(card)
    }

    /// The bottom edge, for BOTH sizings, and it is two caps rather than one because the two guides
    /// answer different questions and neither subsumes the other. `safeAreaLayoutGuide` knows about the
    /// home indicator and nothing about the keyboard; `keyboardLayoutGuide` tracks the keyboard and, when
    /// it is down, sits flush with the view's bottom EDGE — under the indicator. Taking the lower of the
    /// two is the only spelling that is right in both states.
    ///
    /// ⚠️ THIS IS NOT DECORATION — the card opens with the keyboard already up. Without the keyboard cap
    /// a filling card's last rows sit BEHIND it and can never be scrolled out from under it, since the
    /// table's own insets know nothing about a view the card is not inside.
    private func floors(_ card: UIView) -> [NSLayoutConstraint] {
        [
            card.bottomAnchor.constraint(
                lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -Slate.Metric.space4,
            ),
            card.bottomAnchor.constraint(
                lessThanOrEqualTo: keyboardLayoutGuide.topAnchor, constant: -Slate.Metric.space4,
            ),
        ]
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
