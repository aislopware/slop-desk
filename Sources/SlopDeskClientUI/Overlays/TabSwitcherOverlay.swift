// TabSwitcherOverlay — the ⌃⇥ switcher's face: a floating Liquid Glass card listing the session's tabs in
// MOST-RECENTLY-USED order with the provisional highlight marked.
//
// Presented as a plain always-mounted `.overlay` rather than a `.sheet`, unlike every other surface in
// `OverlayHostView`. A sheet is the wrong instrument here: it animates in over ~0.3s and takes key focus,
// but this overlay's whole lifetime is the length of a held ⌃ — often under 200ms — and stealing focus
// mid-gesture would break the `flagsChanged` release that commits it. It renders nothing when the store's
// `tabSwitcher` is nil, so at rest it costs a branch.
//
// It is a READOUT, not a control: the dispatcher owns the gesture (open / step / commit / cancel), and this
// view has no gestures, no buttons, and no state of its own. Clicking through it is impossible because it
// never accepts hits.
//
// NATIVE CHROME, not canvas (DECISIONS §native-chrome): the switcher floats OVER the workspace rather than
// living in it, so it is dressed in the system's own materials — `glassEffect` for the card, system text
// styles, semantic `.primary`/`.secondary` ink, the SF Symbol the pane chooser already names each kind by,
// and the SYSTEM accent for the highlight (`.tint(nil)` resets the workspace's ambient theme tint, which
// would otherwise repaint a native surface in the terminal's colour scheme). `Slate` supplies GEOMETRY only
// — the spacing/radius ladder every floating surface shares — never ink.
//
// Raw font/radius/height literals fail `scripts/check-ds-leaks.sh`; no AppKit, so this compiles for iOS
// with the rest of `SlopDeskClientUI`, where the switcher is simply never opened.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

struct TabSwitcherOverlay: View {
    let store: WorkspaceStore

    /// Custom glass must self-gate the accessibility setting (the native-chrome research's pitfall list):
    /// with Reduce Transparency on, the card takes a plain opaque material instead.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let switcher = store.tabSwitcher {
            card(TabSwitcherRowsBuilder.rows(for: switcher, store: store))
                // A readout never takes hits: the gesture lives entirely on the keyboard, and swallowing a
                // click here would strand a user who reached for the workspace behind it.
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func card(_ rows: [TabSwitcherRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                TabSwitcherRowView(row: row)
            }
        }
        .padding(Slate.Metric.space1)
        .frame(width: cardWidth)
        .modifier(SwitcherSurface(reduceTransparency: reduceTransparency))
        // The system accent, not the workspace's: the window tints its whole subtree with the theme
        // accent, and a native surface wearing Monokai green for its selection is exactly the "not
        // native" reading this round set out to fix.
        .tint(nil)
    }

    /// Wide enough for a two-register row — an agent's task intent on line 1 and `project/sub · 3 panes`
    /// on line 2 — without either truncating on a normal workspace. Still narrow enough to read as a
    /// switcher rather than a panel.
    private let cardWidth: CGFloat = 380
}

/// The card's SURFACE: Liquid Glass, or a plain material when the user asked for less transparency.
/// Split into a modifier because the two branches must land on the same geometry — a `if/else` around
/// the whole card would give SwiftUI two different view identities to cross-fade between.
private struct SwitcherSurface: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                .regularMaterial,
                in: .rect(cornerRadius: Slate.Metric.radiusPanel, style: .continuous),
            )
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: Slate.Metric.radiusPanel))
        }
    }
}

/// One row: the pane's kind glyph, its identity over its place, the program label, and the ⌘-number.
private struct TabSwitcherRowView: View {
    let row: TabSwitcherRow

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemName: row.symbol)
                .font(.body)
                .foregroundStyle(row.isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: Slate.Metric.space4)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.body)
                    .foregroundStyle(row.isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        // The place is the LONG field, so it truncates at the head — the tail
                        // (`…/packages/api · 3 panes`) is the half that distinguishes.
                        .truncationMode(.head)
                        .foregroundStyle(
                            row.isHighlighted
                                ? AnyShapeStyle(.white.opacity(highlightedSecondary))
                                : AnyShapeStyle(.secondary),
                        )
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Slate.Metric.space2)
            if let slot = row.slot {
                Text(slot)
                    .font(.caption)
                    .foregroundStyle(
                        row.isHighlighted
                            ? AnyShapeStyle(.white.opacity(highlightedSecondary))
                            : AnyShapeStyle(.tertiary),
                    )
                    .lineLimit(1)
            }
            Text("\(row.number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(
                    row.isHighlighted
                        ? AnyShapeStyle(.white.opacity(highlightedSecondary))
                        : AnyShapeStyle(.tertiary),
                )
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if row.isHighlighted {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusItem, style: .continuous)
                    .fill(.tint)
            }
        }
    }

    /// The muted registers ON the accent fill. Secondary/tertiary system ink is tuned for a system
    /// background and washes out over a saturated accent, so the highlighted row keeps one white ramp.
    private let highlightedSecondary: Double = 0.75
}
#endif
