// DropZonePresentation — the face over what the five drop blobs SAY and how they are inked.
//
// The overlay that draws them is a stateless renderer over `PaneDropZoneLayout` — the ellipse
// centres and radii are `slopdesk_workspace::drop_zone`'s, which is what makes draw == hit true
// rather than merely intended. Everything AROUND that geometry is now the same crate's: the five
// labels, the green-terminal-half / blue-pane-half partition, the label's offset for the two edge
// ellipses, the three-way branch that picks a blob's wash, and the negative-radius clamp. Each is
// small, and each is exactly the kind of thing a second renderer re-derives slightly differently —
// the Mac's "Open In-Place" against the phone's "Open in place", a partition that puts Insert Path
// on the wrong side of the split, an edge label that drifts off-pane.
//
// TWO CROSSINGS, SPLIT THE WAY THE TWO QUESTIONS ARE ASKED. Where a blob and its word GO is a
// function of the pane box alone, so a resize asks for it and a hover does not; how they are INKED
// turns on `(active, allowed)`, and those three verdicts arrive together because asking separately
// would let a renderer draw a lit blob under a faded word. The label is a third door, because a word
// does not change while a drag is over the pane.
//
// THE INK IS NAMED, NEVER COLOURED. `SlopDeskClientCore` holds no design tokens (docs/56 §2): the
// verdict below says WHICH RUNG at WHAT ALPHA and each framework resolves it through its own view of
// the one ladder — `Slate.Status.ok` / `Slate.State.accent` in SwiftUI, `Slate.Native.*` in AppKit —
// the same "one palette, drawn twice and spelled once" shape `ToastMarkRung` and `AgentReadout`
// already are. The two enums stay HERE, spelled as cases, because `rust/slopdesk-invariants` reads
// this file to ratchet that both renderers resolve every rung.

import CoreGraphics
import CSlopDeskFFI
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

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

/// Which rung a zone's LABEL is drawn in — the reading ladder, not the status one.
package enum DropZoneLabelInk: Sendable, Equatable {
    /// The hovered zone: full-strength reading ink.
    case primary
    /// An allowed but un-hovered zone.
    case secondary
    /// A zone the content cannot act on — faded, matching its muted blob.
    case tertiary
}

// MARK: - The codes the doors answer in

// The two enums above hold NOTHING but their cases: `rust/slopdesk-invariants` reads the rungs
// straight out of each body to ratchet that both renderers resolve every one, so a `switch` spelled
// inside either would read as a rung nobody drew.

private extension DropZoneInk {
    /// The rung a `SLOPDESK_DROP_ZONE_INK_*` code names. An unrecognised one reads as the muted rung:
    /// a blob that says nothing is better than one that invites a drop the door did not allow.
    init(ffiCode: UInt8) {
        switch ffiCode {
        case UInt8(SLOPDESK_DROP_ZONE_INK_OK): self = .ok
        case UInt8(SLOPDESK_DROP_ZONE_INK_ACCENT): self = .accent
        default: self = .accentMuted
        }
    }
}

private extension DropZoneLabelInk {
    /// The rung a `SLOPDESK_DROP_ZONE_LABEL_INK_*` code names. An unrecognised one reads as tertiary,
    /// matching the wash its unrecognised neighbour falls back to.
    init(ffiCode: UInt8) {
        switch ffiCode {
        case UInt8(SLOPDESK_DROP_ZONE_LABEL_INK_PRIMARY): self = .primary
        case UInt8(SLOPDESK_DROP_ZONE_LABEL_INK_SECONDARY): self = .secondary
        default: self = .tertiary
        }
    }
}

/// WHERE one blob and its word are drawn — a function of the pane box alone, so a resize asks for
/// this and a hover does not.
package struct DropZoneMarks: Sendable, Equatable {
    /// The blob's drawn size, already clamped away from the negative dimensions a pane mid-layout
    /// answers with — neither framework may be handed a negative width.
    package let blobSize: CGSize
    /// Where the zone's label sits in pane-local coordinates: at the blob centre for the three
    /// central circles, and inset from the edge for the two side ellipses, whose true centre is ON
    /// the pane edge (half the blob is clipped away) so a centred label would be half off-pane.
    package let labelCenter: CGPoint
}

/// HOW one blob and its word are inked, from ONE crossing.
package struct DropZoneWash: Sendable, Equatable {
    /// The wash's rung.
    package let ink: DropZoneInk
    /// The alpha that rung is laid down at. `1` means the rung's own value, undiluted (the muted rung
    /// is already the faint one).
    package let opacity: Double
    /// The alpha the ring is stroked at — `0` on every zone but the hovered one, so the ring is one
    /// number rather than a branch each renderer writes out.
    package let strokeOpacity: Double
    /// The label's rung.
    package let labelInk: DropZoneLabelInk
}

/// The wording, the partition, the label geometry and the ink verdicts of the pane drop overlay —
/// all of them `slopdesk_workspace::drop_zone`'s, reached through three doors.
package enum DropZonePresentation {
    /// The label under a zone's blob. Title Case, and "Open In-Place" keeps its capital I and its
    /// hyphen — it names the verb the ⌘-click menu already spells that way.
    package static func label(_ zone: DropZone) -> String {
        wsAnswer { out, cap in Int(slopdesk_drop_zone_label(zone.crossing, out, cap)) } ?? ""
    }

    /// Where `zone`'s blob and word are drawn over a pane of `size`.
    package static func marks(_ zone: DropZone, in size: CGSize) -> DropZoneMarks {
        let drawn = slopdesk_drop_zone_marks(
            zone.crossing, Double(size.width), Double(size.height),
        )
        return DropZoneMarks(
            blobSize: CGSize(width: drawn.blob_width, height: drawn.blob_height),
            labelCenter: CGPoint(x: drawn.label_center.x, y: drawn.label_center.y),
        )
    }

    /// How `zone` is inked while `active` / `allowed`.
    package static func wash(_ zone: DropZone, active: Bool, allowed: Bool) -> DropZoneWash {
        let inked = slopdesk_drop_zone_wash(zone.crossing, active, allowed)
        return DropZoneWash(
            ink: DropZoneInk(ffiCode: inked.ink),
            opacity: inked.opacity,
            strokeOpacity: inked.stroke_opacity,
            labelInk: DropZoneLabelInk(ffiCode: inked.label_ink),
        )
    }
}

private extension DropZone {
    /// This zone in the door's own numbering. The codes are `PaneDropZoneLayout`'s, spelled by name
    /// so no number is written twice.
    var crossing: UInt8 {
        switch self {
        case .newTab: UInt8(SLOPDESK_DROP_ZONE_NEW_TAB)
        case .insertPath: UInt8(SLOPDESK_DROP_ZONE_INSERT_PATH)
        case .openInPlace: UInt8(SLOPDESK_DROP_ZONE_OPEN_IN_PLACE)
        case .splitLeft: UInt8(SLOPDESK_DROP_ZONE_SPLIT_LEFT)
        case .splitRight: UInt8(SLOPDESK_DROP_ZONE_SPLIT_RIGHT)
        }
    }
}
