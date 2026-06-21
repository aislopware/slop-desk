// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// The global UI density control for the chrome. Muxy stores this in a `CodableFileStore`; we drop that
/// dependency and persist a single preset string in `UserDefaults` (key `aislopdesk.uiScale`). Every
/// `UIMetrics` token multiplies its base by `UIScale.shared.multiplier`, so flipping the preset rescales
/// the whole chrome at once. Changing the preset posts `aislopdeskThemeDidChange` so views can refresh.
@preconcurrency @MainActor
@Observable
public final class UIScale {
    /// The process-wide instance every chrome view reads.
    public static let shared = UIScale()

    /// The discrete density steps (Muxy `UIScale.Preset`): a multiplier + a human title.
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case regular
        case large
        case extraLarge

        public var id: String { rawValue }

        /// The scale factor applied to every metric base.
        public var multiplier: CGFloat {
            switch self {
            case .regular: 1.00
            case .large: 1.12
            case .extraLarge: 1.24
            }
        }

        /// The menu / settings label for this preset.
        public var title: String {
            switch self {
            case .regular: "Default"
            case .large: "Large"
            case .extraLarge: "Extra Large"
            }
        }
    }

    /// The preset chosen if nothing is persisted.
    public static let defaultPreset: Preset = .regular

    /// The `UserDefaults` key the chosen preset is stored under.
    private static let storageKey = "aislopdesk.uiScale"

    /// The active density preset.
    ///
    /// ⚠️ WRITE-FROZEN POST-P5: P5 retired the Settings preset picker (replaced by the ``DSDensity`` density
    /// picker), and `UIScale/multiplier` now delegates to the active density TIER — so NOTHING writes `preset`
    /// at runtime any more; it is permanently `.regular`. Its `didSet` `save()` + `aislopdeskThemeDidChange`
    /// post and the `aislopdesk.uiScale` `UserDefaults` key are therefore DEAD paths (kept only so a previously
    /// persisted value still type-checks; the live density lives on ``DSDensity/storageKey``). The enum itself
    /// survives ONLY as the ``WindowConfigurator`` traffic-light reconfigure trigger (`uiScalePreset`).
    /// Persists to `UserDefaults` and posts `aislopdeskThemeDidChange` when changed (now unreachable).
    public var preset: Preset = UIScale.defaultPreset {
        didSet {
            guard !isLoading, preset != oldValue else { return }
            save()
            NotificationCenter.default.post(name: .aislopdeskThemeDidChange, object: nil)
        }
    }

    /// The current scale factor — the only thing `UIMetrics` needs.
    ///
    /// P5: DELEGATES to the active ``DSDensity`` tier (``DSThemeStore/shared`` `.density.multiplier`) rather
    /// than the legacy `preset.multiplier`, so the legacy ``UIMetrics`` token tree and the DS tokens scale
    /// from ONE source (the density tier) and can never diverge (the dual-multiplier geometric-incoherence
    /// risk). The `preset` enum survives only as the ``WindowConfigurator`` reconfigure trigger.
    public var multiplier: CGFloat { DSThemeStore.shared.density.multiplier }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        guard let raw = defaults.string(forKey: Self.storageKey),
              let stored = Preset(rawValue: raw)
        else { return }
        isLoading = true
        preset = stored
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(preset.rawValue, forKey: Self.storageKey)
    }
}

public extension Notification.Name {
    /// Posted when a theme-affecting setting (currently the UI scale preset) changes, so chrome views can
    /// invalidate cached metrics and redraw (Muxy posts `.themeDidChange`).
    static let aislopdeskThemeDidChange = Notification.Name("aislopdeskThemeDidChange")
}
#endif
