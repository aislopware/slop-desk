//! What a clipboard payload would DO at a shell prompt, and whether to ask first.
//!
//! Paste protection is a safety net, not a scanner: the four dangers below are the ones a person
//! cannot see in a clipboard preview but that a prompt acts on the instant the bytes arrive.
//!
//! ## Not the secret classifier
//!
//! `slopdesk_workspace::secrets::assess` answers a DIFFERENT question — would typing this clipboard
//! into a remote field leak a credential, or splat a file into a password box. These two are
//! deliberately separate engines with separate vocabularies, and overloading either with the
//! other's shapes is how a paste guard starts warning about the wrong thing.
//!
//! ## Conservative by construction
//!
//! Every rule here favours an extra confirmation over a missed one, and every rule is a property of
//! the TEXT rather than a guess about intent. The skip rules in [`should_warn`] are the opposite:
//! each one names a state in which the paste provably cannot run — an alternate screen, or a
//! program that framed the paste as an inert bracketed block.

/// More than one line of content — earlier lines run as soon as they are pasted.
pub const MULTI_LINE: u32 = 1 << 0;
/// Ends with a line terminator — the final command runs on paste, unreviewed.
pub const TRAILING_NEWLINE: u32 = 1 << 1;
/// Contains a `sudo` / `su` command token — may run with elevated privileges.
pub const SUDO_OR_SU: u32 = 1 << 2;
/// Contains C0 control characters other than TAB/LF/CR — possible escape injection.
pub const CONTROL_CHARS: u32 = 1 << 3;

/// Classifies `text` against the four paste dangers, as a mask of the constants above.
///
/// An empty payload is no danger at all rather than an error: there is nothing to run.
#[must_use]
pub fn dangers(text: &str) -> u32 {
    if text.is_empty() {
        return 0;
    }
    let mut found = 0_u32;
    let scalars: Vec<char> = text.chars().collect();

    // Trailing newline: the last scalar is LF or CR, which covers `\r\n`, a bare `\n` and a bare
    // `\r` without asking which line ending the producer uses.
    if matches!(scalars.last(), Some('\n' | '\r')) {
        found |= TRAILING_NEWLINE;
    }

    // Multi-line: strip ONE trailing terminator, then look for any remaining LF/CR. A single
    // trailing newline alone is NOT multi-line — it is exactly the trailing-newline case, and
    // conflating them would flag every ordinary one-line command copied with its line ending.
    let mut end = scalars.len();
    if scalars.get(end.wrapping_sub(1)) == Some(&'\n') {
        end -= 1;
        if end > 0 && scalars.get(end - 1) == Some(&'\r') {
            end -= 1;
        }
    } else if scalars.get(end.wrapping_sub(1)) == Some(&'\r') {
        end -= 1;
    }
    if scalars
        .get(..end)
        .is_some_and(|head| head.iter().any(|&c| c == '\n' || c == '\r'))
    {
        found |= MULTI_LINE;
    }

    // Control characters: any C0 scalar EXCEPT TAB / LF / CR. `ESC` — the classic
    // terminal-escape-injection vector — is below `0x20`, so it is covered here.
    if scalars
        .iter()
        .any(|&c| (c as u32) < 0x20 && c != '\t' && c != '\n' && c != '\r')
    {
        found |= CONTROL_CHARS;
    }

    if contains_elevation_token(&scalars) {
        found |= SUDO_OR_SU;
    }
    found
}

/// Whether the paste-protection confirmation should be shown for `text`.
///
/// The flags are supplied by the caller from the live config and the terminal's own state, so this
/// stays a fold over values rather than a reach into a surface.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "four independent states from four sources — a struct would only rename the same four"
)]
pub fn should_warn(
    text: &str,
    protection_on: bool,
    bracketed_safe: bool,
    program_advertised_bracketed: bool,
    is_alternate_screen: bool,
) -> bool {
    if !protection_on || text.is_empty() {
        return false;
    }
    // A full-screen TUI (vim / less / …) receives the paste as input to ITSELF; there is no prompt
    // to run it.
    if is_alternate_screen {
        return false;
    }
    // The program advertised bracketed paste (DEC `?2004h`) and the payload is safe inside those
    // brackets — it arrives as one inert block, so none of the four dangers applies.
    if bracketed_safe && program_advertised_bracketed {
        return false;
    }
    dangers(text) != 0
}

/// Whether `scalars` contains a `sudo` / `su` token at a word boundary.
///
/// Tokens are maximal runs of non-separator scalars; separators are whitespace and the common shell
/// command separators. It matches the token wherever it appears — favouring an extra warning over a
/// missed `sudo` — but a longer word that merely CONTAINS the letters (`subscribe`, `issue`) is a
/// different token and never matches.
fn contains_elevation_token(scalars: &[char]) -> bool {
    scalars
        .split(|c| matches!(c, ' ' | '\t' | '\n' | '\r' | ';' | '|' | '&' | '(' | ')'))
        .any(|token| token == ['s', 'u', 'd', 'o'] || token == ['s', 'u'])
}

#[cfg(test)]
mod tests {
    use super::{CONTROL_CHARS, MULTI_LINE, SUDO_OR_SU, TRAILING_NEWLINE, dangers, should_warn};

    #[test]
    fn an_empty_payload_is_no_danger_and_never_warns() {
        assert_eq!(dangers(""), 0);
        assert!(!should_warn("", true, false, false, false));
    }

    #[test]
    fn one_trailing_newline_is_not_multiple_lines() {
        assert_eq!(dangers("ls -la\n"), TRAILING_NEWLINE);
        assert_eq!(dangers("ls -la\r\n"), TRAILING_NEWLINE);
        assert_eq!(dangers("ls -la\r"), TRAILING_NEWLINE);
        assert_eq!(dangers("ls -la"), 0);
    }

    #[test]
    fn a_second_line_is_multiple_lines_with_or_without_a_terminator() {
        assert_eq!(dangers("one\ntwo"), MULTI_LINE);
        assert_eq!(dangers("one\ntwo\n"), MULTI_LINE | TRAILING_NEWLINE);
        assert_eq!(dangers("one\r\ntwo\r\n"), MULTI_LINE | TRAILING_NEWLINE);
    }

    #[test]
    fn the_elevation_token_is_a_word_and_not_a_substring() {
        assert_eq!(dangers("sudo rm -rf /"), SUDO_OR_SU);
        assert_eq!(dangers("su"), SUDO_OR_SU);
        assert_eq!(dangers("echo hi; sudo id"), SUDO_OR_SU);
        assert_eq!(dangers("cat x|sudo tee y"), SUDO_OR_SU);
        for safe in ["subscribe", "issue", "status", "pseudo", "sudoku", "sun"] {
            assert_eq!(dangers(safe), 0, "{safe} is not an elevation token");
        }
    }

    #[test]
    fn an_escape_is_a_control_character_and_tab_is_not() {
        assert_eq!(dangers("go \u{1B}[31m"), CONTROL_CHARS);
        assert_eq!(dangers("a\u{0}b"), CONTROL_CHARS);
        assert_eq!(dangers("a\tb"), 0);
    }

    #[test]
    fn the_skip_rules_each_name_a_state_the_paste_cannot_run_in() {
        let risky = "sudo rm -rf /\n";
        assert!(should_warn(risky, true, false, false, false));
        assert!(!should_warn(risky, false, false, false, false), "protection off");
        assert!(!should_warn(risky, true, false, false, true), "alternate screen");
        assert!(
            !should_warn(risky, true, true, true, false),
            "bracketed, and the program said so"
        );
        assert!(
            should_warn(risky, true, true, false, false),
            "bracketed-safe alone is not enough — the program never advertised it"
        );
    }
}
