import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// The settings models, each pinned at the seam it actually has.
///
/// ``VideoPreferences`` and ``AgentPreferences`` are still `Codable` — they ride the `video-prefs.json`
/// sidecar the host daemon reads — so a round-trip is the right test for them. ``TerminalPreferences``
/// is NOT: the config file is its only authoring surface and ``AppConfig`` already decodes it, so what
/// is pinned instead is that the table's defaults and the struct's field defaults are one answer.
/// Keybindings keep their own chord canonicalisation + conflict tests.
final class PreferencesTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testVideoPreferencesRoundTrip() throws {
        let prefs = VideoPreferences(
            qpSharp: 22, qpCoarse: 44, qpDecouple: true, fecM: 2, fecK: 5,
            pacer: .arrival, playoutMs: 12.5, captureScale: 1, displayCapture: .window,
            virtualDisplay: false, sharpen: 0.4,
        )
        XCTAssertEqual(try roundTrip(prefs), prefs)
        XCTAssertEqual(VideoPreferences(), VideoPreferences()) // default is all-nil
        XCTAssertNil(VideoPreferences().qpSharp)
    }

    /// The `[terminal]` rows and ``TerminalPreferences``'s own field defaults are the SAME answers.
    ///
    /// They are typed in two languages — the table says `terminal.font-size` defaults to
    /// `FACTORY_FONT_SIZE`, the struct says `fontSize = 14` — so this is where they are held together.
    /// It fails the moment a row's default is retuned without the struct following, which is the only
    /// way the two can drift now that the file is the one authoring surface.
    func testTerminalPreferencesFromCompiledDefaultsMatchesFieldDefaults() {
        XCTAssertEqual(TerminalPreferences(AppConfig.compiledDefaults), TerminalPreferences())
    }

    /// `terminal.line-height` is the one dual-typed row: a named stop OR a raw multiplier, with the
    /// number winning when both readings are present. `LineHeightMode` is not `RawRepresentable`, so
    /// this cannot go through `AppConfig.choice` and needs its own pin.
    func testLineHeightReadsBothNamedStopAndMultiplier() {
        let base = AppConfig.compiledDefaults
        XCTAssertEqual(TerminalPreferences(base).lineHeight, .default)
        XCTAssertEqual(TerminalPreferences(base.setting("terminal.line-height", "compact")).lineHeight, .compact)
        XCTAssertEqual(TerminalPreferences(base.setting("terminal.line-height", "loose")).lineHeight, .loose)
        XCTAssertEqual(TerminalPreferences(base.setting("terminal.line-height", 1.5)).lineHeight, .custom(1.5))
        XCTAssertEqual(
            TerminalPreferences(base.setting("terminal.line-height", "compact").setting("terminal.line-height", 1.25))
                .lineHeight,
            .custom(1.25),
            "a multiplier beats a named stop when the file somehow carries both",
        )
    }

    func testAgentPreferencesRoundTrip() throws {
        XCTAssertNil(AgentPreferences().preventSleep)
        let custom = AgentPreferences(preventSleep: true, resumeOnRecovery: false)
        XCTAssertEqual(try roundTrip(custom), custom)
    }

    // MARK: Keybindings

    func testKeyChordCanonical() {
        let c = KeybindingPreferences.KeyChord(key: "D", command: true, shift: true)
        XCTAssertEqual(c.key, "d") // lowercased on init
        XCTAssertEqual(c.canonical, "shift+cmd+d") // stable modifier order
    }

    /// A PERSISTED / hand-edited file with an UPPERCASE `key` must DECODE to the lowercase form
    /// (the synthesised decoder would have stored "D" verbatim — a silently-dead override, since
    /// `canonical` would be "cmd+D" and never match the lowercase chord the lookup compares). The custom
    /// `init(from:)` normalises on decode. (Fails on the synthesised decoder.)
    func testKeyChordDecodeLowercasesKey() throws {
        let json = Data(#"{"key":"D","command":true,"shift":true,"option":false,"control":false}"#.utf8)
        let chord = try JSONDecoder().decode(KeybindingPreferences.KeyChord.self, from: json)
        XCTAssertEqual(chord.key, "d", "an uppercase persisted key must normalise to lowercase on decode")
        XCTAssertEqual(chord.canonical, "shift+cmd+d")
        // And it matches a chord built via the (already-lowercasing) memberwise init — so the lookup works.
        XCTAssertEqual(chord, KeybindingPreferences.KeyChord(key: "d", command: true, shift: true))
    }

    /// The same normalisation applies through a full `KeybindingPreferences` decode + the `chord(for:)`
    /// lookup, so an uppercase override in a persisted prefs file resolves correctly. The blob carries the
    /// CURRENT `schemaVersion` (3) — no-backcompat: a versionless / stale blob is
    /// rejected (see below).
    func testKeybindingPreferencesDecodeNormalisesKey() throws {
        let json = Data(#"{"schemaVersion":3,"overrides":{"pane.splitRight":{"key":"D","command":true}}}"#.utf8)
        let prefs = try JSONDecoder().decode(KeybindingPreferences.self, from: json)
        XCTAssertEqual(prefs.chord(for: "pane.splitRight")?.key, "d")
        XCTAssertEqual(prefs.chord(for: "pane.splitRight")?.canonical, "cmd+d")
    }

    /// No-backcompat (single-user): a persisted blob MISSING the schema version or
    /// carrying a STALE version decode-FAILS — the store's `try? decode ?? .init()` then lands on the empty
    /// default rather than importing a stale shape. (FAILS on the un-versioned model: it would decode fine.)
    /// The current version is 3, so a v1 AND a v2 blob are both stale and rejected.
    func testKeybindingPreferencesStaleSchemaDecodeFails() {
        let versionless = Data(#"{"overrides":{"pane.splitRight":{"key":"d","command":true}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeybindingPreferences.self, from: versionless))
        let stale = Data(#"{"schemaVersion":1,"overrides":{"pane.splitRight":{"key":"d","command":true}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeybindingPreferences.self, from: stale))
        // The previous version 2 blob is ALSO rejected now that the schema is at 3.
        let v2 = Data(#"{"schemaVersion":2,"overrides":{"pane.splitRight":{"key":"d","command":true}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeybindingPreferences.self, from: v2))
    }

    /// PREFIX-REMOVAL PIN: a v3 blob still carrying the RETIRED `prefixKey` / `sequenceOverrides` fields
    /// (written before the 2026-07-22 prefix-mode removal) decodes cleanly — the unknown keys are simply
    /// not read, and no schema bump was needed (fields were only removed, never re-shaped).
    func testRetiredPrefixFieldsInBlobAreIgnored() throws {
        let legacy = Data("""
        {"schemaVersion":3,
         "overrides":{"pane.splitRight":{"key":"d","command":true}},
         "prefixKey":{"key":"g","control":true},
         "sequenceOverrides":{"tab.new":[{"key":"a","control":true},{"key":"t"}]}}
        """.utf8)
        let prefs = try JSONDecoder().decode(KeybindingPreferences.self, from: legacy)
        XCTAssertEqual(prefs.chord(for: "pane.splitRight")?.canonical, "cmd+d", "live fields still decode")
    }

    func testKeybindingPreferencesRoundTrip() throws {
        let prefs = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "d", command: true),
            "pane.splitDown": .init(key: "d", command: true, shift: true),
        ])
        XCTAssertEqual(try roundTrip(prefs), prefs)
        XCTAssertEqual(prefs.chord(for: "pane.splitRight")?.canonical, "cmd+d")
        XCTAssertNil(prefs.chord(for: "pane.notOverridden"))
    }

    // MARK: Keybindings — text bindings + unbinds (schema v3)

    /// The new `textBindings` (chord → literal bytes) and `unbinds` (suppressed-default chords) maps
    /// round-trip through the v3 schema. The `textBindings` map is keyed by a non-`String` `KeyChord`, so
    /// JSON encodes it as a flat key/value array — this asserts that survives a full encode→decode.
    /// (FAILS on a model with no `textBindings` / `unbinds` fields and schema still 2.)
    func testTextBindingsAndUnbindsRoundTrip() throws {
        let prefs = KeybindingPreferences(
            textBindings: [
                .init(key: "h", command: true, shift: true): .init(kind: .text, payload: [0x68, 0x69]),
                .init(key: "k", control: true): .init(kind: .csi, payload: [0x1B, 0x5B, 0x31, 0x37, 0x7E]),
            ],
            unbinds: [.init(key: "q", command: true)],
        )
        let restored = try roundTrip(prefs)
        XCTAssertEqual(restored, prefs)
        XCTAssertEqual(
            restored.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
        XCTAssertEqual(restored.textBindings[.init(key: "h", command: true, shift: true)]?.kind, .text)
        XCTAssertTrue(restored.unbinds.contains(.init(key: "q", command: true)))
        XCTAssertEqual(KeybindingPreferences.currentSchemaVersion, 3)
    }
}
