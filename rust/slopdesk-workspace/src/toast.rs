//! What one transient notification card SAYS, and which of the two speakers said it.
//!
//! A notification here is A PANE SPEAKING FROM OFF-SCREEN: every construction site is gated on the
//! source pane NOT being focused, so a toast always names a place the user is not looking at. That
//! shapes the whole card — it carries WHO spoke ([`Source`] and [`Flavor`]), WHAT happened (the
//! title and the body), and WHERE to go (the pane key, which is the jump target).
//!
//! What is here is the three FACTORIES — the fields each event turns into — and the STACK the
//! cards stand in. This module used to say the stack was the coordinator's, "because none of it is
//! a decision about words". That reasoning was sound while the coordinator's clock was a
//! declarative `.task(id:)` that owned the whole lifecycle as one thing. `docs/62` split it: under
//! `UIKit` the dwell is an explicit `Task` per card, which separates the CLOCK from the RULES, and
//! the rules — the cap, the replace-by-id, which end the eviction eats — were never about the
//! clock. A timer is an actuator and stays near; [`push`] is a fold and does not.
//!
//! ## The headline is `source` + `flavor` TOGETHER, never flavour alone
//!
//! `success` means "the agent finished its turn" for an agent and "the command exited 0" for a
//! command, and those are two different speakers saying two different sentences. Fusing them into
//! one flavour and letting the view guess is the exact mistake the tab-badge resolver made.
//!
//! ## Redaction happens HERE, at the one construction site
//!
//! OSC 0/2 titles and OSC 9/777 bodies are remote-controlled text: a prompt, a `set -x` trace or a
//! `mysql -pSECRET` command line can splat a credential into one. The toast is the ONLY
//! notification surface on iOS — the macOS user-notification path never runs there — so an
//! unmasked title would render verbatim on screen, which is a shoulder-surf, screen-share and
//! recording leak. [`crate::secrets::redact`] is idempotent, so a source that already passed
//! through a redacting ingress pays nothing.

use crate::secrets;

/// Which of the workspace's two status speakers raised this notification.
///
/// Not a style knob: it picks the headline's VERB, so it must name a real distinction between the
/// speakers.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Source {
    /// A living agent session with a lifecycle — its success is "finished a turn".
    Agent,
    /// A command's outcome, or any other one-off event at a pane — its success is "exited clean".
    Command,
}

impl Source {
    /// The discriminant the near side's enum crosses as.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Agent => 0,
            Self::Command => 1,
        }
    }
}

/// How loud the card is.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Flavor {
    /// A plain notice.
    Default,
    /// Something completed cleanly.
    Success,
    /// Something failed.
    Error,
    /// Something wants a person, or warns them.
    Attention,
}

impl Flavor {
    /// The discriminant the near side's enum crosses as.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Default => 0,
            Self::Success => 1,
            Self::Error => 2,
            Self::Attention => 3,
        }
    }
}

/// The fields one card is built from.
///
/// The pane key is the caller's own and comes back unchanged, because it is BOTH the jump target
/// and the stable id's tail — a factory that returned only the id would make the caller re-derive
/// the other half of the same string.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Card {
    /// Stable id — a newer card with the same id replaces the older one.
    pub id: String,
    /// How loud the card is.
    pub flavor: Flavor,
    /// Who spoke.
    pub source: Source,
    /// The card's subject line.
    pub title: String,
    /// The detail line, or `None` for a card that has none.
    pub body: Option<String>,
    /// The event phrase that LEADS the card, when a factory knows a truer one than the
    /// `source` + `flavor` + `title` derivation can reach.
    pub headline: Option<String>,
}

/// Masks likely secrets in untrusted, remote-controlled text when the setting is on.
///
/// The gate is an argument rather than a read, because a store lookup is the caller's and this
/// crate has no preferences.
fn masked(text: &str, redact: bool) -> String {
    if redact {
        secrets::redact(text)
    } else {
        text.to_owned()
    }
}

/// The card for an explicit OSC 9/777 notification.
///
/// Both the title and the body are the remote's own text, so both are masked here — see the module
/// header. `pane_key` is the pane's id in its printable form.
#[must_use]
pub fn explicit_osc(pane_key: &str, title: &str, body: Option<&str>, redact: bool) -> Card {
    Card {
        id: format!("pane.{pane_key}"),
        flavor: Flavor::Default,
        // A program in the pane announced something — an EVENT at that pane, not an agent's
        // lifecycle.
        source: Source::Command,
        title: masked(title, redact),
        body: body.map(|body| masked(body, redact)),
        headline: None,
    }
}

/// The card for a finished LONG-running command — the background "your build finished" cue.
///
/// `pane_title` is the live OSC 0/2 title, which is remote-settable and so is masked. The body is a
/// FIXED exit-code and duration template carrying no untrusted text, so it needs none. A clean exit
/// is a success; a non-zero one is an error, because a green checkmark on a failed build would
/// mislead.
///
/// A title-less pane falls back to the bare SUBJECT rather than to a sentence: the derived headline
/// appends the verb, so a card titled with a sentence would double up.
#[must_use]
pub fn long_command(
    pane_key: &str,
    pane_title: &str,
    exit_code: Option<i32>,
    duration_ms: u32,
    redact: bool,
) -> Card {
    let seconds = (f64::from(duration_ms) / 1000.0).round();
    let clean_exit = exit_code.unwrap_or(0) == 0;
    let code = exit_code.map_or_else(|| String::from("?"), |code| code.to_string());
    Card {
        id: format!("pane.{pane_key}"),
        flavor: if clean_exit {
            Flavor::Success
        } else {
            Flavor::Error
        },
        source: Source::Command,
        title: if pane_title.is_empty() {
            String::from("Command")
        } else {
            masked(pane_title, redact)
        },
        // `.0` after a `round` prints the integer the round produced; the two together are the
        // near side's `Int(rounded())` without an `as` cast that could truncate a hostile duration.
        body: Some(format!("exit {code} \u{b7} {seconds:.0}s")),
        headline: None,
    }
}

/// A completed reconnect's fresh-vs-resumed verdict.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ResumeOutcome {
    /// No output delivered on the current connection yet, or the link is down.
    Undetermined,
    /// The sequence stream restarted — the host spawned a FRESH shell.
    FreshShell,
    /// The stream continued past the presented sequence — the host reattached the SAME live shell.
    ResumedSession,
}

impl ResumeOutcome {
    /// The outcome the near side's case index names; anything past the end has not resolved.
    #[must_use]
    pub const fn from_index(index: u8) -> Self {
        match index {
            1 => Self::FreshShell,
            2 => Self::ResumedSession,
            _ => Self::Undetermined,
        }
    }
}

/// The card for a completed reconnect, or `None` when there is nothing to say.
///
/// This is the ONLY signal the user gets for whether a dropped link reattached the SAME live shell
/// (scrollback and history intact) or spawned a FRESH one (the previous session, and its context,
/// ended). A resume is reassuring; a fresh shell is a soft warning that context is gone.
/// [`Undetermined`](ResumeOutcome::Undetermined) is never a user-facing edge — the verdict has not
/// resolved — so it shows nothing.
///
/// The verdict rides as an explicit HEADLINE, because no `flavor` + `title` suffix encodes
/// "reattached vs fresh"; that frees the detail line to say what it MEANS for the user's context.
/// Neither string is untrusted, so nothing here is masked. The stable id de-dupes with the pane's
/// other cards, so a newer event replaces this one.
#[must_use]
pub fn session_resume(pane_key: &str, outcome: ResumeOutcome) -> Option<Card> {
    let (flavor, title, body) = match outcome {
        ResumeOutcome::ResumedSession => {
            (
                Flavor::Success,
                "Session reattached",
                "Same shell — context preserved",
            )
        },
        ResumeOutcome::FreshShell => {
            (
                Flavor::Attention,
                "Reconnected to a fresh shell",
                "The previous session ended",
            )
        },
        ResumeOutcome::Undetermined => return None,
    };
    Some(Card {
        id: format!("pane.{pane_key}"),
        flavor,
        source: Source::Command,
        title: title.to_owned(),
        body: Some(body.to_owned()),
        headline: Some(title.to_owned()),
    })
}

/// How many cards may stand at once.
///
/// Four, because the stack is a corner of a window someone is working in rather than a log: past
/// four the oldest is already off the bottom of anybody's attention, and the fifth would push the
/// one that is still being read. The number is the crate's for the same reason `veil_delay` is —
/// two shells that trim to different depths disagree about which pane spoke last.
pub const CAP: usize = 4;

/// Which of the caller's standing cards survive one push, as positions in the stack it handed over.
///
/// The pushed card is not in the answer: it is always last, so naming it would be a constant the
/// caller has to read. What IS decided here is the pair of rules a stack has and a list does not.
/// A newer card with the SAME id REPLACES the older rather than standing beside it, because both
/// name one pane and two rows for one pane is the surface lying about how many things happened.
/// And when the cap is reached the eviction eats the FRONT, which is where the oldest live — the
/// other end is the card that just arrived.
///
/// Ids cross as they are, unhashed: a stack is four entries, and a set would cost more to build
/// than the scan it replaces.
#[must_use]
pub fn push(standing: &[&str], incoming: &str) -> Vec<usize> {
    let mut kept: Vec<usize> = standing
        .iter()
        .enumerate()
        .filter(|(_, id)| **id != incoming)
        .map(|(at, _)| at)
        .collect();
    // The pushed card takes the last slot, so the survivors may hold every other one.
    let room = CAP - 1;
    if kept.len() > room {
        kept.drain(..kept.len() - room);
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::{CAP, Flavor, ResumeOutcome, Source, explicit_osc, long_command, push, session_resume};
    use crate::secrets::MASK;

    /// Every factory de-dupes on the SAME id shape, so a newer event at a pane replaces the older.
    #[test]
    fn one_pane_owns_one_card_slot() {
        let osc = explicit_osc("abc", "hi", None, false);
        let command = long_command("abc", "make", Some(0), 1000, false);
        assert_eq!(osc.id, "pane.abc");
        assert_eq!(command.id, osc.id);
        assert_eq!(
            session_resume("abc", ResumeOutcome::FreshShell).map(|card| card.id),
            Some(osc.id),
        );
    }

    /// The untrusted halves are masked and the trusted ones are not — the whole point of doing it
    /// at the construction site.
    #[test]
    fn the_remotes_own_text_is_masked_and_the_template_is_left_alone() {
        // Assembled from fragments so no contiguous token literal sits in this file — the same
        // reason `secrets`' own suite does it: push protection scans source, not intent.
        let leak = ["AKIA", "IOSFODNN7EXAMPLE"].concat();
        let leak = leak.as_str();
        let card = explicit_osc("abc", leak, Some(leak), true);
        assert!(card.title.contains(MASK), "the title leaked: {}", card.title);
        assert!(card.body.is_some_and(|body| body.contains(MASK)));
        let unmasked = explicit_osc("abc", leak, None, false);
        assert_eq!(unmasked.title, leak, "the gate is the caller's, not this crate's");
    }

    #[test]
    fn a_command_toast_prints_its_exit_code_and_its_seconds() {
        let card = long_command("abc", "make check", Some(0), 12_400, false);
        assert_eq!(card.flavor, Flavor::Success);
        assert_eq!(card.source, Source::Command);
        assert_eq!(card.title, "make check");
        assert_eq!(card.body.as_deref(), Some("exit 0 \u{b7} 12s"));
    }

    /// A green checkmark on a failed build would mislead, and an unknown code is not a clean one
    /// being hidden.
    #[test]
    fn a_non_zero_exit_is_an_error_and_an_unknown_one_is_still_clean() {
        assert_eq!(long_command("a", "t", Some(1), 0, false).flavor, Flavor::Error);
        let unknown = long_command("a", "t", None, 500, false);
        assert_eq!(unknown.flavor, Flavor::Success);
        assert_eq!(
            unknown.body.as_deref(),
            Some("exit ? \u{b7} 1s"),
            "the dwell rounds"
        );
    }

    /// A title-less pane falls back to the bare SUBJECT, because the headline appends the verb.
    #[test]
    fn a_nameless_pane_is_called_command_rather_than_nothing() {
        assert_eq!(long_command("a", "", Some(0), 0, true).title, "Command");
    }

    #[test]
    fn a_reconnect_says_what_it_means_for_the_users_context() {
        let resumed = session_resume("abc", ResumeOutcome::ResumedSession);
        assert_eq!(resumed.as_ref().map(|card| card.flavor), Some(Flavor::Success),);
        assert_eq!(
            resumed.as_ref().and_then(|card| card.headline.as_deref()),
            Some("Session reattached"),
        );
        assert_eq!(
            resumed.and_then(|card| card.body),
            Some("Same shell — context preserved".to_owned()),
        );
        let fresh = session_resume("abc", ResumeOutcome::FreshShell);
        assert_eq!(fresh.map(|card| card.flavor), Some(Flavor::Attention));
    }

    /// An unresolved verdict is not a user-facing edge, so it shows nothing.
    #[test]
    fn an_unresolved_reconnect_says_nothing() {
        assert_eq!(session_resume("abc", ResumeOutcome::Undetermined), None);
        assert_eq!(ResumeOutcome::from_index(0), ResumeOutcome::Undetermined);
        assert_eq!(ResumeOutcome::from_index(1), ResumeOutcome::FreshShell);
        assert_eq!(ResumeOutcome::from_index(2), ResumeOutcome::ResumedSession);
        assert_eq!(ResumeOutcome::from_index(9), ResumeOutcome::Undetermined);
    }

    /// A second card for one pane REPLACES the first, and it does so at the TOP: the pane spoke
    /// again, so it is the newest thing that happened, not the oldest.
    #[test]
    fn a_pane_that_speaks_twice_moves_to_the_top_rather_than_standing_twice() {
        assert_eq!(push(&["pane.a", "pane.b"], "pane.a"), vec![1]);
        assert_eq!(push(&["pane.a", "pane.b"], "pane.c"), vec![0, 1]);
        assert_eq!(push(&[], "pane.a"), Vec::<usize>::new());
    }

    /// The eviction eats the FRONT. Dropping the other end would evict the card that just arrived,
    /// which is the one thing on screen the user has not read yet.
    #[test]
    fn a_full_stack_loses_its_oldest_and_never_the_arrival() {
        let full = ["pane.a", "pane.b", "pane.c", "pane.d"];
        assert_eq!(push(&full, "pane.e"), vec![1, 2, 3]);
        assert_eq!(
            push(&full, "pane.e").len(),
            CAP - 1,
            "the arrival holds the last slot"
        );
        // A de-dupe already made room, so nothing is evicted on top of it.
        assert_eq!(push(&full, "pane.a"), vec![1, 2, 3]);
    }

    /// Distinct speakers and flavours take distinct codes — a renderer switches on the number.
    #[test]
    fn every_speaker_and_flavour_has_its_own_code() {
        assert_ne!(Source::Agent.code(), Source::Command.code());
        let mut codes: Vec<u8> = [Flavor::Default, Flavor::Success, Flavor::Error, Flavor::Attention]
            .into_iter()
            .map(Flavor::code)
            .collect();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), 4);
    }
}
