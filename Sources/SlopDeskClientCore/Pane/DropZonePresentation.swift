// DropZonePresentation — what the five drop blobs SAY and how they are inked, for both halves.
//
// The overlay that draws them is a stateless renderer over `PaneDropZoneLayout` — the ellipse
// centres and radii are already one function in Rust (`slopdesk_drop_zone_shape`), which is what
// makes draw == hit true rather than merely intended. What had NOT descended with the geometry was
// everything around it: the five labels, the green-terminal-half / blue-pane-half partition, the
// label's offset for the two edge ellipses, and the three-way branch that picks a blob's wash. Each
// is small, and each is exactly the kind of thing a second renderer re-derives slightly differently
// — the Mac's "Open In-Place" against the phone's "Open in place", a partition that puts Insert Path
// on the wrong side of the split, an edge label that drifts off-pane.
//
// THE INK IS NAMED, NEVER COLOURED. `SlopDeskClientCore` holds no design tokens (docs/56 §2): the
// verdict below says WHICH RUNG at WHAT ALPHA and each framework resolves it through its own view of
// the one ladder — `Slate.Status.ok` / `Slate.State.accent` in SwiftUI, `Slate.Native.*` in AppKit —
// the same "one palette, drawn twice and spelled once" shape `ToastMarkRung` and `AgentReadout`
// already are. The alphas travel WITH the rung for the same reason: a wash is the pair, and a half
// that owned the number would be free to disagree about how faint "at rest" is.
//
// The negative-radius clamp travels too. A pane that has not been laid out yet has a zero (or, mid
// re-layout, a negative) box, and the Rust layout answers proportionally — so the clamp is what
// stops a frame with a negative dimension reaching either framework, where SwiftUI logs and AppKit
// draws garbage. It is one `max` and it belongs next to the size it guards, not in two view bodies.

import CoreGraphics
import SlopDeskWorkspaceCore

/// Which rung of the one ink ladder a blob's wash is drawn from. Named, not coloured — see the file
/// header.
package enum DropZoneInk: Sendable, Equatable {
    /// The status-OK rung (green): the hovered zone, and the terminal half at rest.
    case ok
    /// The accent rung: the pane half at rest.
    case accent
    /// The muted-accent rung: a zone the dragged content cannot act on — a barely-there neutral, not
    /// a faded accent, so a disabled blob never reads as merely "further away".
    case accentMuted
}

/// One blob's wash: the rung, and the alpha it is laid down at. `opacity == 1` means the rung's own
/// value, undiluted (the muted rung is already the faint one).
package struct DropZoneTint: Sendable, Equatable {
    package let ink: DropZoneInk
    package let opacity: Double

    package init(ink: DropZoneInk, opacity: Double) {
        self.ink = ink
        self.opacity = opacity
    }
}

/// Which rung a zone's LABEL is drawn in — the reading ladder, not the status one.
package enum DropZoneLabelInk: Sendable, Equatable {
    /// The hovered zone: full-strength reading ink.
    case primary
    /// An allowed but un-hovered zone.
    case secondary
    /// A zone the content cannot act on — faded, matching its muted blob.
    case tertiary
}

/// The wording, the partition, the label geometry and the ink verdicts of the pane drop overlay.
/// Everything here is a pure function of `(zone, state, shape)`; nothing draws.
package enum DropZonePresentation {
    // MARK: - The partition

    /// The "green / terminal half" zones (the drag-and-drop spec's left column) — tinted green even
    /// at rest, because both of them act on the TERMINAL (a new rooted tab, an inject into the live
    /// PTY). The remaining "blue / pane half" zones act on the PANE TREE and tint with the accent.
    /// The split is the user's whole mental model of the overlay, so it is one set rather than a
    /// condition each renderer writes out.
    package static let terminalHalf: Set<DropZone> = [.newTab, .insertPath]

    // MARK: - The wording

    /// The label under a zone's blob. Title Case, and "Open In-Place" keeps its capital I and its
    /// hyphen — it names the verb the ⌘-click menu already spells that way.
    package static func label(_ zone: DropZone) -> String {
        switch zone {
        case .newTab: "New Tab"
        case .insertPath: "Insert Path"
        case .openInPlace: "Open In-Place"
        case .splitLeft: "Split Left"
        case .splitRight: "Split Right"
        }
    }

    // MARK: - Geometry the shape does not carry

    /// The blob's drawn size for `shape`, clamped away from negative dimensions (see the header): a
    /// pane mid-layout answers with a degenerate box, and neither framework may be handed a negative
    /// width.
    package static func blobSize(for shape: DropZoneShape) -> CGSize {
        CGSize(width: max(shape.radiusX * 2, 0), height: max(shape.radiusY * 2, 0))
    }

    /// Where a zone's label sits in pane-local coordinates: at the blob centre for the three central
    /// circles, and inset from the edge for the two side ellipses — whose true centre is ON the pane
    /// edge (half the blob is clipped away), so a centred label would be half off-pane. Half the
    /// x-radius in from the edge lands it inside the visible half of the ellipse.
    ///
    /// This is the one bit of drop geometry that never made it into `PaneDropZoneLayout`, and it is
    /// here rather than beside `shape(for:)` only because the shapes are answered by Rust and a label
    /// offset is not a law of the layout — it is a reading decision about text.
    package static func labelCenter(_ zone: DropZone, shape: DropZoneShape, in size: CGSize) -> CGPoint {
        switch zone {
        case .splitLeft: CGPoint(x: shape.radiusX * 0.5, y: shape.center.y)
        case .splitRight: CGPoint(x: size.width - shape.radiusX * 0.5, y: shape.center.y)
        default: shape.center
        }
    }

    // MARK: - The ink verdicts

    /// The alpha the active zone's ring is stroked at. Here rather than in either renderer for the
    /// same reason the washes are: the ring is what says "release now", and two halves that ringed a
    /// hover differently would be two different affordances.
    package static let activeStrokeOpacity = 0.7

    /// The blob's wash: the hovered zone glows status-green at half strength; an allowed zone sits as
    /// a faint wash (green for the terminal half, accent for the pane half); a disabled zone is a
    /// barely-there neutral.
    package static func tint(_ zone: DropZone, active: Bool, allowed: Bool) -> DropZoneTint {
        if active { return DropZoneTint(ink: .ok, opacity: 0.5) }
        if !allowed { return DropZoneTint(ink: .accentMuted, opacity: 1) }
        return terminalHalf.contains(zone)
            ? DropZoneTint(ink: .ok, opacity: 0.14)
            : DropZoneTint(ink: .accent, opacity: 0.10)
    }

    /// The label's rung: bright on the active zone, secondary on an allowed one, tertiary (faded) on
    /// a disabled one — so the text tracks its blob rather than announcing a target that is inert.
    package static func labelInk(active: Bool, allowed: Bool) -> DropZoneLabelInk {
        if active { return .primary }
        return allowed ? .secondary : .tertiary
    }
}
