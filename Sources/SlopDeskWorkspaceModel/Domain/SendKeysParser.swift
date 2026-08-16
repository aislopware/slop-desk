import CSlopDeskFFI

// MARK: - SendKeysParser (tmux-style control-key tokens → bytes)

/// Turns `<Token>`-marked text into the raw byte sequence to feed a PTY — the shared "send-keys"
/// primitive (launch presets, session templates, block re-run, drops, the CLI `pane send-keys`).
/// Literal runs become their UTF-8 bytes; `<Token>` markers become control bytes. An UNRECOGNIZED
/// `<...>` (or a bare `<` with no close) is emitted LITERALLY, so ordinary text containing `<`
/// (`a < b`, `printf "<3"`) is never mangled. Token names are case-insensitive.
///
/// The table and the scanner are `rust/slopdesk-workspace`'s `send_keys` (docs/55): this is one
/// rule, run by both the client typing into a pane and the host replaying a template, and a second
/// copy of it would be a second answer to "what does `<C-c>` mean".
public enum SendKeysParser {
    /// The bytes, or none at all for text that encodes to nothing.
    public static func encode(_ text: String) -> [UInt8] {
        wsTransform(text) { bytes, len, out, cap in
            slopdesk_ws_send_keys(bytes, len, out, cap)
        } ?? []
    }
}
