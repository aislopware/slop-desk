// CanvasBackdrop — the depth-ladder canvas margin (2026-07-04 v4): the surface the pane cards float ON.
//
// Three layers, back → front:
//   1. macOS: the window's OWN system glass (the NavigationSplitView's window-spanning
//      `.contentBackground` VEV) stays underneath — we draw OVER it, never replace it.
//      iOS: the system background (`WindowGlassBackdrop`) plays that base role.
//   2. `Slate.Surface.canvasBackdrop` at high-but-not-full opacity — the theme-derived margin tone a
//      full lift-step DARKER than the card (Linear's surface ladder: depth = tonal lift, not shadow).
//      Not fully opaque, deliberately: the sliver of glass keeps the desktop's light alive so the
//      margin reads as smoked glass, not a dead fill.
//   3. `GrainOverlay` — a few percent of static monochrome grain so the wide margin band reads as a
//      coated material instead of a flat swatch (and can never band).
//
// History (why this exists): the v1 card-canvas drew a THEME margin near-identical to the card tone —
// no depth read. v3 removed the margin entirely for the native glass — on a dark desktop the glass
// resolves ≈ the card tone and the whole depth read collapsed again ("giao diện không thấy khác gì").
// The ladder needs a GUARANTEED contrast step, which only a derived tone can promise; the derivation
// (`SlateTheme.scaledHex`, ×0.55 dark / ×0.94 light) is hue-preserving so every Monokai filter keeps
// its own cast. Never hit-tests.

#if canImport(SwiftUI)
import SwiftUI

struct CanvasBackdrop: View {
    /// The active session's identity colour (`SessionAccentPalette`) — washes the margin's top edge so
    /// SWITCHING SESSIONS visibly recolours the whole frame (the Arc-Spaces "the chrome is the
    /// context" idiom). `nil` ⇒ no wash (no session).
    var sessionTint: Color?

    /// The margin tint's coverage over the glass. 1.0 would kill the glass entirely; the band that
    /// reads as "smoked glass over the desktop" is ~0.85–0.92.
    static let tintOpacity: Double = 0.88
    /// The session wash's peak opacity at the top edge — identity, never decoration: strong enough to
    /// name the session at a glance, weak enough that terminal text never fights it.
    static let sessionWashOpacity: Double = 0.12

    var body: some View {
        ZStack {
            #if os(iOS)
            WindowGlassBackdrop()
            #endif
            Slate.Surface.canvasBackdrop
                .opacity(Self.tintOpacity)
            if let sessionTint {
                LinearGradient(
                    stops: [
                        .init(color: sessionTint.opacity(Self.sessionWashOpacity), location: 0),
                        .init(color: sessionTint.opacity(0), location: 0.45),
                    ],
                    startPoint: .top, endPoint: .bottom,
                )
            }
            GrainOverlay()
        }
        // A session switch DRIFTS the wash to the new identity (never snaps — the recolour is the
        // "you moved somewhere else" cue, so it should read as a move, not a glitch).
        .animation(.easeInOut(duration: 0.8), value: sessionTint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
