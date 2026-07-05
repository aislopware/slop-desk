import Foundation

// E15 (WI-2) — the leaf-level FONT-PARITY model: the four font-appearance enums + their libghostty token
// mapping, plus the pure `FontScopeResolver`.
//
// WHY a separate leaf file: `TerminalConfigBuilder` (also in this leaf `SlopDeskVideoProtocol`) must turn
// these settings into libghostty `key = value` lines WITHOUT importing any UI; the font UI
// (`FontSettingsView`, WI-8, up in `SlopDeskClientUI`) binds the SAME enums. Keeping them here keeps the
// mapping pure + headlessly testable (no SwiftUI, no libghostty surface — the hang-safety rule).
//
// GOLDEN-SAFETY: this config string is CLIENT-only (the libghostty surface) and NEVER on the wire, so it
// can never move a golden vector regardless of what it emits. Most settings still map to a libghostty line
// ONLY for their NON-default value; the ONE exception is `font-feature`, emitted UNCONDITIONALLY (ligatures
// default `.off` ⇒ the disabling set `-calt,-liga,-dlig` must always be sent). So a default-constructed
// `TerminalPreferences` is NOT byte-identical to the pre-E15 builder output — it gains exactly the one
// `font-feature = -calt,-liga,-dlig` line (pinned by `TerminalConfigBuilderTests`). The two controls that
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

/// Glyph anti-aliasing blend mode (`font-blending`, five values). Only ``macosLike`` has a verified
/// libghostty key (`font-thicken = true`); ``default`` and the remaining three (`srgb-over` / `linear` /
/// `perceptual`) are PERSISTED + surfaced but NOT emitted (no verified key — deferred-apply, like
/// `cursorAnimation = .smooth`). Raw values are the config tokens 1:1 (for persistence + the UI).
public enum FontBlending: String, Codable, Sendable, Equatable, CaseIterable {
    /// Defer to the active theme (falls back to `srgb-over`) — NO line.
    case `default`
    /// Default baseline (`srgb-over`) — persisted, NOT emitted (no verified libghostty key).
    case srgbOver = "srgb-over"
    /// macOS-native Display-P3 path → `font-thicken = true` (the one mode that maps).
    case macosLike = "macos-like"
    /// Physically-correct linear-light blend — persisted, NOT emitted.
    case linear
    /// Like ``linear`` but boosts thin dark text — persisted, NOT emitted.
    case perceptual

    /// `true` iff this mode maps to an emitted libghostty key (only ``macosLike`` → `font-thicken = true`).
    public var thickens: Bool { self == .macosLike }
}

// MARK: - FontScopeResolver (Computed scope precedence — pure)

/// The pure precedence resolver for the Font-Family SCOPE tabs (`Computed / Global / Light Theme /
/// Dark Theme / Fallback`). The "Computed" tab shows the EFFECTIVE family for the active OS-appearance slot.
///
/// PRECEDENCE: an explicitly-set ACTIVE-slot per-theme font (`appearance.themeFonts[slug]`) WINS; else the
/// Global family; else the bundled default — `scopeFont ?? globalFont ?? bundled`.
///
/// WHY scope-over-Global (E15 review #4): the Global slot (`terminal.fontFamily`) carries a NON-EMPTY
/// default (the bundled JetBrains Mono is a fallback value, not an explicit override), so it can't represent
/// "unset". Under a naive "Global wins everywhere" rule that non-empty default would permanently SHADOW a
/// per-theme font, so setting a Dark-theme font while Global sat at its default did NOTHING (the
/// silent-no-op the review flagged). Letting an explicitly-set per-scope font win instead means a per-theme
/// override travels with the theme, and Global only takes priority once the user EXPLICITLY sets it. Trims
/// whitespace and treats an empty/whitespace value as "unset" at every level.
public enum FontScopeResolver {
    /// Resolve the effective terminal font family for the active theme slot.
    /// - Parameters:
    ///   - global: the Global-scope override (`terminal.fontFamily` when the Global tab is set); `nil`/empty
    ///     ⇒ no Global override.
    ///   - themeFonts: the per-theme font overrides keyed by theme slug (`appearance.themeFonts`).
    ///   - slug: the active theme's slug (the Light/Dark slot in effect); `nil` ⇒ no per-theme lookup.
    ///   - fallback: the bundled default family used when neither scope provides a value.
    public static func resolvedFamily(
        global: String?,
        themeFonts: [String: String]?,
        slug: String?,
        fallback: String,
    ) -> String {
        // Scope-over-Global: an explicitly-set per-theme font for the active slot wins over the Global value
        // (see the type doc — slopdesk's Global default is non-empty, so it must NOT shadow a per-scope font).
        if let slug, let perTheme = nonEmpty(themeFonts?[slug]) { return perTheme }
        if let g = nonEmpty(global) { return g }
        return fallback
    }

    // MARK: Per-slot slug resolution (the Light / Dark / Computed scope tabs, WI-8)

    /// The theme-font key (slug) the Font → **Light Theme** scope tab writes under: the built-in id the light
    /// slot's ``AppearancePreferences/theme`` choice resolves to under OS-light (so a `.system` light slot
    /// keys the OS-light default). Pure — mirrors ``ThemeResolution`` slot routing, headless.
    public static func lightSlotSlug(_ appearance: AppearancePreferences) -> String {
        ThemeResolution.builtinID(for: appearance.theme, osIsDark: false)
    }

    /// The theme-font key (slug) the Font → **Dark Theme** scope tab writes under: the built-in id the dark
    /// slot's ``AppearancePreferences/themeDark`` choice resolves to under OS-dark. INDEPENDENT of
    /// ``AppearancePreferences/useSeparateDarkTheme`` — the Dark Theme tab always targets the dark slot's own
    /// theme even when follow-OS dual-slot is off (the slot still has a configured theme).
    public static func darkSlotSlug(_ appearance: AppearancePreferences) -> String {
        ThemeResolution.builtinID(for: appearance.themeDark, osIsDark: true)
    }

    /// The slug of the slot ACTIVE under `osIsDark` — drives the read-only **Computed** scope tab (the
    /// effective font for whatever theme the current OS appearance resolves to). The light/primary slot unless
    /// ``AppearancePreferences/useSeparateDarkTheme`` is on AND the OS is dark
    /// (``ThemeResolution/activeBuiltinID(appearance:osIsDark:)``).
    public static func activeSlotSlug(_ appearance: AppearancePreferences, osIsDark: Bool) -> String {
        ThemeResolution.activeBuiltinID(appearance: appearance, osIsDark: osIsDark)
    }

    /// The trimmed value if it is non-empty, else `nil` (an empty/whitespace string counts as "unset").
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
