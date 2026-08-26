//! Between what the shell SAID and what a client is TOLD.
//!
//! `slopdesk_superwire`'s header says the two vocabularies are deliberately apart: a `SniffEvent`
//! is what superd's pump found in the bytes, a [`WireMessage`] is what a peer receives, and they
//! are the same thing for a title and are not for a cwd (host-gated, published only as a resolved
//! project key) or a notification (dropped while an agent's hook already banners the edge). This
//! module is the join, in two halves that must not be confused with each other:
//!
//! - **Up** — an event batch becomes a [`Fact`] batch, which is what
//!   [`Truths::ingest_sniffed`](slopdesk_muxsession::truths::Truths::ingest_sniffed) folds. Every
//!   DECISION lives in that fold; nothing here decides.
//! - **Down** — a verdict names a fact by index and this builds the message that fact spells. Pure
//!   marshalling, and the fold has already withheld or suppressed whatever must not be built.
//!
//! ## Zero copy, and where the floor actually is
//!
//! A `Fact` BORROWS its text on purpose, and here the arena is the caller's own event slice: the
//! sink is handed `&[SniffEvent]` and holds it for the whole fold, so a title crosses as a `&str`
//! into the `String` superd's reply already allocated. A chunk carrying ten titles allocates the
//! fact vector and nothing else. The two truths that OUTLIVE the batch — the title and the running
//! command — are copied by the fold, which is where the copy belongs.
//!
//! ## Facts are not events, and the index is the fact's
//!
//! A progress body that will not parse and a kind this build has no name for are dropped on the way
//! up, so the fact vector is SHORTER than the event slice and a verdict's `fact` field indexes the
//! former. Reading it against the latter is the one mistake this shape allows, which is why nothing
//! outside this module ever sees both.

use slopdesk_muxsession::truths::{Fact, Kind, Reassert, Scalars, Truths};
use slopdesk_superwire::blockwire::{BlockEvent, BlockMeta, SyntheticProgress};
use slopdesk_superwire::sniffwire::{CommandStatus as SniffedStatus, SniffEvent};
use slopdesk_wire::message::{CommandStatus, WireMessage};
use slopdesk_wire::osc::parse_progress;

/// One block fact, beside the metadata it was built from.
///
/// The metadata rides along rather than being reconstructed out of [`Scalars`] on the way down: a
/// type-28 is built by ONE function shared with the reattach backfill, precisely so that a re-sent
/// block and a live one cannot disagree about a field. Rebuilding it here would be the second
/// spelling that has to agree forever.
#[derive(Debug, Clone, Copy)]
pub(crate) struct BlockRow<'batch> {
    /// What the fold is given.
    pub(crate) fact: Fact<'batch>,
    /// The block this fact came from, `None` for a synthetic progress badge.
    pub(crate) meta: Option<&'batch BlockMeta>,
}

/// One sniffed batch as the facts the fold takes.
///
/// Dropped members are dropped HERE rather than inside the fold, for the reason
/// `slopdesk_superwire` gives for keeping them in the event vocabulary at all: an unknown kind is
/// kept on the reading side so a skew is COUNTABLE, and acted on nowhere. This is the nowhere.
pub(crate) fn sniffed_facts(events: &[SniffEvent]) -> Vec<Fact<'_>> {
    let mut facts = Vec::with_capacity(events.len());
    for event in events {
        match *event {
            SniffEvent::Title(ref title) => facts.push(Fact::text(Kind::Title, title)),
            SniffEvent::Bell => facts.push(Fact::bare(Kind::Bell)),
            SniffEvent::Status(SniffedStatus::Running) => {
                facts.push(Fact::bare(Kind::CommandRunning));
            },
            SniffEvent::Status(SniffedStatus::Idle {
                exit_code,
                duration_ms,
            }) => {
                facts.push(Fact {
                    kind: Kind::CommandIdle,
                    primary: "",
                    secondary: "",
                    scalars: Scalars {
                        exit_code,
                        duration_ms: Some(duration_ms),
                        ..Scalars::new()
                    },
                });
            },
            SniffEvent::Cwd(ref path) => facts.push(Fact::text(Kind::Cwd, path)),
            SniffEvent::Notification { ref title, ref body } => {
                facts.push(Fact {
                    kind: Kind::Notification,
                    primary: title,
                    secondary: body,
                    scalars: Scalars::new(),
                });
            },
            // The OSC 9;4 grammar belongs to `slopdesk_wire::osc`, which owns it for the encoder
            // too. A body that will not parse is dropped rather than promoted: it was progress
            // either way, never a notification.
            SniffEvent::ProgressBody(ref body) => {
                if let Some(update) = parse_progress(body) {
                    facts.push(Fact {
                        kind: Kind::Progress,
                        primary: "",
                        secondary: "",
                        scalars: Scalars {
                            progress_state: update.state.to_wire(),
                            progress_percent: update.percent,
                            ..Scalars::new()
                        },
                    });
                }
            },
            SniffEvent::Unknown { .. } => {},
        }
    }
    facts
}

/// One block batch as the facts the fold takes, each beside its metadata.
pub(crate) fn block_rows(events: &[BlockEvent]) -> Vec<BlockRow<'_>> {
    let mut rows = Vec::with_capacity(events.len());
    for event in events {
        match *event {
            BlockEvent::Meta(ref meta) => {
                rows.push(BlockRow {
                    fact: Fact {
                        kind: Kind::Block,
                        primary: &meta.command_text,
                        secondary: "",
                        scalars: Scalars {
                            exit_code: meta.exit_code,
                            duration_ms: meta.duration_ms,
                            index: meta.index,
                            output_len: meta.output_len,
                            prompt_ordinal: meta.prompt_ordinal,
                            complete: meta.complete,
                            ..Scalars::new()
                        },
                    },
                    meta: Some(meta),
                });
            },
            // A synthetic badge is a second source of the SAME reattach truth, so it latches
            // through the progress door the sniffed one does.
            BlockEvent::Progress(state) => {
                rows.push(BlockRow {
                    fact: Fact {
                        kind: Kind::Progress,
                        primary: "",
                        secondary: "",
                        scalars: Scalars {
                            progress_state: synthetic_state(state),
                            ..Scalars::new()
                        },
                    },
                    meta: None,
                });
            },
            BlockEvent::Unknown { .. } => {},
        }
    }
    rows
}

/// A synthetic badge as the OSC 9;4 state byte it stands for.
const fn synthetic_state(state: SyntheticProgress) -> u8 {
    match state {
        SyntheticProgress::Indeterminate => slopdesk_wire::osc::ProgressState::Indeterminate.to_wire(),
        SyntheticProgress::Clear => slopdesk_wire::osc::ProgressState::Clear.to_wire(),
    }
}

/// One fact as the message its kind spells — the marshalling half, and only that.
///
/// `None` for a title-less title, which is the one shape a fact can carry that has no message:
/// every other absence was decided by the fold, which answered no verdict at all for it.
///
/// A [`Kind::Block`] fact has no message here on purpose — a block's type-28 is
/// [`block_message`]'s, built from the metadata rather than from the scalars.
pub(crate) fn sniffed_message(fact: &Fact<'_>) -> Option<WireMessage> {
    match fact.kind {
        Kind::Title => Some(WireMessage::Title(String::from(fact.primary))),
        Kind::Bell => Some(WireMessage::Bell),
        Kind::CommandRunning => Some(WireMessage::CommandStatus(CommandStatus::Running)),
        Kind::CommandIdle => {
            Some(WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: fact.scalars.exit_code,
                duration_ms: fact.scalars.duration_ms.unwrap_or(0),
            }))
        },
        Kind::Cwd => Some(WireMessage::Cwd(String::from(fact.primary))),
        Kind::Notification => {
            Some(WireMessage::Notification {
                title: String::from(fact.primary),
                body: String::from(fact.secondary),
            })
        },
        Kind::Progress => {
            Some(WireMessage::Progress {
                state: fact.scalars.progress_state,
                percent: fact.scalars.progress_percent,
            })
        },
        Kind::Block => None,
    }
}

/// One block's metadata as its type-28.
///
/// Shared by the live fold and the reattach backfill, which receive the same value from superd
/// precisely so this can be one function.
pub(crate) fn block_message(meta: &BlockMeta) -> WireMessage {
    WireMessage::CommandBlock {
        index: meta.index,
        exit_code: meta.exit_code,
        duration_ms: meta.duration_ms,
        complete: meta.complete,
        output_len: meta.output_len,
        command_text: meta.command_text.clone(),
        prompt_ordinal: meta.prompt_ordinal,
    }
}

/// One re-assert entry as the message it spells, read out of the truths it names.
///
/// The DOWN half again, and for the same reason it is here rather than in `slopdesk-muxsession`:
/// that crate answers WHICH truths a joiner is owed and in what order, and deliberately keeps
/// almost no edge to the protocol. Turning each into a frame is marshalling, and marshalling lives
/// with the wire.
///
/// `None` for an entry whose truth vanished between the ladder being built and this being called.
/// The ladder and the read happen inside one acquisition of the fold lock in practice, so it is the
/// unreachable arm — but a fabricated default here would publish a truth the pane does not hold,
/// which is worse than sending one message fewer.
pub(crate) fn reassert_message(truths: &Truths, entry: Reassert) -> Option<WireMessage> {
    match entry {
        // Only the RUNNING case, and deliberately: idle IS the client's reconnect reset state, and a
        // synthetic idle would fabricate a `lastCommand` and a completion edge for a command that
        // never finished.
        Reassert::CommandRunning => {
            truths
                .command_running_since()
                .map(|_| WireMessage::CommandStatus(CommandStatus::Running))
        },
        Reassert::Progress => {
            truths
                .progress()
                .map(|(state, percent)| WireMessage::Progress { state, percent })
        },
        Reassert::Cwd => truths.cwd().map(|cwd| WireMessage::Cwd(String::from(cwd))),
        Reassert::ProjectKey => {
            truths
                .project_key()
                .map(|key| WireMessage::ProjectKey(String::from(key)))
        },
        Reassert::Title => {
            let title = truths.title();
            (!title.is_empty()).then(|| WireMessage::Title(String::from(title)))
        },
    }
}

/// One block row as the message it spells: the metadata's type-28, or the badge's progress.
pub(crate) fn block_row_message(row: &BlockRow<'_>) -> Option<WireMessage> {
    row.meta
        .map_or_else(|| sniffed_message(&row.fact), |meta| Some(block_message(meta)))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::panic,
        reason = "an out-of-range index in a fixture IS the failure report — a fallback here would let the \
                  fold drop a fact and still read as a pass"
    )]

    use slopdesk_muxsession::truths::{Fact, Kind, Stamps, Truths};
    use slopdesk_superwire::blockwire::{BlockEvent, BlockMeta, SyntheticProgress};
    use slopdesk_superwire::sniffwire::{CommandStatus as SniffedStatus, SniffEvent};
    use slopdesk_wire::message::{CommandStatus, WireMessage};

    use super::{block_row_message, block_rows, reassert_message, sniffed_facts, sniffed_message};

    /// A title's text is BORROWED out of the event, not copied on the way in. Pointer identity is
    /// the only way to state that, and it is the property the hot path is built on.
    #[test]
    fn a_title_crosses_by_reference() {
        let events = vec![SniffEvent::Title(String::from("build ✳"))];
        let facts = sniffed_facts(&events);
        let SniffEvent::Title(ref source) = events[0] else {
            panic!("the event under test is a title");
        };
        assert_eq!(facts.len(), 1);
        assert!(
            std::ptr::eq(facts[0].primary.as_ptr(), source.as_ptr()),
            "the fact copied the title instead of borrowing it",
        );
    }

    /// An unparseable progress body and an unknown kind both vanish, so the fact vector is shorter
    /// than the event slice and a verdict index means the FACT's position.
    #[test]
    fn undecodable_members_leave_no_fact_behind() {
        let events = vec![
            SniffEvent::ProgressBody(String::from("4;")),
            SniffEvent::Bell,
            SniffEvent::Unknown {
                kind: String::from("from-a-newer-superd"),
            },
            SniffEvent::ProgressBody(String::from("4;1;40")),
        ];
        let facts = sniffed_facts(&events);
        assert_eq!(facts.len(), 2);
        assert_eq!(facts[0].kind, Kind::Bell);
        assert_eq!(facts[1].kind, Kind::Progress);
        assert_eq!(facts[1].scalars.progress_percent, 40);
    }

    /// A `D` without a code still carries its duration — the code-less mark that closes the running
    /// latch and leaves the exit latch alone.
    #[test]
    fn a_codeless_idle_keeps_its_duration() {
        let events = vec![SniffEvent::Status(SniffedStatus::Idle {
            exit_code: None,
            duration_ms: 1_250,
        })];
        let facts = sniffed_facts(&events);
        assert_eq!(
            sniffed_message(&facts[0]),
            Some(WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: None,
                duration_ms: 1_250,
            })),
        );
    }

    /// A block's type-28 is built from the METADATA, so every field survives the round trip
    /// including the two the scalars would have had to re-derive.
    #[test]
    fn a_block_message_comes_from_its_metadata() {
        let events = vec![BlockEvent::Meta(BlockMeta {
            index: 7,
            exit_code: Some(1),
            duration_ms: Some(90),
            complete: true,
            output_len: 4_096,
            command_text: String::from("cargo test"),
            prompt_ordinal: 3,
        })];
        let rows = block_rows(&events);
        assert_eq!(
            block_row_message(&rows[0]),
            Some(WireMessage::CommandBlock {
                index: 7,
                exit_code: Some(1),
                duration_ms: Some(90),
                complete: true,
                output_len: 4_096,
                command_text: String::from("cargo test"),
                prompt_ordinal: 3,
            }),
        );
    }

    /// The arrival ladder is what a joining client is owed, and TITLE IS LAST — the client judges
    /// a title's freshness against the command-start stamp the head just republished, so a title
    /// that arrived first would lose that comparison for the rest of the session.
    #[test]
    fn the_arrival_ladder_ends_with_the_title() {
        let mut truths = Truths::new();
        let stamps = Stamps {
            reference: 100.0,
            uptime: 7.0,
        };
        truths.ingest_sniffed(
            &[
                Fact::bare(Kind::CommandRunning),
                Fact::text(Kind::Title, "cargo test"),
            ],
            stamps,
            false,
        );
        let ladder = truths
            .reestablish_head()
            .into_iter()
            .chain(truths.reestablish_tail())
            .filter_map(|entry| reassert_message(&truths, entry))
            .collect::<Vec<_>>();
        assert_eq!(ladder, vec![
            WireMessage::CommandStatus(CommandStatus::Running),
            WireMessage::Title(String::from("cargo test")),
        ]);
    }

    /// An idle pane owes an arriving client NOTHING. Idle is the client's own reconnect reset
    /// state, so a synthetic `.idle` would fabricate a `lastCommand` and a completion edge for
    /// a command that never finished — and the empty ladder is what keeps an ordinary
    /// reconnect's control stream byte-identical.
    #[test]
    fn an_idle_pane_owes_an_arriving_client_nothing() {
        let truths = Truths::new();
        assert!(truths.reestablish_head().is_empty());
        assert!(truths.reestablish_tail().is_empty());
    }

    /// A synthetic badge is a PROGRESS fact, which is what makes it latch the same reattach truth
    /// the sniffed OSC does rather than a parallel one.
    #[test]
    fn a_synthetic_badge_is_a_progress_fact() {
        let rows = block_rows(&[
            BlockEvent::Progress(SyntheticProgress::Indeterminate),
            BlockEvent::Progress(SyntheticProgress::Clear),
        ]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].fact.kind, Kind::Progress);
        assert_eq!(
            block_row_message(&rows[0]),
            Some(WireMessage::Progress { state: 3, percent: 0 }),
        );
        assert_eq!(
            block_row_message(&rows[1]),
            Some(WireMessage::Progress { state: 0, percent: 0 }),
        );
    }
}
