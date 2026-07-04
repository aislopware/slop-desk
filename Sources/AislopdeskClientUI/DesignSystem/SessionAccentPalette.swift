// SessionAccentPalette — the curated colour set behind `SessionAccent` (visible-design pass,
// 2026-07-04): 8 Monokai Pro Classic chromatics, theme-INDEPENDENT by design. The session identity
// must survive a theme switch (an Arc Space keeps its gradient across appearance flips) and every
// Monokai filter shares the same chromatic family, so the fixed set sits comfortably on all of them.
// Deliberately NOT `Slate.theme` reads — identity is not theming.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

enum SessionAccentPalette {
    /// The 8 identity chromatics, index-aligned with ``SessionAccent/index(for:)``. Count is pinned
    /// against `SessionAccent.paletteCount` by test.
    static let colors: [Color] = [
        Color(slateHex: 0x78DCE8), // cyan
        Color(slateHex: 0xAB9DF2), // purple
        Color(slateHex: 0xA9DC76), // green
        Color(slateHex: 0xFC9867), // orange
        Color(slateHex: 0xFF6188), // pink
        Color(slateHex: 0xFFD866), // yellow
        Color(slateHex: 0x85DACC), // teal
        Color(slateHex: 0x61AFEF), // blue
    ]

    /// The session's identity colour; `nil` in ⇒ `nil` out (callers fall back to the theme accent).
    static func color(for id: SessionID?) -> Color? {
        guard let id else { return nil }
        let index = SessionAccent.index(for: id)
        guard colors.indices.contains(index) else { return nil }
        return colors[index]
    }
}
#endif
