// AmbientCanvasUnderlay — the visible half of the ambient light engine (design-craft big-swing A,
// 2026-07-04). Each pane card casts a soft light field onto the canvas behind it, TV-bias-light style:
//   • a `.remoteGUI` pane bleeds the REAL dominant colours of its live decoded video
//     (renderer 4×4 downsample → `AmbientPalette` reduction on `RemoteWindowModel`),
//   • a terminal pane whose shell is BUSY glows with the theme accent — "something is running here"
//     you can see from across the room,
//   • an idle terminal / grey-white video frame casts nothing (`AmbientPalette.strength` ≈ 0).
//
// Rendering discipline: the underlay is drawn FIRST in the tab's compositor ZStack, so light can never
// wash over a neighbouring card's content — it lives only in the glass gutters and margins. No blur
// filter: each glow is one `EllipticalGradient` fill (GPU-trivial, animates smoothly). Palette changes
// ease over ~1.6 s so the canvas DRIFTS with the content instead of flickering with it; Reduce Motion
// snaps instead. Never hit-tests.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// The per-leaf glow decision, kept pure so the taste constants are pinnable.
struct AmbientGlowStyle: Equatable {
    let inner: Color
    let outer: Color
    /// 0 ⇒ invisible (the gradient stays mounted so the fade-out animates).
    let intensity: Double

    /// Video palette wins over shell-busy (a streaming pane's own light IS its activity cue);
    /// a busy shell casts the theme accent; anything else casts nothing.
    static func resolve(palette: AmbientPalette?, shellBusy: Bool, accent: Color) -> Self {
        if let palette, palette.strength > 0.01 {
            return Self(
                inner: Color(red: palette.primary.red, green: palette.primary.green, blue: palette.primary.blue),
                outer: Color(
                    red: palette.secondary.red, green: palette.secondary.green, blue: palette.secondary.blue,
                ),
                intensity: palette.strength,
            )
        }
        if shellBusy {
            return Self(inner: accent, outer: accent, intensity: 0.55)
        }
        return Self(inner: accent, outer: accent, intensity: 0)
    }
}

/// The whole shown tab's light field: one glow per visible tiled leaf.
struct AmbientCanvasUnderlay: View {
    let store: WorkspaceStore
    let leaves: [SplitTreeRenderModel.PlacedLeaf]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(leaves, id: \.id) { leaf in
                AmbientLeafGlow(store: store, paneID: leaf.id, rect: leaf.rect)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One leaf's cast light: an elliptical falloff centred on the card, extending `bleed` points past its
/// edges — the card itself covers the bright core, so only the spill ring reads.
private struct AmbientLeafGlow: View {
    let store: WorkspaceStore
    let paneID: PaneID
    let rect: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far past the card edge the light spills.
    private static let bleed: CGFloat = 48

    var body: some View {
        let model = (store.handle(for: paneID) as? LivePaneSession)?.remoteWindow
        let glow = AmbientGlowStyle.resolve(
            palette: model?.ambientPalette,
            shellBusy: store.paneIsBusy(paneID),
            accent: Slate.theme.accent,
        )
        Rectangle()
            .fill(EllipticalGradient(
                stops: [
                    .init(color: glow.inner.opacity(0.50 * glow.intensity), location: 0.30),
                    .init(color: glow.outer.opacity(0.22 * glow.intensity), location: 0.70),
                    .init(color: glow.outer.opacity(0), location: 1.0),
                ],
                center: .center,
            ))
            .frame(width: rect.width + Self.bleed * 2, height: rect.height + Self.bleed * 2)
            .position(x: rect.midX, y: rect.midY)
            // The bias-light drift: palette shifts ease slowly (the light "breathes with the content");
            // Reduce Motion snaps. Value-keyed on the whole style so colour AND strength interpolate.
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.6), value: glow)
    }
}
#endif
