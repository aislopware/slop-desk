// NativePaneColor — pane-grid colour aliases, now backed by the otty token layer (REBUILD-V2, L5).
//
// Previously these resolved to OS semantic colours (auto light/dark). They now map onto the PINNED
// otty palette (`Otty.Surface` / `Otty.Divider`) so the chrome is the cohesive "clean like otty.sh"
// dark theme on every host, light or dark — same rationale as the libghostty terminal-bg pin. The
// alias names are kept so the 10 call sites need no change; the SOURCE of truth is `OttyDesign.swift`.

#if canImport(SwiftUI)
import SwiftUI

enum NativePaneColor {
    /// The chrome / window background (pane header, divider bands, empty content) — otty window backdrop.
    static var window: Color { Otty.Surface.window }

    /// The terminal / editable content surface background — the floating card surface.
    static var terminalBackground: Color { Otty.Surface.card }

    /// The hairline separator colour — otty divider.
    static var separator: Color { Otty.Line.divider }
}
#endif
