#if canImport(SwiftUI)
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - DSScale (the live-scale fix)

/// The design-system's density multiplier — the LIVE, injected replacement for the dead
/// ``UIScale``-notification path.
///
/// THE CORRECTNESS FIX (P1): `DSScale` is `@Observable` AND is injected into the SwiftUI dependency
/// graph at ``WorkspaceRootView`` via `.environment(DSScale.shared)`. The `dsFont` / `dsSpace`
/// ViewModifiers read `@Environment(DSScale.self)`, so SwiftUI records the dependency and a density
/// change repaints every token-reading view. This closes the gap where ``UIScale`` is `@Observable`
/// but never injected — ``UIMetrics`` reads `UIScale.shared.multiplier` inside *static* computed vars,
/// which SwiftUI cannot observe, so `aislopdeskThemeDidChange` posts into the void (zero consumers).
///
/// P5: `DSScale.shared.multiplier` is now driven by the active ``DSDensity`` tier (via ``DSThemeStore``),
/// NOT the legacy ``UIScale`` preset. ``UIScale/multiplier`` in turn DELEGATES to the same density tier
/// (so the legacy ``UIMetrics`` tree and the DS tokens scale from ONE source and never diverge), while the
/// legacy ``UIScale`` survives as a thin compat shim for ``WindowConfigurator`` (the traffic-light Y).
@preconcurrency @MainActor
@Observable
public final class DSScale {
    /// The process-wide instance injected at ``WorkspaceRootView`` and read by every `dsFont`/`dsSpace`.
    public static let shared = DSScale()

    /// The density multiplier applied to every geometric token (fonts, spacing, radii).
    ///
    /// P5 default 1.00 (the `.default` density tier). It is a stored, observable property so mutating it
    /// invalidates every view whose body read `@Environment(DSScale.self)` — the tracked repaint path. It is
    /// seeded once from the resolved ``DSDensity`` tier (env + persistence) and re-set live by
    /// ``DSThemeStore``'s `density` `didSet` whenever the user (or env launch seed) changes the tier.
    public var multiplier: CGFloat

    private init() {
        // P5: seed from the resolved density tier (env launch-seed wins over persisted UserDefaults, else
        // `.default`) so DS tokens AND the bridged legacy `UIMetrics` tokens scale from one source. The live
        // re-set happens in DSThemeStore.density.didSet; this is the launch value.
        multiplier = DSDensity.resolved().multiplier
    }

    /// Scales a base point value by the active multiplier.
    ///
    /// CONVENTION: a single `*` — there is no `+ c` term, so the FMA rule is moot, but the project bans
    /// `addingProduct`/`fma` everywhere; keep it a plain multiply.
    public static func scaled(_ value: CGFloat) -> CGFloat {
        value * shared.multiplier
    }
}

// MARK: - DSDensity (semantic density tiers — wired to DSScale + heights in P5)

/// The semantic density tiers that REPLACE ``UIScale.Preset`` (`regular`/`large`/`extraLarge`). Each tier
/// carries a `multiplier` (fed to ``DSScale``) PLUS row-height tokens (`rowHeight`/`tabHeight`/
/// `statusBarHeight`, read by ``DSSpace``) so a density flip reflows the WHOLE chrome — fonts + padding via
/// the multiplier AND the chrome heights via the height tokens — not just fonts (the legacy presets only
/// touched the font multiplier, leaving heights fixed).
///
/// P5: wired to ``DSThemeStore`` (the persisted active tier) and to ``DSScale`` (the live multiplier).
/// Resolved at ONE site, ``resolved(env:userDefaults:)``, called from `DSThemeStore.init`.
public enum DSDensity: String, CaseIterable, Sendable {
    case compact
    case `default`
    case comfortable

    /// The scale factor fed to ``DSScale``.
    public var multiplier: CGFloat {
        switch self {
        case .compact: 0.92
        case .default: 1.00
        case .comfortable: 1.10
        }
    }

    /// The Settings-picker label for this tier.
    public var title: String {
        switch self {
        case .compact: "Compact"
        case .default: "Default"
        case .comfortable: "Comfortable"
        }
    }

    /// The list-row height for this tier (drives `DSSpace.rowHeight` in P5).
    public var rowHeight: CGFloat {
        switch self {
        case .compact: 24
        case .default: 28
        case .comfortable: 32
        }
    }

    /// The tab-strip row height for this tier.
    public var tabHeight: CGFloat {
        switch self {
        case .compact: 28
        case .default: 30
        case .comfortable: 34
        }
    }

    /// The bottom status-bar height for this tier.
    public var statusBarHeight: CGFloat {
        switch self {
        case .compact: 24
        case .default: 26
        case .comfortable: 28
        }
    }

    /// The `UserDefaults` key the chosen tier persists under (mirrored by ``SettingsKey/density`` so the
    /// Settings picker writes the same key this factory reads).
    static let storageKey = "appearance.density"

    /// Resolves the active density tier from the env launch-seed, falling back to the persisted
    /// `UserDefaults` value, else `.default`. Called ONCE from `DSThemeStore.init`.
    ///
    /// DEFAULT-OFF IDIOM (the load-bearing comparison): `AISLOPDESK_DENSITY == "1"` (or `"compact"`)
    /// enables compact for power users; `"comfortable"` is the explicit opt-in to the comfortable tier.
    /// Any UNSET or other value falls through to the persisted choice, else `.default` — it is `== "1"`
    /// (NOT the default-ON `!= "0"`), so an unset env NEVER resolves to `.compact`.
    public static func resolved(
        env: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
    ) -> Self {
        let raw = env["AISLOPDESK_DENSITY"]
        if raw == "1" || raw == "compact" { return .compact }
        if raw == "comfortable" { return .comfortable }
        if raw == "default" { return .default }
        // No env override (or any unrecognised value): fall through to the persisted choice, else .default.
        return userDefaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .default
    }
}

// MARK: - DSThemeStore (the optional accent override + density tier)

/// The persisted, observable theme overrides: an optional user accent (nil ⇒ ``DSColor.accentSolid``
/// falls back to ``DSPalette.a9``) and the active ``DSDensity`` tier.
///
/// P5: `density` is PERSISTED (to `UserDefaults` under ``DSDensity/storageKey``) and DRIVES ``DSScale``.
/// `init` resolves the launch tier via ``DSDensity/resolved(env:userDefaults:)`` (env launch-seed wins
/// over the persisted value); a later in-Settings density change writes the binding (mirrored to the same
/// key), and `density.didSet` re-sets `DSScale.shared.multiplier` LIVE + re-persists. `accent` stays a
/// forward-vocabulary override (always `nil` until the accent picker ships).
@preconcurrency @MainActor
@Observable
public final class DSThemeStore {
    /// The process-wide theme store read by ``DSColor.accentSolid`` + injected at ``WorkspaceRootView``.
    public static let shared = DSThemeStore()

    /// The user's accent override. `nil` ⇒ the DS default indigo (``DSPalette.a9``). Always `nil` today.
    public var accent: Color?

    /// The active density tier. Mutating it (Settings picker, or the resolved launch seed) re-sets
    /// ``DSScale``'s live multiplier AND persists the choice — so one tier flip reflows fonts/padding (via
    /// the multiplier) AND chrome heights (via the ``DSSpace`` height tokens that read `density.<height>`).
    public var density: DSDensity {
        didSet {
            guard density != oldValue else { return }
            // Drive the LIVE font/space/radius multiplier (the @Observable repaint path).
            DSScale.shared.multiplier = density.multiplier
            // Persist the choice so it survives relaunch (idempotent when the launch seed already matched).
            defaults.set(density.rawValue, forKey: DSDensity.storageKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = nil
        // Resolve the launch tier ONCE (env launch-seed wins over the persisted value, else .default). This
        // does NOT go through `didSet` (it is the initial assignment), so DSScale is seeded separately in
        // DSScale.init from the same `resolved()` source — the two agree at launch without a clobber loop.
        density = DSDensity.resolved(userDefaults: defaults)
    }
}
#endif
