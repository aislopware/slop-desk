//! The client control socket's VALIDATE-THEN-DROP rules, and the words it refuses in.
//!
//! `slopdesk pane capture`, `slopdesk view`, `slopdesk tab badge` and eleven more arrive here as
//! one NDJSON line per request, written by a process the app did not launch and cannot vouch for.
//! The contract is the repo's untrusted-input one: every field is validated BEFORE it is used,
//! every count is bounded BEFORE anything allocates against it, and a hostile or truncated line
//! becomes an `ok:false` answer rather than a trap.
//!
//! What is here is that validation and the REFUSAL vocabulary it answers in. What is deliberately
//! NOT here is the method table and the three token vocabularies — `slopdesk-cli`'s `clientctl`
//! holds those, and `slopdesk-invariants` pins them against the Swift `ClientControlProtocol` they
//! are dispatched through, so a third spelling in this crate would be the very drift that gate
//! exists to catch.
//!
//! ## A refusal is a CODE plus a detail, never a sentence built twice
//!
//! Nineteen of the twenty refusals are a fixed string; five of them name a token the request
//! supplied. So a caller names the refusal and hands over the token it read, and the sentence is
//! assembled once — which is what keeps `invalid placement 'x'` from becoming
//! `invalid placement "x"` on one of the two ends that print it.
//!
//! ## The trim is the SCAN's, and it answers a span
//!
//! [`scan_line`] trims, and then answers where the trimmed request STARTS and ENDS rather than a
//! new string: nothing needs to be allocated to slice at an offset, and a trim done on both sides
//! of the boundary is a rule spelled twice. Rust's `str::trim` and Foundation's
//! `.whitespacesAndNewlines` are the same set — Unicode's `White_Space` property — and trim
//! boundaries are scalar boundaries, so the span is always whole UTF-8.

// ---------------------------------------------------------------------------------------------- //
// The bounds
// ---------------------------------------------------------------------------------------------- //

/// Max bytes in one request line, measured on the TRIMMED request — the same cap the host's own
/// control socket keeps.
///
/// The line is refused at this size before it is parsed, so a megabyte of hostile JSON costs a
/// length comparison rather than a parse.
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;

/// How many scrollback lines `pane-capture` reads when the request names no count.
pub const DEFAULT_CAPTURE_LINES: i64 = 100;

/// The ceiling on `pane-capture`'s count, so a hostile number cannot force an unbounded read.
///
/// Clamped rather than refused, unlike a non-positive count: asking for more scrollback than exists
/// is what `--lines 999999` MEANS, while asking for none of it is a request that cannot be served.
pub const MAX_CAPTURE_LINES: i64 = 100_000;

// ---------------------------------------------------------------------------------------------- //
// The refusal vocabulary
// ---------------------------------------------------------------------------------------------- //

/// Every way the control socket says no.
///
/// One enum rather than twenty literals at their call sites, because these strings are a USER
/// INTERFACE: they are what `slopdesk` prints when a verb does not land, and the ones that name a
/// token are the ones a person reads to find their typo.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The line is past [`MAX_REQUEST_BYTES`].
    TooLarge,
    /// The line is not a JSON object with a string `id` and `method`.
    Malformed,
    /// A method this build does not dispatch. Names the method.
    UnknownMethod,
    /// `tab-badge` with no `kind`.
    MissingBadgeKind,
    /// `tab-badge` with a `kind` no badge answers to. Names the token.
    InvalidBadgeKind,
    /// `tab-badge` naming a tab that is not there.
    TabNotFound,
    /// `jump` resolved to nothing.
    NoJumpTarget,
    /// `learn` with no path and no focused pane to take one from.
    NothingToLearn,
    /// `ignore` with no `path`, or an empty one.
    MissingPath,
    /// `ignore` on a path the frecency store would not drop.
    CouldNotIgnore,
    /// `view` / `edit` with no `target`, or an empty one.
    MissingTarget,
    /// `view` / `edit` with a `placement` no surface answers to. Names the token.
    InvalidPlacement,
    /// `view` / `edit` on a target that would not open.
    CouldNotOpen,
    /// `font-list` with a `scope` no font surface answers to. Names the token.
    InvalidScope,
    /// `pane-capture` with a `lines` that is not a positive integer.
    CaptureLines,
    /// A pane verb naming a pane that is not there.
    PaneNotFound,
    /// `pane-send-keys` with a `keys` that is not an array.
    KeysNotAnArray,
    /// `pane-send-keys` with neither text nor a named key to send.
    NothingToSend,
    /// `pane-send-keys` naming a key the table does not carry. Names the key.
    UnknownKey,
    /// `agent-status` with no `id`, or an empty one.
    MissingId,
}

impl Refusal {
    /// Every refusal, in discriminant order.
    pub const ALL: [Self; 20] = [
        Self::TooLarge,
        Self::Malformed,
        Self::UnknownMethod,
        Self::MissingBadgeKind,
        Self::InvalidBadgeKind,
        Self::TabNotFound,
        Self::NoJumpTarget,
        Self::NothingToLearn,
        Self::MissingPath,
        Self::CouldNotIgnore,
        Self::MissingTarget,
        Self::InvalidPlacement,
        Self::CouldNotOpen,
        Self::InvalidScope,
        Self::CaptureLines,
        Self::PaneNotFound,
        Self::KeysNotAnArray,
        Self::NothingToSend,
        Self::UnknownKey,
        Self::MissingId,
    ];

    /// Its discriminant, as it crosses. Numbered from `1`, so `0` is free to mean NO refusal —
    /// which is what the doors that answer "is this request acceptable" say when it is.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::TooLarge => 1,
            Self::Malformed => 2,
            Self::UnknownMethod => 3,
            Self::MissingBadgeKind => 4,
            Self::InvalidBadgeKind => 5,
            Self::TabNotFound => 6,
            Self::NoJumpTarget => 7,
            Self::NothingToLearn => 8,
            Self::MissingPath => 9,
            Self::CouldNotIgnore => 10,
            Self::MissingTarget => 11,
            Self::InvalidPlacement => 12,
            Self::CouldNotOpen => 13,
            Self::InvalidScope => 14,
            Self::CaptureLines => 15,
            Self::PaneNotFound => 16,
            Self::KeysNotAnArray => 17,
            Self::NothingToSend => 18,
            Self::UnknownKey => 19,
            Self::MissingId => 20,
        }
    }

    /// The refusal a discriminant names, or `None` — including for `0`, which is the absence of a
    /// refusal rather than one this build cannot name.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::TooLarge),
            2 => Some(Self::Malformed),
            3 => Some(Self::UnknownMethod),
            4 => Some(Self::MissingBadgeKind),
            5 => Some(Self::InvalidBadgeKind),
            6 => Some(Self::TabNotFound),
            7 => Some(Self::NoJumpTarget),
            8 => Some(Self::NothingToLearn),
            9 => Some(Self::MissingPath),
            10 => Some(Self::CouldNotIgnore),
            11 => Some(Self::MissingTarget),
            12 => Some(Self::InvalidPlacement),
            13 => Some(Self::CouldNotOpen),
            14 => Some(Self::InvalidScope),
            15 => Some(Self::CaptureLines),
            16 => Some(Self::PaneNotFound),
            17 => Some(Self::KeysNotAnArray),
            18 => Some(Self::NothingToSend),
            19 => Some(Self::UnknownKey),
            20 => Some(Self::MissingId),
            _ => None,
        }
    }

    /// Whether this refusal NAMES a token the request supplied.
    ///
    /// The five that do are the five worth reading twice: they are what tells a person that
    /// `--placement split-lefft` was a typo rather than a verb the app never grew.
    #[must_use]
    pub const fn names_detail(self) -> bool {
        matches!(
            self,
            Self::UnknownMethod
                | Self::InvalidBadgeKind
                | Self::InvalidPlacement
                | Self::InvalidScope
                | Self::UnknownKey
        )
    }

    /// The sentence this refusal answers with, with `detail` filled in where one is named.
    ///
    /// A `detail` handed to a refusal that names none is IGNORED rather than appended: the caller
    /// that always passes what it read stays a one-liner, and no message grows a stray token.
    #[must_use]
    pub fn message(self, detail: &str) -> String {
        match self {
            Self::UnknownMethod => format!("unknown method: {detail}"),
            Self::InvalidBadgeKind => format!("invalid badge kind '{detail}'"),
            Self::InvalidPlacement => format!("invalid placement '{detail}'"),
            Self::InvalidScope => format!("invalid scope '{detail}'"),
            Self::UnknownKey => format!("unknown key: {detail}"),
            Self::TooLarge => "request too large".to_owned(),
            Self::Malformed => "malformed request".to_owned(),
            Self::MissingBadgeKind => "missing params.kind".to_owned(),
            Self::TabNotFound => "tab not found".to_owned(),
            Self::NoJumpTarget => "no jump target".to_owned(),
            Self::NothingToLearn => {
                "no directory to learn (give a path or focus a pane with a cwd)".to_owned()
            },
            Self::MissingPath => "missing params.path".to_owned(),
            Self::CouldNotIgnore => "could not ignore path".to_owned(),
            Self::MissingTarget => "missing params.target".to_owned(),
            Self::CouldNotOpen => "could not open target".to_owned(),
            Self::CaptureLines => "lines must be a positive integer".to_owned(),
            Self::PaneNotFound => "pane not found".to_owned(),
            Self::KeysNotAnArray => "keys must be an array of strings".to_owned(),
            Self::NothingToSend => "nothing to send (need text or keys)".to_owned(),
            Self::MissingId => "missing params.id".to_owned(),
        }
    }
}

// ---------------------------------------------------------------------------------------------- //
// The line guard
// ---------------------------------------------------------------------------------------------- //

/// What one raw request line IS, before anything is parsed out of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineVerdict {
    /// Blank or whitespace-only. There is nothing to respond TO — which is not the same as an
    /// error response, and is why the socket answers no line at all.
    Blank,
    /// Past [`MAX_REQUEST_BYTES`]. Refused before it is parsed, with [`Refusal::TooLarge`].
    TooLarge,
    /// Worth parsing. The span is the trimmed request.
    Parse,
}

impl LineVerdict {
    /// Every verdict, in discriminant order.
    pub const ALL: [Self; 3] = [Self::Blank, Self::TooLarge, Self::Parse];

    /// Its discriminant, as it crosses.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Blank => 0,
            Self::TooLarge => 1,
            Self::Parse => 2,
        }
    }

    /// The verdict a discriminant names, or `None` for one this build does not know.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::Blank),
            1 => Some(Self::TooLarge),
            2 => Some(Self::Parse),
            _ => None,
        }
    }
}

/// One line's verdict, and where its trimmed request lies inside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineScan {
    /// What to do with the line.
    pub verdict: LineVerdict,
    /// The BYTE offset the trimmed request starts at.
    pub start: usize,
    /// The BYTE offset one past its last byte. Equal to `start` for a blank line.
    pub end: usize,
}

/// What one raw request line is, and where the request inside it lies.
///
/// The span is answered for EVERY verdict, including the two that refuse — a caller that wants to
/// log what it refused has it without a second pass, and a blank line's empty span is honest rather
/// than reserved.
#[must_use]
pub fn scan_line(line: &str) -> LineScan {
    let from_start = line.trim_start();
    let start = line.len().saturating_sub(from_start.len());
    let trimmed = from_start.trim_end();
    let end = start.saturating_add(trimmed.len());
    let verdict = if trimmed.is_empty() {
        LineVerdict::Blank
    } else if trimmed.len() > MAX_REQUEST_BYTES {
        LineVerdict::TooLarge
    } else {
        LineVerdict::Parse
    };
    LineScan { verdict, start, end }
}

// ---------------------------------------------------------------------------------------------- //
// The two bounded payloads
// ---------------------------------------------------------------------------------------------- //

/// How many scrollback lines a `pane-capture` request asks for, or `None` for
/// [`Refusal::CaptureLines`].
///
/// `present` is whether the request carried a `lines` field at all and `is_integer` whether it was
/// one — a field carrying `"12"` or `1.5` is a refusal rather than a coercion, because a control
/// socket that guesses at types is one that reads `true` as 1. The three cases:
///
/// * absent ⇒ [`DEFAULT_CAPTURE_LINES`];
/// * present, an integer, positive ⇒ itself, clamped to [`MAX_CAPTURE_LINES`];
/// * anything else ⇒ refused.
#[must_use]
pub const fn capture_lines(present: bool, is_integer: bool, raw: i64) -> Option<i64> {
    if !present {
        return Some(DEFAULT_CAPTURE_LINES);
    }
    if !is_integer || raw <= 0 {
        return None;
    }
    if raw < MAX_CAPTURE_LINES {
        Some(raw)
    } else {
        Some(MAX_CAPTURE_LINES)
    }
}

/// What a `pane-send-keys` request carries, once its `keys` have been read.
#[expect(
    clippy::struct_excessive_bools,
    reason = "four facts about two independent fields, and the record IS the argument list — the pair per \
              field is what makes 'present but wrong' distinguishable from 'absent'"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SendKeysFacts {
    /// Whether the request carried a `keys` field at all.
    pub keys_present: bool,
    /// Whether that field was an array. Meaningless when `keys_present` is `false`.
    pub keys_is_array: bool,
    /// Whether `text` is a non-empty string.
    pub has_text: bool,
    /// Whether any key SURVIVED the read.
    ///
    /// The near side drops non-string elements as it reads them, so an array of numbers arrives
    /// here as an array with nothing in it — and an otherwise empty request carrying one is
    /// [`Refusal::NothingToSend`], which is what it is: nothing was sendable.
    pub has_keys: bool,
}

/// Why a `pane-send-keys` request cannot be served, or `None` when it can.
///
/// The order is the near side's and is load-bearing: a `keys` of the wrong TYPE is reported as
/// such even when there is text to send, because a request that half-arrived should not look like
/// one that fully did.
#[must_use]
pub const fn send_keys_refusal(facts: SendKeysFacts) -> Option<Refusal> {
    if facts.keys_present && !facts.keys_is_array {
        return Some(Refusal::KeysNotAnArray);
    }
    if !facts.has_text && !facts.has_keys {
        return Some(Refusal::NothingToSend);
    }
    None
}

// ---------------------------------------------------------------------------------------------- //
// Tests
// ---------------------------------------------------------------------------------------------- //

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_CAPTURE_LINES, LineVerdict, MAX_CAPTURE_LINES, MAX_REQUEST_BYTES, Refusal, SendKeysFacts,
        capture_lines, scan_line, send_keys_refusal,
    };

    // -- the line guard -------------------------------------------------------------------------

    #[test]
    fn a_a_request_line_is_trimmed_to_its_span() {
        let line = "  {\"id\":\"1\"}\n";
        let scan = scan_line(line);
        assert_eq!(scan.verdict, LineVerdict::Parse);
        assert_eq!(scan.start, 2);
        assert_eq!(scan.end, 12);
        assert_eq!(line.get(scan.start..scan.end), Some("{\"id\":\"1\"}"));
    }

    #[test]
    fn a_blank_line_is_nothing_to_respond_to() {
        for line in ["", " ", "\n", "\r\n", " \t \n"] {
            let scan = scan_line(line);
            assert_eq!(scan.verdict, LineVerdict::Blank, "{line:?}");
            assert_eq!(scan.start, scan.end, "{line:?}");
        }
    }

    #[test]
    fn an_oversized_line_is_refused_before_it_is_parsed() {
        let line = "x".repeat(MAX_REQUEST_BYTES.saturating_add(1));
        assert_eq!(scan_line(&line).verdict, LineVerdict::TooLarge);
        let exact = "x".repeat(MAX_REQUEST_BYTES);
        assert_eq!(
            scan_line(&exact).verdict,
            LineVerdict::Parse,
            "the cap is inclusive",
        );
    }

    /// The cap is measured on the TRIMMED request, so a padded line is not refused for its padding.
    #[test]
    fn the_cap_measures_the_request_rather_than_the_line() {
        let padded = format!("{}{}", " ".repeat(64), "x".repeat(MAX_REQUEST_BYTES));
        assert_eq!(scan_line(&padded).verdict, LineVerdict::Parse);
    }

    /// The span is always whole UTF-8, because a trim boundary is a scalar boundary.
    #[test]
    fn a_span_lands_on_character_boundaries() {
        let line = "\u{2028} {\"café\":1} \u{a0}";
        let scan = scan_line(line);
        assert!(line.is_char_boundary(scan.start));
        assert!(line.is_char_boundary(scan.end));
        assert_eq!(line.get(scan.start..scan.end), Some("{\"café\":1}"));
    }

    #[test]
    fn every_line_verdict_round_trips_through_its_code() {
        for verdict in LineVerdict::ALL {
            assert_eq!(LineVerdict::from_code(verdict.code()), Some(verdict));
        }
        let codes: Vec<u8> = LineVerdict::ALL.iter().map(|v| v.code()).collect();
        assert_eq!(codes, vec![0, 1, 2]);
        assert_eq!(LineVerdict::from_code(3), None);
    }

    // -- the capture count ----------------------------------------------------------------------

    #[test]
    fn b_an_absent_count_is_the_default() {
        assert_eq!(capture_lines(false, false, 0), Some(DEFAULT_CAPTURE_LINES));
        assert_eq!(capture_lines(false, true, 7), Some(DEFAULT_CAPTURE_LINES));
    }

    #[test]
    fn a_positive_count_is_taken_and_clamped() {
        assert_eq!(capture_lines(true, true, 1), Some(1));
        assert_eq!(
            capture_lines(true, true, MAX_CAPTURE_LINES),
            Some(MAX_CAPTURE_LINES)
        );
        assert_eq!(
            capture_lines(true, true, i64::MAX),
            Some(MAX_CAPTURE_LINES),
            "a hostile number cannot force an unbounded read",
        );
    }

    #[test]
    fn a_non_positive_or_non_integer_count_is_refused() {
        assert_eq!(capture_lines(true, true, 0), None);
        assert_eq!(capture_lines(true, true, -1), None);
        assert_eq!(capture_lines(true, true, i64::MIN), None);
        assert_eq!(capture_lines(true, false, 12), None, "a string is not a count");
    }

    // -- the send-keys payload ------------------------------------------------------------------

    #[expect(
        clippy::fn_params_excessive_bools,
        reason = "the four bools ARE the record under test — naming each one an enum here would state the \
                  refusal table twice, once in the rule and once in its fixture"
    )]
    const fn payload(
        keys_present: bool,
        keys_is_array: bool,
        has_text: bool,
        has_keys: bool,
    ) -> SendKeysFacts {
        SendKeysFacts {
            keys_present,
            keys_is_array,
            has_text,
            has_keys,
        }
    }

    #[test]
    fn c_text_alone_or_keys_alone_is_enough() {
        assert_eq!(send_keys_refusal(payload(false, false, true, false)), None);
        assert_eq!(send_keys_refusal(payload(true, true, false, true)), None);
        assert_eq!(send_keys_refusal(payload(true, true, true, true)), None);
    }

    #[test]
    fn an_empty_payload_has_nothing_to_send() {
        assert_eq!(
            send_keys_refusal(payload(false, false, false, false)),
            Some(Refusal::NothingToSend),
        );
        // `keys: [1, 2]` — an array, read, and nothing in it was a key.
        assert_eq!(
            send_keys_refusal(payload(true, true, false, false)),
            Some(Refusal::NothingToSend),
        );
    }

    #[test]
    fn a_keys_field_of_the_wrong_type_outranks_the_text() {
        assert_eq!(
            send_keys_refusal(payload(true, false, true, false)),
            Some(Refusal::KeysNotAnArray),
            "a half-arrived request must not look like one that fully arrived",
        );
    }

    // -- the refusal vocabulary -----------------------------------------------------------------

    #[test]
    fn d_every_refusal_round_trips_through_its_code() {
        for refusal in Refusal::ALL {
            assert_eq!(Refusal::from_code(refusal.code()), Some(refusal));
        }
        let codes: Vec<u8> = Refusal::ALL.iter().map(|r| r.code()).collect();
        assert_eq!(codes, (1_u8..=20).collect::<Vec<u8>>());
    }

    /// `0` is the ABSENCE of a refusal, which is what the acceptance doors answer with.
    #[test]
    fn zero_names_no_refusal() {
        assert_eq!(Refusal::from_code(0), None);
        assert_eq!(Refusal::from_code(21), None);
        assert_eq!(Refusal::from_code(u8::MAX), None);
    }

    #[test]
    fn every_refusal_says_something() {
        for refusal in Refusal::ALL {
            assert!(!refusal.message("").is_empty(), "{refusal:?}");
        }
    }

    #[test]
    fn only_the_five_that_name_a_token_carry_one() {
        for refusal in Refusal::ALL {
            let spoken = refusal.message("zzz-token");
            assert_eq!(
                spoken.contains("zzz-token"),
                refusal.names_detail(),
                "{refusal:?}: {spoken}",
            );
        }
    }

    /// The exact sentences, because they are the user interface: a person reads them out of a
    /// terminal and searches for them.
    #[test]
    fn the_words_are_the_shipped_ones() {
        assert_eq!(Refusal::TooLarge.message(""), "request too large");
        assert_eq!(Refusal::Malformed.message(""), "malformed request");
        assert_eq!(Refusal::UnknownMethod.message("nope"), "unknown method: nope");
        assert_eq!(Refusal::MissingBadgeKind.message(""), "missing params.kind");
        assert_eq!(
            Refusal::InvalidBadgeKind.message("blue"),
            "invalid badge kind 'blue'"
        );
        assert_eq!(Refusal::TabNotFound.message(""), "tab not found");
        assert_eq!(Refusal::NoJumpTarget.message(""), "no jump target");
        assert_eq!(
            Refusal::NothingToLearn.message(""),
            "no directory to learn (give a path or focus a pane with a cwd)"
        );
        assert_eq!(Refusal::MissingPath.message(""), "missing params.path");
        assert_eq!(Refusal::CouldNotIgnore.message(""), "could not ignore path");
        assert_eq!(Refusal::MissingTarget.message(""), "missing params.target");
        assert_eq!(
            Refusal::InvalidPlacement.message("split-lefft"),
            "invalid placement 'split-lefft'"
        );
        assert_eq!(Refusal::CouldNotOpen.message(""), "could not open target");
        assert_eq!(Refusal::InvalidScope.message("ui"), "invalid scope 'ui'");
        assert_eq!(
            Refusal::CaptureLines.message(""),
            "lines must be a positive integer"
        );
        assert_eq!(Refusal::PaneNotFound.message(""), "pane not found");
        assert_eq!(
            Refusal::KeysNotAnArray.message(""),
            "keys must be an array of strings"
        );
        assert_eq!(
            Refusal::NothingToSend.message(""),
            "nothing to send (need text or keys)"
        );
        assert_eq!(Refusal::UnknownKey.message("f5"), "unknown key: f5");
        assert_eq!(Refusal::MissingId.message(""), "missing params.id");
    }
}
