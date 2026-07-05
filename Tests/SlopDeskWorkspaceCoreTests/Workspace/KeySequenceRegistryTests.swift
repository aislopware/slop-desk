import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// WS-B / B1 — the multi-key SEQUENCE extension of the registry chord model. Pins the dispatcher-side
/// ``KeySequence``, the ``WorkspaceBinding`` `sequence:` field + `effectiveSequence`, the sequence glyph
/// renderer, the `sequenceTable`, and the override bridge (`asRegistrySequence` →
/// `resolvedSequenceTable`). Each test FAILS on the un-fixed (single-chord-only) registry.
@MainActor
final class KeySequenceRegistryTests: XCTestCase {
    override func tearDown() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        super.tearDown()
    }

    /// A registry ``KeySequence`` is non-empty by construction: an empty list yields `nil`; a single chord
    /// is the degenerate length-1 sequence with `head` == that chord and `isMultiKey == false`.
    func testKeySequenceConstructionAndHead() {
        XCTAssertNil(KeySequence([]), "an empty sequence is rejected")
        let single = KeySequence(single: KeyChord(character: "d", [.command]))
        XCTAssertEqual(single.head, KeyChord(character: "d", [.command]))
        XCTAssertFalse(single.isMultiKey)

        let multi = KeySequence([KeyChord(character: "a", [.control]), KeyChord(character: "d")])
        XCTAssertEqual(multi?.head, KeyChord(character: "a", [.control]))
        XCTAssertTrue(multi?.isMultiKey == true)
    }

    /// A ``WorkspaceBinding`` built with a multi-key `sequence:` keeps `chord` in lock-step with the head (so
    /// single-chord consumers still work) and exposes the full list via `effectiveSequence`. A single-chord
    /// binding's `effectiveSequence` is the length-1 sequence wrapping its chord.
    func testWorkspaceBindingEffectiveSequence() {
        let multi = WorkspaceBinding(
            id: "test.prefixSplit", action: .splitRight, title: "Prefix Split",
            category: .panes, chord: nil,
            sequence: KeySequence([KeyChord(character: "a", [.control]), KeyChord(character: "d")]),
            symbol: "rectangle.split.2x1",
        )
        XCTAssertEqual(multi.chord, KeyChord(character: "a", [.control]), "chord mirrors the sequence head")
        XCTAssertEqual(multi.effectiveSequence?.chords.count, 2)

        let single = WorkspaceBindingRegistry.binding(for: .splitRight)
        XCTAssertEqual(single?.effectiveSequence, KeySequence(single: KeyChord(character: "d", [.command])))
    }

    /// The sequence glyph renderer space-joins the per-chord glyphs (e.g. `⌃A D`); a length-1 sequence
    /// renders identically to the single-chord glyph.
    func testSequenceGlyphRendering() throws {
        let multi = try XCTUnwrap(KeySequence([KeyChord(character: "a", [.control]), KeyChord(character: "d")]))
        XCTAssertEqual(WorkspaceBindingRegistry.glyph(multi), "⌃A D")
        let singleChord = KeyChord(character: "d", [.command])
        let single = KeySequence(single: singleChord)
        XCTAssertEqual(
            WorkspaceBindingRegistry.glyph(single),
            WorkspaceBindingRegistry.glyph(singleChord),
        )
    }

    /// `sequenceTable` maps EVERY chord-bearing binding's full sequence to its action — single-chord
    /// bindings appear as their length-1 sequence so one table serves both single + multi-key.
    func testSequenceTableContainsSingleChordBindings() {
        let table = WorkspaceBindingRegistry.sequenceTable
        XCTAssertEqual(table[KeySequence(single: KeyChord(character: "d", [.command]))], .splitRight)
        XCTAssertEqual(table[KeySequence(single: KeyChord(character: "w", [.command]))], .closePane)
    }

    /// A SEQUENCE override (`⌃A` then `D` for split-right) bridges through `asRegistrySequence` into the
    /// live `resolvedSequenceTable`, routing the new multi-key sequence while FREEING the old ⌘D default.
    func testSequenceOverrideRoutesViaResolvedSequenceTable() throws {
        let seq = KeybindingPreferences.KeySequence(chords: [
            .init(key: "a", control: true),
            .init(key: "d"),
        ])
        let overrides = KeybindingPreferences(sequenceOverrides: ["pane.splitRight": seq])
        let table = WorkspaceBindingRegistry.resolvedSequenceTable(overrides: overrides)

        let mapped = try XCTUnwrap(KeySequence([KeyChord(character: "a", [.control]), KeyChord(character: "d")]))
        XCTAssertEqual(table[mapped], .splitRight, "the multi-key override routes split-right")
        XCTAssertNil(
            table[KeySequence(single: KeyChord(character: "d", [.command]))],
            "the old single-chord ⌘D default is freed by the sequence override",
        )
    }

    /// A MALFORMED sequence override (an unmappable chord) is ignored → the binding keeps its registry
    /// default sequence (validate-then-default, never a partial/wrong fire).
    func testMalformedSequenceOverrideFallsBackToDefault() {
        let bad = KeybindingPreferences.KeySequence(chords: [
            .init(key: "a", control: true),
            .init(key: ""), // empty → unmappable
        ])
        let overrides = KeybindingPreferences(sequenceOverrides: ["pane.splitRight": bad])
        let resolved = WorkspaceBindingRegistry.resolvedSequence(for: .splitRight, overrides: overrides)
        XCTAssertEqual(
            resolved, KeySequence(single: KeyChord(character: "d", [.command])),
            "an unmappable override leaves the registry default sequence",
        )
    }

    /// `asRegistrySequence` maps a clean persisted sequence into the dispatcher shape chord-by-chord.
    func testAsRegistrySequenceBridgesCleanSequence() {
        let seq = KeybindingPreferences.KeySequence(chords: [
            .init(key: "a", control: true),
            .init(key: "left"),
        ])
        XCTAssertEqual(
            seq.asRegistrySequence,
            KeySequence([KeyChord(character: "a", [.control]), KeyChord(.leftArrow)]),
        )
    }
}
