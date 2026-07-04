// EmptyStateAurora — the ONE place the app is allowed to be showy (design-craft pass, 2026-07-04): a
// slow, low-amplitude animated MeshGradient in the ACTIVE THEME's hues behind the empty-workspace
// state. The novelty-budget rule (Dia): concentrate personality in one no-precedent moment and keep the
// working chrome boringly familiar — so this NEVER renders behind live terminal/video content (it mounts
// only under the ContentColumn's "No Session" empty state, where there is nothing to compete with).
//
// The mesh's colours are mostly-TRANSPARENT theme tints, so what actually shows is the window's own
// system glass, gently washed with the theme accent/purple — an aurora ON the glass, not a poster over
// it. The drift is deliberately glacial (~30-40s cycles, the "ambient, not screensaver" gate) and
// collapses to a STATIC wash under Reduce Motion.

#if canImport(SwiftUI)
import SwiftUI

struct EmptyStateAurora: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            mesh(at: 0)
        } else {
            // 20 fps is plenty for a drift this slow, and keeps the empty state's GPU cost ambient.
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                mesh(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func mesh(at t: Double) -> some View {
        // Two incommensurate glacial cycles (~37s / ~29s) so the drift never reads as a loop.
        let s = Float(sin(t * 2 * .pi / 37))
        let c = Float(cos(t * 2 * .pi / 29))
        let accent = Slate.theme.accent
        // The theme's purple (ANSI magenta slot, index 5) — the second aurora hue. Falls back to the
        // accent when a theme ships no parseable palette entry.
        let purple = Color(slateHexString: Slate.theme.ansiPalette[safe: 5]) ?? accent
        // Transparent anchors carry the SAME hue at 0 opacity so interpolation never darkens through gray.
        let clearA = accent.opacity(0)
        let clearP = purple.opacity(0)
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5 + 0.10 * s, 0], [1, 0],
                [0, 0.5 + 0.08 * c], [0.5 + 0.14 * c, 0.5 + 0.14 * s], [1, 0.5 - 0.08 * s],
                [0, 1], [0.5 - 0.10 * c, 1], [1, 1],
            ],
            colors: [
                clearA, clearP, clearA,
                accent.opacity(0.20), purple.opacity(0.16), clearA,
                clearP, accent.opacity(0.12), clearP,
            ],
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// Parses a canonical 6-hex palette string ("AB9DF2", no `#`) into a Color; `nil` on anything else.
    /// UI-layer convenience over the theme's string-typed terminal palette — validate-then-drop, never trap.
    init?(slateHexString hex: String?) {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(slateHex: value)
    }
}

extension [String] {
    /// Bounds-safe subscript — the theme palette is data, never worth a trap.
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
