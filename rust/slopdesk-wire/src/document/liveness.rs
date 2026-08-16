//! Everything the host knows about one pane's RUNNING PROCESS, as a value.
//!
//! This is the record that answers "what is true about this pane right now?". The host already
//! derives every one of these facts, but publishes them only as EDGE-TRIGGERED events — so a client
//! that was not listening at the instant of an edge can never learn the fact and has no way to ask.
//! Collecting them into a value the host RETAINS is what makes the document askable.
//!
//! ## Liveness only
//!
//! The topology half of a pane — its kind, title, rename flag, video target and spawn directory —
//! is written by an intent and persisted. Those fields are deliberately absent here: this record is
//! derived from a live process and is never persisted, because restoring "a command is running" for
//! a process that no longer exists is exactly the fake-live render the document exists to prevent.
//!
//! ## Absent means default
//!
//! A field is emitted only when it carries a non-default value, with ONE exception: the liveness
//! state is always emitted, so the presence of a pane in the document is never ambiguous. `None`
//! (never observed) and `""` (retired) stay distinct — a zero-length value is first-class on this
//! wire, since an empty title is already the agent-title-ownership retirement signal.
//!
//! ## One value, not an encoder and a decoder
//!
//! Both ends need this: the host writes [`PaneLiveness::entries`] and the client reads
//! [`PaneLiveness::from_document`]. One round-trippable value beats an encoder and a decoder
//! maintained apart, and it buys a round-trip test with no PTY in sight.

use super::codec;
use super::fields::{PaneLivenessState, pane};
use super::state::{HostWorkspaceState, WorkspaceEntry, WorkspaceKey, WorkspaceObjectKind};
use crate::message::RawUuid;

/// The agent's urgency and its notification class.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AgentState {
    /// The urgency byte.
    pub state: u8,
    /// The notification class.
    pub kind: u8,
}

/// The progress state and percentage a shell reported.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Progress {
    /// The progress state byte.
    pub state: u8,
    /// The percentage, zero to a hundred.
    pub percent: u8,
}

/// The PTY grid, published so a client that is not contributing to the size fold letterboxes
/// correctly instead of guessing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Grid {
    /// Columns.
    pub cols: u16,
    /// Rows.
    pub rows: u16,
}

/// One pane's liveness facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneLiveness {
    /// The host-minted pane id — the mux session id, which is also the document object id.
    pub pane_id: RawUuid,
    /// How real the process is. Always emitted.
    pub liveness: PaneLivenessState,
    /// The title the shell last asserted. `None` is never observed; `Some("")` is retired by the
    /// agent, and the two are not the same thing.
    pub live_title: Option<String>,
    /// The host's verdict on whether that title still describes what is on screen.
    pub title_fresh: bool,
    /// The working directory.
    pub cwd: Option<String>,
    /// The project the directory belongs to.
    pub project_key: Option<String>,
    /// The foreground process's name.
    pub foreground_process: Option<String>,
    /// The host's own open command block.
    pub running_command: Option<String>,
    /// The agent's urgency and class.
    pub agent_state: Option<AgentState>,
    /// The agent's label.
    pub agent_label: Option<String>,
    /// What the agent says it is doing.
    pub agent_intent: Option<String>,
    /// The reported progress.
    pub progress: Option<Progress>,
    /// Whether a command is running right now.
    pub command_running: bool,
    /// The last command's exit code.
    pub last_exit_code: Option<i32>,
    /// How long the last command took, in milliseconds.
    pub last_duration_ms: Option<u32>,
    /// The PTY grid.
    pub grid: Option<Grid>,
    /// A monotone counter, bumped on every working-to-done edge.
    pub completion_epoch: u32,
    /// Milliseconds since the epoch at the last observed activity. Zero is never.
    pub last_activity_ms: i64,
}

impl PaneLiveness {
    /// A record for a pane, with every fact at its default.
    #[must_use]
    pub const fn new(pane_id: RawUuid, liveness: PaneLivenessState) -> Self {
        Self {
            pane_id,
            liveness,
            live_title: None,
            title_fresh: false,
            cwd: None,
            project_key: None,
            foreground_process: None,
            running_command: None,
            agent_state: None,
            agent_label: None,
            agent_intent: None,
            progress: None,
            command_running: false,
            last_exit_code: None,
            last_duration_ms: None,
            grid: None,
            completion_epoch: 0,
            last_activity_ms: 0,
        }
    }

    /// One of this pane's keys.
    const fn key(&self, field: u8) -> WorkspaceKey {
        WorkspaceKey::of(WorkspaceObjectKind::Pane, self.pane_id, field)
    }

    /// This record as document entries, in canonical field order.
    ///
    /// Only the LIVENESS fields are produced. A caller merging this into a document must therefore
    /// replace exactly these keys and leave the topology fields alone — which is what
    /// [`merge_pane_liveness`] does.
    #[must_use]
    pub fn entries(&self) -> Vec<WorkspaceEntry> {
        let mut out = Vec::new();
        let mut put = |field: u8, value: Option<Vec<u8>>| {
            if let Some(value) = value {
                out.push(WorkspaceEntry::new(
                    WorkspaceKey::of(WorkspaceObjectKind::Pane, self.pane_id, field),
                    value,
                ));
            }
        };
        let text =
            |value: Option<&String>| value.map(|text| codec::encode_string(text, codec::MAX_STRING_BYTES));
        put(pane::LIVE_TITLE, text(self.live_title.as_ref()));
        if self.title_fresh {
            put(pane::TITLE_FRESH, Some(codec::encode_bool(true)));
        }
        put(pane::CWD, text(self.cwd.as_ref()));
        put(pane::PROJECT_KEY, text(self.project_key.as_ref()));
        put(pane::FOREGROUND_PROCESS, text(self.foreground_process.as_ref()));
        put(pane::RUNNING_COMMAND, text(self.running_command.as_ref()));
        put(
            pane::AGENT_STATE,
            self.agent_state
                .map(|agent| codec::encode_u8_pair(agent.state, agent.kind)),
        );
        put(pane::AGENT_LABEL, text(self.agent_label.as_ref()));
        put(pane::AGENT_INTENT, text(self.agent_intent.as_ref()));
        put(
            pane::PROGRESS,
            self.progress
                .map(|progress| codec::encode_u8_pair(progress.state, progress.percent)),
        );
        if self.command_running {
            put(pane::COMMAND_RUNNING, Some(codec::encode_bool(true)));
        }
        put(pane::LAST_EXIT_CODE, self.last_exit_code.map(codec::encode_i32));
        put(
            pane::LAST_DURATION_MS,
            self.last_duration_ms.map(codec::encode_u32),
        );
        put(
            pane::GRID,
            self.grid.map(|grid| codec::encode_u16_pair(grid.cols, grid.rows)),
        );
        // ALWAYS emitted — this is the pane's existence marker.
        put(pane::LIVENESS, Some(codec::encode_u8(self.liveness.as_byte())));
        if self.completion_epoch != 0 {
            put(
                pane::COMPLETION_EPOCH,
                Some(codec::encode_u32(self.completion_epoch)),
            );
        }
        if self.last_activity_ms != 0 {
            put(
                pane::LAST_ACTIVITY_MS,
                Some(codec::encode_i64(self.last_activity_ms)),
            );
        }
        out
    }

    /// One pane's liveness record, read back out of a document.
    ///
    /// Every field decodes INDEPENDENTLY and a malformed one falls back to its default rather than
    /// failing the record: these bytes came off a socket, and one bad grid must not blank a pane's
    /// title. `None` only when the pane has no liveness entry at all — that is, when the document
    /// holds no such pane.
    #[must_use]
    pub fn from_document(pane_id: RawUuid, state: &HostWorkspaceState) -> Option<Self> {
        let value = |field: u8| state.get(&WorkspaceKey::of(WorkspaceObjectKind::Pane, pane_id, field));
        let text = |field: u8| value(field).and_then(codec::decode_string);
        let liveness = PaneLivenessState::from_byte(codec::decode_u8(value(pane::LIVENESS)?)?);
        Some(Self {
            pane_id,
            liveness,
            live_title: text(pane::LIVE_TITLE),
            title_fresh: value(pane::TITLE_FRESH)
                .and_then(codec::decode_bool)
                .unwrap_or(false),
            cwd: text(pane::CWD),
            project_key: text(pane::PROJECT_KEY),
            foreground_process: text(pane::FOREGROUND_PROCESS),
            running_command: text(pane::RUNNING_COMMAND),
            agent_state: value(pane::AGENT_STATE)
                .and_then(codec::decode_u8_pair)
                .map(|(state, kind)| AgentState { state, kind }),
            agent_label: text(pane::AGENT_LABEL),
            agent_intent: text(pane::AGENT_INTENT),
            progress: value(pane::PROGRESS)
                .and_then(codec::decode_u8_pair)
                .map(|(state, percent)| Progress { state, percent }),
            command_running: value(pane::COMMAND_RUNNING)
                .and_then(codec::decode_bool)
                .unwrap_or(false),
            last_exit_code: value(pane::LAST_EXIT_CODE).and_then(codec::decode_i32),
            last_duration_ms: value(pane::LAST_DURATION_MS).and_then(codec::decode_u32),
            grid: value(pane::GRID)
                .and_then(codec::decode_u16_pair)
                .map(|(cols, rows)| Grid { cols, rows }),
            completion_epoch: value(pane::COMPLETION_EPOCH)
                .and_then(codec::decode_u32)
                .unwrap_or(0),
            last_activity_ms: value(pane::LAST_ACTIVITY_MS)
                .and_then(codec::decode_i64)
                .unwrap_or(0),
        })
    }
}

/// Every LIVENESS field of a pane — what a merge clears before writing.
///
/// Clearing first is what makes a fact that STOPPED being true actually disappear, instead of an
/// agent's label latching after the agent exited.
pub const LIVENESS_FIELDS: [u8; 17] = [
    pane::LIVE_TITLE,
    pane::TITLE_FRESH,
    pane::CWD,
    pane::PROJECT_KEY,
    pane::FOREGROUND_PROCESS,
    pane::RUNNING_COMMAND,
    pane::AGENT_STATE,
    pane::AGENT_LABEL,
    pane::AGENT_INTENT,
    pane::PROGRESS,
    pane::COMMAND_RUNNING,
    pane::LAST_EXIT_CODE,
    pane::LAST_DURATION_MS,
    pane::GRID,
    pane::LIVENESS,
    pane::COMPLETION_EPOCH,
    pane::LAST_ACTIVITY_MS,
];

/// The other half of a pane's fields — what an INTENT writes and a host restart restores.
///
/// The two lists PARTITION the pane vocabulary and must keep doing so. A field in neither is
/// written by nobody and reaped by nobody; a field in both makes a liveness recapture silently
/// delete a persisted title.
pub const TOPOLOGY_FIELDS: [u8; 5] = [
    pane::KIND,
    pane::TITLE,
    pane::USER_RENAMED,
    pane::VIDEO_TARGET,
    pane::SPAWN_CWD,
];

/// Replaces one pane's LIVENESS fields wholesale, leaving its topology fields untouched.
///
/// Clear-then-write, not write-over: a fact that stopped being true has to disappear. Writing only
/// the fields the new record carries would latch the running command after the command finished and
/// the agent label after the agent exited — the same "edge published, value retained nowhere"
/// failure this document exists to fix, moved one layer up.
///
/// Returns whether anything actually changed. The caller uses that to decide whether the document's
/// version moves: a no-op recapture must never churn a version number, because every subscriber
/// pays for a bump.
pub fn merge_pane_liveness(state: &mut HostWorkspaceState, record: &PaneLiveness) -> bool {
    let next = record.entries();
    let mut changed = false;
    for field in LIVENESS_FIELDS {
        let key = record.key(field);
        let incoming = next
            .iter()
            .find(|entry| entry.key == key)
            .map(|entry| entry.value.clone());
        changed |= state.set_or_clear(key, incoming);
    }
    changed
}

/// Declares that one pane has NO process, keeping only what describes a PLACE.
///
/// The directory and its project survive because they are still true — a dead pane's directory has
/// not moved — and because the by-project sidebar would otherwise re-bucket every restored row the
/// moment its shell is gone. Everything else is a claim about a running process and would render
/// the pane fake-live.
pub fn mark_pane_dead(state: &mut HostWorkspaceState, pane_id: RawUuid) -> bool {
    let read = |field: u8| {
        state
            .get(&WorkspaceKey::of(WorkspaceObjectKind::Pane, pane_id, field))
            .and_then(codec::decode_string)
    };
    let mut record = PaneLiveness::new(pane_id, PaneLivenessState::Dead);
    record.cwd = read(pane::CWD);
    record.project_key = read(pane::PROJECT_KEY);
    merge_pane_liveness(state, &record)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a missing record is a test failure with nothing to return"
    )]

    use super::{
        AgentState, Grid, LIVENESS_FIELDS, PaneLiveness, PaneLivenessState, Progress, TOPOLOGY_FIELDS,
        mark_pane_dead, merge_pane_liveness,
    };
    use crate::document::codec;
    use crate::document::fields::pane;
    use crate::document::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind};
    use crate::message::RawUuid;

    const PANE: RawUuid = [7; 16];

    fn full_record() -> PaneLiveness {
        let mut record = PaneLiveness::new(PANE, PaneLivenessState::Detached);
        record.live_title = Some("vim README.md".to_owned());
        record.title_fresh = true;
        record.cwd = Some("/work/slop-desk".to_owned());
        record.project_key = Some("slop-desk".to_owned());
        record.foreground_process = Some("vim".to_owned());
        record.running_command = Some("make test".to_owned());
        record.agent_state = Some(AgentState { state: 2, kind: 1 });
        record.agent_label = Some("Claude".to_owned());
        record.agent_intent = Some("running the tests".to_owned());
        record.progress = Some(Progress {
            state: 1,
            percent: 42,
        });
        record.command_running = true;
        record.last_exit_code = Some(-1);
        record.last_duration_ms = Some(1234);
        record.grid = Some(Grid { cols: 120, rows: 40 });
        record.completion_epoch = 9;
        record.last_activity_ms = 1_700_000_000_000;
        record
    }

    fn document_of(record: &PaneLiveness) -> HostWorkspaceState {
        HostWorkspaceState::from_entries(record.entries())
    }

    #[test]
    fn a_full_record_round_trips_through_the_document() {
        let record = full_record();
        assert_eq!(
            PaneLiveness::from_document(PANE, &document_of(&record)),
            Some(record),
        );
    }

    #[test]
    fn a_default_record_emits_only_its_existence_marker() {
        let record = PaneLiveness::new(PANE, PaneLivenessState::Attached);
        let entries = record.entries();
        assert_eq!(
            entries.len(),
            1,
            "absent means default, so nothing else is written"
        );
        assert_eq!(entries.first().map(|entry| entry.key.field), Some(pane::LIVENESS));
        assert_eq!(
            PaneLiveness::from_document(PANE, &document_of(&record)),
            Some(record)
        );
    }

    #[test]
    fn an_empty_title_stays_distinct_from_a_missing_one() {
        let mut retired = PaneLiveness::new(PANE, PaneLivenessState::Attached);
        retired.live_title = Some(String::new());
        let read = PaneLiveness::from_document(PANE, &document_of(&retired));
        assert_eq!(
            read.and_then(|record| record.live_title),
            Some(String::new()),
            "an empty title is the agent's retirement signal, not an absence",
        );
    }

    #[test]
    fn a_pane_with_no_liveness_entry_is_not_in_the_document() {
        assert!(PaneLiveness::from_document(PANE, &HostWorkspaceState::new()).is_none());
    }

    #[test]
    fn one_malformed_field_never_costs_the_rest_of_the_record() {
        let mut state = document_of(&full_record());
        state.set(
            WorkspaceKey::of(WorkspaceObjectKind::Pane, PANE, pane::GRID),
            vec![0x01],
        );
        let Some(read) = PaneLiveness::from_document(PANE, &state) else {
            panic!("a bad grid must not fail the record");
        };
        assert_eq!(read.grid, None, "the malformed field falls back to its default");
        assert_eq!(read.live_title.as_deref(), Some("vim README.md"));
    }

    #[test]
    fn an_unknown_liveness_byte_reads_as_dead() {
        let mut state = HostWorkspaceState::new();
        state.set(
            WorkspaceKey::of(WorkspaceObjectKind::Pane, PANE, pane::LIVENESS),
            codec::encode_u8(200),
        );
        assert_eq!(
            PaneLiveness::from_document(PANE, &state).map(|record| record.liveness),
            Some(PaneLivenessState::Dead),
        );
    }

    #[test]
    fn a_merge_clears_a_fact_that_stopped_being_true() {
        let mut state = document_of(&full_record());
        let quiet = PaneLiveness::new(PANE, PaneLivenessState::Attached);
        assert!(merge_pane_liveness(&mut state, &quiet));
        let Some(read) = PaneLiveness::from_document(PANE, &state) else {
            panic!("the pane still exists");
        };
        assert_eq!(read.running_command, None, "the finished command must disappear");
        assert_eq!(read.agent_label, None);
        assert!(!read.command_running);
    }

    #[test]
    fn a_merge_leaves_the_topology_fields_alone() {
        let mut state = document_of(&full_record());
        let title_key = WorkspaceKey::of(WorkspaceObjectKind::Pane, PANE, pane::TITLE);
        state.set(title_key, codec::encode_string("Editor", codec::MAX_STRING_BYTES));
        merge_pane_liveness(&mut state, &PaneLiveness::new(PANE, PaneLivenessState::Attached));
        assert_eq!(
            state.get(&title_key).and_then(codec::decode_string).as_deref(),
            Some("Editor"),
            "a liveness recapture must never delete a persisted title",
        );
    }

    #[test]
    fn a_no_op_recapture_reports_no_change() {
        let record = full_record();
        let mut state = document_of(&record);
        assert!(
            !merge_pane_liveness(&mut state, &record),
            "an unchanged recapture must not churn the version every subscriber pays for",
        );
    }

    #[test]
    fn marking_a_pane_dead_keeps_the_place_and_drops_the_process() {
        let mut state = document_of(&full_record());
        assert!(mark_pane_dead(&mut state, PANE));
        let Some(read) = PaneLiveness::from_document(PANE, &state) else {
            panic!("a dead pane is still a pane");
        };
        assert_eq!(read.liveness, PaneLivenessState::Dead);
        assert_eq!(read.cwd.as_deref(), Some("/work/slop-desk"));
        assert_eq!(read.project_key.as_deref(), Some("slop-desk"));
        assert_eq!(read.running_command, None);
        assert_eq!(read.agent_state, None);
        assert!(!read.command_running);
    }

    #[test]
    fn the_two_field_lists_partition_the_pane_vocabulary() {
        let mut all: Vec<u8> = LIVENESS_FIELDS.into_iter().chain(TOPOLOGY_FIELDS).collect();
        all.sort_unstable();
        let expected: Vec<u8> = (0..=pane::SPAWN_CWD).collect();
        assert_eq!(
            all, expected,
            "a field in neither list is written by nobody; one in both deletes a persisted title",
        );
    }
}
