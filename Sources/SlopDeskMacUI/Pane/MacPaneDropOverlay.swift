// MacPaneDropOverlay — the soft drop-zone blobs an external drag raises over a pane, in AppKit
// (docs/56 wave R, batch R7; `docs/ui-shell/spec/user-interface__drag-and-drop.md`,
// `screenshots/drop-overlay-frame-action.png`).
//
// The AppKit half of ``PaneDropOverlayView``. Everything it draws was already decided one floor down and
// none of it is re-derived here: the blob geometry is the SHARED ``PaneDropZoneLayout`` (the same
// shapes ``MacPaneDropReceiver`` hit-tests against — draw == hit), and the wording, the
// green-terminal-half / blue-pane-half partition, the label's offset on the two edge ellipses, the
// ring's alpha and the three-way ink verdict are ``DropZonePresentation``. What is left is the ONE
// thing the two halves cannot share: turning a named rung into an `NSColor` and hanging it on a
// layer. The ALPHAS travel with the rung for the same reason the wording does — a half that owned
// the number would be free to disagree about how faint "at rest" is.
//
// ⚠️ THE RUNG LOOKUPS ARE A PAIR, AND THE PAIR IS RATCHETED. `slopdesk-invariants` reads every case
// of `DropZoneInk` and `DropZoneLabelInk` out of the enum and requires this file AND
// the phone's `PaneDropOverlayView.swift` to answer each one explicitly. A `default:` arm would compile and would
// silently ink a newly-added rung as whatever the fallback happened to be, in one renderer only —
// which is the exact drift the ratchet exists to make red. Both switches below are exhaustive by
// hand.
//
// ⚠️ FLIPPED, AND THAT IS LOAD-BEARING. `PaneDropZoneLayout` answers in pane-local coordinates with
// the origin TOP-LEFT and y going down (the CG/SwiftUI convention Rust's `slopdesk_drop_zone_shape`
// is written in). An unflipped `NSView` would place New Tab at the bottom of the pane and Split Left
// at the wrong end of its own ellipse, and nothing would fail — it would just be upside down. So the
// view is flipped and every child is positioned by FRAME, which a flipped parent interprets in the
// same top-left space the layout answers in. Each blob then draws an ellipse inside its own bounds,
// which is symmetric under a flip and therefore cannot inherit the ambiguity.
//
// It is a DECORATION: `hitTest` answers nil so the pointer reaches the pane under it, the AppKit
// spelling of the SwiftUI half's `.allowsHitTesting(false)`. The thing that actually takes the drag
// is ``MacPaneDropReceiver``, which is an ancestor rather than this view — see its header for why a
// drop destination cannot be the transparent overlay.
//
// It stays MOUNTED at `alphaValue = 0` between drags and is faded, never hidden (docs/56 risk 3): a
// hidden subtree does not run `layout()`, and this one lays every blob out from its own bounds.

import AppKit
import SlopDeskClientCore // DropZonePresentation / PaneDropOverlayModel — the verdict, already made
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore // DropZone / PaneDropZoneLayout — the shared geometry

/// The five drop blobs and their labels, drawn over one pane for the length of an external drag.
///
/// Stateless in the sense that matters: it holds no drag state of its own and runs no policy. It
/// FOLLOWS ``PaneDropOverlayModel`` — the same object ``MacPaneDropReceiver`` mutates — because
/// AppKit has no equivalent of a parent re-running a `body` with new arguments, and threading the
/// three values in by hand would have meant a second place that knows when the overlay is up.
@MainActor
final class MacPaneDropOverlay: NSView {
    private let model: PaneDropOverlayModel

    /// One blob and one label per zone, built once and kept — the zone set is `CaseIterable` and
    /// fixed for the life of the view, so there is no reconciliation to do, only a repaint.
    private var blobs: [DropZone: MacPaneDropBlob] = [:]
    private var labels: [DropZone: NSTextField] = [:]

    /// False for the FIRST read only. A pane that mounts under a drag already in flight must not
    /// play the reveal from scratch — the launch state is not a gesture.
    private var settled = false

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

    /// See the header: the layout's origin is top-left, so the view's must be too.
    override var isFlipped: Bool { true }

    /// Transparent to the pointer — a decoration never eats the drag, or the tap that focuses the
    /// pane under it. Answering nil here also answers for every child, so no blob or label needs its
    /// own override.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The two side ellipses are centred ON the pane edge, so half of each spills past x = 0 /
        // x = w. Clipping is what turns that spill into the half-circle hugging each edge that the
        // screenshot shows — the AppKit spelling of the SwiftUI half's `.clipShape(Rectangle())`.
        layer?.masksToBounds = true
        setAccessibilityElement(false)

        // Blob then label, per zone, in the layout's own order: subview order IS draw order here,
        // and the SwiftUI half's `ForEach` interleaves them the same way. A later zone's blob may
        // therefore wash over an earlier zone's label, which is what the shipping overlay does.
        for zone in Self.order {
            let blob = MacPaneDropBlob()
            blob.identifier = NSUserInterfaceItemIdentifier("drop.blob.\(zone.rawValue)")
            addSubview(blob)
            blobs[zone] = blob

            let label = NSTextField(labelWithString: DropZonePresentation.label(zone))
            label.identifier = NSUserInterfaceItemIdentifier("drop.label.\(zone.rawValue)")
            label.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold)
            label.setAccessibilityElement(false)
            addSubview(label)
            labels[zone] = label
        }
    }

    // MARK: - The live read

    /// The three values the SwiftUI half is handed as arguments, read in ONE tracked pass. Reading
    /// them separately would arm three observers over the same stored `content` and repaint the
    /// overlay three times for one cursor move.
    private func follow() {
        ObservationFollow.arm(self) { view in
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
    /// The fade is `alphaValue`, never `isHidden` — see the header. Both moves spend
    /// ``Slate/Motion/reveal``, the rung the SwiftUI half names as `Slate.Anim.reveal`, so the two
    /// halves reveal on one curve.
    private func apply(active: DropZone?, allowed: Set<DropZone>, shown: Bool, animated: Bool) {
        let target: CGFloat = shown ? 1 : 0
        guard animated else {
            alphaValue = target
            repaint(active: active, allowed: allowed, animated: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.reveal.duration
            context.timingFunction = Slate.Motion.reveal.timingFunction
            animator().alphaValue = target
        }
        repaint(active: active, allowed: allowed, animated: true)
    }

    /// The rung → `NSColor` lookup applied to all five zones. Which colour a zone wears is
    /// ``DecorationDropOverlayInk``'s — the verdict, the alphas that travel with it and the ring's
    /// one status rung — and the two `switch`es below are what this shell contributes to it.
    private func repaint(active: DropZone?, allowed: Set<DropZone>, animated: Bool) {
        for (zone, blob) in blobs {
            let inks = DecorationDropOverlayInk.inks(
                for: zone, active: active, allowed: allowed, ink: Self.ink, labelInk: Self.labelInk,
            )
            blob.apply(fill: inks.fill, ring: inks.ring, animated: animated)
            labels[zone]?.textColor = inks.label
        }
    }

    /// AppKit's view of the one ink ladder (`Slate.Status.ok` / `Slate.State.accent` is SwiftUI's
    /// view of the same rungs). Exhaustive by hand — see the header's note on the ratchet.
    private static func ink(_ rung: DropZoneInk) -> NSColor {
        switch rung {
        case .ok: Slate.Native.Status.ok
        case .accent: Slate.Native.accent
        case .accentMuted: Slate.Native.State.accentMuted
        }
    }

    /// The reading ladder, for the label under a blob. The BRANCH that picks a rung is
    /// ``DropZonePresentation/labelInk(active:allowed:)``; this is only its lookup.
    private static func labelInk(_ rung: DropZoneLabelInk) -> NSColor {
        switch rung {
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        case .tertiary: Slate.Native.Text.tertiary
        }
    }

    // MARK: - Geometry

    /// Every blob and label is placed from the view's OWN bounds, which is the pane's laid-out size —
    /// the SwiftUI half is handed that size by a `GeometryReader` and builds the identical layout
    /// from it, so this is the same input by a shorter route.
    override func layout() {
        super.layout()
        let layout = PaneDropZoneLayout(size: bounds.size)
        // A resize is not a reveal: the blobs must arrive at their new places with the pane, not
        // drift there over 0.15s behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for zone in layout.zones {
            let shape = layout.shape(for: zone)
            let marks = DropZonePresentation.marks(zone, in: bounds.size)
            let size = marks.blobSize
            blobs[zone]?.frame = NSRect(
                x: shape.center.x - size.width / 2,
                y: shape.center.y - size.height / 2,
                width: size.width,
                height: size.height,
            )
            guard let label = labels[zone] else { continue }
            let centre = marks.labelCenter
            let fit = label.fittingSize
            label.frame = NSRect(
                x: centre.x - fit.width / 2,
                y: centre.y - fit.height / 2,
                width: fit.width,
                height: fit.height,
            )
        }
        CATransaction.commit()
    }

    /// Auto Layout marks a constrained view as needing layout on a size change, but this view is
    /// also mounted by frame in places that do not; `layout()` is the only thing placing five
    /// children, so it is armed on every resize rather than on some of them.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// A `CGColor` is flat and does not follow a theme flip, so every rung is re-resolved. The
    /// verdict does not move; only the colour under it does.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint(active: model.activeZone, allowed: model.allowedZones, animated: false)
    }
}

// MARK: - One zone's blob

/// A single drop zone's soft ellipse: a wash, and the ring that appears on the hovered one.
///
/// Two layers rather than one stroked-and-filled shape, because the SwiftUI half draws the ring with
/// `strokeBorder` — which strokes INSIDE the shape's edge, while `CAShapeLayer` centres its stroke on
/// the path. The ring's path is inset by half a hairline to land where the other half puts it, and a
/// fill that shared that path would shrink by the same amount.
///
/// The ellipse is drawn inside the blob's OWN bounds, which is symmetric under a flip — so this view
/// stays out of the top-left/bottom-left question its parent answers.
@MainActor
private final class MacPaneDropBlob: NSView {
    /// The two shape layers, the cross-fade and the hairline inset — ``DecorationDropBlob``, one
    /// implementation for both shells.
    private let blob = DecorationDropBlob()

    /// Held so an appearance change (which re-runs `paint`) and a resize (which only re-paths) never
    /// have to guess what the current verdict was.
    private var fill: NSColor = .clear
    private var rim: NSColor = .clear

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(blob.node)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Ink this blob. `animated` spends ``Slate/Motion/reveal`` on the cross-fade — the cursor moving
    /// from one zone to the next is the only thing that ever changes these colours, and it is the
    /// same reveal the whole overlay arrives on.
    func apply(fill: NSColor, ring rim: NSColor, animated: Bool) {
        self.fill = fill
        self.rim = rim
        paint(animated: animated)
    }

    /// ⚠️ `effectiveAppearance` HAS TO BE THE CURRENT ONE while a dynamic colour resolves, or every
    /// rung answers for whatever appearance happened to be drawing last. That is this shell's whole
    /// half of the blob: a `CGColor` is flat, so WHERE it is read from is the decision, and the
    /// layers it is read for are one floor down.
    private func paint(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            blob.ink(fill: fill.cgColor, ring: rim.cgColor, animated: animated)
        }
    }

    override func layout() {
        super.layout()
        blob.place(in: CGRect(origin: .zero, size: bounds.size))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
    }
}
