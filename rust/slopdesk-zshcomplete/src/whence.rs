//! `whence -w` through the same captive shell: is the word the user typed a command at all?
//!
//! ## Why it rides the completion shell rather than running `which`
//!
//! A prompt that paints an unknown command differently is only useful if it agrees with the shell
//! that will run the line, and most of what a real user types is not on `PATH` at all: `gst` is an
//! alias their plugin manager installed, `ll` is a function in their `~/.zshrc`, `cd` is a builtin,
//! `time` is a reserved word. A `PATH` walk from Rust sees none of those and would paint every one
//! of them as a typo — the exact failure this crate exists to avoid, one layer down.
//!
//! So the question goes to the same shell that already sourced the user's rc. It costs a widget and
//! a second key binding, and no second process: [`crate::session`]'s warm shell answers it with the
//! completion system untouched.
//!
//! ## Why it is a BATCH
//!
//! The lexer marks every command position in a line, so `git log | grep foo && ll` asks about four
//! words. One request carrying all of them costs one round trip; four requests would cost four,
//! each queued behind the others on the shell's one mutex. The answer echoes each word back beside
//! its verdict rather than relying on order, so a client keyed by word text never has to trust that
//! the two lists line up.
//!
//! ## Why `rehash`
//!
//! zsh hashes `PATH` once and consults the table, so a binary installed after the captive shell
//! started reads as unknown until the shell is replaced — and this shell lives as long as the host
//! does. `rehash` is a `readdir` of each `PATH` entry, single-digit milliseconds on any normal
//! `PATH`, and it runs inside the request's own deadline: an unreachable network `PATH` entry costs
//! a `NotReady`, which is the same answer a slow completion gives. Paying it every request buys the
//! property that matters — `cargo install`ing something and typing its name never lies.

use std::time::Duration;

/// What the shell says a word IS — `whence -w`'s own vocabulary, byte-for-byte.
///
/// Not narrowed to a boolean here, though only [`WordKind::None`] is painted differently today: the
/// distinctions cost nothing on the wire, and a detail column that reads "alias" is the natural
/// next use of the same request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum WordKind {
    /// The shell would not find it. The one verdict a prompt paints.
    #[default]
    None,
    /// An external executable found on `PATH`.
    Command,
    /// A `hash`ed external, which zsh reports separately from a fresh `PATH` hit.
    Hashed,
    /// An alias, including a global or suffix one.
    Alias,
    /// A shell function.
    Function,
    /// A shell builtin.
    Builtin,
    /// A reserved word — `if`, `for`, `time`.
    Reserved,
}

impl WordKind {
    /// The verdict `whence -w` spells `word`, or [`WordKind::None`] for anything unrecognised.
    ///
    /// Unrecognised falls to `None` rather than erroring because this is a COLOUR: a zsh that grew
    /// an eighth category should leave the word unpainted, not fail the request that asked about
    /// it.
    #[must_use]
    pub fn parse(word: &str) -> Self {
        match word {
            "command" => Self::Command,
            "hashed" => Self::Hashed,
            "alias" => Self::Alias,
            "function" => Self::Function,
            "builtin" => Self::Builtin,
            "reserved" => Self::Reserved,
            _ => Self::None,
        }
    }

    /// Whether the shell would find something to run under this word.
    #[must_use]
    pub const fn resolves(self) -> bool {
        !matches!(self, Self::None)
    }
}

/// One word and what the shell says it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WordVerdict {
    /// The word as it was ASKED about, echoed back so a caller keys by text rather than by order.
    pub word: String,
    /// What the shell found.
    pub kind: WordKind,
}

/// The zsh half of this verb, appended to [`crate::setup::SETUP`].
///
/// It shares the request and answer files, the sequence framing and the `BEGIN`/`END` envelope with
/// the completion widget, because the reader that discards an abandoned answer is the same reader.
/// What differs is the body: `V<word>\t<kind>`, one record per word asked about.
pub const WHENCE_SETUP: &str = r#"
# `whence -w` for a batch of words, on the same request/answer files as the completion widget.
#
# Request frame:  line 1 the sequence, line 2 the directory, lines 3.. one word each.
# Record stream:  BEGIN <seq> / V<word>\t<kind> per word / END <seq>
#
# The directory matters: `./deploy` and `bin/tool` are resolved relative to it, and a prompt sitting
# in a repository asks about those constantly.

_slopdesk_zc_whence() {
  emulate -L zsh
  local raw seq word answer kind
  raw="$(<$SLOPDESK_ZC_REQ)"
  local -a lines=("${(@f)raw}")
  seq=$lines[1]
  builtin cd -q -- "$lines[2]" 2>/dev/null
  # See the module doc: a binary installed since this shell started must not read as a typo.
  builtin rehash
  builtin print -r -- "BEGIN $seq" >> $SLOPDESK_ZC_OUT
  for word in $lines[3,-1]; do
    [[ -z $word ]] && continue
    # `--` so a word beginning with `-` is a word and not a flag, and the whole thing quoted so an
    # unset word cannot glob. A miss exits non-zero and prints nothing, which reads as `none`.
    answer="$(builtin whence -w -- "$word" 2>/dev/null)"
    # `whence -w` prints `name: kind`, and the NAME may itself contain a colon, so the kind is what
    # follows the LAST one. Both sides of the `==` are quoted: the right-hand side of a `[[ ]]`
    # comparison is a PATTERN in zsh, and a word like `foo*` would otherwise match itself by glob.
    kind="${answer##*: }"
    [[ "$answer" == "$kind" ]] && kind=none
    [[ $word == *[$'\n\t']* ]] || _slopdesk_zc_emit "V$word	$kind"
  done
  builtin print -r -- "END $seq" >> $SLOPDESK_ZC_OUT
}
zle -N slopdesk-zc-whence _slopdesk_zc_whence
bindkey "^X^B" slopdesk-zc-whence
"#;

/// The keystroke bound to the whence widget, as bytes for the pty.
pub(crate) const DRIVE_KEY: &[u8] = b"\x18\x02";

/// How long a whence request may wait.
///
/// Shorter than a completion's, and the difference is the point: `whence -w` runs no completion
/// function and can only be slow if the shell is wedged or `rehash` is walking a dead network
/// mount. A prompt colour that arrives late is worth nothing, and a caller that gives up gets the
/// word painted plainly — the same thing it shows while the answer is in flight.
pub const DEADLINE: Duration = Duration::from_millis(150);

/// Reads the verdict records of the answer for `seq`, or `None` while it has not arrived whole.
///
/// The framing rules are [`crate::parse::answer`]'s and for the same reason: a request abandoned at
/// its deadline keeps writing, and without an opener carrying the sequence its late records would
/// land in front of the next answer's and be read as part of it.
#[must_use]
pub fn answer(text: &str, seq: u64) -> Option<Vec<WordVerdict>> {
    let begin = format!("BEGIN {seq}");
    let end = format!("END {seq}");
    let mut inside = false;
    let mut verdicts = Vec::new();
    let mut closed = false;
    for line in text.lines() {
        if line == begin {
            // A second opener for the same sequence cannot happen, but starting over rather than
            // appending is the total answer if it ever did.
            inside = true;
            verdicts.clear();
            continue;
        }
        if !inside {
            continue;
        }
        if line == end {
            closed = true;
            break;
        }
        if let Some(record) = line.strip_prefix('V') {
            // A record with no tab is skipped rather than failing the answer: the widget always
            // writes one, so this can only be a line the shell interleaved, and losing one colour
            // beats holding the whole batch to its deadline.
            if let Some((word, kind)) = record.split_once('\t') {
                verdicts.push(WordVerdict {
                    word: word.to_owned(),
                    kind: WordKind::parse(kind),
                });
            }
        }
    }
    closed.then_some(verdicts)
}

/// The request body for `words` asked about from `cwd`.
///
/// Words carrying a newline are DROPPED rather than escaped: the frame is line-oriented, such a
/// word cannot be a command name in any line a shell would run, and dropping it costs one colour
/// where escaping would cost a second quoting implementation.
#[must_use]
pub fn request(seq: u64, cwd: &str, words: &[String]) -> String {
    let mut body = format!("{seq}\n{cwd}\n");
    for word in words {
        if !word.contains('\n') {
            body.push_str(word);
            body.push('\n');
        }
    }
    body
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::{WordKind, WordVerdict, answer, request};

    #[test]
    fn every_kind_zsh_spells_is_read_back() {
        for (spelled, expected) in [
            ("command", WordKind::Command),
            ("hashed", WordKind::Hashed),
            ("alias", WordKind::Alias),
            ("function", WordKind::Function),
            ("builtin", WordKind::Builtin),
            ("reserved", WordKind::Reserved),
            ("none", WordKind::None),
        ] {
            assert_eq!(WordKind::parse(spelled), expected, "zsh spells it `{spelled}`");
        }
    }

    #[test]
    fn a_kind_this_build_has_never_heard_of_is_unresolved_rather_than_an_error() {
        assert_eq!(WordKind::parse("holographic"), WordKind::None);
        assert!(!WordKind::parse("holographic").resolves());
        assert!(WordKind::Builtin.resolves());
    }

    #[test]
    fn an_answer_is_read_only_once_its_end_marker_lands() {
        let partial = "BEGIN 7\nVls\tcommand\n";
        assert_eq!(answer(partial, 7), None, "the writer may still be going");
        let whole = "BEGIN 7\nVls\tcommand\nVnope\tnone\nEND 7\n";
        assert_eq!(
            answer(whole, 7),
            Some(vec![
                WordVerdict {
                    word: "ls".to_owned(),
                    kind: WordKind::Command,
                },
                WordVerdict {
                    word: "nope".to_owned(),
                    kind: WordKind::None,
                },
            ])
        );
    }

    #[test]
    fn an_abandoned_answers_records_never_join_the_next_one() {
        // The deadline passed on 3, its records kept arriving, and 4 opened after them.
        let text = "BEGIN 3\nVstale\tcommand\nBEGIN 4\nVfresh\tfunction\nEND 4\n";
        let read = answer(text, 4).expect("4 is closed");
        assert_eq!(read.len(), 1, "only 4's own record");
        assert_eq!(read[0].word, "fresh");
        assert_eq!(
            answer(text, 3),
            None,
            "and 3 never closed, so it is still nothing"
        );
    }

    #[test]
    fn the_request_frame_puts_the_directory_before_the_words() {
        let body = request(9, "/tmp/here", &["ls".to_owned(), "gst".to_owned()]);
        assert_eq!(body, "9\n/tmp/here\nls\ngst\n");
    }

    #[test]
    fn a_word_with_a_newline_in_it_is_dropped_rather_than_breaking_the_frame() {
        let body = request(1, "/", &["ok".to_owned(), "two\nlines".to_owned()]);
        assert_eq!(body, "1\n/\nok\n", "the frame stays one word per line");
    }
}
