import CSlopDeskFFI

/// Named-key → PTY byte mapping for the agent-control `write` verb (`--key C-c,Enter,Up`).
///
/// tmux `send-keys` vocabulary: an agent should never have to hand-encode `\u{03}` in JSON to
/// interrupt a command.
///
/// A face over `slopdesk-workspace`'s `send_keys`, which is where the `<Token>` grammar the presets
/// and text drops use already reads its table. The two spellings are two ways of NAMING a key, not
/// two vocabularies — this side used to carry a second table, and they had already drifted: `C-?`
/// was DEL here and `C-_`'s byte there, `C-Space` was NUL here and refused there, and the function
/// and paging keys had no spelling there at all. The union is the table now, so a preset can say
/// `<F5>` too.
public enum ControlKeyMap {
    /// The bytes for one key token, or `nil` for an unknown token (validate-then-drop: the
    /// `write` verb rejects the whole request so a typo never sends a partial key sequence).
    public static func bytes(for token: String) -> [UInt8]? {
        Array(token.utf8).withUnsafeBufferPointer { name -> [UInt8]? in
            var needed = 0
            // The longest sequence any name has is a meta chord around a CSI key — six bytes — so
            // the first lend fits and the retry below is the door's contract honoured, not a path
            // this vocabulary reaches.
            var room = [UInt8](repeating: 0, count: 8)
            var found = room.withUnsafeMutableBufferPointer { out in
                slopdesk_ws_key_token(name.baseAddress, name.count, out.baseAddress, out.count, &needed)
            }
            guard found else { return nil }
            if needed > room.count {
                room = [UInt8](repeating: 0, count: needed)
                found = room.withUnsafeMutableBufferPointer { out in
                    slopdesk_ws_key_token(name.baseAddress, name.count, out.baseAddress, out.count, &needed)
                }
                guard found, needed <= room.count else { return nil }
            }
            return Array(room.prefix(needed))
        }
    }

    /// Resolves a comma-separated key list (`"C-c,Enter"`) or an array of tokens into one byte
    /// buffer, or `nil` naming the first unknown token.
    public static func bytes(forTokens tokens: [String]) -> (bytes: [UInt8], unknown: String?) {
        var out: [UInt8] = []
        for token in tokens {
            guard let b = bytes(for: token) else { return ([], token) }
            out.append(contentsOf: b)
        }
        return (out, nil)
    }
}
