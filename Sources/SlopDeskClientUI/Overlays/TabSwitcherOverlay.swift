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
// The card is a grouped LIST, the shape macOS has for "these belong together": the project heads a section,
// said once, and every row underneath is ONE line — the pane's identity, a quiet note for what differs, the
// ⌘-number. No per-row icon (every row is a terminal; the glyph was noise), no second line restating the
// header, no full-bleed selection bar — the highlight is an inset capsule, the way a menu marks its item.
//
// NATIVE CHROME, not canvas (DECISIONS §native-chrome): `glassEffect` for the card, system text styles,
// semantic `.primary`/`.secondary` ink, and the SYSTEM accent for the highlight (`.tint(nil)` resets the
// workspace's ambient theme tint, which would otherwise repaint a native surface in the terminal's colour
// scheme). `Slate` supplies GEOMETRY only — the spacing/radius/height ladder every surface shares — never
// ink.
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
            card(TabSwitcherRowsBuilder.items(for: switcher, store: store))
                // A readout never takes hits: the gesture lives entirely on the keyboard, and swallowing a
                // click here would strand a user who reached for the workspace behind it.
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func card(_ items: [TabSwitcherItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item.content {
                case let .section(name):
                    SectionHeader(name: name, isFirst: item.id == 0)
                case let .row(row):
                    RowView(row: row)
                }
            }
        }
        .padding(Slate.Metric.space2)
        .frame(width: cardWidth)
        .modifier(SwitcherSurface(reduceTransparency: reduceTransparency))
        // The system accent, not the workspace's: the window tints its whole subtree with the theme
        // accent, and a native surface wearing Monokai green for its selection is exactly the "not
        // native" reading this round set out to fix.
        .tint(nil)
    }

    /// Sized for one line of identity plus a short note — a switcher, not a panel. Narrower than the
    /// two-line card it replaces, because a single line needs less measure to stay unbroken.
    private let cardWidth: CGFloat = 320
}

/// The card's SURFACE: Liquid Glass, or a plain material when the user asked for less transparency.
/// Split into a modifier because the two branches must land on the same geometry — an `if/else` around
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

/// A project, said once over the run of rows that share it.
private struct SectionHeader: View {
    let name: String
    /// The first header sits flush against the card's own padding; later ones open a gap above so the
    /// runs read as separate groups rather than one long list.
    let isFirst: Bool

    var body: some View {
        Text(name)
            .font(.caption)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.bottom, Slate.Metric.space1)
            .padding(.top, isFirst ? 0 : Slate.Metric.space3)
    }
}

/// One row: identity, the quiet remainder, and the ⌘-number.
private struct RowView: View {
    let row: TabSwitcherRow

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(row.title)
                .font(.body)
                .foregroundStyle(row.isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
                // The identity is what has to survive a narrow card; the note yields first.
                .layoutPriority(1)
            if let note = row.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Slate.Metric.space2)
            Text("⌘\(row.number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(muted)
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if row.isHighlighted {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl, style: .continuous)
                    .fill(.tint)
            }
        }
    }

    /// The secondary register. Over the accent fill the system's own `.secondary` washes out, so the
    /// highlighted row keeps one white ramp instead.
    private var muted: AnyShapeStyle {
        row.isHighlighted ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary)
    }
}
#endif
