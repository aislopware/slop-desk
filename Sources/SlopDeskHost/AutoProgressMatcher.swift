import Foundation

/// The HOST-side, PURE auto-progress command matcher ("Auto Progress-Bar Commands").
///
/// When shell integration is active, SlopDesk auto-wraps a built-in list of slow commands to emit an
/// INDETERMINATE OSC-9;4 spinner while they run (no program changes needed). It works
/// host-side: the ``CommandBlockSegmenter`` already captures the typed command line between the
/// OSC-133 `B` and `C` marks; at the `C` mark it asks THIS matcher whether the line should auto-drive
/// a synthetic spinner badge.
///
/// PURE / headless: no allocation beyond the token splits, no force-unwrap, no I/O. The match is a
/// WHITESPACE-DELIMITED, CASE-SENSITIVE PREFIX over the command's leading tokens — `git push` matches
/// `git push origin main` but NOT `git status`, and `curl` matches `curl https://…` but NOT `curlie`
/// (token-wise, so a substring can never false-positive). An EMPTY prefix list DISABLES auto-progress
/// entirely (clearing the field turns it off), and an unmatched command emits NOTHING (no phantom progress).
public enum AutoProgressMatcher {
    /// The built-in slow-command prefix list — the default when the operator has not overridden
    /// `SLOPDESK_AUTO_PROGRESS_COMMANDS`. Mirrors `terminal-features__progress-state.md`'s built-in
    /// set (and the client-side display default `SettingsKey.autoProgressCommandsBuiltIn`, which lives
    /// in `SlopDeskWorkspaceCore` and CANNOT import this host module — the two literals are kept in
    /// sync; see docs/DECISIONS.md "E14 progress + notifications + privilege parity").
    public static let builtInPrefixes: [String] = [
        "curl",
        "wget",
        "rsync",
        "scp",
        "git fetch",
        "git pull",
        "git push",
        "git clone",
        "brew install",
        "brew update",
        "brew upgrade",
        "npm install",
        "pnpm install",
        "yarn install",
        "bun install",
        "pip install",
        "cargo build",
        "cargo install",
        "cargo update",
        "docker pull",
        "docker push",
        "docker build",
        "apt install",
        "apt update",
        "apt upgrade",
        "apt-get install",
        "apt-get update",
        "apt-get upgrade",
    ]

    /// Whether `commandLine` should auto-drive a synthetic OSC-9;4 spinner: TRUE iff some entry in
    /// `prefixes` is a leading WHITESPACE-DELIMITED, CASE-SENSITIVE token prefix of the command. An
    /// EMPTY `prefixes` (or an empty command) returns FALSE — auto-progress disabled.
    public static func matches(commandLine: some StringProtocol, prefixes: [String]) -> Bool {
        // Empty prefix list disables auto-progress entirely (clearing the field turns it off).
        guard !prefixes.isEmpty else { return false }
        let cmdTokens = tokenize(Substring(commandLine))
        guard !cmdTokens.isEmpty else { return false }
        for prefix in prefixes {
            let prefixTokens = tokenize(prefix[...])
            // A blank entry (all-whitespace) can never match anything; a prefix longer than the
            // command can't be a leading prefix — skip both (never trust the configured list).
            guard !prefixTokens.isEmpty, prefixTokens.count <= cmdTokens.count else { continue }
            var allEqual = true
            for index in prefixTokens.indices where cmdTokens[index] != prefixTokens[index] {
                allEqual = false
                break
            }
            if allEqual { return true }
        }
        return false
    }

    /// Resolves the env-bridge value (`SLOPDESK_AUTO_PROGRESS_COMMANDS`) into a prefix list:
    /// - UNSET (`nil`) ⇒ ``builtInPrefixes`` (the built-in default list).
    /// - SET-but-EMPTY (`""`) ⇒ `[]` (auto-progress DISABLED — the "clear the field" behaviour).
    /// - SET ⇒ the NEWLINE-split entries, each trimmed, empties dropped. Newline separates entries
    ///   because an entry may itself be a whitespace-delimited multi-word prefix (e.g. `git push`).
    public static func parsePrefixes(envValue: String?) -> [String] {
        guard let raw = envValue else { return builtInPrefixes }
        return raw
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whitespace tokenizer shared by ``matches(commandLine:prefixes:)`` (space + tab, empty
    /// subsequences omitted so leading / trailing / repeated whitespace is normalised).
    private static func tokenize(_ text: Substring) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" })
    }
}
