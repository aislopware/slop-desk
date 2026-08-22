import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// Behaviour-preservation proof for ``EnvConfig`` — the load-bearing W12 invariant.
///
/// With an EMPTY overlay, `EnvConfig.string(k)` MUST equal `ProcessInfo.processInfo.environment[k]`
/// byte-for-byte, and the two polarity idioms (`!= "0"` default-ON / `== "1"` default-OFF) must match
/// the legacy hand-written expression for missing / `"0"` / `"1"` / garbage values. Only then do the
/// golden-pinned controllers resolve their compile-time defaults exactly as before. Then: the overlay
/// fills a key the env does NOT set (the new capability) — but a real env var STILL wins over the
/// overlay (decision #16, `env → overlay → default`) — and the typed accessors validate-then-default.
///
/// Test hygiene: the overlay is process-wide, so every test resets it in `setUp`/`tearDown`. The
/// `ProcessInfo` env is read-only at runtime, so the "empty overlay ≡ ProcessInfo" assertions use the
/// keys that ACTUALLY exist (or don't) in this process's environment — comparing the two expressions
/// against each other, not against a hardcoded expectation.
final class EnvConfigTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EnvConfig.overlay = [:]
    }

    override func tearDown() {
        EnvConfig.overlay = [:]
        super.tearDown()
    }

    // MARK: Empty overlay ≡ ProcessInfo (the safety story)

    /// `EnvConfig.string(k)` with an empty overlay is byte-identical to the direct ProcessInfo read,
    /// for both present (PATH) and absent keys. This is the exact expression the migrated controllers
    /// now call instead of `ProcessInfo.processInfo.environment[k]`.
    func testEmptyOverlayStringEqualsProcessInfo() {
        let env = ProcessInfo.processInfo.environment
        // A representative spread: an SLOPDESK_* key (almost certainly unset in a test run), a
        // ubiquitous real key (PATH), and a guaranteed-absent garbage key.
        let keys = [
            "SLOPDESK_QP_SHARP", "SLOPDESK_FEC_M", "SLOPDESK_ABR_WARMUP", "SLOPDESK_VD",
            "PATH", "HOME",
            "SLOPDESK_DEFINITELY_NOT_SET_\(UUID().uuidString)",
        ]
        for key in keys {
            XCTAssertEqual(
                EnvConfig.string(key), env[key],
                "EnvConfig.string(\(key)) must equal ProcessInfo with an empty overlay",
            )
        }
    }

    /// The default-ON (`!= "0"`) and default-OFF (`== "1"`) idioms, with an empty overlay, equal the
    /// hand-written legacy expression over the ACTUAL ProcessInfo value — for every key the production
    /// proof sites read.
    func testEmptyOverlayPolarityEqualsLegacyExpression() {
        let env = ProcessInfo.processInfo.environment
        let keys = [
            "SLOPDESK_VD", "SLOPDESK_CRISP", "SLOPDESK_NETSTATS", "SLOPDESK_DECODE_OFFQUEUE",
            "SLOPDESK_NACK", "SLOPDESK_ADAPTIVE_QP", "SLOPDESK_IDLE_SKIP", "SLOPDESK_ABR_GRAD",
        ]
        for key in keys {
            XCTAssertEqual(EnvConfig.boolDefaultOn(key), env[key] != "0", "default-ON idiom for \(key)")
            XCTAssertEqual(EnvConfig.boolDefaultOff(key), env[key] == "1", "default-OFF idiom for \(key)")
        }
    }

    // MARK: Polarity truth tables over the overlay (missing / "0" / "1" / garbage)

    func testDefaultOnPolarityTruthTable() {
        let key = "SLOPDESK_TEST_DEFAULT_ON"
        // unset ⇒ ON (!= "0" with nil is true)
        XCTAssertTrue(EnvConfig.boolDefaultOn(key))
        EnvConfig.overlay[key] = "0"
        XCTAssertFalse(EnvConfig.boolDefaultOn(key)) // exactly "0" ⇒ OFF
        EnvConfig.overlay[key] = "1"
        XCTAssertTrue(EnvConfig.boolDefaultOn(key))
        EnvConfig.overlay[key] = "true"
        XCTAssertTrue(EnvConfig.boolDefaultOn(key)) // any non-"0" ⇒ ON
        EnvConfig.overlay[key] = "garbage"
        XCTAssertTrue(EnvConfig.boolDefaultOn(key))
        EnvConfig.overlay[key] = ""
        XCTAssertTrue(EnvConfig.boolDefaultOn(key)) // empty string is not "0"
    }

    func testDefaultOffPolarityTruthTable() {
        let key = "SLOPDESK_TEST_DEFAULT_OFF"
        XCTAssertFalse(EnvConfig.boolDefaultOff(key)) // unset ⇒ OFF
        EnvConfig.overlay[key] = "1"
        XCTAssertTrue(EnvConfig.boolDefaultOff(key)) // exactly "1" ⇒ ON
        EnvConfig.overlay[key] = "0"
        XCTAssertFalse(EnvConfig.boolDefaultOff(key))
        EnvConfig.overlay[key] = "true"
        XCTAssertFalse(EnvConfig.boolDefaultOff(key)) // only literal "1" enables
        EnvConfig.overlay[key] = "garbage"
        XCTAssertFalse(EnvConfig.boolDefaultOff(key))
    }

    /// `bool(_:default:)` dispatches to the matching polarity helper.
    func testBoolDispatchesByDefault() {
        let onKey = "SLOPDESK_TEST_BOOL_ON"
        let offKey = "SLOPDESK_TEST_BOOL_OFF"
        XCTAssertTrue(EnvConfig.bool(onKey, default: true)) // unset, default-ON ⇒ true
        XCTAssertFalse(EnvConfig.bool(offKey, default: false)) // unset, default-OFF ⇒ false
        EnvConfig.overlay[onKey] = "0"
        EnvConfig.overlay[offKey] = "1"
        XCTAssertFalse(EnvConfig.bool(onKey, default: true))
        XCTAssertTrue(EnvConfig.bool(offKey, default: false))
    }

    // MARK: Overlay fills a gap (the new capability) — but a real env var STILL wins (decision #16)

    /// The overlay supplies a value for a key the process env does NOT set — the settings-reach-flag
    /// capability. (`SLOPDESK_TEST_OVERRIDE` is not in a test process's environment.)
    func testOverlayFillsAbsentKey() {
        let key = "SLOPDESK_TEST_OVERRIDE"
        XCTAssertNil(EnvConfig.string(key)) // unset everywhere
        EnvConfig.overlay[key] = "42"
        XCTAssertEqual(EnvConfig.string(key), "42") // overlay fills the gap
    }

    /// PRECEDENCE (decision #16, P2): a real `ProcessInfo` env var WINS over the settings overlay —
    /// `env → overlay → default`. Proven against a key guaranteed to exist (`PATH`): even with an
    /// overlay entry present, the resolved value is the REAL env var, not the overlay. This matches the
    /// host sidecar gap-fill (a real env var is never clobbered) and the "explicit env override is
    /// honoured" contract — an operator's command-line `SLOPDESK_*=…` always beats a persisted setting.
    func testRealEnvVarWinsOverOverlay() {
        let real = ProcessInfo.processInfo.environment["PATH"]
        XCTAssertNotNil(real)
        XCTAssertEqual(EnvConfig.string("PATH"), real) // empty overlay ⇒ the real value
        EnvConfig.overlay["PATH"] = "/overlay/only"
        XCTAssertEqual(EnvConfig.string("PATH"), real) // real env var STILL wins — overlay ignored
    }

    // MARK: Typed accessors

    // `testIntAccessor` and `testDoubleAccessor` were deleted with the two accessors they covered
    // (2026-08-22). They were the ONLY callers of `EnvConfig.int` / `.double` in the tree, which is
    // the shape `docs/55` §8 warns about at its sharpest: a rule with a test and no production
    // caller, beside two private copies of the same rule that had no test at all. The rule now has
    // one implementation — `slopdesk_abr_validated_int` / `_double` — and its differential lives in
    // `rust/slopdesk-ffi`'s `abr` module, where it is held against the CLAMPING reading on the same
    // input rather than checked against itself.

    func testEnumAccessor() {
        let key = "SLOPDESK_TEST_ENUM"
        XCTAssertEqual(EnvConfig.enumValue(key, default: VideoPreferences.Pacer.deadline), .deadline)
        EnvConfig.overlay[key] = "arrival"
        XCTAssertEqual(EnvConfig.enumValue(key, default: VideoPreferences.Pacer.deadline), .arrival)
        EnvConfig.overlay[key] = "bogus"
        XCTAssertEqual(
            EnvConfig.enumValue(key, default: VideoPreferences.Pacer.deadline),
            .deadline,
        ) // unknown ⇒ default
    }
}
