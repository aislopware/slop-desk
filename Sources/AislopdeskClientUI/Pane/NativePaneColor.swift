// NativePaneColor — pane-grid colour aliases, now backed by the Slate token layer (REBUILD-V2, L5).
//
// Previously these resolved to OS semantic colours (auto light/dark). They now map onto the PINNED
// Slate palette (`Slate.Surface` / `Slate.Divider`) so the chrome is a cohesive, flat dark theme
// on every host, light or dark — same rationale as the libghostty terminal-bg pin. The
// alias names are kept so the 10 call sites need no change; the SOURCE of truth is `SlateDesign.swift`.

#if canImport(SwiftUI)
import SwiftUI

// `@MainActor` because the aliases read the runtime ``Slate/theme`` (D3) — call sites are SwiftUI views.
@MainActor
enum NativePaneColor {
    /// The backdrop BEHIND the tiled panes (the SplitContainer fill) — the SAME theme surface the panes
    /// render on (flat hairline canvas, 2026-07-04 v2: one continuous surface, no darker margin tone).
    static var window: Color { Slate.Surface.card }

    /// The terminal / editable content surface background.
    static var terminalBackground: Color { Slate.Surface.card }
}
#endif
