//! `slopdesk version` — the multi-line banner, assembled from values the caller supplies.
//!
//! ## Why the version number is a parameter and not a constant here
//! `docs/49-release-pipeline.md` names six version sites, and `bump-version.sh` owns all six
//! because no gate can see most of them. Transliterating `CLIVersion.version` would have made a
//! seventh — one the bump script does not know about, and one `package-release.sh` would not catch,
//! because that gate asks the built CLI binary and would keep asking the Swift one.
//!
//! So the number stays in exactly one place and arrives here as an argument. What was worth porting
//! is the SHAPE of the banner and the build-hash branch, which is the part that had a test.

use core::fmt::Write as _;

/// The environment variable carrying an optional short build or commit hash, injected by the
/// release pipeline. Absent in a plain build, and then the banner simply omits the parenthetical.
pub const BUILD_HASH_ENV_KEY: &str = "SLOPDESK_BUILD_HASH";

/// The feature summary line — a fact about this build's capabilities, not about its version.
pub const FEATURE_SUMMARY: &str = "remote-terminal · gui-video · read-only-inspector";

/// Builds the `version` output:
///
/// ```text
/// slopdesk <version>[ (<hash>)]
/// terminal protocol v<N>
/// <feature summary>
/// ```
///
/// `build_hash` is the value of [`BUILD_HASH_ENV_KEY`]; empty or absent omits the parenthetical.
#[must_use]
pub fn summary(version: &str, build_hash: Option<&str>, protocol_version: u16) -> String {
    let mut head = format!("slopdesk {version}");
    if let Some(hash) = build_hash.filter(|hash| !hash.is_empty()) {
        let _ = write!(head, " ({hash})");
    }
    format!("{head}\nterminal protocol v{protocol_version}\n{FEATURE_SUMMARY}")
}

#[cfg(test)]
mod tests {
    use super::{FEATURE_SUMMARY, summary};

    #[test]
    fn without_a_build_hash_the_head_is_just_the_version() {
        let text = summary("0.3.0", None, 4);
        assert_eq!(
            text,
            format!("slopdesk 0.3.0\nterminal protocol v4\n{FEATURE_SUMMARY}")
        );
    }

    #[test]
    fn an_empty_hash_is_the_same_as_none() {
        assert_eq!(summary("0.3.0", Some(""), 4), summary("0.3.0", None, 4));
    }

    #[test]
    fn a_build_hash_lands_in_a_parenthetical_on_the_first_line_only() {
        let text = summary("0.3.0", Some("a0e99e5"), 4);
        let mut lines = text.lines();
        assert_eq!(lines.next(), Some("slopdesk 0.3.0 (a0e99e5)"));
        assert_eq!(lines.next(), Some("terminal protocol v4"));
        assert_eq!(lines.next(), Some(FEATURE_SUMMARY));
        assert_eq!(lines.next(), None);
    }

    #[test]
    fn the_banner_carries_no_trailing_newline_of_its_own() {
        assert!(!summary("0.3.0", None, 4).ends_with('\n'));
    }

    #[test]
    fn the_protocol_line_tracks_whatever_the_caller_reports() {
        assert!(summary("0.3.0", None, 9).contains("terminal protocol v9"));
    }
}
