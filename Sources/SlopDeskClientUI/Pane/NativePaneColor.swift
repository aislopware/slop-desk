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
    /// The pane-canvas backdrop (gaps behind placed leaves, empty tab area) — the ISLAND is one
    /// glass card, so its canvas is the glass itself, never a chrome tone.
    static var window: Color { Slate.Surface.terminal }

    /// The terminal / editable content surface background — the terminal profile's glass.
    static var terminalBackground: Color { Slate.Surface.terminal }

    /// The pane-seam line INSIDE the island — the profile's edge tone (one step off the glass), the
    /// JetBrains-Islands internal divider: a subtle line on the glass, never a chrome-coloured gap.
    static var separator: Color { Slate.Terminal.edge }
}
#endif
