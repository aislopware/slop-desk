/// CLIENT-chrome appearance prefs — the density tier the GUI client renders at.
///
/// CRITICAL invariant (golden-safety): unlike ``VideoPreferences`` / ``AgentPreferences``, appearance is
/// PURE client chrome. It is NEVER routed through ``EnvBridge/toEnv(_:)``, never folded into
/// ``EnvConfig/overlay``, and never serialised into the `video-prefs.json` sidecar — so a default install
/// (all-`nil`) leaves the env overlay EMPTY and the golden corpus byte-identical. It persists ONLY to
/// `UserDefaults` (key `settings.appearance.v1`) and applies ONLY to ``SettingsKey/density``.
///
/// THEME IS GONE (user-directed 2026-08-08). The app ships ONE appearance — a cream ground carrying a
/// dark terminal — so there is no slot to choose, no follow-OS resolution, and no per-theme font map.
/// The dual-slot model (`theme` / `themeDark` / `useSeparateDarkTheme` / `themeFonts`) and its
/// `ThemeChoice` enum are deleted, not deprecated: a stored blob carrying those keys simply decodes
/// with them ignored, which leaves the one surviving field intact (no migration, by policy).
///
/// Default = all-`nil` ⇒ NO behaviour change: the density key is left untouched.
public struct AppearancePreferences: Codable, Sendable, Equatable {
    /// The density tier rawValue (mirrors ``SettingsKey/density``). `nil` ⇒ unset ⇒ leave the key untouched.
    public var density: String?

    public init(density: String? = nil) {
        self.density = density
    }
}
