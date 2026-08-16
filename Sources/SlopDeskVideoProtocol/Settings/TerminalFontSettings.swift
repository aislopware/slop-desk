// The leaf-level FONT-PARITY model: the four font-appearance enums + their libghostty token
// mapping.
//
// WHY a separate leaf file: `TerminalConfigBuilder` (also in this leaf `SlopDeskVideoProtocol`) must turn
// these settings into libghostty `key = value` lines WITHOUT importing any UI; the font UI
// (`FontSettingsView`, up in `SlopDeskClientUI`) binds the SAME enums. Keeping them here keeps the
// mapping pure + headlessly testable (no SwiftUI, no libghostty surface — the hang-safety rule).
//
// GOLDEN-SAFETY: this config string is CLIENT-only (the libghostty surface) and NEVER on the wire, so it
// can never move a golden vector regardless of what it emits. Most settings still map to a libghostty line
// ONLY for their NON-default value; the ONE exception is `font-feature`, emitted UNCONDITIONALLY (ligatures
// default `.off` ⇒ the disabling set `-calt,-liga,-dlig` must always be sent). So a default-constructed
// `TerminalPreferences` is NOT byte-identical to a builder that skips defaults entirely — it gains exactly
// the one `font-feature = -calt,-liga,-dlig` line (pinned by `TerminalConfigBuilderTests`). The two controls that
// have no STOCK ghostty key (SGR underline-off, SGR blink) and the three blending modes that have no
// verified key (`srgb-over` / `linear` / `perceptual`) are PERSISTED + surfaced but deliberately NOT emitted
// — we only emit keys verified to exist (an unknown key risks a config-load warning). See
// `docs/ui-shell/plans/E15.md` decision #5.

// MARK: - FontLigatures (`font-ligatures`)

/// Ligature mode (`font-ligatures`). Maps to libghostty `font-feature`.
public enum FontLigatures: String, Codable, Sendable, Equatable, CaseIterable {
    /// No ligation (the default). Unlike the other render prefs, `off` is NOT a no-op: fonts that ship
    /// programming ligatures (Fira Code, JetBrains Mono, Cascadia Code, …) enable `calt` BY DEFAULT in their
    /// GSUB table, so emitting nothing would leave their ligatures ON. To truly turn ligatures OFF the
    /// builder emits the DISABLING features — ghostty documents `-calt, -liga, -dlig` for exactly this (see
    /// `Config.zig` `font-feature`: "To generally disable most ligatures, use `-calt, -liga, -dlig`").
    case off
    /// Standard + contextual alternates (`=>`, `!=`, `>=`, …) → `font-feature = calt`.
    case calt
    /// Everything in ``calt`` plus discretionary ligatures → `font-feature = calt,dlig`.
    case dlig
}

// MARK: - FontStyleMode (`font-bold` / `font-italic`)

/// Bold / italic face mode (`font-bold` / `font-italic`, four values). Maps to libghostty
/// `font-style-bold` / `font-style-italic` + `font-synthetic-style`. The bold and italic settings share
/// this enum (the UI surfaces the SAME four modes for each).
public enum FontStyleMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Use the real bold/italic face, borrowing from fallback if needed (the default → no line, libghostty
    /// default behaviour).
    case auto
    /// Ignore the SGR weight/style, render at the normal face → `font-style-{kind} = false`.
    case off
    /// Use a real face ONLY if the primary font has one, never synthesize/borrow → `font-synthetic-style =
    /// no-{kind}` (approximate; libghostty cannot express "never from fallback" exactly).
    case primaryOnly = "primary-only"
    /// Synthesize a faux face via algorithmic thickening/slanting → `font-synthetic-style = {kind}`.
    case synthetic
}

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

// MARK: - FontBlending (`font-blending`)

/// Glyph anti-aliasing blend mode (`font-blending`). Two values, because two is all libghostty can
/// actuate: `srgb-over` / `linear` / `perceptual` used to be offered too, but none has a verified stock
/// key, so picking one changed nothing on screen — a control that only writes to disk. Raw values are the
/// config tokens 1:1 (for persistence + the UI).
public enum FontBlending: String, Codable, Sendable, Equatable, CaseIterable {
    /// Defer to the active theme — NO line.
    case `default`
    /// macOS-native Display-P3 path → `font-thicken = true`.
    case macosLike = "macos-like"
}

// The per-theme font SCOPE resolver that used to live here is gone with the theme picker
// (user-directed 2026-08-08): with one appearance there is one font slot, so the Global family in
// ``TerminalPreferences/fontFamily`` is the whole precedence chain.
