import Foundation

/// POSIX single-quoting for embedding a path / token in a `/bin/sh` command line. Pure + cross-platform
/// (no AppKit / macOS gating) so BOTH the macOS-only ``CLIInstaller`` admin-escalation path AND the
/// cross-platform client-control backend (`jump` cd, the `view`/`edit` shim) quote identically from ONE
/// source of truth — the same POSIX single-quoting idiom `zoxide` uses for its `cd` target.
public enum ShellQuoting {
    /// Wrap `value` in single quotes, escaping any embedded single quote via the POSIX `'\''` idiom (close
    /// the quote, emit an escaped `'`, reopen). The result is a single shell word: a path with spaces /
    /// metacharacters survives intact (`/Users/x/My Project` → `'/Users/x/My Project'`, `a'b` → `'a'\''b'`).
    public static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
