import Foundation

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

    /// The libghostty `font-feature` tokens for this mode. `off` emits the DISABLING set `-calt,-liga,-dlig`
    /// (so a ligature-shipping font is actually un-ligated); `calt`/`dlig` opt in. The verified key + the
    /// `±feat` token syntax are pinned by `Config.zig`'s `font-feature` (a `RepeatableString`).
    public var baseFeatures: [String] {
        switch self {
        case .off: ["-calt", "-liga", "-dlig"]
        case .calt: ["calt"]
        case .dlig: ["calt", "dlig"]
        }
    }
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

    /// The `font-synthetic-style` token(s) this mode contributes for `kind` (`"bold"` / `"italic"`), or an
    /// empty list when the mode contributes nothing to the (single, combined) synthetic-style key. `auto`
    /// and `off` add nothing (`off` is handled by the separate `font-style-{kind} = false` line).
    ///
    /// `font-synthetic-style` IS a real ghostty key — `Config.zig:218` `@"font-synthetic-style": FontSyntheticStyle = .{}`,
    /// a packed flag-set of `bold`/`italic`/`bold-italic` (`Config.zig:8516-8520`, every field defaulting
    /// `true` ⇒ synthesis ENABLED by default). The token vocabulary is pinned by `Config.zig:201-205`: "You can
    /// disable specific styles using `no-bold`, `no-italic`, and `no-bold-italic` … Available style keys are:
    /// `bold`, `italic`, `bold-italic`." So both tokens this mode emits are VALID, not no-ops:
    ///   • `primaryOnly` → `no-{kind}` — DISABLES synthesis for that style (the flag-set parser, `cli/args.zig`
    ///     `parsePackedStruct`, seeds from the all-true struct default and only flips the named flag, so
    ///     `no-bold` ⇒ `{bold:false, italic:true, bold-italic:true}` → no faux bold, the "primary face only"
    ///     intent).
    ///   • `synthetic` → `{kind}` — re-asserts the default-ON synthesis for that style (ghostty would
    ///     synthesize anyway, but the explicit token makes the user's "Synthetic" choice self-documenting and
    ///     survives a future default flip). Emitting it never disables a sibling style (the parser flips only
    ///     the named flag).
    public func syntheticTokens(kind: String) -> [String] {
        switch self {
        case .auto,
             .off: []
        case .primaryOnly: ["no-\(kind)"]
        case .synthetic: [kind]
        }
    }

    /// `true` iff this mode emits an explicit `font-style-{kind} = false` (only ``off`` disables the face).
    public var disablesFace: Bool { self == .off }
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
    /// builder applies the ordered NaN-faithful clamp + integral formatting.
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

    /// `true` iff this mode maps to an emitted libghostty key (only ``macosLike`` → `font-thicken = true`).
    public var thickens: Bool { self == .macosLike }
}

// The per-theme font SCOPE resolver that used to live here is gone with the theme picker
// (user-directed 2026-08-08): with one appearance there is one font slot, so the Global family in
// ``TerminalPreferences/fontFamily`` is the whole precedence chain.
