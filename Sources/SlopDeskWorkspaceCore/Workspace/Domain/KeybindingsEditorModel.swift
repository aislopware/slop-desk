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
