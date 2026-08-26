//! The half of the two PATH verbs a test can hold: what is refused, and what reaches the Finder.
//!
//! `HostPathActionPerformer`'s own header says the Swift shim is "compiled + code-reviewed ONLY",
//! because `NSWorkspace` needs a window server and a Launch Services session. That is still true of
//! the door — `slopdesk_apple_app::open_path` has exactly one test and it is the refusal — but it
//! was never true of the validator, which is where every hostile argument lands. This suite is that
//! validator, driven against a door that records rather than opens.

#![expect(
    clippy::unwrap_used,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]

use std::sync::{Mutex, PoisonError};

use slopdesk_hostserver::pathaction::{OpensPaths, PathActions};
use slopdesk_hostsession::{MetadataPerformer, MetadataRequest};
use slopdesk_muxsession::metadata_admission::Performer;
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;

/// A Finder that opens nothing and remembers everything.
#[derive(Debug)]
struct Ledger {
    opens: Mutex<Vec<String>>,
    reveals: Mutex<Vec<String>>,
    accepts: bool,
}

impl Ledger {
    /// A door Launch Services always takes.
    const fn willing() -> Self {
        Self {
            opens: Mutex::new(Vec::new()),
            reveals: Mutex::new(Vec::new()),
            accepts: true,
        }
    }

    /// A door Launch Services always declines — the arm the Swift maps to `error`.
    const fn unwilling() -> Self {
        Self {
            opens: Mutex::new(Vec::new()),
            reveals: Mutex::new(Vec::new()),
            accepts: false,
        }
    }

    fn opened(&self) -> Vec<String> {
        self.opens.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn revealed(&self) -> Vec<String> {
        self.reveals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl OpensPaths for &Ledger {
    fn open(&self, path: &str) -> bool {
        self.opens
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(path.to_owned());
        self.accepts
    }

    fn reveal(&self, path: &str) {
        self.reveals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(path.to_owned());
    }
}

/// One request at `verb` carrying `argument`, answered.
fn ask<D: OpensPaths>(performer: &PathActions<D>, verb: MetadataVerb, argument: &str) -> u8 {
    let answer = performer.perform(&MetadataRequest {
        request_id: 7,
        verb: verb.as_byte(),
        payload: argument.as_bytes(),
        performer: Performer::Path,
        master_fd: -1,
        shell_pid: 0,
    });
    assert!(
        answer.payload.is_empty(),
        "these two verbs answer a status and nothing else"
    );
    answer.status
}

/// A directory that certainly exists, and a home that certainly does not resolve to it by accident.
fn temp_dir() -> String {
    std::env::temp_dir()
        .to_string_lossy()
        .trim_end_matches('/')
        .to_owned()
}

#[test]
fn an_absolute_path_that_exists_reaches_the_finder_and_answers_ok() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    let dir = temp_dir();
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, &dir),
        MetadataStatus::Ok.as_byte()
    );
    assert_eq!(
        door.opened(),
        vec![dir],
        "the path reaches the door exactly as resolved"
    );
}

#[test]
fn a_reveal_answers_ok_on_the_existence_check_rather_than_on_the_frameworks_word() {
    let door = Ledger::unwilling();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    let dir = temp_dir();
    assert_eq!(
        ask(&performer, MetadataVerb::RevealPath, &dir),
        MetadataStatus::Ok.as_byte(),
        "`activateFileViewerSelectingURLs:` is void — there is no refusal to report, so a door that would \
         have declined an OPEN changes nothing here",
    );
    assert_eq!(door.revealed(), vec![dir]);
    assert!(door.opened().is_empty(), "a reveal must not also open");
}

#[test]
fn an_open_the_framework_declines_is_an_error_rather_than_a_silent_ok() {
    let door = Ledger::unwilling();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, &temp_dir()),
        MetadataStatus::Error.as_byte(),
    );
}

#[test]
fn a_relative_path_is_malformed_and_never_reaches_the_door() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    for argument in ["relative/path", "", "./here", ".."] {
        assert_eq!(
            ask(&performer, MetadataVerb::OpenPath, argument),
            MetadataStatus::Error.as_byte(),
            "{argument:?} is not an absolute host path",
        );
    }
    assert!(
        door.opened().is_empty(),
        "a refused argument must never reach Launch Services"
    );
}

#[test]
fn an_absolute_path_that_does_not_exist_is_not_found_rather_than_an_error() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    assert_eq!(
        ask(
            &performer,
            MetadataVerb::OpenPath,
            "/nonexistent/slopdesk/never-was"
        ),
        MetadataStatus::NotFound.as_byte(),
        "the two refusals are distinguishable on the wire, and a client renders them differently",
    );
    assert!(door.opened().is_empty());
}

#[test]
fn a_non_utf8_argument_is_refused_without_a_trap() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    let answer = performer.perform(&MetadataRequest {
        request_id: 7,
        verb: MetadataVerb::OpenPath.as_byte(),
        payload: &[0x2F, 0xFF, 0xFE],
        performer: Performer::Path,
        master_fd: -1,
        shell_pid: 0,
    });
    assert_eq!(answer.status, MetadataStatus::Error.as_byte());
    assert!(door.opened().is_empty());
}

#[test]
fn a_leading_tilde_expands_against_the_hosts_home_and_not_the_clients() {
    let home = temp_dir();
    let door = Ledger::willing();
    let performer = PathActions::new(&door, home.clone());
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, "~"),
        MetadataStatus::Ok.as_byte()
    );
    assert_eq!(door.opened(), vec![home], "a bare `~` IS the home directory");
}

#[test]
fn a_tilde_path_expands_and_then_still_has_to_exist() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, temp_dir());
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, "~/nonexistent-slopdesk-probe"),
        MetadataStatus::NotFound.as_byte(),
        "expansion is not existence — the check runs on what the expansion produced",
    );
}

#[test]
fn a_tilde_naming_another_user_is_refused_rather_than_resolved() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, temp_dir());
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, "~root/Library"),
        MetadataStatus::Error.as_byte(),
        "`~user` is not expanded — it is refused, which is the closed answer and the one deliberate \
         difference from `expandingTildeInPath`",
    );
    assert!(door.opened().is_empty());
}

#[test]
fn dot_and_dot_dot_are_normalised_away_before_the_door_sees_the_path() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    let dir = temp_dir();
    let noisy = format!("{dir}/./../{}", dir.rsplit('/').next().unwrap());
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, &noisy),
        MetadataStatus::Ok.as_byte()
    );
    assert_eq!(
        door.opened(),
        vec![dir],
        "the door is handed a path a person can read in a log, not the one the client typed",
    );
}

#[test]
fn a_dot_dot_above_the_root_is_the_root() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, "/../../.."),
        MetadataStatus::Ok.as_byte()
    );
    assert_eq!(
        door.opened(),
        vec!["/".to_owned()],
        "every filesystem resolves it there and so does `standardizingPath`",
    );
}

#[test]
fn there_is_no_confinement_and_a_path_outside_any_pane_cwd_still_opens() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, "/usr/bin"),
        MetadataStatus::Ok.as_byte(),
        "open/reveal return a status byte and no host bytes, so they take any absolute path — which is what \
         makes ⌘-clicking a path outside the pane's cwd work at all",
    );
}

#[test]
fn a_verb_this_performer_does_not_own_is_answered_unsupported_rather_than_guessed_at() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    for verb in [
        MetadataVerb::Cwd,
        MetadataVerb::SetClipboard,
        MetadataVerb::HostInfo,
    ] {
        assert_eq!(
            ask(&performer, verb, "/tmp"),
            MetadataStatus::UnsupportedVerb.as_byte(),
            "{verb:?} belongs to another performer",
        );
    }
    assert!(door.opened().is_empty());
    assert!(door.revealed().is_empty());
}

#[test]
fn an_unknown_future_verb_byte_is_answered_rather_than_dropped() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, "/Users/nobody".to_owned());
    let answer = performer.perform(&MetadataRequest {
        request_id: 7,
        verb: 0xFE,
        payload: b"/tmp",
        performer: Performer::Path,
        master_fd: -1,
        shell_pid: 0,
    });
    assert_eq!(
        answer.status,
        MetadataStatus::UnsupportedVerb.as_byte(),
        "the host ALWAYS replies, or the client's pending-request registry waits out its timeout",
    );
}

#[test]
fn a_host_with_no_home_refuses_every_tilde_rather_than_expanding_to_the_root() {
    let door = Ledger::willing();
    let performer = PathActions::new(&door, String::new());
    assert_eq!(
        ask(&performer, MetadataVerb::OpenPath, "~/Documents"),
        MetadataStatus::Error.as_byte(),
        "an empty home would make `~/x` expand to `/x` — an ABSOLUTE path the rest of the validator would \
         accept, silently rereading the client's home as the root's. The tilde is refused instead: the \
         honest answer for a daemon that cannot say where home is",
    );
    assert!(door.opened().is_empty());
}
