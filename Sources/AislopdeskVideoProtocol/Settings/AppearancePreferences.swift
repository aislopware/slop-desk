import Foundation

/// CLIENT-chrome appearance prefs (WS-D, D2) — the theme + density tier the GUI client renders.
///
/// CRITICAL invariant (golden-safety): unlike ``VideoPreferences`` / ``AgentPreferences``, appearance is
/// PURE client chrome. It is NEVER routed through ``EnvBridge/toEnv(_:)``, never folded into
/// ``EnvConfig/overlay``, and never serialised into the `video-prefs.json` sidecar — so a default install
/// (all-`nil`) leaves the env overlay EMPTY and the golden corpus byte-identical. It persists ONLY to
/// `UserDefaults` (key `settings.appearance.v1`) and applies ONLY to ``ThemeStore`` / ``SettingsKey/density``.
/// The E15 dual-slot / per-theme-font fields ADDED below keep this invariant — they too only drive
/// ``ThemeStore`` (theme/chrome) + ``TerminalConfigBuilder`` (pure client render config), never the
/// wire/sidecar/overlay; a default-install (all-`nil`) is still byte-identical to the frozen golden corpus.
///
/// Default = all-`nil` ⇒ NO behaviour change: the theme stays the compile-time default (Monokai Pro Classic)
/// and the density key is left untouched.
///
/// DUAL-SLOT MODEL (E15 / ES-E15-1): ``theme`` is the LIGHT / single / primary slot; ``themeDark`` is the
/// DARK slot. With ``useSeparateDarkTheme`` OFF (or `nil`) the primary slot applies for EVERY OS appearance
/// (one theme, no follow-OS — except the legacy `.system` built-in, which still follows the OS by
/// construction). With it ON the OS appearance selects the slot (light → light slot, dark → dark slot),
/// re-resolved LIVE by ``ThemeStore``'s OS-appearance observer. The pure picker is
/// ``ThemeResolution/activeBuiltinID(appearance:osIsDark:)``.
public struct AppearancePreferences: Codable, Sendable, Equatable {
    /// The active theme (the LIGHT / single / primary slot). `nil` ⇒ unset ⇒ keep the compile-time
    /// default (Monokai Pro Classic).
    public var theme: ThemeChoice?
    /// The density tier rawValue (mirrors ``SettingsKey/density``). `nil` ⇒ unset ⇒ leave the key untouched.
    public var density: String?
    /// The DARK-slot built-in theme, used only when ``useSeparateDarkTheme`` is ON and the OS is in dark mode.
    /// `nil` ⇒ unset ⇒ the dark slot resolves to the compile-time default Monokai Pro Classic.
    public var themeDark: ThemeChoice?
    /// Follow-OS dual-slot toggle (the "Use separated theme for dark mode" switch). `true` ⇒ the OS appearance
    /// picks the slot (light → ``theme``, dark → ``themeDark``); `nil`/`false` ⇒ the single primary slot
    /// applies for every appearance. `nil` (unset) reads as OFF.
    public var useSeparateDarkTheme: Bool?
    /// Per-theme font overrides keyed by theme slug (the Font → Light/Dark scope tabs, ES-E15-4). `nil`/absent
    /// ⇒ no per-theme override (the Global ``TerminalPreferences/fontFamily`` stands). Stored here (not on the
    /// terminal prefs) because the override is keyed by the THEME a slot resolves to.
    public var themeFonts: [String: String]?

    public init(
        theme: ThemeChoice? = nil,
        density: String? = nil,
        themeDark: ThemeChoice? = nil,
        useSeparateDarkTheme: Bool? = nil,
        themeFonts: [String: String]? = nil,
    ) {
        self.theme = theme
        self.density = density
        self.themeDark = themeDark
        self.useSeparateDarkTheme = useSeparateDarkTheme
        self.themeFonts = themeFonts
    }
}

/// The user-selectable theme. `.system` follows the OS appearance (→ Monokai Pro Classic dark /
/// Monokai Pro Light); the Monokai Pro filters and the legacy `.paper` / `.dark` pin a fixed theme. A
/// `String`-raw `Codable` enum so a stale / unknown persisted value decode-fails the whole
/// ``AppearancePreferences`` blob to its all-`nil` default (validate-then-default, no migration). A `nil`
/// stored theme (fresh install / reset) resolves to the compile-time default Monokai Pro Classic.
public enum ThemeChoice: String, Codable, Sendable, Equatable, CaseIterable {
    case system
    // Monokai Pro filters — palette from monokai.pro/contribute.
    case monokaiProClassic // dark, the DEFAULT
    case monokaiProClassicLight // light
    case monokaiProOctagon
    case monokaiProMachine
    case monokaiProRistretto
    case monokaiProSpectrum
    // Legacy palettes — still selectable.
    case paper
    case dark
}

public extension ThemeChoice {
    /// The stable ``SlateTheme`` `id` this choice pins to, or `nil` for ``system`` (which FOLLOWS the OS — the
    /// resolver substitutes the dark/light default per `osIsDark`). Used by ``ThemeResolution`` to produce a
    /// built-in id WITHOUT importing the SwiftUI `SlateTheme` (the leaf can't see ClientUI). The id strings
    /// MIRROR `SlateTheme.id`; the end-to-end `ThemeStoreTests` round-trip (id → `SlateTheme`) pins them so a
    /// drift between the two halves is caught.
    var builtinID: String? {
        switch self {
        case .system: nil
        case .monokaiProClassic: "monokai-classic"
        case .monokaiProClassicLight: "monokai-classic-light"
        case .monokaiProOctagon: "monokai-octagon"
        case .monokaiProMachine: "monokai-machine"
        case .monokaiProRistretto: "monokai-ristretto"
        case .monokaiProSpectrum: "monokai-spectrum"
        case .paper: "paper"
        case .dark: "dark"
        }
    }
}
