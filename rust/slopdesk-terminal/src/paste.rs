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
//!
//! ## The words the confirmation uses
//!
//! [`Ask`], [`descriptions`] and [`preview`] are the sheet's whole text. They sit beside the rules
//! rather than in the renderer because they are the rules SAID OUT LOUD: a danger the mask can trip
//! and no sentence names renders as a missing bullet, and the only way to see that is to have both
//! halves in one file. What stays in the renderer is the alert itself — that is `AppKit`, and it is
//! the one part of the sheet that could not cross.

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

/// Which confirmation is being drawn.
///
/// Three asks share one surface because they share one shape — a preview, a reason, and a choice —
/// and the only thing that differs is the sentence. Splitting them into three surfaces would let
/// two drift into looking like different features when they are one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ask {
    /// ⌘V into a prompt, where the payload tripped at least one of the four dangers.
    UnsafePaste,
    /// OSC 52 — a program asked to READ the clipboard (`clipboard-read = ask`).
    ClipboardRead,
    /// OSC 52 — a program asked to SET the clipboard (`clipboard-write = ask`).
    ClipboardWrite,
}

impl Ask {
    /// Every ask, in the order the boundary indexes them.
    pub const ALL: [Self; 3] = [Self::UnsafePaste, Self::ClipboardRead, Self::ClipboardWrite];

    /// The ask at a boundary index, or `None` past the end.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::UnsafePaste),
            1 => Some(Self::ClipboardRead),
            2 => Some(Self::ClipboardWrite),
            _ => None,
        }
    }

    /// The question, as the dialog's heading.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::UnsafePaste => "Paste potentially dangerous content?",
            Self::ClipboardRead => "Allow this program to read the clipboard?",
            Self::ClipboardWrite => "Allow this program to set the clipboard?",
        }
    }

    /// The affirmative button. It names the ACTION rather than saying "OK", so the button read on
    /// its own still says what pressing it does.
    #[must_use]
    pub const fn affirmative(self) -> &'static str {
        match self {
            Self::UnsafePaste => "Paste Anyway",
            Self::ClipboardRead | Self::ClipboardWrite => "Allow",
        }
    }

    /// What the body says when no danger was flagged — an OSC-52 ask always reaches the sheet with
    /// an empty mask, because the request itself is the reason rather than the payload. `""` for
    /// the unsafe paste, which never arrives without a danger to list.
    #[must_use]
    pub const fn reason(self) -> &'static str {
        match self {
            Self::UnsafePaste => "",
            Self::ClipboardRead => "A terminal program is requesting clipboard access via OSC 52.",
            Self::ClipboardWrite => "A terminal program is requesting to set the clipboard via OSC 52.",
        }
    }
}

/// One line per flagged danger, in the constants' own bit order.
///
/// The list is what the mask MEANS, so it is derived from the same four bits rather than written
/// again: a fifth danger cannot be added without a sentence, and a sentence cannot outlive its bit.
#[must_use]
pub fn descriptions(mask: u32) -> Vec<&'static str> {
    const LINES: [(u32, &str); 4] = [
        (
            MULTI_LINE,
            "Multiple lines — earlier lines run the moment they are pasted.",
        ),
        (
            TRAILING_NEWLINE,
            "Ends with a newline — the command runs on paste, before you can review it.",
        ),
        (
            SUDO_OR_SU,
            "Contains sudo or su — the paste may run with elevated privileges.",
        ),
        (
            CONTROL_CHARS,
            "Contains control characters — possible hidden terminal-escape injection.",
        ),
    ];
    LINES
        .iter()
        .filter(|&&(bit, _)| mask & bit != 0)
        .map(|&(_, line)| line)
        .collect()
}

/// How many scalars of the payload the preview shows before eliding — enough to see the SHAPE of a
/// paste without rendering a megabyte blob into an alert.
pub const PREVIEW_LIMIT: usize = 480;

/// The payload as the confirmation shows it: capped at [`PREVIEW_LIMIT`], with every control
/// character made VISIBLE.
///
/// The caret notation is the point. A preview that rendered the payload raw would let the escape
/// sequence the user is being warned about run inside the warning — so `ESC` reads `^[`, `NUL`
/// reads `^@`, `DEL` reads `^?`. Only LF (a real line) and TAB (four spaces) pass through, because
/// those two are the shape the reader came to see.
#[must_use]
pub fn preview(text: &str) -> String {
    let mut out = String::with_capacity(text.len().min(PREVIEW_LIMIT) + 1);
    for (count, scalar) in text.chars().enumerate() {
        if count >= PREVIEW_LIMIT {
            out.push('…');
            break;
        }
        match scalar {
            '\n' => out.push('\n'),
            '\t' => out.push_str("    "),
            c if (c as u32) < 0x20 || c as u32 == 0x7F => {
                out.push('^');
                // `^ 0x40` maps C0 to `@`..`_` and DEL to `?` — the notation every terminal prints.
                out.push(char::from_u32((c as u32 ^ 0x40) & 0x7F).unwrap_or(c));
            },
            c => out.push(c),
        }
    }
    out
}

/// The bullet a danger list is set with, in ONE place — the `AppKit` join below reads it and so
/// does the phone's row, so the two lists cannot come to look like different lists.
pub const BULLET: &str = "•";

/// The caption over the defused payload. The one word on this surface that is not a danger sentence
/// — it names a REGION — so it is spelled once and each renderer sets it in its own register.
pub const PREVIEW_CAPTION: &str = "Clipboard preview";

/// One clipboard confirmation, resolved once for both renderers.
///
/// Nothing here is a sentence of its own: the heading, the affirmative, the reason an OSC-52 ask
/// prints where a paste prints bullets, one bullet per flagged danger in the mask's own bit order,
/// and the defused preview all come from this module. What [`confirmation`] adds is the SHAPE the
/// two renderers would otherwise each decide for themselves — bullets OR the reason, never both,
/// and the preview only where there is one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Confirmation {
    /// The question, as the dialog's heading.
    pub title: &'static str,
    /// The affirmative button, naming the action.
    pub affirmative: &'static str,
    /// One line per flagged danger, in the mask's own bit order. EMPTY for every OSC-52 ask, which
    /// carries no payload to classify.
    pub dangers: Vec<&'static str>,
    /// What stands in for the bullets when the mask flagged nothing. EMPTY whenever `dangers` is
    /// non-empty, so a renderer draws exactly one of the two and never both.
    pub reason: &'static str,
    /// The payload as the confirmation may show it. EMPTY where there is nothing to show.
    pub preview: String,
    /// The whole body as ONE string, for the renderer whose dialog takes one — an `NSAlert`'s
    /// `informativeText`. A renderer that lays the parts out reads the fields above and never this.
    pub informative_text: String,
}

/// Resolve the confirmation for `ask` over `text` and the dangers `text` tripped.
///
/// The bullets-or-reason branch is the whole decision: a paste that reached a confirmation reached
/// it because the mask flagged something, so it lists WHAT; an OSC-52 ask has an empty mask by
/// construction, so it prints why the REQUEST is being questioned instead. A renderer asking this
/// cannot get that branch subtly different from the other renderer's.
#[must_use]
pub fn confirmation(ask: Ask, text: &str, mask: u32) -> Confirmation {
    let dangers = descriptions(mask);
    let reason = if dangers.is_empty() { ask.reason() } else { "" };
    let preview = preview(text);
    let mut sections: Vec<String> = Vec::with_capacity(2);
    if dangers.is_empty() {
        if !reason.is_empty() {
            sections.push(reason.to_owned());
        }
    } else {
        sections.push(
            dangers
                .iter()
                .map(|line| format!("{BULLET}  {line}"))
                .collect::<Vec<_>>()
                .join("\n"),
        );
    }
    if !preview.is_empty() {
        sections.push(format!("{PREVIEW_CAPTION}:\n{preview}"));
    }
    Confirmation {
        title: ask.title(),
        affirmative: ask.affirmative(),
        dangers,
        reason,
        preview,
        informative_text: sections.join("\n\n"),
    }
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
    use super::{
        Ask, BULLET, CONTROL_CHARS, MULTI_LINE, PREVIEW_CAPTION, PREVIEW_LIMIT, SUDO_OR_SU, TRAILING_NEWLINE,
        confirmation, dangers, descriptions, preview, should_warn,
    };

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

    #[test]
    fn every_danger_the_mask_can_trip_has_a_sentence() {
        for bit in [MULTI_LINE, TRAILING_NEWLINE, SUDO_OR_SU, CONTROL_CHARS] {
            assert_eq!(descriptions(bit).len(), 1, "bit {bit} has no sentence");
        }
        assert!(descriptions(0).is_empty(), "no danger, no bullet");
        let all = descriptions(MULTI_LINE | TRAILING_NEWLINE | SUDO_OR_SU | CONTROL_CHARS);
        assert_eq!(all.len(), 4, "four bits, four lines, no duplicates");
        assert_eq!(
            descriptions(dangers("sudo rm -rf /\n")),
            all.get(1..3).unwrap_or_default(),
            "the lines follow the bits that tripped, in bit order"
        );
    }

    #[test]
    fn each_ask_reaches_its_own_words_and_only_the_osc_ones_carry_a_reason() {
        for (index, ask) in Ask::ALL.into_iter().enumerate() {
            assert_eq!(u8::try_from(index).ok().and_then(Ask::from_index), Some(ask));
            assert!(!ask.title().is_empty() && !ask.affirmative().is_empty());
        }
        let past_the_end = u8::try_from(Ask::ALL.len()).ok();
        assert_eq!(past_the_end.and_then(Ask::from_index), None);
        assert!(Ask::UnsafePaste.reason().is_empty(), "the dangers are the reason");
        assert!(!Ask::ClipboardRead.reason().is_empty());
        assert!(!Ask::ClipboardWrite.reason().is_empty());
    }

    #[test]
    fn the_preview_shows_a_control_character_rather_than_running_it() {
        assert_eq!(preview("go \u{1B}[31m"), "go ^[[31m");
        assert_eq!(preview("a\u{0}b\u{7F}c"), "a^@b^?c");
        assert_eq!(preview("one\ntwo"), "one\ntwo", "a real line stays a line");
        assert_eq!(preview("a\tb"), "a    b", "tab widens rather than escaping");
        assert_eq!(preview("a\rb"), "a^Mb", "a bare CR is not a line");
        assert_eq!(preview(""), "");
    }

    #[test]
    fn the_preview_elides_rather_than_rendering_a_blob() {
        let long = "x".repeat(PREVIEW_LIMIT + 40);
        let shown = preview(&long);
        assert_eq!(
            shown.chars().count(),
            PREVIEW_LIMIT + 1,
            "the cap plus the ellipsis"
        );
        assert!(shown.ends_with('…'));
        let exact = "x".repeat(PREVIEW_LIMIT);
        assert_eq!(preview(&exact), exact, "exactly at the cap is not elided");
    }

    /// A paste only ever reaches a confirmation because the mask flagged something, so it lists
    /// what — and prints no reason beside the list, which would be two answers to one question.
    #[test]
    fn a_flagged_paste_lists_its_dangers_and_prints_no_reason() {
        let shown = confirmation(Ask::UnsafePaste, "sudo rm -rf /\n", dangers("sudo rm -rf /\n"));
        assert_eq!(shown.title, Ask::UnsafePaste.title());
        assert_eq!(shown.affirmative, "Paste Anyway");
        assert_eq!(shown.dangers, descriptions(TRAILING_NEWLINE | SUDO_OR_SU));
        assert_eq!(shown.reason, "", "the bullets already answered it");
        assert!(shown.informative_text.starts_with(BULLET));
        assert!(shown.informative_text.contains(PREVIEW_CAPTION));
    }

    /// An OSC-52 ask has an empty mask by construction — the REQUEST is the reason, so the body
    /// prints it where a paste would have printed bullets.
    #[test]
    fn an_osc52_ask_prints_its_reason_where_a_paste_prints_bullets() {
        let shown = confirmation(Ask::ClipboardRead, "", 0);
        assert!(shown.dangers.is_empty());
        assert_eq!(shown.reason, Ask::ClipboardRead.reason());
        assert_eq!(shown.affirmative, "Allow");
        assert_eq!(
            shown.informative_text,
            Ask::ClipboardRead.reason(),
            "no payload, so no caption"
        );
    }

    /// The caption may not stand over nothing: a request with no payload has no preview section at
    /// all, rather than a heading with an empty block under it.
    #[test]
    fn an_empty_payload_carries_no_preview_section() {
        let shown = confirmation(Ask::ClipboardWrite, "", 0);
        assert_eq!(shown.preview, "");
        assert!(!shown.informative_text.contains(PREVIEW_CAPTION));
    }

    /// The escape being warned about must not run inside the warning — the body carries the defused
    /// spelling, never the payload.
    #[test]
    fn the_body_shows_the_defused_payload_and_never_the_raw_one() {
        let raw = "\u{1b}[31mred";
        let shown = confirmation(Ask::UnsafePaste, raw, dangers(raw));
        assert_eq!(shown.preview, preview(raw));
        assert!(shown.informative_text.contains("^["));
        assert!(!shown.informative_text.contains('\u{1b}'));
    }
}
