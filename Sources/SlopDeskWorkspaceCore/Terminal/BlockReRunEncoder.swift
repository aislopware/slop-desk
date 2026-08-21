import CSlopDeskFFI
import Foundation

// MARK: - BlockReRunEncoder (re-inject a captured command verbatim)

/// Encodes a ``CommandBlock``'s captured `commandText` into the exact bytes to RE-INJECT into the pane's
/// shell as if the user re-typed and ran it (WB3 — "Re-run Command"). The bytes funnel through
/// ``TerminalViewModel/sendInput(_:)`` (wire type 3 `.input`) — there is NO host / wire change; the host
/// sees ordinary keystrokes.
///
/// THE RULE IS NOT HERE. It is `slopdesk_terminal::blocks::rerun_bytes`, beside the command-block ring the
/// text comes out of, and its module comment carries the whole argument: why a captured command is verbatim
/// literal UTF-8 and never `SendKeysParser` (a command may CONTAIN `"<Enter>"`, and the host output it was
/// segmented from is attacker-influenced), why exactly one trailing `0x0A` is appended and any run of CR/LF
/// stripped first (a double-execute otherwise), why MIDDLE newlines survive, and why empty or
/// whitespace-only sends nothing at all rather than a bare newline.
///
/// One trap belongs to this side of the boundary and is recorded because the code that used to embody it is
/// gone: the Swift this replaces trimmed the trailing run at the BYTE level on purpose, because Swift
/// clusters `"\r\n"` into ONE `Character` and a `Character`-based trim therefore missed `"make\r\n"` and
/// double-executed it. Rust has no such trap — a `Character` there is a scalar — so nothing downstream needs
/// to know this, but the next person to wonder why the rule reads at the byte level does.
enum BlockReRunEncoder {
    /// The bytes to inject to re-run `commandText`, or `nil` for an empty / whitespace-only command.
    static func bytes(for commandText: String) -> Data? {
        let input = Array(commandText.utf8)
        return input.withUnsafeBufferPointer { source -> Data? in
            let call = { (buffer: inout [UInt8]) -> Int in
                buffer.withUnsafeMutableBufferPointer { out in
                    slopdesk_block_rerun_bytes(source.baseAddress, source.count, out.baseAddress, out.count)
                }
            }
            // An ARITHMETIC bound, not a guess: the answer is the command minus its trailing CR/LF run plus
            // one newline, so it can never exceed the input by more than a byte.
            var out = [UInt8](repeating: 0, count: input.count + 1)
            var needed = call(&out)
            if needed > out.count {
                // Unreachable under the bound above. It stays because `docs/55` §4's retry is what makes a
                // short buffer SAFE — the door writes nothing when the answer does not fit — and a bound
                // that silently stopped holding must become a second call rather than a truncated command
                // reaching a shell.
                out = [UInt8](repeating: 0, count: needed)
                needed = call(&out)
            }
            // `0` is "send nothing", and it cannot mean a short answer: every command the door does encode
            // ends in the newline that executes it, so a real answer is never empty.
            guard needed > 0, needed <= out.count else { return nil }
            return Data(out.prefix(needed))
        }
    }
}
