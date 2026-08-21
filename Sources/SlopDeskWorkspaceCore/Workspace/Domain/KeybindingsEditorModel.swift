import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

// MARK: - KeybindingsEditorModel (pure, headless logic for the Settings ▸ Key Bindings editor)

//
// The SwiftUI `KeybindingsEditorView` (SlopDeskClientUI) is a thin shell; all of its non-trivial logic —
// how a captured keystroke maps to a record / cancel / UNBIND outcome, how the search box filters rows, and
// when the global "Reset to Default" affordance appears — lives here as pure value functions so it is unit-
// testable WITHOUT instantiating any SwiftUI view or window-server resource. The view only does the AppKit
// NSEvent → parameters extraction and renders the result.

/// The outcome of capturing one keystroke while a row is recording a replacement chord — a "Rebind /
/// Unbind / cancel" interaction (see `docs/ui-shell/spec/customization__custom-keybindings.md:11-13`).
public enum KeybindingCaptureOutcome: Equatable, Sendable {
    /// Escape — stop recording, make NO change ("Press Esc to cancel").
    case cancel
    /// Backspace / Forward-Delete — CLEAR the binding ("press Backspace to clear the binding"). The
    /// editor removes the override (restoring the registry default) and stops recording. This is the bug the
    /// audit caught: Delete previously fell through to `charactersIgnoringModifiers == "\u{7F}"` and was
    /// recorded as a garbage DEL chord instead of unbinding.
    case clear
    /// A pure modifier / dead / unmappable key — keep recording (the user hasn't pressed a usable chord yet).
    case ignore
    /// Record this chord as the binding's override.
    case bind(KeybindingPreferences.KeyChord)
}

/// Resolution of a captured keystroke (already decomposed from an `NSEvent` by the view) into a
/// ``KeybindingCaptureOutcome``, asked of `slopdesk_video::key_naming` — the SAME table
/// ``KeyChordNormalizer`` reads, so a rebind captured here matches the chord the dispatcher builds.
/// What is Swift is the marshalling and the persisted ``KeybindingPreferences/KeyChord`` shape.
public enum KeybindingCapture {
    /// Resolve a captured keystroke. `keyCode` is the hardware key code; `charactersIgnoringModifiers` is the
    /// base character (shift/option folded out by AppKit); the four `Bool`s are the live modifier flags.
    public static func outcome(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
    ) -> KeybindingCaptureOutcome {
        var characters = charactersIgnoringModifiers ?? ""
        var key = [UInt8](repeating: 0, count: baseKeyCapacity)
        var needed = 0
        let verdict = characters.withUTF8 { chars in
            key.withUnsafeMutableBufferPointer { out in
                slopdesk_key_capture_outcome(
                    keyCode, chars.baseAddress, chars.count, out.baseAddress, out.count, &needed,
                )
            }
        }
        switch verdict {
        case 0: return .cancel
        case 1: return .clear
        case 3:
            guard let base = String(bytes: key.prefix(max(0, needed)), encoding: .utf8), !base.isEmpty else {
                return .ignore
            }
            return .bind(KeybindingPreferences.KeyChord(
                key: base, command: command, shift: shift, option: option, control: control,
            ))
        default: return .ignore
        }
    }

    /// Every canonical base key is a short ASCII token (`pagedown` is the longest) or one character, so this
    /// buffer never forces the door's retry — and if a longer name is ever added, the door reports the size
    /// rather than writing a truncated one.
    private static let baseKeyCapacity = 16
}

/// Pure search-filter + reset-gate logic for the editor.
public enum KeybindingsEditorModel {
    /// Whether `binding` matches a search `query`, filtering by action name (``WorkspaceBinding/title``), the
    /// fuzzy ``WorkspaceBinding/keywords``, OR the binding's EFFECTIVE chord — both its glyph form (`⌘T`) and
    /// its canonical string form (`cmd+t`), so typing `cmd+t` into the search box finds what's bound to that
    /// combo (see `docs/ui-shell/spec/customization__custom-keybindings.md:14`) alongside name search. A blank
    /// query matches all.
    ///
    /// The single-row face of ``surviving(_:effectiveChord:query:)``. `slopdesk-ffi`'s agreement test
    /// walks every member of a batch against this same door called on that member alone, so a list
    /// can never show a row this predicate says is filtered out.
    public static func matches(
        _ binding: WorkspaceBinding,
        effectiveChord: KeyChord?,
        query: String,
    ) -> Bool {
        surviving([binding], effectiveChord: { _ in effectiveChord }, query: query).first ?? false
    }

    /// Which of `bindings` survive `query`, as one flag per row in the given order — the editor's
    /// whole list in ONE crossing.
    ///
    /// The four spellings the filter reads (title, keyword run, chord glyph, chord canonical) are
    /// marshalled into one length-prefixed blob and the door answers positions, the way
    /// `slopdesk_settings_row_matches` does for the settings table. It is one crossing rather than
    /// n×4 not because crossings are dear — one is about a nanosecond — but because the comparison
    /// itself is: `String.contains(_: String)` is grapheme-aware search, measured at 825ns over a
    /// 35-byte title and 1,652ns over a 70-byte keyword run against 29ns and 53ns for the same
    /// containment as bytes. Eighty-five rows of that is 415µs on every keystroke typed into the
    /// search field.
    ///
    /// `effectiveChord` is a closure rather than a parallel array so the caller resolves overrides
    /// its own way and a row with no chord is simply `nil` — its two chord spellings cross empty,
    /// and an empty field matches nothing (only a blank QUERY keeps everything).
    public static func surviving(
        _ bindings: [WorkspaceBinding],
        effectiveChord: (WorkspaceBinding) -> KeyChord?,
        query: String,
    ) -> [Bool] {
        guard !bindings.isEmpty else { return [] }
        var records = [UInt8]()
        records.reserveCapacity(bindings.count * 128)
        append(length: bindings.count, to: &records)
        for binding in bindings {
            records.append(4) // title, keywords, glyph, canonical — the four the filter reads
            append(text: binding.title, to: &records)
            append(text: binding.keywords ?? "", to: &records)
            let written = effectiveChord(binding).map(spelling(of:))
            append(text: written?.glyph ?? "", to: &records)
            append(text: written?.canonical ?? "", to: &records)
        }
        var kept = [Bool](repeating: false, count: bindings.count)
        for position in matchedPositions(query, in: records, rows: bindings.count) {
            guard position >= 0, position < kept.count else { continue }
            kept[position] = true
        }
        return kept
    }

    /// The door, asked once. The answer can never be wider than the list that was offered, so the
    /// buffer is sized up front and the retry the protocol allows for is unreachable — checked
    /// rather than assumed, because reading a buffer the door refused to fill is the one failure
    /// this convention exists to prevent.
    private static func matchedPositions(_ query: String, in records: [UInt8], rows: Int) -> [Int] {
        var query = query
        return query.withUTF8 { needle -> [Int] in
            records.withUnsafeBufferPointer { lent -> [Int] in
                var out = [Int](repeating: 0, count: rows)
                let found = out.withUnsafeMutableBufferPointer { slots in
                    slopdesk_ws_binding_row_matches(
                        needle.baseAddress, needle.count,
                        lent.baseAddress, lent.count,
                        slots.baseAddress, slots.count,
                    )
                }
                guard found > 0, found <= out.count else { return [] }
                return Array(out.prefix(found))
            }
        }
    }

    /// One `[u32 len]` in the blob's little-endian length form.
    private static func append(length: Int, to records: inout [UInt8]) {
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: length).littleEndian) { records.append(contentsOf: $0) }
    }

    /// One `[u32 len][len bytes]` field.
    private static func append(text: String, to records: inout [UInt8]) {
        var text = text
        text.withUTF8 { bytes in
            append(length: bytes.count, to: &records)
            records.append(contentsOf: bytes)
        }
    }

    /// The two ways one chord is written — `⌘⇧T` for a reader, `cmd+shift+t` for a config file — asked
    /// of the doors ONCE per chord the registry declares.
    ///
    /// Both spellings are pure functions of the chord, and every chord in the DEFAULT table is known
    /// before the editor opens, so asking per row per keystroke was asking a constant question 85 times
    /// a keypress: `glyph` is one crossing for the key's canonical token plus one to render it, and
    /// `asPreferencesChord.canonical` is a third to fold the token and a fourth to write the chord back
    /// out. Measured against the shipped xcframework those five doors are ~5ns of BOUNDARY and 1,124ns
    /// of marshalling — nine allocations, two of them `[UInt8]` buffers and four of them `String`s.
    /// A user-rebound chord is not in the table and still asks, which is the right split: there are a
    /// handful of those and eighty-five of the others.
    ///
    /// Also what the chip on each row prints, so the glyph is rendered once for the search and the
    /// display both.
    public static func spelling(of chord: KeyChord) -> ChordSpelling {
        declaredSpellings[chord] ?? ChordSpelling(chord)
    }

    /// One chord written both ways.
    public struct ChordSpelling: Sendable, Equatable {
        /// What a menu row prints — `⌘⇧T`.
        public let glyph: String
        /// What a config file spells the same chord with — `cmd+shift+t`, already lower case.
        public let canonical: String

        /// Asks both doors once.
        init(_ chord: KeyChord) {
            glyph = WorkspaceBindingRegistry.glyph(chord)
            canonical = chord.asPreferencesChord.canonical
        }
    }

    /// Every chord the registry ships, spelled once per process. Built from ``WorkspaceBindingRegistry``
    /// rather than from a list of its own, so a new binding is covered by declaring it and nothing else.
    private static let declaredSpellings: [KeyChord: ChordSpelling] = {
        var spellings: [KeyChord: ChordSpelling] = [:]
        for chord in WorkspaceBindingRegistry.allBindings.compactMap(\.chord) {
            spellings[chord] = ChordSpelling(chord)
        }
        for chord in WorkspaceBindingRegistry.aliasChords.keys {
            spellings[chord] = ChordSpelling(chord)
        }
        return spellings
    }()

    /// Whether the editor should surface the top-right "Reset to Default" button — `true` once ANY
    /// customization exists (the button appears once any binding has been customized, and there is
    /// NO per-row revert; see `docs/ui-shell/spec/customization__custom-keybindings.md:15`). Clearing resets to
    /// `KeybindingPreferences()`.
    public static func hasCustomizations(_ prefs: KeybindingPreferences) -> Bool {
        !prefs.overrides.isEmpty
            || !prefs.textBindings.isEmpty || !prefs.unbinds.isEmpty
    }

    /// Return `prefs` with `id`'s single-chord override set to `chord`, PRESERVING every other collection
    /// (`textBindings` / `unbinds`). The editor previously rebuilt the whole model as
    /// `KeybindingPreferences(overrides:)`, whose initializer defaults those to empty — so ANY
    /// single-chord rebind in Settings silently wiped every config.toml `text:`/`csi:`/`esc:` literal-byte
    /// binding and `unbind:` directive (the audit bug). Mutating a copy keeps
    /// them intact while still yielding a fresh value so the store's `didSet` republishes.
    public static func settingOverride(
        _ chord: KeybindingPreferences.KeyChord,
        for id: String,
        in prefs: KeybindingPreferences,
    ) -> KeybindingPreferences {
        var next = prefs
        next.overrides[id] = chord
        return next
    }

    /// Return `prefs` with `id`'s single-chord override removed (restoring the registry default), PRESERVING
    /// `textBindings` / `unbinds` — the clear-one-row counterpart to ``settingOverride``
    /// (the editor's Backspace-to-clear path), same audit fix.
    public static func clearingOverride(
        for id: String,
        in prefs: KeybindingPreferences,
    ) -> KeybindingPreferences {
        var next = prefs
        next.overrides.removeValue(forKey: id)
        return next
    }
}
