import CSlopDeskFFI
import Foundation

/// Any text as ONE word of a `/bin/sh` command line.
///
/// A face over `slopdesk-workspace`'s `shell_quoting`. The rule was written eight times — seven in
/// Swift and once privately in the Rust template emitter; one of the seven called itself the single
/// source of truth while four others sat beside it, and another justified its copy by not widening a
/// daemon's dependency graph for four lines. It lives in this leaf, which the host, the workspace
/// core and the client UI all already depend on, so no graph widens and the rule is spelled once.
public enum ShellQuoting {
    /// Wrap `value` in single quotes, escaping any embedded single quote via the POSIX `'\''` idiom (close
    /// the quote, emit an escaped `'`, reopen). The result is a single shell word: a path with spaces /
    /// metacharacters survives intact (`/Users/x/My Project` → `'/Users/x/My Project'`, `a'b` → `'a'\''b'`).
    public static func singleQuote(_ value: String) -> String {
        quote(value, bareIfSafe: false)
    }

    /// The same word, left BARE when a shell would not act on it — Python's `shlex.quote`. `file.txt`
    /// stays `file.txt`; anything with a space, a metacharacter or a quote is quoted exactly as
    /// ``singleQuote(_:)`` would. The empty string is still `''`, because it must remain an argument.
    ///
    /// Use this where a human reads the line back — a pasted path should look like the path.
    public static func shlexQuote(_ value: String) -> String {
        quote(value, bareIfSafe: true)
    }

    private static func quote(_ value: String, bareIfSafe: Bool) -> String {
        Array(value.utf8).withUnsafeBufferPointer { text -> String in
            let needed = slopdesk_ws_shell_quote(text.baseAddress, text.count, bareIfSafe, nil, 0)
            guard needed > 0 else { return "''" }
            var room = [UInt8](repeating: 0, count: needed)
            let written = room.withUnsafeMutableBufferPointer { out in
                slopdesk_ws_shell_quote(text.baseAddress, text.count, bareIfSafe, out.baseAddress, out.count)
            }
            // The door only ADDS ASCII quotes around text that arrived as UTF-8, so this never
            // fails; the fallback is the empty word, which is the safe answer for a shell to read.
            guard written == needed else { return "''" }
            return String(bytes: room, encoding: .utf8) ?? "''"
        }
    }
}
