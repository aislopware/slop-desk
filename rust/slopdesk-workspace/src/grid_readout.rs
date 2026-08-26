//! What a terminal pane SAYS about a grid it did not choose — `docs/45` §8.3 rule 7's readout,
//! verbatim: `120×40 · sized by MacBook Pro`.
//!
//! This is what makes the size policy debuggable on hardware. A phone is size-passive host-side:
//! its window never votes in a pane's `min` fold, so the resolved grid is whatever the Macs on that
//! pane settled on. Without a readout the user sees a pane that is the wrong size for no stated
//! reason, and a RULE reads as a bug.
//!
//! ## The join is tokens; only the WINNING label crosses
//!
//! [`clamped_by`] is the roster's third join and it keeps [`crate::mirror_fold`]'s law exactly: a
//! client is a dense `u32` token the caller minted, an offer is a token beside the size it stands
//! for, and the answer is a POSITION into the list the caller still holds. No `UUID` crosses and no
//! roster of labels crosses.
//!
//! What differs from the two joins next door is what comes AFTER. Their answers are lists of labels
//! and the caller prints them; this answer is one SENTENCE, and a sentence needs its label. So the
//! split is: the join picks the position, and [`text`] takes exactly ONE label — the one already
//! picked. Every literal in the readout is here, including the word for a client nothing can name.
//!
//! ## Two calls, because the middle step is the caller's own map
//!
//! Between them the near side does a lookup it is already holding — position to label — the same
//! step [`crate::mirror_fold::holders`] hands back. Folding both halves into one door would mean
//! crossing every client's label to print one of them, which is the allocation `docs/55` ranks
//! against.

use crate::mirror_fold::{RosterClient, grid_published};

/// One attachment's standing offer, as the join needs it.
///
/// The size is what the client ASKED for, not what the host resolved. A client contributes its
/// offer to the `min` fold or it does not, and only a contributing one can be the reason the grid
/// came out where it did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Offer {
    /// The dense token the caller minted for this attachment's client instance id.
    pub token: u32,
    /// Whether this attachment votes in the pane's `min` fold at all.
    pub contributes: bool,
    /// The columns this attachment stands for.
    pub cols: u32,
    /// The rows this attachment stands for.
    pub rows: u32,
}

/// Who, if anybody, the resolved grid is attributed to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Clamp {
    /// The host has resolved no grid for this pane, so there is nothing honest to say at all.
    Absent,
    /// A grid, with no attribution: nothing contributing matches it, or the client that clamped it
    /// is THIS one. A client that chose the grid needs no explanation of it.
    Unattributed,
    /// A grid clamped by the client at this POSITION in the `clients` list the caller still holds.
    SizedBy(u32),
    /// A grid clamped by an attachment no roster client names.
    ///
    /// Reported rather than dropped: a bare `slopdesk-client` opens no workspace channel, so the
    /// host publishes its attachment with the all-zero instance id. It is still a real client that
    /// really did clamp this pane, and saying nothing would make the arithmetic unexplainable.
    SizedByUnnamed,
}

impl Clamp {
    /// The byte this verdict crosses as: `0` no grid · `1` the grid alone · `2` a named client at
    /// the position beside it · `3` a client nothing names.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Absent => 0,
            Self::Unattributed => 1,
            Self::SizedBy(_) => 2,
            Self::SizedByUnnamed => 3,
        }
    }

    /// The position this verdict names, when it names one.
    #[must_use]
    pub const fn position(self) -> Option<u32> {
        match self {
            Self::SizedBy(position) => Some(position),
            Self::Absent | Self::Unattributed | Self::SizedByUnnamed => None,
        }
    }
}

/// Which client the pane's resolved grid is attributed to.
///
/// The clamping contributor is the FIRST contributing offer whose standing size equals the resolved
/// grid. The roster's own order decides, so the answer does not flicker between tied clients on
/// every presence frame — two Macs at the same size are both "why", and picking the earlier one
/// every time is the only stable way to name one of them.
#[must_use]
pub fn clamped_by(
    resolved_cols: u32,
    resolved_rows: u32,
    offers: &[Offer],
    clients: &[RosterClient],
    own: Option<u32>,
) -> Clamp {
    if !grid_published(resolved_cols, resolved_rows) {
        return Clamp::Absent;
    }
    let Some(clamping) = offers
        .iter()
        .find(|offer| offer.contributes && offer.cols == resolved_cols && offer.rows == resolved_rows)
    else {
        return Clamp::Unattributed;
    };
    if matches!(own, Some(mine) if mine == clamping.token) {
        return Clamp::Unattributed;
    }
    clients
        .iter()
        .position(|client| client.labelled && client.token == clamping.token)
        .and_then(|index| u32::try_from(index).ok())
        .map_or(Clamp::SizedByUnnamed, Clamp::SizedBy)
}

/// What an attachment nothing can name is called.
///
/// It is a real client holding a real pane at a real size — the honest readout is "somebody", never
/// silence.
pub const UNNAMED_CONTRIBUTOR: &str = "another client";

/// Who the readout attributes the grid to, once the join has decided.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Attribution<'a> {
    /// Nobody — the grid prints alone.
    Nobody,
    /// The label the caller read at the position [`clamped_by`] answered.
    Named(&'a str),
    /// A client nothing names, which prints as [`UNNAMED_CONTRIBUTOR`].
    Unnamed,
}

impl<'a> Attribution<'a> {
    /// The attribution a verdict code and a label mean together, so no caller re-derives the
    /// pairing.
    ///
    /// An unrecognised code attributes NOTHING: the grid alone is true of every pane that has one,
    /// and inventing an author for a byte this build cannot name would print a claim about a
    /// client.
    #[must_use]
    pub const fn from_code(code: u8, label: &'a str) -> Self {
        match code {
            2 => Self::Named(label),
            3 => Self::Unnamed,
            _ => Self::Nobody,
        }
    }

    /// The word this attribution prints, when it prints one.
    #[must_use]
    const fn word(self) -> Option<&'a str> {
        match self {
            Self::Nobody => None,
            Self::Named(label) => Some(label),
            Self::Unnamed => Some(UNNAMED_CONTRIBUTOR),
        }
    }
}

/// The readout for a pane, or [`None`] when the host has resolved no grid and there is nothing
/// honest to say.
///
/// A `Named("")` prints as the unnamed word rather than a dangling `sized by `: an empty label is
/// exactly the case the roster's own join filters out, and a readout that trailed off would be a
/// worse answer than the honest one.
#[must_use]
pub fn text(cols: u32, rows: u32, attribution: Attribution<'_>) -> Option<String> {
    if !grid_published(cols, rows) {
        return None;
    }
    let grid = format!("{cols}×{rows}");
    Some(match attribution.word() {
        Some(word) if !word.is_empty() => grid + " · sized by " + word,
        Some(_) => grid + " · sized by " + UNNAMED_CONTRIBUTOR,
        None => grid,
    })
}

#[cfg(test)]
mod tests {
    use super::{Attribution, Clamp, Offer, UNNAMED_CONTRIBUTOR, clamped_by, text};
    use crate::mirror_fold::RosterClient;

    /// The three clients every case here joins against: two named, one that published no label.
    fn clients() -> [RosterClient; 3] {
        [
            RosterClient {
                token: 1,
                labelled: true,
                viewing: false,
            },
            RosterClient {
                token: 2,
                labelled: true,
                viewing: false,
            },
            RosterClient {
                token: 3,
                labelled: false,
                viewing: false,
            },
        ]
    }

    /// A contributing offer at the size beside it.
    const fn offer(token: u32, cols: u32, rows: u32) -> Offer {
        Offer {
            token,
            contributes: true,
            cols,
            rows,
        }
    }

    /// An unpublished grid is ABSENT on either axis, and absent beats every attribution below it —
    /// a zero row count with a clamping offer beside it must still say nothing.
    #[test]
    fn an_unpublished_grid_says_nothing_on_either_axis() {
        for (cols, rows) in [(0, 0), (0, 40), (120, 0)] {
            assert_eq!(
                clamped_by(cols, rows, &[offer(1, cols, rows)], &clients(), None),
                Clamp::Absent
            );
            assert_eq!(text(cols, rows, Attribution::Named("mac-studio")), None);
        }
    }

    /// The clamping contributor is the first offer that MATCHES, and the roster's order decides
    /// between ties rather than the answer flickering between them.
    #[test]
    fn the_first_matching_contributor_clamps_and_ties_do_not_flicker() {
        let offers = [offer(2, 120, 40), offer(1, 120, 40)];
        assert_eq!(
            clamped_by(120, 40, &offers, &clients(), None),
            Clamp::SizedBy(1),
            "token 2 offered first, and it sits at position 1"
        );
        let reversed = [offer(1, 120, 40), offer(2, 120, 40)];
        assert_eq!(
            clamped_by(120, 40, &reversed, &clients(), None),
            Clamp::SizedBy(0)
        );
    }

    /// An offer that does not contribute is not the reason for anything, however well it matches.
    #[test]
    fn a_non_contributing_offer_never_clamps() {
        let offers = [
            Offer {
                token: 1,
                contributes: false,
                cols: 120,
                rows: 40,
            },
            offer(2, 200, 60),
        ];
        assert_eq!(
            clamped_by(120, 40, &offers, &clients(), None),
            Clamp::Unattributed
        );
    }

    /// An offer at a DIFFERENT size than the one resolved explains nothing — a pane whose grid no
    /// live attachment asked for prints the grid alone.
    #[test]
    fn an_offer_at_another_size_explains_nothing() {
        assert_eq!(
            clamped_by(120, 40, &[offer(1, 200, 60), offer(2, 120, 41)], &clients(), None),
            Clamp::Unattributed
        );
    }

    /// A client that chose the grid needs no explanation of it — its OWN clamp is unattributed, and
    /// the same clamp under another client's eyes is not.
    #[test]
    fn your_own_clamp_needs_no_explanation() {
        let offers = [offer(1, 120, 40)];
        assert_eq!(
            clamped_by(120, 40, &offers, &clients(), Some(1)),
            Clamp::Unattributed
        );
        assert_eq!(
            clamped_by(120, 40, &offers, &clients(), Some(2)),
            Clamp::SizedBy(0)
        );
    }

    /// An attachment no roster client names is REPORTED, not dropped — both when its token matches
    /// an unlabelled client and when it matches no client at all.
    #[test]
    fn an_unnameable_contributor_is_reported_rather_than_dropped() {
        assert_eq!(
            clamped_by(120, 40, &[offer(3, 120, 40)], &clients(), None),
            Clamp::SizedByUnnamed,
            "token 3 is a roster client with no label"
        );
        assert_eq!(
            clamped_by(120, 40, &[offer(9, 120, 40)], &clients(), None),
            Clamp::SizedByUnnamed,
            "token 9 names no roster client at all"
        );
    }

    /// Every verdict carries its code, and only the named one carries a position — the pair a door
    /// crosses, and the one mistake a two-field verdict invites.
    #[test]
    fn each_verdict_carries_its_code_and_only_one_a_position() {
        for (verdict, code, position) in [
            (Clamp::Absent, 0, None),
            (Clamp::Unattributed, 1, None),
            (Clamp::SizedBy(4), 2, Some(4)),
            (Clamp::SizedByUnnamed, 3, None),
        ] {
            assert_eq!((verdict.code(), verdict.position()), (code, position));
        }
    }

    /// A code and a label rebuild the attribution the join meant, and a byte this build cannot name
    /// attributes nothing rather than inventing an author.
    #[test]
    fn a_code_and_a_label_rebuild_the_attribution() {
        assert_eq!(
            Attribution::from_code(2, "mac-studio"),
            Attribution::Named("mac-studio")
        );
        assert_eq!(Attribution::from_code(3, "ignored"), Attribution::Unnamed);
        for code in [0_u8, 1, 4, 200] {
            assert_eq!(Attribution::from_code(code, "mac-studio"), Attribution::Nobody);
        }
    }

    /// The sentence, verbatim — the readout `docs/45` §8.3 rule 7 names and the deleted Swift suite
    /// measured.
    #[test]
    fn the_readout_reads_exactly_as_the_rule_states_it() {
        assert_eq!(
            text(120, 40, Attribution::Named("MacBook Pro")).as_deref(),
            Some("120×40 · sized by MacBook Pro")
        );
        assert_eq!(text(120, 40, Attribution::Nobody).as_deref(), Some("120×40"));
        assert_eq!(
            text(120, 40, Attribution::Unnamed).as_deref(),
            Some("120×40 · sized by another client")
        );
        assert_eq!(UNNAMED_CONTRIBUTOR, "another client");
    }

    /// An empty label is the unnamed case, not a sentence that trails off.
    #[test]
    fn an_empty_label_prints_the_unnamed_word() {
        assert_eq!(
            text(1, 1, Attribution::Named("")).as_deref(),
            Some("1×1 · sized by another client")
        );
    }
}
