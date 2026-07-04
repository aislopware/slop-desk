import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// Round-trip + default tests for the four W12 settings models. Each model is a pure `Codable` value
/// type; this proves `encode |> decode == value`, that defaults are sensible, and (for keybindings)
/// the chord canonicalisation + conflict detection.
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

    func testTerminalPreferencesRoundTripAndDefaults() throws {
        let def = TerminalPreferences()
        XCTAssertEqual(def.fontFamily, "SF Mono")
        XCTAssertEqual(def.scrollbackLines, 10000)
        XCTAssertEqual(def.cursorStyle, .block)
        XCTAssertEqual(def.cursorBlink, .default) // tri-state default = defer to DEC mode 12
        // E8 WI-1: cursor color/text/opacity/animation render-pref defaults (empty colour = follow theme,
        // opacity 1.0, animation Off — the "Default" state).
        XCTAssertEqual(def.cursorColor, "")
        XCTAssertEqual(def.cursorTextColor, "")
        XCTAssertEqual(def.cursorOpacity, 1.0)
        XCTAssertEqual(def.cursorAnimation, .off)
        // E15 WI-2: the font-parity defaults — every one is the value that emits NO new libghostty line, so
        // a default-constructed prefs stays byte-identical to the pre-E15 builder output.
        XCTAssertEqual(def.fontFamilyFallback, "")
        XCTAssertEqual(def.fontFamilyBold, "")
        XCTAssertEqual(def.fontFamilyItalic, "")
        XCTAssertEqual(def.fontFamilyBoldItalic, "")
        XCTAssertTrue(def.autoMatchWeightStyle)
        XCTAssertEqual(def.fontLigatures, .off)
        XCTAssertFalse(def.fontLigaturesAlphabet)
        XCTAssertEqual(def.fontBold, .auto)
        XCTAssertEqual(def.fontItalic, .auto)
        XCTAssertTrue(def.fontUnderline)
        XCTAssertFalse(def.fontBlink)
        XCTAssertEqual(def.fontBlending, .default)
        XCTAssertEqual(def.lineHeight, .default)
        let custom = TerminalPreferences(
            fontFamily: "JetBrains Mono", fontSize: 14, fontWeight: "bold", theme: "Light",
            cursorStyle: .bar, cursorBlink: .off, scrollbackLines: 50000,
            cursorColor: "FF8800", cursorTextColor: "101010", cursorOpacity: 0.75, cursorAnimation: .smooth,
            fontFamilyFallback: "PingFang SC", fontFamilyBold: "IBM Plex Mono Bold",
            fontFamilyItalic: "IBM Plex Mono Italic", fontFamilyBoldItalic: "IBM Plex Mono Bold Italic",
            autoMatchWeightStyle: false, fontLigatures: .dlig, fontLigaturesAlphabet: true,
            fontBold: .synthetic, fontItalic: .primaryOnly, fontUnderline: false, fontBlink: true,
            fontBlending: .macosLike, lineHeight: .custom(1.5),
        )
        XCTAssertEqual(try roundTrip(custom), custom)
        // The associated-value `LineHeightMode` round-trips its payload (and the simple cases).
        for mode in [LineHeightMode.default, .compact, .loose, .custom(0.9), .custom(2.0)] {
            XCTAssertEqual(try roundTrip(TerminalPreferences(lineHeight: mode)).lineHeight, mode)
        }
    }

    func testAgentPreferencesRoundTrip() throws {
        XCTAssertNil(AgentPreferences().agentDetect)
        let custom = AgentPreferences(agentDetect: true, agentHooks: false)
        XCTAssertEqual(try roundTrip(custom), custom)
    }

    // MARK: Appearance (D2 — client chrome, golden-irrelevant)

    func testAppearancePreferencesDefaultIsAllNil() {
        let def = AppearancePreferences()
        XCTAssertNil(def.theme)
        XCTAssertNil(def.density)
    }

    func testAppearancePreferencesRoundTrip() throws {
        // Every theme choice (System, the six Monokai Pro filters, and legacy Paper/Dark) round-trips.
        for theme in ThemeChoice.allCases {
            let prefs = AppearancePreferences(theme: theme, density: "comfortable")
            XCTAssertEqual(try roundTrip(prefs), prefs)
        }
        // The default Monokai Pro Classic choice persists explicitly.
        XCTAssertEqual(try roundTrip(AppearancePreferences(theme: .monokaiProClassic)).theme, .monokaiProClassic)
        // A partially-set model round-trips too (density unset).
        let partial = AppearancePreferences(theme: .dark)
        XCTAssertEqual(try roundTrip(partial), partial)
        XCTAssertNil(try roundTrip(partial).density)
    }

    /// A malformed persisted blob must decode-FAIL to the all-`nil` default (validate-then-default, no
    /// migration). The store wraps this in `try? decode ?? .init()`, so the throw is the load-bearing
    /// behaviour: an unknown `theme` raw value invalidates the WHOLE blob.
    func testAppearancePreferencesMalformedDecodeFails() {
        // An unknown ThemeChoice raw value → the enum decode throws → the whole struct decode throws.
        let badTheme = Data(#"{"theme":"midnight"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppearancePreferences.self, from: badTheme))
        // Wholly non-object JSON also throws.
        let notObject = Data("[1,2,3]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppearancePreferences.self, from: notObject))
        // The store idiom collapses both to the all-nil default.
        XCTAssertEqual(
            (try? JSONDecoder().decode(AppearancePreferences.self, from: badTheme)) ?? AppearancePreferences(),
            AppearancePreferences(),
        )
    }

    // MARK: Keybindings

    func testKeyChordCanonical() {
        let c = KeybindingPreferences.KeyChord(key: "D", command: true, shift: true)
        XCTAssertEqual(c.key, "d") // lowercased on init
        XCTAssertEqual(c.canonical, "shift+cmd+d") // stable modifier order
    }

    /// P4 #15: a PERSISTED / hand-edited file with an UPPERCASE `key` must DECODE to the lowercase form
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
    /// CURRENT `schemaVersion` (3, bumped by E1/WI-6) — no-backcompat: a versionless / stale blob is
    /// rejected (see below).
    func testKeybindingPreferencesDecodeNormalisesKey() throws {
        let json = Data(#"{"schemaVersion":3,"overrides":{"pane.splitRight":{"key":"D","command":true}}}"#.utf8)
        let prefs = try JSONDecoder().decode(KeybindingPreferences.self, from: json)
        XCTAssertEqual(prefs.chord(for: "pane.splitRight")?.key, "d")
        XCTAssertEqual(prefs.chord(for: "pane.splitRight")?.canonical, "cmd+d")
    }

    /// No-backcompat (single-user): a persisted blob MISSING the schema version (the pre-W-B shape) or
    /// carrying a STALE version decode-FAILS — the store's `try? decode ?? .init()` then lands on the empty
    /// default rather than importing a stale shape. (FAILS on the un-versioned model: it would decode fine.)
    /// E1/WI-6 bumped the current version to 3, so a v1 AND a v2 blob are now both stale and rejected.
    func testKeybindingPreferencesStaleSchemaDecodeFails() {
        let versionless = Data(#"{"overrides":{"pane.splitRight":{"key":"d","command":true}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeybindingPreferences.self, from: versionless))
        let stale = Data(#"{"schemaVersion":1,"overrides":{"pane.splitRight":{"key":"d","command":true}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeybindingPreferences.self, from: stale))
        // The previous (W-B) version 2 blob is ALSO rejected now that WI-6 advanced the schema to 3.
        let v2 = Data(#"{"schemaVersion":2,"overrides":{"pane.splitRight":{"key":"d","command":true}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeybindingPreferences.self, from: v2))
    }

    /// A multi-key SEQUENCE override round-trips and bridges to the registry: `⌃A` then `D` (the tmux split
    /// idiom). The sequence canonical distinguishes it from a single-chord override, and `sequence(for:)`
    /// returns the full list. (FAILS on the single-chord-only model — no `sequenceOverrides` / `KeySequence`.)
    func testKeySequenceOverrideRoundTrips() throws {
        let seq = KeybindingPreferences.KeySequence(chords: [
            .init(key: "a", control: true),
            .init(key: "d"),
        ])
        let prefs = KeybindingPreferences(sequenceOverrides: ["pane.splitRight": seq])
        XCTAssertEqual(try roundTrip(prefs), prefs)
        XCTAssertEqual(prefs.sequence(for: "pane.splitRight")?.chords.count, 2)
        XCTAssertTrue(prefs.sequence(for: "pane.splitRight")?.isMultiKey == true)
        XCTAssertEqual(prefs.sequence(for: "pane.splitRight")?.canonical, "ctrl+a ; d")
    }

    /// `conflicts()` detects a SEQUENCE-vs-SINGLE collision: a single-chord override and a length-1 sequence
    /// override of the SAME chord collide (their canonicals match); a multi-key sequence only collides with
    /// an identical full sequence. (FAILS on the single-chord-only model — sequences aren't compared.)
    func testKeySequenceVsSingleConflictDetection() {
        // A single-chord override `⌘X` and a length-1 SEQUENCE override `⌘X` on a different id collide.
        let collide = KeybindingPreferences(
            overrides: ["a": .init(key: "x", command: true)],
            sequenceOverrides: ["b": .init(chords: [.init(key: "x", command: true)])],
        )
        let conflicts = collide.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts["cmd+x"].map { Set($0) }, Set(["a", "b"]))

        // A multi-key sequence does NOT collide with a single chord sharing only its HEAD.
        let noCollide = KeybindingPreferences(
            overrides: ["a": .init(key: "a", control: true)], // ⌃A single
            sequenceOverrides: ["b": .init(chords: [.init(key: "a", control: true), .init(key: "d")])], // ⌃A D
        )
        XCTAssertTrue(noCollide.conflicts().isEmpty, "a prefix-head overlap is not a full-sequence collision")
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

    // MARK: Keybindings — E1/WI-6 text bindings + unbinds (schema v3)

    /// The new `textBindings` (chord → literal bytes) and `unbinds` (suppressed-default chords) maps
    /// round-trip through the v3 schema. The `textBindings` map is keyed by a non-`String` `KeyChord`, so
    /// JSON encodes it as a flat key/value array — this asserts that survives a full encode→decode.
    /// (FAILS on the pre-WI-6 model: no `textBindings` / `unbinds` fields, schema still 2.)
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

    /// `conflicts()` folds text bindings + unbinds into the chord namespace: a text binding on a chord an
    /// action override ALSO resolves to is a real clash, and so is a text-binding-vs-unbind on the same
    /// chord. A text binding on its own (unique chord) is NOT a conflict.
    /// (FAILS on the pre-WI-6 `conflicts()`: it ignored text bindings + unbinds entirely.)
    func testTextBindingAndUnbindConflictFold() {
        // An action override `⌘X` and a text binding on the SAME chord ⌘X collide.
        let clash = KeybindingPreferences(
            overrides: ["pane.splitRight": .init(key: "x", command: true)],
            textBindings: [.init(key: "x", command: true): .init(kind: .text, payload: [0x78])],
        )
        let conflicts = clash.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(
            conflicts["cmd+x"].map { Set($0) }, Set(["pane.splitRight", "text:cmd+x"]),
        )

        // A text binding and an unbind on the SAME chord also collide (contradictory intent).
        let textVsUnbind = KeybindingPreferences(
            textBindings: [.init(key: "p", command: true): .init(kind: .esc, payload: [0x1B, 0x4F])],
            unbinds: [.init(key: "p", command: true)],
        )
        XCTAssertEqual(textVsUnbind.conflicts().count, 1)

        // A text binding on a UNIQUE chord is not a conflict.
        let unique = KeybindingPreferences(
            textBindings: [.init(key: "z", command: true): .init(kind: .text, payload: [0x7A])],
        )
        XCTAssertTrue(unique.conflicts().isEmpty)
    }

    func testKeybindingConflictDetection() {
        // Two ids bound to the SAME chord ⇒ a conflict; a unique binding ⇒ none.
        let prefs = KeybindingPreferences(overrides: [
            "a": .init(key: "x", command: true),
            "b": .init(key: "x", command: true), // collides with a
            "c": .init(key: "y", command: true), // unique
        ])
        let conflicts = prefs.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts["cmd+x"].map { Set($0) }, Set(["a", "b"]))
        XCTAssertTrue(KeybindingPreferences().conflicts().isEmpty) // empty ⇒ no conflicts
    }
}
