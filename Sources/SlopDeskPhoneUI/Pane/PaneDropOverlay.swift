// PaneDropOverlay — the soft circular/elliptical drop-zone overlay drawn over a pane while an external drag
// hovers it (see `docs/ui-shell/spec/user-interface__drag-and-drop.md`, `screenshots/drop-overlay-frame-action.png`).
//
// PURE presentation, and after docs/56 that is meant literally: every decision the file used to make itself
// now lives below it. The blob geometry is the SHARED ``PaneDropZoneLayout`` (the SAME shapes the
// ``PaneDropReceiver`` hit-tests against — draw == hit, so the `.contentShape`-before-`.position` trap is
// mooted); the wording, the green-terminal-half / blue-pane-half partition, the label's offset on the two
// edge ellipses and the three-way ink verdict are ``DropZonePresentation``. What is left here is the ONE
// thing the AppKit half cannot share: turning a named rung into a `Color` and hanging it on a `View`. It
// holds no state and runs no policy — ``PaneContainer`` feeds it `(layout, activeZone, allowedZones)` from
// the drag model. Kept in the tree at opacity 0 and faded in (like the resize scrim), so it never hit-tests
// and the pane's taps/gestures pass straight through.
//
// Visual DNA (from the screenshot): a central column of three circles — New Tab / Insert Path / Open
// In-Place — over the "green / terminal half" and "blue / pane half" split, plus a tall ellipse hugging each
// side edge (Split Left / Split Right) whose off-edge half is clipped away. The hovered zone glows
// status-green; the rest sit as faint washes and a disabled zone reads as a barely-there neutral. `Slate.*`
// tokens only (raw colour / size literals fail the `design-token-leaks` gate) — and the ALPHAS are the
// verdict's, not this file's, so the two renderers cannot disagree about how faint "at rest" is.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

struct PaneDropOverlay: View {
    /// The pane's drop-zone geometry — the single source of truth (also hit-tested by ``PaneDropReceiver``).
    let layout: PaneDropZoneLayout
    /// The zone the cursor is over right now (`nil` in a gap) — drawn saturated.
    let activeZone: DropZone?
    /// The zones the dragged content can act on — the others render muted + un-highlightable.
    let allowedZones: Set<DropZone>

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
        let size = DropZonePresentation.blobSize(for: shape)
        Ellipse()
            .fill(fill(zone, active: active, allowed: allowed))
            .overlay {
                if active {
                    Ellipse().strokeBorder(
                        Slate.Status.ok.opacity(DropZonePresentation.activeStrokeOpacity),
                        lineWidth: Slate.Metric.hairline,
                    )
                }
            }
            .frame(width: size.width, height: size.height)
            .position(shape.center)
        Text(DropZonePresentation.label(zone))
            .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            .foregroundStyle(labelColor(active: active, allowed: allowed))
            .position(DropZonePresentation.labelCenter(zone, shape: shape, in: layout.size))
    }

    // MARK: - Per-zone styling (the rung → `Color` lookup, and nothing else)

    /// The blob fill: ``DropZonePresentation/tint(_:active:allowed:)`` decides which rung at which alpha;
    /// this resolves the rung through SwiftUI's spelling of the ladder. `.opacity(1)` on the muted rung is
    /// the identity (alpha × 1), so the disabled wash is bit-identical to the token itself.
    private func fill(_ zone: DropZone, active: Bool, allowed: Bool) -> Color {
        let tint = DropZonePresentation.tint(zone, active: active, allowed: allowed)
        return ink(tint.ink).opacity(tint.opacity)
    }

    /// SwiftUI's view of the one ink ladder (`Slate.Native.*` is AppKit's view of the same rungs).
    private func ink(_ rung: DropZoneInk) -> Color {
        switch rung {
        case .ok: Slate.Status.ok
        case .accent: Slate.State.accent
        case .accentMuted: Slate.State.accentMuted
        }
    }

    /// The label colour tracks the zone state — the branch is
    /// ``DropZonePresentation/labelInk(active:allowed:)``; this is its reading-ink lookup.
    private func labelColor(active: Bool, allowed: Bool) -> Color {
        switch DropZonePresentation.labelInk(active: active, allowed: allowed) {
        case .primary: Slate.Text.primary
        case .secondary: Slate.Text.secondary
        case .tertiary: Slate.Text.tertiary
        }
    }
}
#endif
