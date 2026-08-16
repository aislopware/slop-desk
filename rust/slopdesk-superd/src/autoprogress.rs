//! Which typed commands earn a synthetic progress spinner.
//!
//! With shell integration active the host can drive an indeterminate OSC 9;4 badge for commands
//! known to be slow, with no change to the program being run. The segmenter already has the typed
//! command line by the time the `C` mark arrives; this decides whether that line is one of them.
//!
//! The match is a WHITESPACE-DELIMITED, CASE-SENSITIVE prefix over leading tokens. Token-wise
//! rather than substring-wise so `curl` cannot match `curlie` and `git push` cannot match
//! `git status`. An empty prefix list disables the feature outright — clearing the field turns it
//! off — and an unmatched command produces nothing rather than a phantom badge.

/// The built-in slow-command prefixes, used when the operator has not overridden them.
///
/// This is the ONLY copy. The client used to hold a display mirror behind a settings row, but
/// nothing serialised that row down to the host, so the host never saw it and the two could only
/// disagree.
pub const BUILT_IN_PREFIXES: [&str; 28] = [
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
];

/// Whether `command_line` should drive a synthetic spinner.
///
/// True when some entry in `prefixes` is a leading token prefix of the command. An empty list, an
/// empty command, or a blank list entry all answer false — the configured list is never trusted to
/// be well-formed.
#[must_use]
pub fn matches(command_line: &str, prefixes: &[String]) -> bool {
    if prefixes.is_empty() {
        return false;
    }
    let command: Vec<&str> = tokenize(command_line).collect();
    if command.is_empty() {
        return false;
    }
    prefixes.iter().any(|prefix| {
        let wanted: Vec<&str> = tokenize(prefix).collect();
        !wanted.is_empty()
            && wanted.len() <= command.len()
            && wanted
                .iter()
                .zip(command.iter())
                .all(|(wanted, actual)| wanted == actual)
    })
}

/// Resolves the env bridge into a prefix list.
///
/// Unset gives the built-in list; set-but-empty gives none, which is how clearing the field turns
/// the feature off; otherwise the value splits on NEWLINES, each entry trimmed and empties dropped.
/// Newline rather than whitespace because an entry is itself allowed to be a multi-word prefix.
#[must_use]
pub fn parse_prefixes(env_value: Option<&str>) -> Vec<String> {
    let Some(raw) = env_value else {
        return BUILT_IN_PREFIXES
            .iter()
            .map(|prefix| (*prefix).to_owned())
            .collect();
    };
    raw.split('\n')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Splits on spaces and tabs, dropping empties so leading, trailing and repeated whitespace all
/// normalise away.
fn tokenize(text: &str) -> impl Iterator<Item = &str> {
    text.split([' ', '\t']).filter(|token| !token.is_empty())
}

#[cfg(test)]
mod tests {
    use super::{BUILT_IN_PREFIXES, matches, parse_prefixes};

    fn prefixes(entries: &[&str]) -> Vec<String> {
        entries.iter().map(|entry| (*entry).to_owned()).collect()
    }

    #[test]
    fn a_prefix_matches_on_whole_tokens_and_never_on_a_substring() {
        let list = prefixes(&["curl", "git push"]);
        assert!(matches("curl https://example.com", &list));
        assert!(matches("curl", &list));
        assert!(matches("git push origin main", &list));
        // The substring traps this exists to avoid.
        assert!(!matches("curlie https://example.com", &list));
        assert!(!matches("git status", &list));
        assert!(!matches("mycurl", &list));
    }

    #[test]
    fn the_match_is_case_sensitive() {
        assert!(!matches("CURL https://example.com", &prefixes(&["curl"])));
    }

    #[test]
    fn repeated_and_surrounding_whitespace_normalises_away() {
        assert!(matches("  git   push   origin  ", &prefixes(&["git push"])));
        assert!(matches("git\tpush", &prefixes(&["git push"])));
    }

    #[test]
    fn an_empty_list_or_an_empty_command_disables_the_spinner() {
        assert!(!matches("curl https://example.com", &[]));
        assert!(!matches("", &prefixes(&["curl"])));
        assert!(!matches("   ", &prefixes(&["curl"])));
    }

    #[test]
    fn a_blank_entry_and_an_over_long_prefix_are_skipped_rather_than_trusted() {
        assert!(!matches("curl x", &prefixes(&["   "])));
        assert!(!matches("git", &prefixes(&["git push"])));
        // A blank entry beside a real one does not poison the real one.
        assert!(matches("curl x", &prefixes(&["", "curl"])));
    }

    #[test]
    fn an_unset_bridge_gives_the_built_ins_and_an_empty_one_disables_the_feature() {
        assert_eq!(parse_prefixes(None).len(), BUILT_IN_PREFIXES.len());
        assert!(parse_prefixes(Some("")).is_empty());
        assert!(parse_prefixes(Some("\n \n\t\n")).is_empty());
    }

    #[test]
    fn a_set_bridge_splits_on_newlines_so_an_entry_can_be_multi_word() {
        let parsed = parse_prefixes(Some("  git push \nmake test\n\nninja"));
        assert_eq!(parsed, prefixes(&["git push", "make test", "ninja"]));
        assert!(matches("make test -j8", &parsed));
    }
}
