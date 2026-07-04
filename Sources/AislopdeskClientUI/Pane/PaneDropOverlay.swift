// PaneDropOverlay — the soft circular/elliptical drop-zone overlay drawn over a pane while an external drag
// hovers it (E18 WI-5; see `docs/ui-shell/spec/user-interface__drag-and-drop.md`, `screenshots/drop-overlay-frame-action.png`).
//
// PURE presentation: it draws the five labelled blobs straight from the SHARED ``PaneDropZoneLayout`` (the
// SAME geometry the ``PaneDropReceiver`` hit-tests against — draw == hit, so the `.contentShape`-before-
// `.position` trap is mooted), saturates the active zone, and mutes the zones the dragged content can't act
// on (`allowedZones`). It holds no state and runs no policy — ``PaneContainer`` feeds it
// `(layout, activeZone, allowedZones)` from the drag model. Kept in the tree at opacity 0 and faded in (like
// the resize scrim), so it never hit-tests and the pane's taps/gestures pass straight through.
//
// Visual DNA (from the screenshot): a central column of three circles — New Tab / Insert Path / Open
// In-Place — over the "green / terminal half" and "blue / pane half" split, plus a tall ellipse hugging each
// side edge (Split Left / Split Right) whose off-edge half is clipped away. The hovered zone glows
// status-green; the rest sit as faint washes — green for the terminal half, accent for the pane half — and a
// disabled zone (the green New-Tab half for a file/URL) reads as a barely-there neutral. `Slate.*` tokens
// only (raw colour / size literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct PaneDropOverlay: View {
    /// The pane's drop-zone geometry — the single source of truth (also hit-tested by ``PaneDropReceiver``).
    let layout: PaneDropZoneLayout
    /// The zone the cursor is over right now (`nil` in a gap) — drawn saturated.
    let activeZone: DropZone?
    /// The zones the dragged content can act on — the others render muted + un-highlightable.
    let allowedZones: Set<DropZone>

    /// The "green / terminal half" zones (the drag-and-drop spec's left column) — tinted green even at rest; the
    /// remaining "blue / pane half" zones tint with the accent.
    private static let terminalHalf: Set<DropZone> = [.newTab, .insertPath]

    var body: some View {
        ZStack {
            ForEach(layout.zones, id: \.self) { zone in
                blob(zone)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clip the side ellipses to the pane (their off-edge half spills past x = 0 / x = w), matching the
        // half-circle the screenshot shows hugging each edge.
        .clipShape(Rectangle())
        .allowsHitTesting(false)
        .animation(Slate.Anim.reveal, value: activeZone)
    }

    /// One zone's blob (a soft ellipse) + its centred label.
    @ViewBuilder
    private func blob(_ zone: DropZone) -> some View {
        let shape = layout.shape(for: zone)
        let active = activeZone == zone
        let allowed = allowedZones.contains(zone)
        Ellipse()
            .fill(fill(zone, active: active, allowed: allowed))
            .overlay {
                if active {
                    Ellipse().strokeBorder(Slate.Status.ok.opacity(0.7), lineWidth: Slate.Metric.hairline)
                }
            }
            .frame(width: max(shape.radiusX * 2, 0), height: max(shape.radiusY * 2, 0))
            .position(shape.center)
        Text(label(zone))
            .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            .foregroundStyle(labelColor(active: active, allowed: allowed))
            .position(labelCenter(zone, shape: shape))
    }

    // MARK: - Per-zone styling

    /// The blob fill: the hovered zone glows status-green; an allowed zone sits as a faint wash (green for
    /// the terminal half, accent for the pane half); a disabled zone is a barely-there neutral.
    private func fill(_ zone: DropZone, active: Bool, allowed: Bool) -> Color {
        if active { return Slate.Status.ok.opacity(0.5) }
        if !allowed { return Slate.State.accentMuted }
        return Self.terminalHalf.contains(zone)
            ? Slate.Status.ok.opacity(0.14)
            : Slate.State.accent.opacity(0.10)
    }

    /// The label colour tracks the zone state: bright on the active zone, secondary on an allowed one,
    /// tertiary (faded) on a disabled one.
    private func labelColor(active: Bool, allowed: Bool) -> Color {
        if active { return Slate.Text.primary }
        return allowed ? Slate.Text.secondary : Slate.Text.tertiary
    }

    /// Where the label sits: at the blob centre for the three central circles; inset from the edge for the
    /// two side ellipses (whose true centre is ON the edge / off-screen) so the text stays readable.
    private func labelCenter(_ zone: DropZone, shape: DropZoneShape) -> CGPoint {
        switch zone {
        case .splitLeft: CGPoint(x: shape.radiusX * 0.5, y: shape.center.y)
        case .splitRight: CGPoint(x: layout.size.width - shape.radiusX * 0.5, y: shape.center.y)
        default: shape.center
        }
    }

    private func label(_ zone: DropZone) -> String {
        switch zone {
        case .newTab: "New Tab"
        case .insertPath: "Insert Path"
        case .openInPlace: "Open In-Place"
        case .splitLeft: "Split Left"
        case .splitRight: "Split Right"
        }
    }
}
#endif
