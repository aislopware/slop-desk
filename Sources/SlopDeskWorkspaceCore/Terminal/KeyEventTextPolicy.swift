import CSlopDeskFFI

// MARK: - PUA function-key text filter

/// What `text` a key event may carry into libghostty-vt's encoder (`slopdesk_term_surface_key`'s `text`): given the raw
/// `NSEvent.characters` of a press, the text the encoder should see — or `nil` when the characters are an
/// `AppKit` **function-key placeholder** or a **control-led payload** that must never reach the wire.
///
/// Both bugs this closes — arrow keys typing garbage under the kitty protocol, and Shift+Tab / Shift+Enter
/// losing their modifier — are written up at `slopdesk_terminal::surface::forwards_encoder_text`, which is
/// where the rule lives. The door answers only WHETHER the characters may be forwarded: the text itself is
/// this caller's own input, so returning it would be a round trip for nothing.
///
/// ## Scope (deliberate delta from upstream `ghosttyCharacters`)
/// Upstream's helper also re-translates a single **C0 control** character (Ctrl-C → U+0003) back to its
/// letter so libghostty-vt's `KeyEncoder` owns control encoding. slopdesk intercepts that whole class
/// EARLIER — the documented Ctrl+C0 raw fast path (`TerminalViewModel.sendInput`'s doc names it) sends
/// the raw control byte and returns (the universal-interrupt fix), so control-modified C0 text never
/// reaches this policy.
public enum KeyEventTextPolicy {
    /// The text (if any) a key event should hand to libghostty-vt's key encoder.
    ///
    /// - Parameter characters: the event's raw `characters` string (`AppKit`'s translation of the press).
    /// - Returns: `characters` verbatim for real text (multi-scalar IME output included), or `nil` when it
    ///   is a single function-key PUA placeholder (U+F700–U+F8FF) or a control-led payload (first UTF-8
    ///   byte < 0x20) — the key is then encoded purely from its keycode/mods, matching upstream Ghostty.
    public static func encoderText(for characters: String?) -> String? {
        guard var characters else { return nil }
        let forwards = characters.withUTF8 {
            slopdesk_term_forwards_encoder_text($0.baseAddress, $0.count)
        }
        return forwards ? characters : nil
    }
}
