//! One pane's latches as the workspace document's two RECORDS — the liveness row every client
//! renders, and the roster row that says who is holding the pane at what size.
//!
//! ## The composing is here because the DECISIONS are here
//!
//! Nothing in this module reads a pane. [`slopdesk_hostsession::PaneLatches`] is the reading, taken
//! in one lock acquisition by the pane itself; what is left is four decisions that have to be made
//! the same way by the host and by the client's mirror, and every one of them has been made wrong
//! at least once:
//!
//! 1. **`None` and `Some("")` are different titles.** `None` is "this pane has never asserted one";
//!    `Some("")` is "the agent that owned the title handed it back", which is what an empty type-21
//!    means on the wire. Collapsing them loses the retirement and the pane keeps a dead agent's
//!    name.
//! 2. **A dead pane keeps its title as a LABEL and is never FRESH.** Rule 4 of `docs/45` §4.4, and
//!    the rule is [`title_is_fresh`]'s rather than this module's — the client's mirror asks the
//!    same function, which is the whole point of the field crossing the wire as a VERDICT instead
//!    of as two stamps the two ends compare for themselves.
//! 3. **A pane whose detector never saw an agent publishes no agent record at all.** State 0 with
//!    kind 0 is `ClaudeStatus::None`, and a row of zeroes renders as an agent resting rather than
//!    as no agent.
//! 4. **`liveness` is the SERVER's fact, so it rides in.** Whether a pane is attached, detached or
//!    dead is about the session maps, not about the PTY — a pane cannot see the table holding it,
//!    and a guess renders a dead pane fake-live.
//!
//! ## `last_activity_ms` is deliberately zero
//!
//! The record has the field and nothing produces it. The only place to stamp it is the PTY read
//! path — a wall-clock read per chunk, on the hot path, for a field nothing reads yet. Zero is the
//! record's own "never observed", so the absence is already expressible; it stays that way until
//! something needs it. Carried across from the Swift verbatim, reason and all.

use slopdesk_hostsession::PaneLatches;
use slopdesk_muxsession::fanout::SubscriberId;
use slopdesk_muxsession::resize_fold::Attachment;
use slopdesk_wire::document::fields::{PaneLivenessState, title_is_fresh};
use slopdesk_wire::document::liveness::{AgentState, Grid, PaneLiveness, Progress};
use slopdesk_wire::message::RawUuid;
use slopdesk_wire::workspace::{WorkspaceRosterAttachment, WorkspaceRosterPane};

/// One pane's liveness row, from its latches and the server's own verdict about it.
///
/// `grid` is passed beside the latches rather than inside them because it is behind the PTY's lock
/// rather than the folds lock, and `slopdesk-hostsession` does not nest the two.
#[must_use]
pub fn liveness_record(
    pane_id: RawUuid,
    liveness: PaneLivenessState,
    latches: &PaneLatches,
    grid: Option<(u16, u16)>,
) -> PaneLiveness {
    PaneLiveness {
        pane_id,
        liveness,
        // Decision 1: never-observed and retired-by-the-agent stay distinct all the way to the wire.
        live_title: if latches.title_at.is_none() && latches.title.is_empty() {
            None
        } else {
            Some(latches.title.clone())
        },
        // Decision 2: the verdict crosses, not the two stamps — the client's mirror asks the same
        // function, so the two ends cannot drift apart by comparing differently.
        title_fresh: title_is_fresh(latches.title_at, latches.command_started_at, liveness),
        cwd: latches.cwd.clone(),
        project_key: latches.project_key.clone(),
        // `Some("")` is the poll's real "nothing holds the terminal" and reads as absent here: the
        // record's field is a program NAME, and the empty one names nothing.
        foreground_process: latches
            .foreground
            .as_deref()
            .filter(|name| !name.is_empty())
            .map(String::from),
        running_command: latches.running_command.clone(),
        // Decision 3: no agent at all publishes no agent record, rather than a row of zeroes.
        agent_state: if latches.agent_state == 0 && latches.agent_kind == 0 {
            None
        } else {
            Some(AgentState {
                state: latches.agent_state,
                kind: latches.agent_kind,
            })
        },
        agent_label: latches.agent_label.clone(),
        agent_intent: latches.agent_intent.clone(),
        progress: latches
            .progress
            .map(|(state, percent)| Progress { state, percent }),
        command_running: latches.command_started_at.is_some(),
        last_exit_code: latches.last_exit_code,
        last_duration_ms: latches.last_duration_ms,
        grid: grid.map(|(rows, cols)| Grid { cols, rows }),
        completion_epoch: latches.completion_epoch,
        // See the module note: the field exists, nothing produces it, and zero already says so.
        last_activity_ms: 0,
    }
}

/// One pane's roster row: the grid the size fold RESOLVED, and one entry per watching device.
///
/// `identity` answers which client an attachment belongs to. The join is legitimately partial —
/// `slopdesk-client` opens no workspace channel at all, so it has no instance id to be named by —
/// and an unnamed attachment still COUNTS: it is a real client holding a real pane at a real size,
/// so it is published under the all-zero id rather than dropped. Dropping it would make the pane
/// look unheld and let a reader conclude nobody is sizing it.
#[must_use]
pub fn roster_record(
    pane_id: RawUuid,
    resolved: (u16, u16),
    attachments: &[Attachment],
    identity: impl Fn(SubscriberId) -> Option<RawUuid>,
) -> WorkspaceRosterPane {
    WorkspaceRosterPane {
        pane_id,
        resolved_cols: resolved.0,
        resolved_rows: resolved.1,
        attachments: attachments
            .iter()
            .map(|attachment| {
                WorkspaceRosterAttachment {
                    client_instance_id: identity(attachment.subscriber).unwrap_or_default(),
                    contributes: attachment.contributes,
                    cols: attachment.cols,
                    rows: attachment.rows,
                }
            })
            .collect(),
    }
}

/// The order a roster is published in: by pane id, ascending.
///
/// Deterministic rather than whatever the tables happened to walk in, and that is the whole reason
/// it is a function: the roster is broadcast WHOLE every time and diffed by the receiver, so a
/// reshuffle between two identical rosters reads as a change on every device.
pub fn sort_roster(records: &mut [WorkspaceRosterPane]) {
    records.sort_by_key(|record| record.pane_id);
}

#[cfg(test)]
mod tests {
    use slopdesk_hostsession::PaneLatches;
    use slopdesk_muxsession::resize_fold::Attachment;
    use slopdesk_wire::document::fields::PaneLivenessState;

    use super::{liveness_record, roster_record, sort_roster};

    const PANE: [u8; 16] = [7; 16];
    const CLIENT: [u8; 16] = [9; 16];

    fn titled(title: &str, at: Option<f64>) -> PaneLatches {
        PaneLatches {
            title: String::from(title),
            title_at: at,
            ..PaneLatches::default()
        }
    }

    #[test]
    fn a_pane_that_never_titled_itself_has_no_title_rather_than_an_empty_one() {
        let record = liveness_record(PANE, PaneLivenessState::Attached, &titled("", None), None);
        assert_eq!(record.live_title, None);
    }

    #[test]
    fn a_title_the_agent_handed_back_is_empty_rather_than_absent() {
        // The stamp is what tells the two apart: a retirement drops the stamp and the text, and an
        // empty type-21 is this codebase's retirement signal — so the record has to be able to say
        // it. This is the shape the fold leaves after `retire_title`, with a title once observed.
        let record = liveness_record(PANE, PaneLivenessState::Attached, &titled("", Some(12.0)), None);
        assert_eq!(record.live_title, Some(String::new()));
    }

    #[test]
    fn a_dead_pane_keeps_its_title_and_loses_its_freshness() {
        let latches = titled("nvim", Some(100.0));
        let live = liveness_record(PANE, PaneLivenessState::Attached, &latches, None);
        let dead = liveness_record(PANE, PaneLivenessState::Dead, &latches, None);
        assert!(live.title_fresh, "a live titled pane with no open block is fresh");
        assert_eq!(dead.live_title, Some(String::from("nvim")), "the label survives");
        assert!(
            !dead.title_fresh,
            "rule 4 of §4.4: a dead pane has no fresh title"
        );
    }

    #[test]
    fn a_title_stamped_before_the_running_command_is_stale() {
        let latches = PaneLatches {
            title: String::from("vi ."),
            title_at: Some(10.0),
            command_started_at: Some(20.0),
            ..PaneLatches::default()
        };
        let record = liveness_record(PANE, PaneLivenessState::Attached, &latches, None);
        assert!(!record.title_fresh);
        assert!(record.command_running, "an open block is what makes it stale");
    }

    #[test]
    fn a_pane_with_no_agent_publishes_no_agent_record() {
        let record = liveness_record(PANE, PaneLivenessState::Attached, &PaneLatches::default(), None);
        assert_eq!(record.agent_state, None);
    }

    #[test]
    fn an_agent_that_has_spoken_publishes_its_pair() {
        let latches = PaneLatches {
            agent_state: 2,
            agent_kind: 1,
            agent_label: Some(String::from("waiting")),
            agent_intent: Some(String::from("port the reducer")),
            ..PaneLatches::default()
        };
        let record = liveness_record(PANE, PaneLivenessState::Attached, &latches, None);
        assert_eq!(
            record.agent_state.map(|state| (state.state, state.kind)),
            Some((2, 1))
        );
        assert_eq!(record.agent_label.as_deref(), Some("waiting"));
        assert_eq!(record.agent_intent.as_deref(), Some("port the reducer"));
    }

    #[test]
    fn nothing_in_the_foreground_reads_as_no_program_rather_than_an_empty_name() {
        let sampled = PaneLatches {
            foreground: Some(String::new()),
            ..PaneLatches::default()
        };
        assert_eq!(
            liveness_record(PANE, PaneLivenessState::Attached, &sampled, None).foreground_process,
            None
        );
        let running = PaneLatches {
            foreground: Some(String::from("claude")),
            ..PaneLatches::default()
        };
        assert_eq!(
            liveness_record(PANE, PaneLivenessState::Attached, &running, None).foreground_process,
            Some(String::from("claude"))
        );
    }

    #[test]
    fn the_grid_crosses_as_columns_and_rows_in_that_order() {
        // The pane answers `(rows, cols)` and the record is `(cols, rows)`; a swap here would
        // letterbox every non-driving client against a transposed grid.
        let record = liveness_record(
            PANE,
            PaneLivenessState::Attached,
            &PaneLatches::default(),
            Some((24, 80)),
        );
        assert_eq!(record.grid.map(|grid| (grid.cols, grid.rows)), Some((80, 24)));
    }

    #[test]
    fn a_pane_with_no_activity_stamp_says_never_rather_than_now() {
        let record = liveness_record(PANE, PaneLivenessState::Attached, &PaneLatches::default(), None);
        assert_eq!(record.last_activity_ms, 0);
    }

    #[test]
    fn an_attachment_the_join_cannot_name_still_counts() {
        let attachments = [
            Attachment {
                subscriber: 1,
                contributes: true,
                cols: 100,
                rows: 40,
            },
            Attachment {
                subscriber: 2,
                contributes: false,
                cols: 50,
                rows: 20,
            },
        ];
        let record = roster_record(PANE, (100, 40), &attachments, |subscriber| {
            (subscriber == 1).then_some(CLIENT)
        });
        assert_eq!(
            record.attachments.len(),
            2,
            "the unnamed one is published, not dropped"
        );
        assert_eq!(
            record.attachments.first().map(|entry| entry.client_instance_id),
            Some(CLIENT)
        );
        assert_eq!(
            record.attachments.get(1).map(|entry| entry.client_instance_id),
            Some([0; 16]),
            "an unnamed client rides the all-zero id"
        );
        assert_eq!(
            record.attachments.get(1).map(|entry| entry.contributes),
            Some(false)
        );
    }

    #[test]
    fn a_pane_nobody_is_watching_keeps_its_size_and_lists_nobody() {
        let record = roster_record(PANE, (80, 24), &[], |_| None);
        assert_eq!((record.resolved_cols, record.resolved_rows), (80, 24));
        assert!(record.attachments.is_empty());
    }

    #[test]
    fn the_roster_is_published_in_pane_order() {
        let mut records = [
            roster_record([3; 16], (80, 24), &[], |_| None),
            roster_record([1; 16], (80, 24), &[], |_| None),
            roster_record([2; 16], (80, 24), &[], |_| None),
        ];
        sort_roster(&mut records);
        assert_eq!(
            records.map(|record| record.pane_id[0]),
            [1, 2, 3],
            "a reshuffle would read as a change on every device"
        );
    }
}
