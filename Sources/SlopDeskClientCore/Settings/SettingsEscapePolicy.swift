// SettingsEscapePolicy — what Esc means inside the Settings window.
//
// Esc closes the Settings window, and the window itself performs that: `MacSettingsWindow` overrides
// `cancelOperation(_:)`, which is the responder chain's own path for the key. This file is what it
// ASKS — the decision, and the one flag that can veto it.
//
// It used to be a window-scoped `NSEvent` monitor mounted as a zero-size `.background`, because a
// stock SwiftUI `Settings` scene had no Esc behaviour at all and `.onExitCommand` resolved against a
// focused branch that a freshly-opened settings window did not have. Two hardware rounds went into
// that monitor; all of it is now one AppKit override, and the monitor is gone with the scene.
//
// TEXT FIELDS DO NOT GET A VETO, and that took those two rounds to settle. Esc in a field editor is
// macOS's leave-the-field key, so the first two designs tried to respect it: (1) pass Esc THROUGH
// while a field editor is up — but SwiftUI's `.searchable` pill silently ignored it, so with the pill
// focused Esc did nothing at all, forever; (2) resign first responder on the first Esc and close on
// the second — but `makeFirstResponder(nil)` did not stick against `.searchable`. Both were dead
// ends, verified on hardware. Nothing is lost by closing from any focus state: every text surface in
// Settings commits continuously — `Defaults`-backed fields on change, the raw `SLOPDESK_*` editor in
// its `onChange`, the font-family combobox through `DraftCommitDebouncer` — so there is no pending
// edit for an Esc to revert, and the window ends its field editors before closing so an in-flight
// commit lands through its normal path.
//
// THE ONE REAL VETO is the Key Bindings chord recorder, where Esc already MEANS "cancel this capture"
// (`KeybindingsEditorModel` maps keyCode 53 → `.cancel`). The recorder publishes
// ``SettingsChordCapture/isCapturing`` and the decision stands down while it is armed.
//
// The decision itself is `slopdesk_video::escape_monitor`, asked through ``SettingsEscapePolicy``;
// the caller only measures the inputs — the keycode and the wire's own modifier mask.

import CSlopDeskFFI

// MARK: - SettingsEscapePolicy (pure — no AppKit, so it is unit-pinned headlessly)

/// What a key-down should do to the Settings window.
package enum SettingsEscapeDecision: Equatable {
    /// Close the Settings window and SWALLOW the event (nothing else should see this Esc).
    case closeWindow
    /// Leave the event alone — it isn't Esc, it carries a modifier, or a chord capture owns this Esc.
    case passThrough
}

// MARK: - SettingsChordCapture (the recorder's claim on Esc)

/// Whether a Key Bindings row is currently recording a replacement chord. Published by
/// `KeybindingsEditorView` (the only writer) and read by the Esc monitor, which stands down while it is armed —
/// there Esc already means "cancel this capture" (`KeybindingCapture.cancel`), and two local `.keyDown` monitors
/// racing for the same key would otherwise resolve in AppKit's undocumented install order.
///
/// A plain `@MainActor` flag, not `@Observable`: nothing RENDERS from it (the recorder drives its own UI off
/// `recordingID`); it exists only so the key monitor can ask "is the recorder armed?".
@MainActor
package final class SettingsChordCapture {
    package static let shared = SettingsChordCapture()

    /// True from the moment a chord row starts recording until it commits or cancels.
    package var isCapturing = false

    private init() {}
}

/// The Esc-in-Settings decision, asked of `slopdesk_video::escape_monitor`. AppKit-free (a keycode, the
/// wire's six-bit modifier mask, a flag) so it pins headlessly on the `swift test` host and compiles on
/// iOS, where the Settings surface is a sheet with its own dismiss.
package enum SettingsEscapePolicy {
    /// What this key-down does to the Settings window.
    ///
    /// - Parameters:
    ///   - keyCode: the AppKit `NSEvent.keyCode`.
    ///   - modifierMask: the modifiers held, in the wire's own bits — WHICH of them disqualify a dismiss is
    ///     the crate's decision, not this call site's (⌥Esc is macOS's own Speak-Selection binding; a stuck
    ///     caps lock is not a chord at all).
    ///   - isCapturingChord: whether a Key Bindings row is recording a replacement chord. There Esc already
    ///     means "cancel the capture", so it passes through — the ONE surface that outranks the dismiss.
    package static func decide(
        keyCode: UInt16,
        modifierMask: UInt8,
        isCapturingChord: Bool,
    ) -> SettingsEscapeDecision {
        slopdesk_escape_dismisses_window(keyCode, modifierMask, isCapturingChord) ? .closeWindow : .passThrough
    }
}
