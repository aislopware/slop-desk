import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import Observation
import SwiftUI
#endif

/// The headless proof of the P1 LIVE-SCALE FIX (the critical correctness change). Two halves:
///   1. density math — `DSScale.scaled` is `value * multiplier`, separated (no FMA drift);
///   2. wiring — `DSScale` is `@Observable` (a `multiplier` mutation fires `withObservationTracking`),
///      and the `dsFont`/`dsSpace` ViewModifiers declare `@Environment(DSScale.self)` so SwiftUI records
///      the dependency and a density change repaints. The wiring half is the revert-to-confirm-fail guard
///      for the dead-notification bug (UIScale was @Observable but never injected; UIMetrics read
///      UIScale.shared inside static vars, which SwiftUI cannot observe).
///
/// No GUI: NO NSWindow / Ghostty / SCStream / VT is instantiated. The modifier wiring is proven by
/// reflecting the modifier struct (an `@Environment(DSScale.self)` property surfaces as an
/// `Environment<DSScale>` Mirror child), and the observability by `withObservationTracking`.
@MainActor
final class DSScaleWiringTests: XCTestCase {
    /// Pin the shared singletons to the default tier BEFORE every test so a leaked density from an unrelated
    /// suite (a future test that flips `DSThemeStore.shared.density` without restoring) can't poison the
    /// multiplier-pinning assertions here. Reset the density FIRST (its `didSet` re-sets the multiplier), then
    /// the multiplier — the same order as `tearDown`.
    override func setUp() {
        super.setUp()
        DSThemeStore.shared.density = .default
        DSScale.shared.multiplier = 1.0
    }

    /// Restore the shared tier + multiplier after any test mutates them, so tests stay order-independent.
    /// Reset the density FIRST (its `didSet` re-sets `DSScale.shared.multiplier`), THEN pin the multiplier —
    /// otherwise a test that flipped the tier would leave density and multiplier diverged for the next test.
    override func tearDown() {
        DSThemeStore.shared.density = .default
        DSScale.shared.multiplier = 1.0
        super.tearDown()
    }

    // MARK: - Density math

    /// At the P1 default multiplier 1.00, scaling is the identity.
    func testScaledIdentityAtDefault() {
        DSScale.shared.multiplier = 1.0
        XCTAssertEqual(DSScale.scaled(8), 8, accuracy: 1e-12)
        XCTAssertEqual(DSScale.scaled(0), 0, accuracy: 1e-12)
        XCTAssertEqual(DSScale.scaled(13), 13, accuracy: 1e-12)
    }

    /// `scaled` is exactly `value * multiplier` — a plain separated multiply, no FMA. Pin at a non-unit
    /// multiplier so the result is `base * mult` to full precision (FMA would keep extra precision and
    /// could differ in the low bits).
    ///
    /// ORDER-INDEPENDENCE: the mutation of the process-wide `DSScale.shared.multiplier` is wrapped in a
    /// `defer` restore so the singleton is back at 1.0 even if an assertion throws mid-test — `tearDown`
    /// alone is not enough (a thrown XCTest assertion would leak a non-unit multiplier to the next test).
    func testScaledIsSeparatedMultiply() {
        defer { DSScale.shared.multiplier = 1.0 }
        DSScale.shared.multiplier = 1.12
        XCTAssertEqual(DSScale.scaled(10), 10 * 1.12)
        XCTAssertEqual(DSScale.scaled(13), 13 * 1.12)
        DSScale.shared.multiplier = 1.24
        XCTAssertEqual(DSScale.scaled(28), 28 * 1.24)
    }

    /// P5 wiring: the legacy `UIScale.shared.multiplier` now DELEGATES to the active `DSDensity` tier (so the
    /// legacy `UIMetrics` tree and the DS tokens scale from ONE source). At the default tier both are 1.00.
    ///
    /// ORDER-INDEPENDENCE: this asserts the SHARED singleton's live value, which a sibling test could have
    /// left mid-mutation (XCTest runs serially + every mutator `defer`s a restore, but be defensive) — so
    /// it FIRST forces the tier back to `.default`, then asserts both multipliers agree at 1.00.
    func testLegacyMultiplierDelegatesToDensityTier() {
        defer { DSThemeStore.shared.density = .default }
        DSThemeStore.shared.density = .default
        XCTAssertEqual(UIScale.shared.multiplier, 1.0, "default density tier = 1.00, and UIScale delegates to it")
        DSScale.shared.multiplier = UIScale.shared.multiplier
        XCTAssertEqual(DSScale.shared.multiplier, 1.0)
        // A tier flip drives BOTH paths from the one source: UIScale (legacy) tracks the tier multiplier.
        DSThemeStore.shared.density = .compact
        XCTAssertEqual(UIScale.shared.multiplier, 0.92, accuracy: 1e-12)
    }

    // MARK: - Observability (the @Observable half of the fix)

    #if canImport(SwiftUI)
    /// `DSScale` is `@Observable`: a read of `multiplier` inside `withObservationTracking` registers a
    /// dependency, and a subsequent mutation fires the change handler. This is the mechanism SwiftUI uses
    /// to repaint a `dsFont`/`dsSpace` view on a density change — the thing the old `UIScale` static-var
    /// path could never trigger. REVERT-TO-CONFIRM-FAIL: drop `@Observable` from `DSScale` and this fails.
    func testDSScaleIsObservable() {
        defer { DSScale.shared.multiplier = 1.0 }
        let scale = DSScale.shared
        let fired = expectation(description: "observation change handler fires on multiplier mutation")
        withObservationTracking {
            _ = scale.multiplier
        } onChange: {
            fired.fulfill()
        }
        scale.multiplier = 1.5
        wait(for: [fired], timeout: 1.0)
    }
    #endif

    // MARK: - Modifier reads @Environment(DSScale.self) (the injection half of the fix)

    #if canImport(SwiftUI)
    /// The `dsFont` modifier declares `@Environment(DSScale.self)` — surfaced as an `Environment<DSScale>`
    /// stored property. This is what makes SwiftUI track the density dependency and repaint live (instead
    /// of reading `DSScale.shared` inside a static var, which is unobservable). REVERT-TO-CONFIRM-FAIL:
    /// change `DSFontModifier` to read `DSScale.shared` (drop the `@Environment` property) and this fails.
    func testDSFontModifierReadsEnvironmentDSScale() {
        let modifier = DSFontModifier(token: .body)
        XCTAssertTrue(
            hasEnvironmentDSScaleProperty(modifier),
            "DSFontModifier must hold an @Environment(DSScale.self) property for live repaint",
        )
    }

    /// The `dsSpace` modifier likewise reads `@Environment(DSScale.self)`.
    func testDSSpaceModifierReadsEnvironmentDSScale() {
        let modifier = DSSpaceModifier(edges: .all, base: 8)
        XCTAssertTrue(
            hasEnvironmentDSScaleProperty(modifier),
            "DSSpaceModifier must hold an @Environment(DSScale.self) property for live repaint",
        )
    }

    // MARK: - P5 density: the .dsFrame(height:) chrome-height modifier (tracks DSThemeStore + DSScale)

    /// The P5 `.dsFrame(height:)` modifier must hold BOTH an `@Environment(DSThemeStore.self)` property (the
    /// tier → the height VALUE) AND an `@Environment(DSScale.self)` property (the multiplier) — DSScale alone
    /// is insufficient because the chrome height comes from the active TIER, not just the multiplier.
    /// REVERT-TO-CONFIRM-FAIL: drop either `@Environment` from `DSFrameHeightModifier` and this fails.
    func testDSFrameHeightModifierTracksThemeStoreAndScale() {
        let modifier = DSFrameHeightModifier(height: \.tabHeight)
        // Both env properties use the OPTIONAL non-trapping form (`DSThemeStore?` / `DSScale?`), so the
        // runtime types are `Environment<DSThemeStore?>` / `Environment<DSScale?>`.
        XCTAssertTrue(
            Mirror(reflecting: modifier).children.contains {
                $0.value is Environment<DSThemeStore> || $0.value is Environment<DSThemeStore?>
            },
            "DSFrameHeightModifier must hold @Environment(DSThemeStore.self) — the tier carries the height value",
        )
        XCTAssertTrue(
            hasEnvironmentDSScaleProperty(modifier),
            "DSFrameHeightModifier must ALSO hold @Environment(DSScale.self) for the multiplier",
        )
    }

    // MARK: - P5 density: the multiplier + row-height math

    /// Each density tier's multiplier is the spec value (0.92 / 1.00 / 1.10).
    func testDensityMultipliers() {
        XCTAssertEqual(DSDensity.compact.multiplier, 0.92, accuracy: 1e-12)
        XCTAssertEqual(DSDensity.default.multiplier, 1.00, accuracy: 1e-12)
        XCTAssertEqual(DSDensity.comfortable.multiplier, 1.10, accuracy: 1e-12)
    }

    /// The per-tier chrome heights are the spec density table (row 24/28/32, tab 28/30/34, status 24/26/28).
    func testDensityHeights() {
        XCTAssertEqual(DSDensity.compact.rowHeight, 24)
        XCTAssertEqual(DSDensity.default.rowHeight, 28)
        XCTAssertEqual(DSDensity.comfortable.rowHeight, 32)
        XCTAssertEqual(DSDensity.compact.tabHeight, 28)
        XCTAssertEqual(DSDensity.default.tabHeight, 30)
        XCTAssertEqual(DSDensity.comfortable.tabHeight, 34)
        XCTAssertEqual(DSDensity.compact.statusBarHeight, 24)
        XCTAssertEqual(DSDensity.default.statusBarHeight, 26)
        XCTAssertEqual(DSDensity.comfortable.statusBarHeight, 28)
    }

    /// A tier flip drives BOTH the DSScale multiplier (fonts/space) AND the DSSpace height tokens (heights) —
    /// the end-to-end live-reflow path. Flipping `DSThemeStore.density` re-sets `DSScale.shared.multiplier`
    /// via the `didSet`; the height tokens come PURELY from the new tier (UNSCALED — the tier IS the density
    /// step for heights, so re-multiplying by the multiplier would double-count, landing 34·1.10=37.4 instead
    /// of the spec table's 34). This pins the single-density-step contract: the heights are the spec table
    /// (28/30/34, 24/26/28, 24/28/32) exactly, NOT compounded by the multiplier.
    func testTierFlipDrivesMultiplierAndUnscaledHeights() {
        defer { DSThemeStore.shared.density = .default }
        DSThemeStore.shared.density = .comfortable
        // The multiplier tracked the tier (the didSet re-set DSScale) — this still drives fonts + padding.
        XCTAssertEqual(DSScale.shared.multiplier, 1.10, accuracy: 1e-12)
        // The chrome HEIGHT tokens land on the spec table EXACTLY — the tier value, UNSCALED (no compounding).
        XCTAssertEqual(DSSpace.tabHeight, 34, accuracy: 1e-9)
        XCTAssertEqual(DSSpace.statusBarHeight, 28, accuracy: 1e-9)
        XCTAssertEqual(DSSpace.rowHeight, 32, accuracy: 1e-9)

        DSThemeStore.shared.density = .compact
        XCTAssertEqual(DSScale.shared.multiplier, 0.92, accuracy: 1e-12)
        XCTAssertEqual(DSSpace.tabHeight, 28, accuracy: 1e-9)
        XCTAssertEqual(DSSpace.statusBarHeight, 24, accuracy: 1e-9)
        XCTAssertEqual(DSSpace.rowHeight, 24, accuracy: 1e-9)
    }

    // MARK: - P5 density: the AISLOPDESK_DENSITY env parse (DEFAULT-OFF idiom)

    /// An isolated, empty `UserDefaults` suite (no force-unwrap — `XCTUnwrap` per the test lint rule). The
    /// suite plist is removed on teardown so the per-test UUID suites don't leak to disk.
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "DSScaleWiringTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// The load-bearing default-OFF idiom: an UNSET `AISLOPDESK_DENSITY` (and no persisted choice) resolves
    /// to `.default`, NEVER `.compact`. This is the `== "1"` (not `!= "0"`) rule — revert it and this fails.
    func testEnvUnsetResolvesToDefaultNotCompact() throws {
        let empty = try makeDefaults()
        XCTAssertEqual(DSDensity.resolved(env: [:], userDefaults: empty), .default)
    }

    /// `AISLOPDESK_DENSITY=1` (or `=compact`) enables compact for power users.
    func testEnvOneOrCompactEnablesCompact() throws {
        let empty = try makeDefaults()
        XCTAssertEqual(DSDensity.resolved(env: ["AISLOPDESK_DENSITY": "1"], userDefaults: empty), .compact)
        XCTAssertEqual(DSDensity.resolved(env: ["AISLOPDESK_DENSITY": "compact"], userDefaults: empty), .compact)
    }

    /// `AISLOPDESK_DENSITY=comfortable` is the explicit opt-in to the comfortable tier; `=default` pins default.
    func testEnvExplicitComfortableAndDefault() throws {
        let empty = try makeDefaults()
        XCTAssertEqual(
            DSDensity.resolved(env: ["AISLOPDESK_DENSITY": "comfortable"], userDefaults: empty), .comfortable,
        )
        XCTAssertEqual(DSDensity.resolved(env: ["AISLOPDESK_DENSITY": "default"], userDefaults: empty), .default)
    }

    /// `AISLOPDESK_DENSITY=0` must NOT be read as "enable" (the inverse of the default-ON `!= "0"` idiom): a
    /// `0` is an unrecognised value that falls through to the persisted choice, else `.default` — NOT compact.
    func testEnvZeroDoesNotEnableCompact() throws {
        let empty = try makeDefaults()
        XCTAssertEqual(DSDensity.resolved(env: ["AISLOPDESK_DENSITY": "0"], userDefaults: empty), .default)
    }

    /// With NO env override, the resolution falls through to the persisted `UserDefaults` value (so an
    /// in-Settings choice survives relaunch); an env override is the launch seed that WINS over persistence.
    func testEnvUnsetFallsThroughToPersisted_envWinsWhenSet() throws {
        let store = try makeDefaults()
        store.set(DSDensity.comfortable.rawValue, forKey: DSDensity.storageKey)
        // No env → the persisted comfortable value is used.
        XCTAssertEqual(DSDensity.resolved(env: [:], userDefaults: store), .comfortable)
        // Env launch-seed wins over the persisted value.
        XCTAssertEqual(
            DSDensity.resolved(env: ["AISLOPDESK_DENSITY": "compact"], userDefaults: store), .compact,
        )
    }

    /// The Settings key string matches the persistence key DSThemeStore reads/writes (so the picker, the
    /// store, and the persisted value all agree on one key — no drift).
    func testSettingsDensityKeyMatchesStorageKey() {
        XCTAssertEqual(SettingsKey.density, DSDensity.storageKey)
    }

    /// A tier change PERSISTS to the storage key (so it survives relaunch). Drive a store with an isolated
    /// UserDefaults and assert the `didSet` wrote the rawValue.
    func testTierChangePersists() throws {
        let store = try makeDefaults()
        let theme = DSThemeStore(defaults: store)
        theme.density = .comfortable
        XCTAssertEqual(store.string(forKey: DSDensity.storageKey), DSDensity.comfortable.rawValue)
    }

    /// Reflects a modifier and reports whether it has a stored property of type `Environment<DSScale>` OR
    /// `Environment<DSScale?>` — the runtime representation of an `@Environment(DSScale.self)` declaration.
    /// The OPTIONAL binding form (`private var scale: DSScale?`, the non-trapping shape the modifiers use so
    /// they fall back to the shared instance instead of crashing when rendered outside the injected scope)
    /// surfaces as `Environment<DSScale?>`, so both runtime types must be accepted.
    private func hasEnvironmentDSScaleProperty(_ subject: Any) -> Bool {
        Mirror(reflecting: subject).children.contains { child in
            child.value is Environment<DSScale> || child.value is Environment<DSScale?>
        }
    }
    #endif
}
