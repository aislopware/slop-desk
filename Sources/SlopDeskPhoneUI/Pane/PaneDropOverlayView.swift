// PaneDropOverlayView — the soft drop-zone blobs an external drag raises over a pane, in UIKit
// (docs/62 stage E.2; `docs/ui-shell/spec/user-interface__drag-and-drop.md`,
// `screenshots/drop-overlay-frame-action.png`).
//
// The UIKit half of the deleted `PaneDropOverlay`. Everything it draws was already decided one floor
// down and none of it is re-derived here: the blob geometry is the SHARED ``PaneDropZoneLayout`` (the
// same shapes ``PaneDropReceiverView`` hit-tests against — draw == hit), and the wording, the
// green-terminal-half / blue-pane-half partition, the label's offset on the two edge ellipses, the
// ring's alpha and the three-way ink verdict are ``DropZonePresentation``. What is left is the ONE
// thing the renderers cannot share: turning a named rung into a `UIColor` and hanging it on a layer.
// The ALPHAS travel with the rung for the same reason the wording does — a half that owned the number
// would be free to disagree about how faint "at rest" is.
//
// ⚠️ THE RUNG LOOKUPS ARE A PAIR, AND THE PAIR IS RATCHETED. `slopdesk-invariants` reads every case
// of `DropZoneInk` and `DropZoneLabelInk` out of the enum and requires this file AND its Mac twin to
// answer each one explicitly. A `default:` arm would compile and would silently ink a newly-added rung
// as whatever the fallback happened to be, in one renderer only — which is the exact drift the ratchet
// exists to make red. Both switches below are exhaustive by hand.
//
// NO FLIP, AND THAT IS THE WHOLE OF THE COORDINATE STORY. `PaneDropZoneLayout` answers in pane-local
// coordinates with the origin TOP-LEFT and y going down (the CG convention Rust's
// `slopdesk_drop_zone_shape` is written in). `MacPaneDropOverlay` has to override `isFlipped` to reach
// that space and says so at length; a `UIView` is already there, so the rects pass through untouched
// and the override simply vanishes. Each blob then draws an ellipse inside its own bounds, which is
// symmetric under a flip and never had the ambiguity anyway.
//
// It is a DECORATION: `isUserInteractionEnabled = false` so the touch reaches the pane under it — the
// UIKit spelling of the deleted half's `.allowsHitTesting(false)`, and unlike AppKit it needs no
// second half (there are no tracking areas here). The thing that actually takes the drag is
// ``PaneDropReceiverView``, which carries the `UIDropInteraction`.
//
// It stays MOUNTED at opacity 0 between drags and is faded, never hidden (docs/62 §3.2): a hidden
// subtree does not run `layoutSubviews`, and this one lays every blob out from its own bounds.

#if os(iOS)
import SlopDeskClientCore // DropZonePresentation / PaneDropOverlayModel — the verdict, already made
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore // DropZone / PaneDropZoneLayout — the shared geometry
import UIKit

/// The five drop blobs and their labels, drawn over one pane for the length of an external drag.
///
/// Stateless in the sense that matters: it holds no drag state of its own and runs no policy. It
/// FOLLOWS ``PaneDropOverlayModel`` — the same object ``PaneDropReceiverView`` mutates — because UIKit
/// has no equivalent of a parent re-running a `body` with new arguments, and threading the three
/// values in by hand would have meant a second place that knows when the overlay is up.
@MainActor
final class PaneDropOverlayView: UIView {
    private let model: PaneDropOverlayModel

    /// One blob and one label per zone, built once and kept — the zone set is `CaseIterable` and
    /// fixed for the life of the view, so there is no reconciliation to do, only a repaint.
    private var blobs: [DropZone: PaneDropBlobView] = [:]
    private var labels: [DropZone: UILabel] = [:]

    /// False for the FIRST read only. A pane that mounts under a drag already in flight must not
    /// play the reveal from scratch — the launch state is not a gesture.
    private var settled = false

    /// The live following, stopped on teardown so a late wake cannot re-arm against a model this overlay
    /// has finished with (docs/62 §3.1).
    private var dropFollow: ObservationFollow?

    /// The draw / hit ORDER, which is ``PaneDropZoneLayout/zones``'. Asked of a degenerate layout
    /// because the order belongs to the layout type and not to any one pane's size — spelling
    /// `DropZone.allCases` here instead would be a second statement of the same thing, free to drift
    /// the day the layout re-orders its zones.
    private static let order = PaneDropZoneLayout(size: .zero).zones

    init(model: PaneDropOverlayModel) {
        self.model = model
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.opacity = 0
        // The two side ellipses are centred ON the pane edge, so half of each spills past x = 0 /
        // x = w. Clipping is what turns that spill into the half-circle hugging each edge that the
        // screenshot shows — the UIKit spelling of the deleted half's `.clipShape(Rectangle())`.
        clipsToBounds = true

        // Blob then label, per zone, in the layout's own order: subview order IS draw order here,
        // and the deleted half's `ForEach` interleaved them the same way. A later zone's blob may
        // therefore wash over an earlier zone's label, which is what the shipping overlay does.
        for zone in Self.order {
            let blob = PaneDropBlobView()
            blob.accessibilityIdentifier = "drop.blob.\(zone.rawValue)"
            addSubview(blob)
            blobs[zone] = blob

            let label = UILabel()
            label.text = DropZonePresentation.label(zone)
            label.accessibilityIdentifier = "drop.label.\(zone.rawValue)"
            label.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold)
            label.isAccessibilityElement = false
            addSubview(label)
            labels[zone] = label
        }
    }

    /// The pane is going away for good. Ends the tracking chain — ``ObservationFollow/stop()`` is what
    /// makes a wake already in flight a no-op.
    func teardown() {
        dropFollow?.stop()
        dropFollow = nil
    }

    // MARK: - The live read

    /// The three values the deleted half was handed as arguments, read in ONE tracked pass. Reading
    /// them separately would arm three observers over the same stored `content` and repaint the
    /// overlay three times for one finger move.
    private func follow() {
        dropFollow = ObservationFollow.arm(self) { view in
            (active: view.model.activeZone, allowed: view.model.allowedZones, shown: view.model.isActive)
        } apply: { view, reading in
            view.apply(
                active: reading.active, allowed: reading.allowed, shown: reading.shown,
                animated: view.settled,
            )
            view.settled = true
        }
    }

    /// Fade the whole overlay to the drag's presence and re-ink every blob to the hovered zone.
    ///
    /// The fade is opacity, never `isHidden` — see the header. Both moves spend ``Slate/Motion/reveal``,
    /// the rung the deleted half named as `Slate.Anim.reveal`, so the two renderers reveal on one curve.
    private func apply(active: DropZone?, allowed: Set<DropZone>, shown: Bool, animated: Bool) {
        PaneFade.set(self, shown: shown)
        repaint(active: active, allowed: allowed, animated: animated)
    }

    /// The rung → `UIColor` lookup applied to all five zones. Which colour a zone wears is
    /// ``DecorationDropOverlayInk``'s — the verdict, the alphas that travel with it and the ring's one
    /// status rung — and the two `switch`es below are what this renderer contributes to it.
    ///
    /// A `UIColor` on a label stays dynamic and re-resolves itself on a theme flip, so unlike the
    /// blobs' `CGColor`s the labels need no re-ink pass of their own.
    private func repaint(active: DropZone?, allowed: Set<DropZone>, animated: Bool) {
        for (zone, blob) in blobs {
            let inks = DecorationDropOverlayInk.inks(
                for: zone, active: active, allowed: allowed, ink: Self.ink, labelInk: Self.labelInk,
            )
            blob.apply(fill: inks.fill, ring: inks.ring, animated: animated)
            labels[zone]?.textColor = inks.label
        }
    }

    /// UIKit's view of the one ink ladder (`Slate.Status.ok` / `Slate.State.accent` was SwiftUI's view
    /// of the same rungs). Exhaustive by hand — see the header's note on the ratchet.
    private static func ink(_ rung: DropZoneInk) -> UIColor {
        switch rung {
        case .ok: Slate.Native.Status.ok
        case .accent: Slate.Native.accent
        case .accentMuted: Slate.Native.State.accentMuted
        }
    }

    /// The reading ladder, for the label under a blob. The BRANCH that picks a rung is
    /// ``DropZonePresentation/labelInk(active:allowed:)``; this is only its lookup.
    private static func labelInk(_ rung: DropZoneLabelInk) -> UIColor {
        switch rung {
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        case .tertiary: Slate.Native.Text.tertiary
        }
    }

    // MARK: - Geometry

    /// Every blob and label is placed from the view's OWN bounds, which is the pane's laid-out size —
    /// the deleted half was handed that size by a `GeometryReader` and built the identical layout from
    /// it, so this is the same input by a shorter route.
    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = PaneDropZoneLayout(size: bounds.size)
        // A resize is not a reveal: the blobs must arrive at their new places with the pane, not
        // drift there over 0.15s behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for zone in layout.zones {
            let shape = layout.shape(for: zone)
            let marks = DropZonePresentation.marks(zone, in: bounds.size)
            let size = marks.blobSize
            blobs[zone]?.frame = CGRect(
                x: shape.center.x - size.width / 2,
                y: shape.center.y - size.height / 2,
                width: size.width,
                height: size.height,
            )
            guard let label = labels[zone] else { continue }
            let centre = marks.labelCenter
            let fit = label.intrinsicContentSize
            label.frame = CGRect(
                x: centre.x - fit.width / 2,
                y: centre.y - fit.height / 2,
                width: fit.width,
                height: fit.height,
            )
        }
        CATransaction.commit()
    }
}

// MARK: - One zone's blob

/// A single drop zone's soft ellipse: a wash, and the ring that appears on the hovered one.
///
/// Two layers rather than one stroked-and-filled shape, because the deleted half drew the ring with
/// `strokeBorder` — which strokes INSIDE the shape's edge, while `CAShapeLayer` centres its stroke on
/// the path. The ring's path is inset by half a hairline to land where the other half puts it, and a
/// fill that shared that path would shrink by the same amount.
@MainActor
private final class PaneDropBlobView: UIView {
    /// The two shape layers, the cross-fade and the hairline inset — ``DecorationDropBlob``, one
    /// implementation for both shells.
    private let blob = DecorationDropBlob()

    /// Held so a theme flip (which re-inks) and a resize (which only re-paths) never have to guess
    /// what the current verdict was.
    private var fill: UIColor = .clear
    private var rim: UIColor = .clear

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(blob.node)
        // A `CGColor` is flat and does not follow a theme flip, so both rungs are re-resolved. The
        // verdict does not move; only the colour under it does.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.apply(fill: view.fill, ring: view.rim, animated: false)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Ink this blob. `animated` spends ``Slate/Motion/reveal`` on the cross-fade — the finger moving
    /// from one zone to the next is the only thing that ever changes these colours, and it is the
    /// same reveal the whole overlay arrives on.
    ///
    /// ⚠️ THE COLOURS RESOLVE HERE, against this view's own `traitCollection`, and that is this
    /// renderer's whole half of the blob: a `CGColor` is flat, so WHERE it is read from is the
    /// decision and the layers it is read for are one floor down.
    func apply(fill: UIColor, ring rim: UIColor, animated: Bool) {
        self.fill = fill
        self.rim = rim
        blob.ink(
            fill: fill.resolvedColor(with: traitCollection).cgColor,
            ring: rim.resolvedColor(with: traitCollection).cgColor,
            animated: animated,
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blob.place(in: CGRect(origin: .zero, size: bounds.size))
    }
}
#endif
