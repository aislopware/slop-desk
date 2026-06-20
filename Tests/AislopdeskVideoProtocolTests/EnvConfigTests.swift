import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

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
        // A representative spread: an AISLOPDESK_* key (almost certainly unset in a test run), a
        // ubiquitous real key (PATH), and a guaranteed-absent garbage key.
        let keys = [
            "AISLOPDESK_QP_SHARP", "AISLOPDESK_FEC_M", "AISLOPDESK_ABR_WARMUP", "AISLOPDESK_VD",
            "PATH", "HOME",
            "AISLOPDESK_DEFINITELY_NOT_SET_\(UUID().uuidString)",
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
            "AISLOPDESK_VD", "AISLOPDESK_CRISP", "AISLOPDESK_NETSTATS", "AISLOPDESK_DECODE_OFFQUEUE",
            "AISLOPDESK_NACK", "AISLOPDESK_ADAPTIVE_QP", "AISLOPDESK_IDLE_SKIP", "AISLOPDESK_ABR_GRAD",
        ]
        for key in keys {
            XCTAssertEqual(EnvConfig.boolDefaultOn(key), env[key] != "0", "default-ON idiom for \(key)")
            XCTAssertEqual(EnvConfig.boolDefaultOff(key), env[key] == "1", "default-OFF idiom for \(key)")
        }
    }

    // MARK: Polarity truth tables over the overlay (missing / "0" / "1" / garbage)

    func testDefaultOnPolarityTruthTable() {
        let key = "AISLOPDESK_TEST_DEFAULT_ON"
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
        let key = "AISLOPDESK_TEST_DEFAULT_OFF"
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
        let onKey = "AISLOPDESK_TEST_BOOL_ON"
        let offKey = "AISLOPDESK_TEST_BOOL_OFF"
        XCTAssertTrue(EnvConfig.bool(onKey, default: true)) // unset, default-ON ⇒ true
        XCTAssertFalse(EnvConfig.bool(offKey, default: false)) // unset, default-OFF ⇒ false
        EnvConfig.overlay[onKey] = "0"
        EnvConfig.overlay[offKey] = "1"
        XCTAssertFalse(EnvConfig.bool(onKey, default: true))
        XCTAssertTrue(EnvConfig.bool(offKey, default: false))
    }

    // MARK: Overlay fills a gap (the new capability) — but a real env var STILL wins (decision #16)

    /// The overlay supplies a value for a key the process env does NOT set — the settings-reach-flag
    /// capability. (`AISLOPDESK_TEST_OVERRIDE` is not in a test process's environment.)
    func testOverlayFillsAbsentKey() {
        let key = "AISLOPDESK_TEST_OVERRIDE"
        XCTAssertNil(EnvConfig.string(key)) // unset everywhere
        EnvConfig.overlay[key] = "42"
        XCTAssertEqual(EnvConfig.string(key), "42") // overlay fills the gap
        XCTAssertEqual(EnvConfig.int(key, default: 0), 42)
    }

    /// PRECEDENCE (decision #16, P2): a real `ProcessInfo` env var WINS over the settings overlay —
    /// `env → overlay → default`. Proven against a key guaranteed to exist (`PATH`): even with an
    /// overlay entry present, the resolved value is the REAL env var, not the overlay. This matches the
    /// host sidecar gap-fill (a real env var is never clobbered) and the "explicit env override is
    /// honoured" contract — an operator's command-line `AISLOPDESK_*=…` always beats a persisted setting.
    func testRealEnvVarWinsOverOverlay() {
        let real = ProcessInfo.processInfo.environment["PATH"]
        XCTAssertNotNil(real)
        XCTAssertEqual(EnvConfig.string("PATH"), real) // empty overlay ⇒ the real value
        EnvConfig.overlay["PATH"] = "/overlay/only"
        XCTAssertEqual(EnvConfig.string("PATH"), real) // real env var STILL wins — overlay ignored
    }

    // MARK: Typed accessors (validate-then-default)

    func testIntAccessor() {
        let key = "AISLOPDESK_TEST_INT"
        XCTAssertEqual(EnvConfig.int(key, default: 7), 7) // unset ⇒ default
        EnvConfig.overlay[key] = "13"
        XCTAssertEqual(EnvConfig.int(key, default: 7), 13)
        EnvConfig.overlay[key] = "notanumber"
        XCTAssertEqual(EnvConfig.int(key, default: 7), 7) // garbage ⇒ default
        EnvConfig.overlay[key] = "100"
        XCTAssertEqual(EnvConfig.int(key, default: 7, min: 1, max: 10), 7) // out of range REJECTED ⇒ default
        EnvConfig.overlay[key] = "5"
        XCTAssertEqual(EnvConfig.int(key, default: 7, min: 1, max: 10), 5)
    }

    func testDoubleAccessor() {
        let key = "AISLOPDESK_TEST_DOUBLE"
        XCTAssertEqual(EnvConfig.double(key, default: 0.5), 0.5)
        EnvConfig.overlay[key] = "0.85"
        XCTAssertEqual(EnvConfig.double(key, default: 0.5), 0.85)
        EnvConfig.overlay[key] = "nan"
        XCTAssertEqual(EnvConfig.double(key, default: 0.5), 0.5) // non-finite REJECTED
        EnvConfig.overlay[key] = "inf"
        XCTAssertEqual(EnvConfig.double(key, default: 0.5), 0.5)
        EnvConfig.overlay[key] = "9.0"
        XCTAssertEqual(EnvConfig.double(key, default: 0.5, min: 0, max: 1), 0.5) // out of range ⇒ default
    }

    func testEnumAccessor() {
        let key = "AISLOPDESK_TEST_ENUM"
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
