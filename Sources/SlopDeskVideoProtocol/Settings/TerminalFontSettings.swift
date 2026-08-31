// The one font-appearance mode the renderer actuates: how tall a cell is.
//
// ## What left this file
//
// Three more enums lived here — ligature mode, the bold/italic face modes and the anti-aliasing
// blend — each mapping a stored token to a libghostty `key = value` line. Nothing emits that text
// any more (docs/68), and the renderer that replaced the fork actuates none of the three, so each
// was a row a user could set to watch nothing happen. They went with their config rows rather than
// staying as settings that lie; a ligature mode comes back the day the shaper can honour one, in
// the same change.
//
// ``LineHeightMode`` stays because it has a live reader: `CodeFontSync` sends its percentage to the
// code panel. The TERMINAL half of it is not actuated either, which is a gap on the record rather
// than a lie — the row does something, just not everything its name suggests.

// MARK: - LineHeightMode (`line-height`)

/// Cell-height mode (`line-height`, four values). Maps to libghostty `adjust-cell-height` (a
/// percentage relative to the natural cell height). ``default`` emits NO line (the theme/font decides).
public enum LineHeightMode: Codable, Sendable, Equatable {
    /// Use whatever the theme/font defines (the default) → NO `adjust-cell-height` line.
    case `default`
    /// Tight spacing (1.0×) → `adjust-cell-height = 0%`.
    case compact
    /// Roomy spacing (1.2×) → `adjust-cell-height = 20%`.
    case loose
    /// A user-supplied multiplier `m` → `adjust-cell-height = ((m - 1) * 100)%` (plain `*`/`+`).
    case custom(Double)

    /// The `adjust-cell-height` PERCENTAGE for this mode, or `nil` for ``default`` (no line). `compact` /
    /// `loose` are exact integral constants (0 / 20) — NOT routed through the `(m-1)*100` formula, which on
    /// `1.2` would land on `19.999…%` (1.2 is not representable). `custom` uses the formula with PLAIN
    /// subtract-then-multiply (never fused / `addingProduct`, per the codec/controller convention). The
    /// CLAMP and the formatting are the far side's — `slopdesk-terminal`'s `config` — which is why this
    /// stays here rather than crossing as a mode: `CodeFontSync` reads the percent too.
    public var adjustCellHeightPercent: Double? {
        switch self {
        case .default: nil
        case .compact: 0
        case .loose: 20
        case let .custom(m): (m - 1.0) * 100.0
        }
    }
}

// The per-theme font SCOPE resolver that used to live here is gone with the theme picker
// (user-directed 2026-08-08): with one appearance there is one font slot, so the Global family in
// ``TerminalPreferences/fontFamily`` is the whole precedence chain.
