import Foundation

// MARK: - SecretRedactor

/// Scrubs likely SECRETS out of untrusted terminal-derived text (OSC 0/2 window titles and OSC 9/777
/// notification bodies) BEFORE it reaches a persistent UI surface — the sidebar title, the floating pill,
/// and especially the macOS Notification Center (which keeps a banner around long after the command ran).
///
/// A remote shell controls these strings; a prompt, a `set -x` trace, or a noisy program can splat an
/// access key / bearer token / `PASSWORD=…` into the title or a notification body, and the user would not
/// expect a remote-desktop window chrome to archive their credentials. This masks the well-known token
/// shapes and `key=value` secrets with a fixed, prefix-preserving placeholder.
///
/// Pure + `nonisolated` — no view, no settings read (the call sites gate on ``SettingsKey/redactSecrets``);
/// fully table-tested. Tuned to AVOID false positives on ordinary titles: a path (`~/project — nvim`), a
/// host (`user@host: ~/dir`), or a git SHA (lower-case hex) is left untouched. The generic high-entropy
/// backstop requires length ≥ 32 AND mixed case AND a digit, so hashes/paths/words never trip it.
public enum SecretRedactor {
    /// The fixed placeholder a masked secret collapses to. Contains no secret-shaped substring, so
    /// ``redact(_:)`` is idempotent (re-running never re-matches the mask).
    public static let mask = "«redacted»"

    /// Returns `text` with any recognized secret masked. Cheap no-op fast path for the common case (a
    /// short title with no trigger character), so it is safe to call on every render.
    public static func redact(_ text: String) -> String {
        guard mightContainSecret(text) else { return text }
        var s = text
        // Context-preserving rules FIRST (keep the key / "Bearer" so the line still reads), then the
        // standalone token shapes, then the conservative generic backstop. Order matters: an assignment
        // like `token=eyJ…` is masked by the assignment rule before the JWT rule sees the bare value.
        for rule in rules {
            s = rule.apply(to: s)
        }
        return s
    }

    /// Cheap pre-filter: only strings that contain an assignment delimiter, a known token prefix, or a
    /// long run worth scanning are handed to the (compiled) regex pass. Keeps the per-render cost ~nil
    /// for ordinary titles.
    private static func mightContainSecret(_ text: String) -> Bool {
        if text.count < 16 { return false }
        if text.contains("=") || text.contains(":") { return true }
        for needle in [
            "AKIA",
            "ghp_",
            "gho_",
            "ghu_",
            "ghs_",
            "ghr_",
            "github_pat_",
            "xox",
            "AIza",
            "eyJ",
            "Bearer",
            "bearer",
            "sk_live_",
            "sk_test_",
            "rk_live_",
            "rk_test_",
            "pk_live_",
            "npm_",
        ] where text.contains(needle) {
            return true
        }
        // A long unbroken alphanumeric run is the generic-backstop trigger.
        var run = 0
        for ch in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || ch == "+" || ch == "/" || ch == "=" {
                run += 1
                if run >= 32 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    // MARK: - Rule table

    private struct Rule {
        let regex: NSRegularExpression
        /// The replacement template (`$1` etc. reference capture groups; the literal mask is inlined).
        let template: String
        func apply(to s: String) -> String {
            let range = NSRange(s.startIndex..., in: s)
            return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
        }
    }

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programmer error, so trap loudly in debug.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Compiled once (NSRegularExpression matching is thread-safe), applied in order.
    private static let rules: [Rule] = {
        let m = NSRegularExpression.escapedTemplate(for: mask)
        return [
            // 1. key=value / key: value for credential-ish keys — KEEP the key + delimiter, mask the value.
            //    The key may carry an env-style prefix as long as it ENDS in a secret word, so GITHUB_TOKEN,
            //    DB_PASSWORD, MY_CLIENT_SECRET all match while `tokenizer=` / `keyword=` do NOT (the secret
            //    word must sit immediately before the delimiter).
            Rule(
                regex: re(
                    #"(?i)\b([A-Za-z0-9_]*"#
                        + #"(?:password|passwd|passphrase|secret|api[_-]?key|apikey|"#
                        + #"access[_-]?key|auth[_-]?token|client[_-]?secret|token))"#
                        + #"(\s*[=:]\s*)(\S+)"#,
                ),
                template: "$1$2\(m)",
            ),
            // 2. Authorization: Bearer <token> — keep "Bearer", mask the token.
            Rule(
                regex: re(#"(?i)\b(bearer)(\s+)([A-Za-z0-9._~+/\-]+=*)"#),
                template: "$1$2\(m)",
            ),
            // 3. AWS key ids (access / temporary / user / role / …).
            Rule(regex: re(#"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|AIPA)[0-9A-Z]{16}\b"#), template: m),
            // 4. GitHub tokens (PAT / OAuth / app / refresh) + fine-grained PAT.
            Rule(regex: re(#"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#), template: m),
            Rule(regex: re(#"\bgithub_pat_[A-Za-z0-9_]{30,}\b"#), template: m),
            // 5. Slack tokens.
            Rule(regex: re(#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#), template: m),
            // 5b. Stripe (sk/rk/pk _live_/_test_) + npm — underscores split the generic run, so name them.
            Rule(regex: re(#"\b[srp]k_(?:live|test)_[A-Za-z0-9]{16,}\b"#), template: m),
            Rule(regex: re(#"\bnpm_[A-Za-z0-9]{30,}\b"#), template: m),
            // 6. Google API key.
            Rule(regex: re(#"\bAIza[0-9A-Za-z\-_]{35}\b"#), template: m),
            // 7. JWT (three base64url segments).
            Rule(regex: re(#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b"#), template: m),
            // 8. Generic high-entropy backstop: a 32+ run of base64url-ish chars (NO '/', so a long path
            //    like Users/me/Project2024 can't form one contiguous run) that has BOTH cases AND a digit —
            //    so a lower-case hex SHA, a dictionary word, or a path never trips it. The mixed-shape
            //    lookaheads validate the upcoming run before the greedy body matches.
            Rule(
                regex: re(
                    #"\b(?=[A-Za-z0-9+]*[a-z])(?=[A-Za-z0-9+]*[A-Z])(?=[A-Za-z0-9+]*[0-9])[A-Za-z0-9+]{32,}={0,2}\b"#,
                ),
                template: m,
            ),
        ]
    }()
}
