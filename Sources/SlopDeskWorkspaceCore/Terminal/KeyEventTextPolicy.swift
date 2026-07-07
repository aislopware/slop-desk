import Foundation

// MARK: - Keyboard-map audit 2026-07-07: PUA function-key text filter

/// The PURE, headless decision behind **what `text` a key event may carry into libghostty's encoder**
/// (`ghostty_input_key_s.text`): given the raw `NSEvent.characters` of a key press, return the text the
/// encoder should see — or `nil` when the characters are an AppKit **function-key placeholder** that must
/// never reach the wire.
///
/// ## The bug this pins (arrow keys typing garbage into Claude Code)
/// AppKit reports every named function key (arrows, Home/End, PgUp/PgDn, F1–F20, forward-delete…) as a
/// **Private-Use-Area codepoint** in `event.characters` (`NSUpArrowFunctionKey` == U+F700 … the whole
/// 0xF700–0xF8FF range). Upstream Ghostty strips these before calling the encoder
/// (`NSEvent+Extension.swift` `ghosttyCharacters` at the pinned v1.3.1 tag: "we don't want to send PUA
/// ranges down to Ghostty"); slopdesk's `GhosttyTerminalView.keyDown` passed `event.characters` through
/// raw. In **legacy** encoding the PC-style function-key table wins first, so plain shells looked fine —
/// but under the **kitty keyboard protocol** (Claude Code enables it) ghostty's encoder has a plain-text
/// fast path (`key_encode.zig` `kitty()` preprocessing) that writes a non-empty, unmodified, printable
/// `utf8` payload STRAIGHT to the PTY. U+F700 is "printable" by that check, so every arrow press typed the
/// raw bytes `EF 9C 80…` into the application instead of `CSI A` — rendered as garbage glyphs.
///
/// ## Scope (deliberate delta from upstream `ghosttyCharacters`)
/// Upstream's helper also re-translates a single **C0 control** character (Ctrl-C → U+0003) back to its
/// letter so ghostty's KeyEncoder owns control encoding. slopdesk intercepts that whole class EARLIER —
/// the documented Ctrl+C0 fast path in `GhosttyTerminalView.keyDown` sends the raw control byte and
/// returns (the universal-interrupt fix), so control-modified C0 text never reaches this policy; an
/// unmodified C0 (Enter `\r`, Tab `\t`, Esc) passes through unchanged, exactly what upstream's transform
/// yields with no Ctrl held, and ghostty's encoder filters control text on every path (`isControlUtf8`).
/// This policy therefore makes ONE decision: drop the PUA placeholder, pass everything else verbatim.
///
/// Pinned by `KeyEventTextPolicyTests`: an implementation that forwarded any 0xF700–0xF8FF placeholder, or
/// that dropped real typed text / IME output / control bytes, each fails a specific case.
public enum KeyEventTextPolicy {
    /// Apple's function-key Private Use Area: `NSUpArrowFunctionKey` (U+F700) through the end of the
    /// reserved range AppKit uses for named keys (`NSEvent.h` defines F700–F747; the full PUA block Apple
    /// reserves — and upstream Ghostty filters — is F700–F8FF).
    private static let functionKeyPUA: ClosedRange<UInt32> = 0xF700...0xF8FF

    /// The text (if any) a key event should hand to libghostty's key encoder.
    ///
    /// - Parameter characters: the event's raw `characters` string (AppKit's translation of the press).
    /// - Returns: `characters` verbatim for real text (including unmodified C0 controls and multi-scalar
    ///   IME output), or `nil` when it is a single function-key PUA placeholder (U+F700–U+F8FF) — the key
    ///   is then encoded purely from its keycode/mods, matching upstream Ghostty.
    public static func encoderText(for characters: String?) -> String? {
        guard let characters else { return nil }
        // Mirror upstream: only a SINGLE-scalar placeholder is a function key; a longer string is real
        // text (composed/IME output) even in the unlikely case it embeds a PUA scalar.
        if characters.unicodeScalars.count == 1,
           let scalar = characters.unicodeScalars.first,
           functionKeyPUA.contains(scalar.value)
        {
            return nil
        }
        return characters
    }
}
