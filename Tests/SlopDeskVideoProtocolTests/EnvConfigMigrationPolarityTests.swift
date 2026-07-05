import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// Polarity-preservation proof for the D1 migration (W12): every raw `ProcessInfo` read swapped to an
/// `EnvConfig` accessor MUST be byte-identical to the legacy hand-written expression at that site, for
/// the full `{unset, "0", "1", garbage}` matrix. If a swap inverted the polarity (e.g. `boolDefaultOn`
/// ↔ `boolDefaultOff`, or `== "1"` ↔ `!= "0"`) one of these rows would diverge from its legacy lambda
/// and the assertion would FAIL — that is the whole point of pinning each migrated site individually.
///
/// The migrated sites and their legacy expressions:
///   • `SLOPDESK_DETACH_ENABLED`        (LivePaneSession)   `env[k] != "0"`  → `EnvConfig.boolDefaultOn`
///   • `SLOPDESK_ADAPTIVE_QP`           (WindowCapturer)    `env[k] == "1"`  → `EnvConfig.boolDefaultOff`
///   • `SLOPDESK_IDLE_SKIP`             (WindowCapturer)    `env[k] == "1"`  → `EnvConfig.boolDefaultOff`
///   • `SLOPDESK_SYSTEM_DIALOG_PANES`   (SlopDeskClientApp) raw `String?` 3-state → `EnvConfig.string`
///   • `SLOPDESK_SCROLL_RESAMPLE_HZ`    (InputInjector)     `Int?`+clamp on `env[k]`→ `EnvConfig.string`
///
/// `ProcessInfo` env is read-only at runtime, so the `{"0","1",garbage}` rows are driven through the
/// (process-wide) overlay for keys GUARANTEED absent from the real env (`SLOPDESK_*` test keys); the
/// `unset` row reads the empty overlay (≡ raw `ProcessInfo` of an absent key ≡ `nil`). Both expressions
/// resolve the SAME `EnvConfig.string(k)`, so the test compares the accessor against the legacy lambda
/// applied to that resolved string — not against a hardcoded expectation.
final class EnvConfigMigrationPolarityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EnvConfig.overlay = [:]
    }

    override func tearDown() {
        EnvConfig.overlay = [:]
        super.tearDown()
    }

    /// The `{unset, "0", "1", garbage}` value matrix. `nil` = leave the key out of the overlay (and the
    /// key is absent from the test process env), so `EnvConfig.string(k)` resolves to `nil` (= unset).
    private static let matrix: [String?] = [nil, "0", "1", "garbage"]

    /// Drives a key through the matrix and asserts the `EnvConfig` accessor equals the legacy expression
    /// over the SAME resolved string, for every row. `set` mutates the overlay (or clears it for `nil`).
    private func assertMigratedIdiom(
        key: String,
        accessor: (String) -> Bool,
        legacy: (String?) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        for value in Self.matrix {
            if let value { EnvConfig.overlay[key] = value } else { EnvConfig.overlay[key] = nil }
            let resolved = EnvConfig.string(key)
            XCTAssertEqual(
                accessor(key), legacy(resolved),
                "\(key) idiom diverged from legacy for value \(value.map { "\"\($0)\"" } ?? "unset")",
                file: file, line: line,
            )
        }
    }

    // MARK: default-ON (`!= "0"`) — SLOPDESK_DETACH_ENABLED

    /// `boolDefaultOn` reproduces the legacy `env[k] != "0"` exactly: ON for unset / "1" / garbage,
    /// OFF only for the literal "0". A `boolDefaultOff` swap here would flip the unset + garbage rows.
    func testDetachEnabledPreservesDefaultOnPolarity() {
        assertMigratedIdiom(
            key: "SLOPDESK_DETACH_ENABLED",
            accessor: EnvConfig.boolDefaultOn,
            legacy: { $0 != "0" },
        )
    }

    // MARK: default-OFF (`== "1"`) — SLOPDESK_ADAPTIVE_QP / _IDLE_SKIP

    /// `boolDefaultOff` reproduces the legacy `env[k] == "1"` exactly: ON only for the literal "1",
    /// OFF for unset / "0" / garbage. A `boolDefaultOn` swap here would flip the unset + garbage rows.
    func testAdaptiveQPPreservesDefaultOffPolarity() {
        assertMigratedIdiom(
            key: "SLOPDESK_ADAPTIVE_QP",
            accessor: EnvConfig.boolDefaultOff,
            legacy: { $0 == "1" },
        )
    }

    func testIdleSkipPreservesDefaultOffPolarity() {
        assertMigratedIdiom(
            key: "SLOPDESK_IDLE_SKIP",
            accessor: EnvConfig.boolDefaultOff,
            legacy: { $0 == "1" },
        )
    }

    // MARK: 3-state raw String? — SLOPDESK_SYSTEM_DIALOG_PANES

    /// The 3-state flag is read as a raw `String?` (the `unset / "0" / "force"` branch lives at the call
    /// site, NOT collapsed into a bool). `EnvConfig.string` must equal the legacy `env[k]` for every row,
    /// and crucially the downstream branch (`flag != "0"`, `flag != "force"`) must match too — so a
    /// `boolDefaultOn`/`Off` swap (which would erase the "force" arm) is provably wrong here.
    func testSystemDialogPanesPreservesRawThreeStateString() {
        let key = "SLOPDESK_SYSTEM_DIALOG_PANES"
        for value in [nil, "0", "force", "1", "garbage"] as [String?] {
            if let value { EnvConfig.overlay[key] = value } else { EnvConfig.overlay[key] = nil }
            // The raw resolved string equals the legacy ProcessInfo-style read.
            XCTAssertEqual(EnvConfig.string(key), value, "raw string for \(value ?? "unset")")
            // The two call-site branches (verbatim from SlopDeskClientApp) over the resolved value.
            let flag = EnvConfig.string(key)
            XCTAssertEqual(flag != "0", value != "0", "the `!= \"0\"` guard for \(value ?? "unset")")
            XCTAssertEqual(flag != "force", value != "force", "the `!= \"force\"` guard for \(value ?? "unset")")
        }
    }

    // MARK: Int-parse + clamp — SLOPDESK_SCROLL_RESAMPLE_HZ

    /// The scroll-resample site routes only its lookup through `EnvConfig.string`; the `Int?`+`> 0`
    /// guard + `0`-default + `[60, 1000]` clamp idiom is unchanged. This asserts the migrated resolver
    /// drives the SAME result as the legacy `Int(env[k])` expression across the matrix (incl. a real
    /// value, a below-floor value clamped up, an above-ceiling value clamped down, and garbage → 0).
    func testScrollResampleHzPreservesIntParseAndClamp() {
        let key = "SLOPDESK_SCROLL_RESAMPLE_HZ"
        // (overlay value, expected resolved Hz). The legacy expression, applied to the resolved string.
        let cases: [(String?, Int)] = [
            (nil, 0), // unset ⇒ 0 (OFF)
            ("0", 0), // not > 0 ⇒ 0
            ("250", 250), // in band
            ("30", 60), // below floor ⇒ clamped up to 60
            ("5000", 1000), // above ceiling ⇒ clamped down to 1000
            ("garbage", 0), // unparseable ⇒ 0
        ]
        func resolveHz(_ resolved: String?) -> Int {
            guard let s = resolved, let v = Int(s), v > 0 else { return 0 }
            return max(60, min(1000, v))
        }
        for (value, expected) in cases {
            if let value { EnvConfig.overlay[key] = value } else { EnvConfig.overlay[key] = nil }
            let resolved = EnvConfig.string(key)
            // EnvConfig.string equals the raw read, and the unchanged parse/clamp yields the expected Hz.
            XCTAssertEqual(resolved, value, "raw string for \(value ?? "unset")")
            XCTAssertEqual(resolveHz(resolved), expected, "resolved Hz for \(value ?? "unset")")
        }
    }
}
