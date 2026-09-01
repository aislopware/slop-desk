//! The reader for the record stream [`crate::setup::SETUP`] emits.
//!
//! Pure: it takes text and answers candidates, touches no file and spawns nothing. That is the
//! whole reason the split falls here — everything zsh alone can decide is decided in zsh, and
//! everything after the first newline is decided by a function a test can call with a string
//! literal. The fixtures in this module's tests are verbatim captures from a real interactive zsh.
//!
//! ## The grammar
//! ```text
//! BEGIN <seq>                 one per request, before the widget runs
//!   CALL                      one per `compadd` call that added matches
//!   I<ipre> P<prefix>         the line context at that call
//!   S<suffix> J<isuf>
//!   X<-P> Y<-p> Z<-s> W<-S>   the affixes an accepted match is written with
//!   F<flags>                  `Q` = the matches carry their own quoting, `U` = unmatched
//!   M<match>\t<display>       one per candidate
//! END <seq>                   after the widget returns
//! ```
//!
//! ## Why the answer is a PREFIX and not a range
//! A group carries the text it would replace rather than an offset into the document, because the
//! document has moved on: the round trip is milliseconds and the user is typing through it. An
//! offset computed against the buffer the host was asked about would land somewhere else in the
//! buffer that is now on screen, and would delete characters the user has since typed. A prefix is
//! self-describing — the provider re-derives the range against the LIVE document and offers
//! nothing when it no longer matches, which is the same staleness rule the filesystem source's
//! `base` already follows.

/// The most candidates one answer may carry, across every group.
///
/// `ls --` alone is 68 and a bare `~/` in a large home is hundreds. The list a user reads is a
/// dozen at most and the ranking upstream truncates far below this, so the cap is not a display
/// decision — it is the bound that keeps one pathological completion from putting a megabyte on the
/// wire.
pub const MAX_CANDIDATES: usize = 512;

/// The most groups one answer may carry.
///
/// A rich request is two or three — `_describe` makes two passes and `_arguments` adds one per
/// option class. Anything past this is a completion function in a loop, and truncating it costs a
/// tail nobody would have scrolled to.
pub const MAX_GROUPS: usize = 32;

/// One `compadd` call's worth of candidates, and the line context they share.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CandidateGroup {
    /// The text BEFORE the caret that accepting one of these replaces — zsh's `PREFIX`.
    pub prefix: String,
    /// The text AFTER the caret that it replaces — zsh's `SUFFIX`. Empty at a normal caret, which
    /// is why it is a separate field rather than folded into the prefix.
    pub suffix: String,
    /// What this call offered.
    pub candidates: Vec<ShellCandidate>,
}

/// One thing zsh's own completion would insert.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellCandidate {
    /// The literal that replaces the group's prefix+suffix: `-P` + `-p` + the match + `-s` + `-S`,
    /// assembled here because zsh reports the five parts separately and only ever inserts them
    /// together.
    pub text: String,
    /// The `-d` display string — a flag's summary, a subcommand's one-line help. `None` when the
    /// completion function offered none, which is a different fact from an empty one.
    pub detail: Option<String>,
    /// `-Q`: the match already carries its own shell quoting and goes in verbatim. Quoting it again
    /// would insert the escapes literally, which is the failure that writes the user's command line
    /// for them.
    pub verbatim: bool,
}

/// Every candidate the stream reports between `BEGIN seq` and `END seq`.
///
/// Records outside that window are DISCARDED, including a whole earlier answer that arrived late:
/// a request abandoned at the deadline keeps writing, and without this its records would land in
/// front of the next request's and read as part of it. Returns `None` when the answer for `seq` has
/// not finished arriving, which is the caller's signal to keep waiting.
#[must_use]
pub fn answer(stream: &str, seq: u64) -> Option<Vec<CandidateGroup>> {
    let opened = opener(stream, seq)?;
    let body = closed(opened, seq)?;
    Some(groups(body))
}

/// The text after the LAST `BEGIN seq`, or `None` when the request has not been seen yet.
///
/// The last rather than the first because a respawned shell restarts the sequence, and the newer
/// window is the one being waited on.
fn opener(stream: &str, seq: u64) -> Option<&str> {
    let mut found = None;
    let mut rest = stream;
    loop {
        let line_start = rest;
        let (line, tail) = split_line(rest);
        if line.strip_prefix("BEGIN ").and_then(number) == Some(seq) {
            found = Some(tail);
        }
        if tail.len() == line_start.len() {
            return found;
        }
        rest = tail;
    }
}

/// The records up to `END seq`, or `None` while the answer is still being written.
fn closed(body: &str, seq: u64) -> Option<&str> {
    let mut offset = 0;
    let mut rest = body;
    loop {
        let (line, tail) = split_line(rest);
        if line.strip_prefix("END ").and_then(number) == Some(seq) {
            return body.get(..offset);
        }
        if tail.len() == rest.len() {
            return None;
        }
        offset += rest.len() - tail.len();
        rest = tail;
    }
}

/// `text` up to the first newline, and everything past it. The tail is `text` itself at the end,
/// which is how the two loops above detect that they are done without an index.
fn split_line(text: &str) -> (&str, &str) {
    text.find('\n').map_or((text, text), |at| {
        (text.get(..at).unwrap_or(""), text.get(at + 1..).unwrap_or(""))
    })
}

/// A decimal sequence number, or `None` for anything else. Deliberately strict: a partially written
/// line must not read as a complete one.
fn number(text: &str) -> Option<u64> {
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// The `CALL` blocks in one request's records.
fn groups(body: &str) -> Vec<CandidateGroup> {
    let mut out: Vec<CandidateGroup> = Vec::new();
    let mut open: Option<Call> = None;
    let mut total = 0_usize;
    for line in body.lines() {
        // A `CALL` closes whatever was open and starts a new context. Every field below defaults to
        // empty, so a truncated block yields the candidates it did report rather than nothing.
        if line == "CALL" {
            push(&mut out, open.take());
            open = Some(Call::default());
            continue;
        }
        let Some(call) = open.as_mut() else { continue };
        let Some((tag, value)) = line.split_at_checked(1) else {
            continue;
        };
        match tag {
            "P" => value.clone_into(&mut call.prefix),
            "S" => value.clone_into(&mut call.suffix),
            "X" => value.clone_into(&mut call.auto_prefix),
            "Y" => value.clone_into(&mut call.hidden_prefix),
            "Z" => value.clone_into(&mut call.hidden_suffix),
            "W" => value.clone_into(&mut call.auto_suffix),
            "F" => {
                call.verbatim = value.contains('Q');
                // `-U` means the matches were never compared against the line, so `PREFIX` does not
                // describe what they would replace and the group's whole range is a guess. Dropping
                // it costs one exotic completion; keeping it would delete text the user typed.
                call.unmatched = value.contains('U');
            },
            "M" if total < MAX_CANDIDATES && !call.unmatched => {
                let (body, display) = value.split_once('\t').unwrap_or((value, ""));
                total += 1;
                call.candidates.push(ShellCandidate {
                    text: call.assemble(body),
                    detail: (!display.is_empty()).then(|| display.into()),
                    verbatim: call.verbatim,
                });
            },
            // `I`/`J` are IPREFIX/ISUFFIX: zsh keeps them on the line across an accept, so they are
            // neither replaced nor inserted. They are captured for the record's completeness and
            // read by nothing — `git --git-dir=ru` works precisely because `--git-dir=` is IPREFIX
            // and the group's prefix is the `ru` alone.
            _ => {},
        }
        if total >= MAX_CANDIDATES {
            break;
        }
    }
    push(&mut out, open.take());
    out
}

/// Appends `call` when it has candidates and there is room. A `compadd` that added nothing is not a
/// group: it is one of the several passes a completion function makes before the one that answers.
fn push(out: &mut Vec<CandidateGroup>, call: Option<Call>) {
    let Some(call) = call else { return };
    if call.candidates.is_empty() || out.len() >= MAX_GROUPS {
        return;
    }
    out.push(CandidateGroup {
        prefix: call.prefix,
        suffix: call.suffix,
        candidates: call.candidates,
    });
}

/// One `compadd` call being read.
#[derive(Debug, Default)]
struct Call {
    prefix: String,
    suffix: String,
    auto_prefix: String,
    hidden_prefix: String,
    hidden_suffix: String,
    auto_suffix: String,
    verbatim: bool,
    unmatched: bool,
    candidates: Vec<ShellCandidate>,
}

impl Call {
    /// The five affix parts around `body`, in the order zsh writes them onto the line.
    ///
    /// The trailing spaces come off the result. zsh's git-ref completion really does pass each ref
    /// as `HEAD ` — the space is that function's "and put the caret past it" convention, expressed
    /// in the match instead of in `-S` — and carrying it through would make an unquoted candidate
    /// insert as `'HEAD '`, a ref no repository has.
    fn assemble(&self, body: &str) -> String {
        let mut text = String::with_capacity(
            self.auto_prefix.len()
                + self.hidden_prefix.len()
                + body.len()
                + self.hidden_suffix.len()
                + self.auto_suffix.len(),
        );
        text.push_str(&self.auto_prefix);
        text.push_str(&self.hidden_prefix);
        text.push_str(body);
        text.push_str(&self.hidden_suffix);
        text.push_str(&self.auto_suffix);
        while text.ends_with(' ') {
            text.pop();
        }
        text
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::{MAX_CANDIDATES, answer};

    /// `git com` against the user's own zsh, verbatim.
    ///
    /// Written with REAL newlines rather than `\n` escapes: these records are line-oriented, and a
    /// long escaped literal is exactly the shape rustfmt's `format_strings` rewraps with a `\`
    /// continuation — which once ate the newline in front of a record and left this fixture
    /// describing something the shell never emitted.
    const GIT_COM: &str = "BEGIN 6
CALL
I
Pcom
S
J
X
Y
Z
W
F
Mcommit\tcommit  -- record changes to the repository
END 6
";

    /// `cd rust/slopdesk-w` — the hidden-prefix case.
    const HIDDEN_PREFIX: &str = "BEGIN 1
CALL
I
Prust/slopdesk-w
S
J
X
Yrust/
Z
W
FQ
Mslopdesk-wire\t
Mslopdesk-workspace\t
END 1
";

    #[test]
    fn a_described_candidate_carries_its_description() {
        let groups = answer(GIT_COM, 6).unwrap_or_default();
        assert_eq!(groups.len(), 1);
        let group = groups.first().unwrap();
        assert_eq!(group.prefix, "com");
        assert_eq!(group.suffix, "");
        let candidate = group.candidates.first().unwrap();
        assert_eq!(candidate.text, "commit");
        assert_eq!(
            candidate.detail.as_deref(),
            Some("commit  -- record changes to the repository")
        );
        assert!(!candidate.verbatim);
    }

    /// The whole reason the affixes are captured: `-p` is what makes the insert land in the right
    /// directory, and the group's prefix is the WHOLE typed word rather than its last component —
    /// so the two compose without either doubling or dropping `rust/`.
    #[test]
    fn a_hidden_prefix_is_part_of_what_gets_inserted() {
        let groups = answer(HIDDEN_PREFIX, 1).unwrap_or_default();
        let group = groups.first().unwrap();
        assert_eq!(group.prefix, "rust/slopdesk-w");
        let texts: Vec<&str> = group.candidates.iter().map(|item| item.text.as_str()).collect();
        assert_eq!(texts, ["rust/slopdesk-wire", "rust/slopdesk-workspace"]);
        assert!(group.candidates.iter().all(|item| item.verbatim));
        assert!(group.candidates.iter().all(|item| item.detail.is_none()));
    }

    #[test]
    fn an_answer_that_has_not_finished_arriving_is_not_an_empty_one() {
        let partial = GIT_COM.trim_end_matches("END 6\n");
        assert!(answer(partial, 6).is_none());
        assert!(answer(GIT_COM, 6).is_some());
    }

    /// The record that makes abandoning a request safe. A late answer for 5 sits in front of 6's,
    /// and 6 must read as its own single candidate rather than inheriting the stale one.
    #[test]
    fn a_late_answer_for_an_older_request_is_discarded_whole() {
        let mut stream = HIDDEN_PREFIX
            .replace("BEGIN 1", "BEGIN 5")
            .replace("END 1", "END 5");
        stream.push_str(GIT_COM);
        let groups = answer(&stream, 6).unwrap_or_default();
        assert_eq!(groups.len(), 1);
        let group = groups.first().unwrap();
        assert_eq!(group.prefix, "com");
        assert_eq!(group.candidates.len(), 1);
    }

    /// A request whose own `BEGIN` has not been written yet must not read the previous answer's
    /// records as its own.
    #[test]
    fn an_unopened_request_reads_nothing_rather_than_its_predecessors_records() {
        assert!(answer(GIT_COM, 7).is_none());
    }

    /// `-U` matches were never compared against the line, so `PREFIX` does not describe what they
    /// would replace. The group is dropped rather than offered against a range that is a guess.
    #[test]
    fn an_unmatched_call_offers_nothing_rather_than_a_guessed_range() {
        let stream = GIT_COM.replace("\nF\n", "\nFU\n");
        assert_eq!(answer(&stream, 6).unwrap_or_default(), Vec::new());
    }

    /// zsh's git-ref completion passes `HEAD ` with the trailing space; a `-Q` candidate goes in
    /// verbatim, and verbatim `HEAD ` would name a ref that does not exist.
    #[test]
    fn a_trailing_space_in_a_match_is_the_shells_convention_and_not_part_of_the_name() {
        let stream = "BEGIN 1\nCALL\nI\nP\nS\nJ\nX\nY\nZ\nW\nFQ\nMHEAD \t\nMmain \t\nEND 1\n";
        let groups = answer(stream, 1).unwrap_or_default();
        let group = groups.first().unwrap();
        let texts: Vec<&str> = group.candidates.iter().map(|item| item.text.as_str()).collect();
        assert_eq!(texts, ["HEAD", "main"]);
    }

    /// A completion function in a loop must not put a megabyte on the wire.
    #[test]
    fn a_runaway_completion_is_capped_rather_than_carried() {
        let mut stream = String::from("BEGIN 1\nCALL\nI\nP\nS\nJ\nX\nY\nZ\nW\nF\n");
        for index in 0..(MAX_CANDIDATES * 2) {
            use core::fmt::Write as _;
            let _written = writeln!(stream, "Mcandidate{index}\t");
        }
        stream.push_str("END 1\n");
        let groups = answer(&stream, 1).unwrap_or_default();
        let total: usize = groups.iter().map(|group| group.candidates.len()).sum();
        assert_eq!(total, MAX_CANDIDATES);
    }

    /// A `compadd` that added nothing is one of the passes a completion function makes on the way
    /// to the one that answers — not an empty group the client would render as a heading.
    #[test]
    fn a_call_that_added_nothing_is_not_a_group() {
        let stream =
            "BEGIN 1\nCALL\nI\nP\nS\nJ\nX\nY\nZ\nW\nF\nCALL\nI\nPc\nS\nJ\nX\nY\nZ\nW\nF\nMcommit\t\nEND 1\n";
        let groups = answer(stream, 1).unwrap_or_default();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups.first().map(|group| group.prefix.as_str()), Some("c"));
    }
}
