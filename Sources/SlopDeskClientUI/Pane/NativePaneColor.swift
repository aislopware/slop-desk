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
    /// The chrome / window background (pane header, divider bands, empty content) — the Slate window backdrop.
    static var window: Color { Slate.Surface.ground }

    /// The terminal / editable content surface background — the TERMINAL glass rung (on a
    /// split-tone seed this is the dark cell surface, NOT the light chrome `face`).
    static var terminalBackground: Color { Slate.Surface.terminal }

    /// The pane-seam hairline — the `void` rung: on the split-tone seed the 1px gap between dark
    /// glass panes shows the warm FRAME through it (the Canario gap, kept tight).
    static var separator: Color { Slate.Surface.void }
}
#endif
