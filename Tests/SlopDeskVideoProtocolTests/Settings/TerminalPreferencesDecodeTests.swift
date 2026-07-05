import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// E15 item 10 — ``TerminalPreferences`` ADDITIVE-TOLERANT decoding. The E15 font-parity fields were added
/// non-optional; under SYNTHESIZED `Codable` an existing user's stored blob (missing those keys) would
/// decode-FAIL and reset EVERY terminal pref once on upgrade. The custom `init(from:)` defaults absent keys
/// (NOT a migration — no-backcompat preserved), so a pre-E15 blob SURVIVES, while genuinely corrupt data
/// (a present-but-invalid value) still decode-fails to the default (validate-then-default).
final class TerminalPreferencesDecodeTests: XCTestCase {
    /// A pre-E15 blob — only the old keys present, NONE of the new font-parity keys — decodes SUCCESSFULLY:
    /// the old values are preserved and the new fields take their defaults (no whole-blob reset). Pre-fix
    /// (synthesized Decodable) this threw `keyNotFound` → the user lost their font/theme/cursor/scrollback.
    func testPreE15BlobSurvivesWithNewFieldsDefaulted() throws {
        let json = """
        {
          "fontFamily": "Menlo",
          "fontSize": 16,
          "fontWeight": "bold",
          "theme": "My Theme",
          "background": "000000",
          "foreground": "FFFFFF",
          "cursorStyle": "bar",
          "cursorBlink": "on",
          "scrollbackLines": 5000,
          "cursorColor": "",
          "cursorTextColor": "",
          "cursorOpacity": 1,
          "cursorAnimation": "off"
        }
        """
        let decoded = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8))

        // The OLD fields survive verbatim …
        XCTAssertEqual(decoded.fontFamily, "Menlo")
        XCTAssertEqual(decoded.fontSize, 16)
        XCTAssertEqual(decoded.fontWeight, "bold")
        XCTAssertEqual(decoded.cursorStyle, .bar)
        XCTAssertEqual(decoded.cursorBlink, .on)
        XCTAssertEqual(decoded.scrollbackLines, 5000)
        // … and the NEW E15 font-parity fields default (the value that emits no new line) — NOT reset to all.
        let d = TerminalPreferences()
        XCTAssertEqual(decoded.fontFamilyFallback, d.fontFamilyFallback)
        XCTAssertEqual(decoded.autoMatchWeightStyle, d.autoMatchWeightStyle)
        XCTAssertEqual(decoded.fontLigatures, d.fontLigatures)
        XCTAssertEqual(decoded.fontBold, d.fontBold)
        XCTAssertEqual(decoded.fontItalic, d.fontItalic)
        XCTAssertEqual(decoded.fontUnderline, d.fontUnderline)
        XCTAssertEqual(decoded.fontBlending, d.fontBlending)
        XCTAssertEqual(decoded.lineHeight, d.lineHeight)
    }

    /// An EMPTY object decodes to the full default (every key absent ⇒ every default) — never a throw.
    func testEmptyObjectDecodesToDefault() throws {
        let decoded = try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, TerminalPreferences())
    }

    /// GENUINE corruption still decode-FAILS: a key that is PRESENT but holds an invalid value (an unknown
    /// `cursorStyle` raw) throws — so `PreferencesStore.decode`'s `try?` falls back to the default. Absence is
    /// tolerated; a bad value is NOT (the validate-then-default discipline for hostile/stale data).
    func testPresentButInvalidValueStillThrows() {
        let json = #"{"cursorStyle":"midnight"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8)))
    }

    /// Full round-trip identity through the custom init(from:) + synthesized encode(to:).
    func testRoundTripIsIdentity() throws {
        let prefs = TerminalPreferences(
            fontFamily: "JetBrains Mono", fontSize: 14.5, cursorStyle: .underline,
            fontFamilyFallback: "PingFang SC", fontLigatures: .calt, lineHeight: .loose,
        )
        let data = try JSONEncoder().encode(prefs)
        let back = try JSONDecoder().decode(TerminalPreferences.self, from: data)
        XCTAssertEqual(back, prefs)
    }
}
