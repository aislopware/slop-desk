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

/// Pure resolution of a captured keystroke (already decomposed from an `NSEvent` by the view) into a
/// ``KeybindingCaptureOutcome``. Mirrors `KeyChordNormalizer`'s keyCode handling but emits the persisted
/// ``KeybindingPreferences/KeyChord`` shape the editor stores.
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
        // Escape (53) cancels with no change.
        if keyCode == 53 { return .cancel }
        // Backspace/Delete (51) and Forward-Delete (117) UNBIND ("press Backspace to clear"). This MUST
        // branch before `baseKey`: otherwise Backspace's `charactersIgnoringModifiers` is the DEL scalar
        // "\u{7F}", which is ASCII + non-whitespace and would be recorded as a junk override.
        if keyCode == 51 || keyCode == 117 { return .clear }
        guard let key = baseKey(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers) else {
            return .ignore
        }
        return .bind(KeybindingPreferences.KeyChord(
            key: key, command: command, shift: shift, option: option, control: control,
        ))
    }

    /// The normalized base-key token for a captured keystroke: a named key for the special key codes, else a
    /// lowercased single printable character. `nil` for a pure modifier / control scalar / unmappable key so
    /// the caller keeps recording. Rejects DEL and the C0 control scalars (the bug source) explicitly.
    static func baseKey(keyCode: UInt16, charactersIgnoringModifiers: String?) -> String? {
        switch keyCode {
        case 36,
             76: return "return" // Return / keypad Enter
        case 48: return "tab"
        case 123: return "left"
        case 124: return "right"
        case 126: return "up"
        case 125: return "down"
        case 116: return "pageup"
        case 121: return "pagedown"
        case 115: return "home"
        case 119: return "end"
        default: break
        }
        // `charactersIgnoringModifiers` gives the base key independent of shift/option (so ⇧2 is "2").
        guard let chars = charactersIgnoringModifiers, let first = chars.first else { return nil }
        // Accept a single printable char only; reject whitespace AND any control scalar (DEL "\u{7F}" /
        // C0 < 0x20), which would otherwise sneak through (DEL is ASCII + non-whitespace).
        guard chars.count == 1, !first.isWhitespace, !isControlScalar(first),
              first.isASCII || first.isLetter
        else { return nil }
        return String(first).lowercased()
    }

    /// Whether `c` is a single control scalar (a C0 control or DEL). Anything that is not exactly one Unicode
    /// scalar is treated as control-like (it can't be a base key) so we never record it.
    private static func isControlScalar(_ c: Character) -> Bool {
        let scalars = c.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return true }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }
}

/// Pure search-filter + reset-gate logic for the editor.
public enum KeybindingsEditorModel {
    /// Whether `binding` matches a search `query`, filtering by action name (``WorkspaceBinding/title``), the
    /// fuzzy ``WorkspaceBinding/keywords``, OR the binding's EFFECTIVE chord — both its glyph form (`⌘T`) and
    /// its canonical string form (`cmd+t`), so typing `cmd+t` into the search box finds what's bound to that
    /// combo (see `docs/ui-shell/spec/customization__custom-keybindings.md:14`) alongside name search. A blank
    /// query matches all.
    public static func matches(
        _ binding: WorkspaceBinding,
        effectiveChord: KeyChord?,
        query: String,
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if binding.title.lowercased().contains(q) { return true }
        if let keywords = binding.keywords, keywords.lowercased().contains(q) { return true }
        if let chord = effectiveChord {
            if WorkspaceBindingRegistry.glyph(chord).lowercased().contains(q) { return true }
            // The canonical persisted form is `cmd+shift+t` etc. — what "search by chord" matching expects.
            if chord.asPreferencesChord.canonical.contains(q) { return true }
        }
        return false
    }

    /// Whether the editor should surface the top-right "Reset to Default" button — `true` once ANY
    /// customization exists (the button appears once any binding has been customized, and there is
    /// NO per-row revert; see `docs/ui-shell/spec/customization__custom-keybindings.md:15`). Clearing resets to
    /// `KeybindingPreferences()`.
    public static func hasCustomizations(_ prefs: KeybindingPreferences) -> Bool {
        !prefs.overrides.isEmpty || !prefs.sequenceOverrides.isEmpty
            || !prefs.textBindings.isEmpty || !prefs.unbinds.isEmpty
    }

    /// Return `prefs` with `id`'s single-chord override set to `chord`, PRESERVING every other collection
    /// (`sequenceOverrides` / `textBindings` / `unbinds`). The editor previously rebuilt the whole model as
    /// `KeybindingPreferences(overrides:)`, whose initializer defaults those three to empty — so ANY
    /// single-chord rebind in Settings silently wiped every config.toml `text:`/`csi:`/`esc:` literal-byte
    /// binding, `unbind:` directive, and multi-key sequence override (the audit bug). Mutating a copy keeps
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
    /// `sequenceOverrides` / `textBindings` / `unbinds` — the clear-one-row counterpart to ``settingOverride``
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
