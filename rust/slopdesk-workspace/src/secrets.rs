//! Credentials, recognised in text nobody vouched for.
//!
//! Two questions, one vocabulary of shapes:
//!
//! - [`redact`] scrubs a title or a notification body BEFORE it reaches a surface that KEEPS it —
//!   the sidebar row, the floating pill, and above all Notification Center, which holds a banner
//!   long after the command that wrote it exited. A remote shell owns those strings: a prompt, a
//!   `set -x` trace or a noisy program can splat an access key into one, and nobody expects window
//!   chrome to archive their credentials.
//! - [`assess`] judges a "paste as keystrokes" before the host types the clipboard into a remote
//!   field. The same capability that can type into a `sudo` prompt can type a secret into a field
//!   that ECHOES it, or splat a whole file into a password box.
//!
//! ## Why `regex` and not a hand-written scanner
//!
//! These shapes ARE regular expressions — that is how the Swift original wrote them and how every
//! secret-scanning corpus in the world publishes them, so keeping them in that notation is what
//! makes a new vendor prefix a one-line change rather than a new byte loop to review. The crate is
//! the same one [`slopdesk-screend`](../../slopdesk-screend/Cargo.toml) already takes for the
//! detection ladder, for the same reason: it is a finite automaton with a documented linear-time
//! guarantee, so a title an adversary wrote cannot make the scan blow up the way ICU's
//! backtracking can.
//!
//! One rule needs help the automaton will not give: the generic backstop's three lookaheads. A
//! lookahead is not regular, and this one does not need to be — it only checks the run the
//! automaton ALREADY matched, so it is a filter on the match rather than a widening of the engine.
//!
//! ## It favours false negatives
//!
//! A masked title the user needed is a bug they cannot work around; a missed secret is the status
//! quo. So the generic backstop demands length AND mixed case AND a digit, which a lower-case hex
//! SHA, a dictionary word and a path all fail.

use std::sync::LazyLock;

use regex::{Captures, Regex};

/// The fixed placeholder a masked secret collapses to. Contains no secret-shaped substring, so
/// [`redact`] is idempotent — running it on its own output changes nothing.
pub const MASK: &str = "«redacted»";

/// Needles the cheap pre-filter looks for before any matching happens.
const NEEDLES: [&str; 18] = [
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
];

/// What a rule does with the text it matched.
#[derive(Clone, Copy)]
enum Action {
    /// The whole match collapses to the mask.
    Whole,
    /// Groups 1 and 2 are KEPT — the key and its delimiter, or `Bearer` and its space — and only
    /// what follows them becomes the mask, so the line still reads.
    KeepingTwoGroups,
    /// The whole match collapses, but only when the run carries lower case AND upper case AND a
    /// digit. This is the lookahead trio the Swift pattern opened with; see the module header for
    /// why it is a filter on the match rather than part of the pattern.
    WholeIfMixed,
}

/// One masking rule.
struct Rule {
    pattern: Regex,
    action: Action,
}

impl Rule {
    /// `text` with every occurrence of this rule's shape masked.
    fn apply(&self, text: &str) -> String {
        match self.action {
            Action::Whole => self.pattern.replace_all(text, MASK),
            Action::KeepingTwoGroups => {
                self.pattern.replace_all(text, |captures: &Captures<'_>| {
                    format!("{}{}{MASK}", group(captures, 1), group(captures, 2))
                })
            },
            Action::WholeIfMixed => {
                self.pattern.replace_all(text, |captures: &Captures<'_>| {
                    let run = group(captures, 0);
                    if is_mixed(run) { MASK } else { run }.to_owned()
                })
            },
        }
        .into_owned()
    }
}

/// Capture group `index`, or the empty string — every group these rules read is non-optional, so
/// the fallback is unreachable and exists only to keep the lint block's panic denial honest.
fn group<'a>(captures: &Captures<'a>, index: usize) -> &'a str {
    captures.get(index).map_or("", |group| group.as_str())
}

/// Whether a run carries lower case AND upper case AND a digit — the generic backstop's three
/// lookaheads, read off the match instead of steering it.
fn is_mixed(run: &str) -> bool {
    run.bytes().any(|byte| byte.is_ascii_lowercase())
        && run.bytes().any(|byte| byte.is_ascii_uppercase())
        && run.bytes().any(|byte| byte.is_ascii_digit())
}

/// The shapes, in the order they are applied, as `(pattern, action)`.
///
/// ORDER is part of the rule: the context-preserving assignment and `Bearer` rules run first, so
/// `token=eyJ…` keeps its key and is masked as an assignment rather than as a bare JWT. The
/// standalone vendor shapes follow, and the generic high-entropy backstop runs last, over what is
/// left.
const PATTERNS: [(&str, Action); 11] = [
    // `key=value` / `key: value` for credential-ish keys. The key may carry an env-style prefix as
    // long as it ENDS in a secret word, so GITHUB_TOKEN, DB_PASSWORD and MY_CLIENT_SECRET all
    // match while `tokenizer=` and `keyword=` do not — the secret word must sit immediately before
    // the delimiter.
    (
        concat!(
            r"(?i)\b([A-Za-z0-9_]*",
            r"(?:password|passwd|passphrase|secret|api[_-]?key|apikey|",
            r"access[_-]?key|auth[_-]?token|client[_-]?secret|token))",
            r"(\s*[=:]\s*)(\S+)",
        ),
        Action::KeepingTwoGroups,
    ),
    // `Authorization: Bearer <token>` — the word is kept, the credential masked.
    (
        r"(?i)\b(bearer)(\s+)([A-Za-z0-9._~+/\-]+=*)",
        Action::KeepingTwoGroups,
    ),
    // AWS key ids: access, temporary, group, user, role, managed-policy, instance-profile.
    (
        r"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|AIPA)[0-9A-Z]{16}\b",
        Action::Whole,
    ),
    // GitHub tokens (PAT / OAuth / app / refresh), then the fine-grained PAT.
    (r"\bgh[pousr]_[A-Za-z0-9]{30,}\b", Action::Whole),
    (r"\bgithub_pat_[A-Za-z0-9_]{30,}\b", Action::Whole),
    // Slack.
    (r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b", Action::Whole),
    // Stripe and npm — underscores split the generic run, so these are named rather than left to
    // the backstop.
    (r"\b[srp]k_(?:live|test)_[A-Za-z0-9]{16,}\b", Action::Whole),
    (r"\bnpm_[A-Za-z0-9]{30,}\b", Action::Whole),
    // Google API key.
    (r"\bAIza[0-9A-Za-z\-_]{35}\b", Action::Whole),
    // JWT: three base64url segments.
    (
        r"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b",
        Action::Whole,
    ),
    // The generic backstop: a 32-or-longer run of base64-ish characters (no `/`, so a long path
    // like `Users/me/Project2024` cannot form one contiguous run) carrying both cases and a digit.
    (r"\b[A-Za-z0-9+]{32,}={0,2}\b", Action::WholeIfMixed),
];

/// The compiled rules, built once per process.
///
/// A pattern that fails to compile is DROPPED rather than fatal — one bad shape must not cost a
/// title every other rule — and `every_pattern_compiles` in the suite is what stops that silence
/// being how a rule rots.
static RULES: LazyLock<Vec<Rule>> = LazyLock::new(|| {
    PATTERNS
        .iter()
        .filter_map(|&(pattern, action)| Regex::new(pattern).ok().map(|pattern| Rule { pattern, action }))
        .collect()
});

/// `text` with every recognised secret masked.
///
/// A cheap pre-filter answers first for the common case — a short title with no delimiter, no known
/// prefix and no long run — so this is safe to call on every render.
#[must_use]
pub fn redact(text: &str) -> String {
    if !might_contain_secret(text) {
        return text.to_owned();
    }
    RULES
        .iter()
        .fold(text.to_owned(), |masked, rule| rule.apply(&masked))
}

/// Whether `text` is worth matching at all: long enough, and carrying a delimiter, a known token
/// prefix, or a long unbroken run.
fn might_contain_secret(text: &str) -> bool {
    if text.chars().count() < 16 {
        return false;
    }
    if text.contains('=') || text.contains(':') {
        return true;
    }
    if NEEDLES.iter().any(|needle| text.contains(needle)) {
        return true;
    }
    // The generic-backstop trigger, with a wider charset than the rule itself: this only decides
    // whether to look, and looking is what applies the narrower shape.
    let mut run = 0_usize;
    for character in text.chars() {
        if character.is_alphanumeric() || matches!(character, '+' | '/' | '=') {
            run += 1;
            if run >= 32 {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

// MARK: The paste guard

/// The risk verdict for typing the clipboard into a remote field.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PasteRisk {
    /// Nothing notable — paste freely.
    Ok,
    /// The payload looks like a credential and the field is NOT secure, so it would be typed where
    /// it echoes visibly.
    SecretIntoInsecureField,
    /// A large or multi-line blob into a SECURE field. A password is one short token, so this is
    /// almost certainly a mis-paste — a file, or a command block, into a hidden box.
    BulkIntoSecureField,
    /// Beyond what can be typed as keystrokes at all. Refuse.
    TooLarge,
}

impl PasteRisk {
    /// Every verdict in declaration order — the discriminant order the FFI and the Swift enum
    /// share.
    pub const ALL: [Self; 4] = [
        Self::Ok,
        Self::SecretIntoInsecureField,
        Self::BulkIntoSecureField,
        Self::TooLarge,
    ];
}

/// A password is one short token; past this many characters into a secure field, it is a mis-paste.
const BULK_INTO_SECURE_FLOOR: usize = 256;

/// The floor a single token must clear before its entropy is worth measuring, and the ceiling past
/// which it is a blob rather than a credential.
const ENTROPY_TOKEN_RANGE: (usize, usize) = (20, 256);

/// Bits per character a random token clears and a dictionary word does not.
const ENTROPY_FLOOR: f64 = 3.8;

/// The verdict for pasting `text` into a field that is (or is not) a secure password input.
///
/// `max_length` is the keystroke-replay ceiling, which the caller owns — it is a transport limit,
/// not a rule about secrets.
#[must_use]
pub fn assess(text: &str, target_is_secure: bool, max_length: usize) -> PasteRisk {
    if text.chars().count() > max_length {
        return PasteRisk::TooLarge;
    }
    if target_is_secure {
        let multiline = text.contains('\n') || text.contains('\r');
        if multiline || text.chars().count() > BULK_INTO_SECURE_FLOOR {
            return PasteRisk::BulkIntoSecureField;
        }
        return PasteRisk::Ok;
    }
    if looks_secret(text) {
        PasteRisk::SecretIntoInsecureField
    } else {
        PasteRisk::Ok
    }
}

/// Whether `text` looks like a credential: a shape [`redact`] recognises, or a single token with
/// high per-character entropy.
///
/// No hard digit requirement, deliberately — a random base64url key often has none, and the
/// redactor's own backstop already demands one, so requiring it on both paths left digit-free keys
/// uncovered by either.
#[must_use]
pub fn looks_secret(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    if redact(trimmed) != trimmed {
        return true;
    }
    // A PATH is excluded by the slash: it is the one long single token that is never a credential.
    if trimmed
        .chars()
        .any(|c| c == ' ' || c == '\t' || c == '/' || c.is_control())
    {
        return false;
    }
    let length = trimmed.chars().count();
    if length < ENTROPY_TOKEN_RANGE.0 || length > ENTROPY_TOKEN_RANGE.1 {
        return false;
    }
    if char_class_count(trimmed) < 2 {
        return false;
    }
    shannon_entropy_per_char(trimmed) >= ENTROPY_FLOOR
}

/// How many of {lower, upper, digit, symbol} appear in `text`.
fn char_class_count(text: &str) -> usize {
    let (mut lower, mut upper, mut digit, mut symbol) = (false, false, false, false);
    for character in text.chars() {
        if character.is_lowercase() {
            lower = true;
        } else if character.is_uppercase() {
            upper = true;
        } else if character.is_numeric() {
            digit = true;
        } else {
            symbol = true;
        }
    }
    usize::from(lower) + usize::from(upper) + usize::from(digit) + usize::from(symbol)
}

/// Shannon entropy per character, in bits: `-Σ p·log2(p)` over the character-frequency
/// distribution. A random token approaches 4–6 bits; a repeated or dictionary string is far lower.
///
/// The frequencies are summed in a DETERMINISTIC order — a sorted counting table rather than a hash
/// map — so the last bits of the answer do not depend on iteration order, and the comparison
/// against the floor is reproducible across builds.
#[must_use]
fn shannon_entropy_per_char(text: &str) -> f64 {
    let mut characters: Vec<char> = text.chars().collect();
    if characters.is_empty() {
        return 0.0;
    }
    #[expect(
        clippy::cast_precision_loss,
        reason = "a count that reached 2^53 could not be held"
    )]
    let total = characters.len() as f64;
    characters.sort_unstable();
    let mut entropy = 0.0_f64;
    let mut run = 0_usize;
    for (index, character) in characters.iter().enumerate() {
        run += 1;
        if characters.get(index + 1) == Some(character) {
            continue;
        }
        #[expect(clippy::cast_precision_loss, reason = "bounded by the length above")]
        let probability = run as f64 / total;
        entropy -= probability * probability.log2();
        run = 0;
    }
    entropy
}

#[cfg(test)]
mod tests {
    use super::{MASK, PATTERNS, PasteRisk, RULES, assess, looks_secret, redact, shannon_entropy_per_char};

    /// Assembled from fragments so no contiguous token literal sits in this file — the same reason
    /// the Swift suite does it: push protection scans source, not intent.
    fn joined(parts: &[&str]) -> String {
        parts.concat()
    }

    #[track_caller]
    fn assert_masked(input: &str, secret: &str) {
        let out = redact(input);
        assert_ne!(out, input, "expected redaction of: {input}");
        assert!(out.contains(MASK), "expected the mask in: {out}");
        assert!(!out.contains(secret), "secret leaked into output: {out}");
        assert_eq!(redact(&out), out, "redact is not idempotent for: {input}");
    }

    /// A pattern that fails to compile is dropped silently at startup, which would be a rule
    /// quietly leaking. This is the check that keeps the silence honest.
    #[test]
    fn every_pattern_compiles() {
        assert_eq!(RULES.len(), PATTERNS.len(), "a shape failed to compile");
    }

    #[test]
    fn the_vendor_shapes_are_masked() {
        let aws = joined(&["AKIA", "IOSFODNN7EXAMPLE"]);
        assert_masked(&format!("region us-east-1 key {aws} done"), &aws);
        let github = joined(&["ghp", "_0123456789abcdefghijklmnopqrstuvwxyzAB"]);
        assert_masked(&format!("cloning with {github}"), &github);
        let slack = joined(&["xoxb", "-123456789012-abcdefABCDEF0123"]);
        assert_masked(&format!("slack {slack}"), &slack);
        let stripe = joined(&["sk", "_live_4eC39HqLyjWDarjtT1zdp7dc"]);
        assert_masked(&format!("deploy key {stripe} ok"), &stripe);
        let npm = joined(&["npm", "_1234567890abcdefABCDEF1234567890ab"]);
        assert_masked(&format!("token is {npm}"), &npm);
        let google = joined(&["AIza", "SyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY"]);
        assert_masked(&format!("key {google} here"), &google);
        let jwt = joined(&[
            "eyJhbGciOiJIUzI1NiJ9",
            ".eyJzdWIiOiIxMjM0NTY3ODkwIn0",
            ".dozjgNryP4J3jVmNHl0w5N",
        ]);
        assert_masked(&format!("auth {jwt}"), &jwt);
    }

    #[test]
    fn an_assignment_keeps_its_key_and_loses_its_value() {
        assert_eq!(redact("PASSWORD=hunter2secretvalue"), format!("PASSWORD={MASK}"));
        assert_eq!(
            redact("GITHUB_TOKEN=abc123XYZsecretlongvalue"),
            format!("GITHUB_TOKEN={MASK}")
        );
        assert_eq!(redact("DB_PASSWORD: p@ssw0rd!"), format!("DB_PASSWORD: {MASK}"));
        assert_eq!(redact("api_key=AbCdEf123456"), format!("api_key={MASK}"));
        // The secret word must sit immediately before the delimiter.
        assert_eq!(redact("tokenizer=wordpiece"), "tokenizer=wordpiece");
    }

    #[test]
    fn a_bearer_header_keeps_the_word_and_loses_the_credential() {
        let out = redact("Authorization: Bearer abc123.def456-xyz");
        assert!(out.contains(&format!("Bearer {MASK}")), "{out}");
        assert!(!out.contains("abc123.def456-xyz"));
        assert_eq!(redact(&out), out);
    }

    #[test]
    fn a_high_entropy_run_is_the_backstop_and_it_is_a_narrow_one() {
        let token = "aB3dE6fG9hJ2kL5mN8pQ1rS4tU7vW0xY3zA6bC9d";
        assert_masked(&format!("export X={token}"), token);
        // A lower-case hex SHA has no upper case; a path is broken by its slashes; neither trips.
        for ordinary in [
            "HEAD at 5f3a9c2b8e1d4a6f0c7b2e9d8a1f5c3b6e4d7a0f",
            "/Users/me/Project2024ABC/src/MainView2024Final",
            "~/project — nvim",
            "user@host: ~/Workspace/oss/slop-desk",
            "zsh",
            "build: 42 passed, 0 failed",
            "",
            "ok",
            "AKIA",
        ] {
            assert_eq!(redact(ordinary), ordinary, "false positive on: {ordinary}");
        }
    }

    #[test]
    fn the_paste_guard_reads_the_payload_against_the_field() {
        assert_eq!(assess("hunter2", true, 8192), PasteRisk::Ok);
        assert_eq!(assess("a\nb", true, 8192), PasteRisk::BulkIntoSecureField);
        assert_eq!(
            assess(&"x".repeat(300), true, 8192),
            PasteRisk::BulkIntoSecureField
        );
        assert_eq!(assess(&"x".repeat(9000), true, 8192), PasteRisk::TooLarge);
        assert_eq!(assess("ls -la", false, 8192), PasteRisk::Ok);
        let token = "aB3dE6fG9hJ2kL5mN8pQ1rS4tU7vW0xY3zA6bC9d";
        assert_eq!(assess(token, false, 8192), PasteRisk::SecretIntoInsecureField);
        // A path is a long single token that is never a credential.
        assert!(!looks_secret("/Users/me/Documents/some/long/path/name"));
    }

    #[test]
    fn entropy_is_bits_per_character_and_it_does_not_depend_on_iteration_order() {
        assert!((shannon_entropy_per_char("") - 0.0).abs() < f64::EPSILON);
        assert!((shannon_entropy_per_char("aaaa") - 0.0).abs() < f64::EPSILON);
        // Four distinct characters, evenly spread: exactly two bits.
        assert!((shannon_entropy_per_char("abcd") - 2.0).abs() < 1e-12);
        // The same multiset in any order is the same answer, to the bit.
        assert!(
            (shannon_entropy_per_char("aabbccdd") - shannon_entropy_per_char("dcbadcba")).abs()
                < f64::EPSILON
        );
    }
}
