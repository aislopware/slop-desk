//! The metadata reducer, against a query door a test holds.
//!
//! The Swift's `MetadataResponseBuilderTests` is 534 lines and its centre of gravity is not the
//! happy path — it is the set of anchors that assert a REFUSED request never reached the query at
//! all. Those are carried over here one for one, because the failure they guard is a read of a file
//! outside the pane's subtree and it is silent: the answer looks like any other listing.
//!
//! Everything is a fake. There is no filesystem, no `git`, no `lsof` and no clock — the reducer
//! performs no IO by construction, so the only thing worth driving it against is a door that
//! records what it was asked.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_hostserver::metadata::{
    HostMetadata, HostQuerying, MAX_DIR_ENTRIES, MAX_OPAQUE_PAYLOAD_BYTES, PaneHandles,
};
use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest};
use slopdesk_muxsession::metadata_admission::{Performer, performer};
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{
    AgentSessionInfo, DirEntry, GitStatusPayload, HostVitals, decode_agent_session_list, decode_dir_listing,
    decode_git_status, decode_host_vitals,
};

// MARK: - The door a test holds

/// Every call the reducer made, in order, as `verb(argument)` strings.
type Ledger = Arc<Mutex<Vec<String>>>;

/// A query door that answers what it was told to and writes down what it was asked.
#[derive(Debug)]
struct Fake {
    asked: Ledger,
    cwd: Option<String>,
    processes: Vec<u8>,
    ports: Vec<u8>,
    status: GitStatusPayload,
    diff: Option<Vec<u8>>,
    entries: Option<Vec<DirEntry>>,
    sessions: Vec<AgentSessionInfo>,
    transcript: Option<Vec<u8>>,
    host_name: Option<String>,
    vitals: Option<HostVitals>,
}

impl Fake {
    /// A door that answers every verb, rooted at `/repo`.
    fn answering() -> Self {
        Self {
            asked: Ledger::default(),
            cwd: Some(String::from("/repo")),
            processes: vec![0, 1],
            ports: vec![0, 2],
            // `has_repo` is the codec's own gate: false and the encoder writes ONE zero byte and
            // drops every other field, so a fixture that spells a branch without it round-trips to
            // an empty one and asserts nothing.
            status: GitStatusPayload {
                has_repo: true,
                branch: String::from("main"),
                ..GitStatusPayload::default()
            },
            diff: Some(b"--- a\n+++ b\n".to_vec()),
            entries: Some(vec![DirEntry {
                is_dir: true,
                name: String::from("src"),
            }]),
            sessions: Vec::new(),
            transcript: Some(b"{}\n".to_vec()),
            host_name: Some(String::from("mac-studio.local")),
            vitals: Some(HostVitals {
                cpu_percent: 7,
                memory_percent: 42,
                pressure_byte: 0,
                disk_free_mib: Some(1024),
            }),
        }
    }

    fn note(&self, what: &str) {
        self.asked
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(String::from(what));
    }
}

impl HostQuerying for Fake {
    fn working_directory(&self, _pane: PaneHandles) -> Option<String> {
        self.cwd.clone()
    }

    fn processes(&self, _pane: PaneHandles) -> Vec<u8> {
        self.note("processes");
        self.processes.clone()
    }

    fn ports(&self, _pane: PaneHandles) -> Vec<u8> {
        self.note("ports");
        self.ports.clone()
    }

    fn git_status(&self, cwd: &str) -> GitStatusPayload {
        self.note(&format!("git_status({cwd})"));
        self.status.clone()
    }

    fn git_diff(&self, cwd: &str, file: &str) -> Option<Vec<u8>> {
        self.note(&format!("git_diff({cwd}, {file})"));
        self.diff.clone()
    }

    fn list_directory(&self, absolute: &str) -> Option<Vec<DirEntry>> {
        self.note(&format!("list_directory({absolute})"));
        self.entries.clone()
    }

    fn list_agent_sessions(&self, project: &str) -> Vec<AgentSessionInfo> {
        self.note(&format!("list_agent_sessions({project})"));
        self.sessions.clone()
    }

    fn read_agent_session(&self, id: &str) -> Option<Vec<u8>> {
        self.note(&format!("read_agent_session({id})"));
        self.transcript.clone()
    }

    fn host_name(&self) -> Option<String> {
        self.host_name.clone()
    }

    fn host_vitals(&self) -> Option<HostVitals> {
        self.vitals
    }
}

/// A delegate that answers a recognisable payload, so "it was handed over" is provable rather than
/// inferred from a status the reducer could also have produced.
#[derive(Debug)]
struct Stub {
    seen: Ledger,
}

impl MetadataPerformer for Stub {
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer {
        self.seen
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(format!("delegated({})", request.verb));
        MetadataAnswer::ok(b"delegate".to_vec())
    }
}

// MARK: - The harness

/// A reducer, its door's ledger and its delegate's.
struct Wired {
    performer: HostMetadata,
    asked: Ledger,
    delegated: Ledger,
}

impl Wired {
    /// A reducer over `door`, with production caps.
    fn over(door: Fake) -> Self {
        Self::capped(door, MAX_DIR_ENTRIES, MAX_OPAQUE_PAYLOAD_BYTES)
    }

    /// The same, with caps small enough to reach without allocating megabytes.
    fn capped(door: Fake, dir_entries: usize, opaque_bytes: usize) -> Self {
        let asked = Arc::clone(&door.asked);
        let delegated = Ledger::default();
        let delegate = Arc::new(Stub {
            seen: Arc::clone(&delegated),
        });
        Self {
            performer: HostMetadata::new(Arc::new(door), delegate).capped(dir_entries, opaque_bytes),
            asked,
            delegated,
        }
    }

    /// Serves `verb` with `argument`, routed the way a live session would route it.
    fn ask(&self, verb: MetadataVerb, argument: &[u8]) -> MetadataAnswer {
        self.ask_byte(verb.as_byte(), argument)
    }

    /// The same for a RAW byte, so a verb this build does not know can be asked at all.
    fn ask_byte(&self, verb: u8, argument: &[u8]) -> MetadataAnswer {
        self.performer.perform(&MetadataRequest {
            request_id: 1,
            verb,
            payload: argument,
            performer: performer(verb),
            master_fd: 9,
            shell_pid: 4242,
        })
    }

    fn asked(&self) -> Vec<String> {
        self.asked.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn delegated(&self) -> Vec<String> {
        self.delegated
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

fn status_of(answer: &MetadataAnswer) -> MetadataStatus {
    MetadataStatus::from_byte(answer.status).unwrap_or(MetadataStatus::Error)
}

// MARK: - Routing

/// A byte this build does not serve reaches the reducer — the routing table sends unknowns to the
/// builder on purpose — and is answered ONCE, here.
#[test]
fn a_byte_this_build_does_not_serve_is_answered_unsupported() {
    let wired = Wired::over(Fake::answering());
    let answer = wired.ask_byte(200, b"");
    assert_eq!(status_of(&answer), MetadataStatus::UnsupportedVerb);
    assert!(answer.payload.is_empty());
    assert!(
        wired.asked().is_empty(),
        "an unknown verb asks the machine nothing"
    );
    assert!(
        wired.delegated().is_empty(),
        "and is not somebody else's to answer"
    );
}

/// The twelve verbs the carve-out leaves in Swift cross UNTOUCHED — same request, delegate's
/// answer, no reinterpretation on the way through.
#[test]
fn every_verb_the_routing_gave_someone_else_reaches_the_delegate_whole() {
    let wired = Wired::over(Fake::answering());
    let elsewhere: Vec<MetadataVerb> = MetadataVerb::ALL
        .into_iter()
        .filter(|verb| performer(verb.as_byte()) != Performer::Builder)
        .collect();
    assert_eq!(elsewhere.len(), 12, "docs/60 §5's carve-out is twelve verbs wide");
    for verb in elsewhere {
        let answer = wired.ask(verb, b"argument");
        assert_eq!(status_of(&answer), MetadataStatus::Ok);
        assert_eq!(
            answer.payload, b"delegate",
            "{verb:?} was answered rather than handed over"
        );
    }
    assert_eq!(wired.delegated().len(), 12);
    assert!(
        wired.asked().is_empty(),
        "a delegated verb asks this door nothing"
    );
}

/// A verb this reducer OWNS but that actuates on the host would be a routing bug. It is refused
/// rather than best-efforted: "the table disagreed with itself" is not a reason to touch the
/// Finder.
#[test]
fn an_actuating_verb_routed_here_by_mistake_is_refused_without_a_side_effect() {
    let wired = Wired::over(Fake::answering());
    let answer = wired.performer.perform(&MetadataRequest {
        request_id: 1,
        verb: MetadataVerb::OpenPath.as_byte(),
        payload: b"/repo/README.md",
        // The bug being modelled: the table said "yours" about a verb that is not.
        performer: Performer::Builder,
        master_fd: 9,
        shell_pid: 4242,
    });
    assert_eq!(status_of(&answer), MetadataStatus::Error);
    assert!(wired.asked().is_empty());
    assert!(wired.delegated().is_empty());
}

// MARK: - The pane verbs

/// The census encodes; this reducer forwards. Nothing in between re-reads the bytes.
#[test]
fn the_pane_lists_are_forwarded_exactly_as_the_census_encoded_them() {
    let wired = Wired::over(Fake::answering());
    assert_eq!(wired.ask(MetadataVerb::Processes, b"").payload, vec![0, 1]);
    assert_eq!(wired.ask(MetadataVerb::Ports, b"").payload, vec![0, 2]);
    assert_eq!(wired.asked(), vec!["processes", "ports"]);
}

/// Every verb rooted in the pane cwd is refused BEFORE its query when there is no cwd to root it
/// in. `error` and not `notFound`: the pane could not answer, rather than the thing not existing.
#[test]
fn a_pane_with_no_working_directory_refuses_every_rooted_verb_before_asking() {
    for absent in [None, Some(String::new())] {
        let wired = Wired::over(Fake {
            cwd: absent.clone(),
            ..Fake::answering()
        });
        for verb in [
            MetadataVerb::Cwd,
            MetadataVerb::GitStatus,
            MetadataVerb::GitDiff,
            MetadataVerb::ListDirectory,
            MetadataVerb::ListAgentSessions,
        ] {
            let answer = wired.ask(verb, b"src/main.rs");
            assert_eq!(
                status_of(&answer),
                MetadataStatus::Error,
                "{verb:?} with cwd {absent:?}"
            );
        }
        assert!(
            wired.asked().is_empty(),
            "no cwd means no query, not a query on nothing"
        );
    }
}

/// The pane's own directory crosses as raw UTF-8 — there is no nested codec for this one.
#[test]
fn the_working_directory_crosses_as_raw_utf8() {
    let wired = Wired::over(Fake::answering());
    let answer = wired.ask(MetadataVerb::Cwd, b"");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    assert_eq!(answer.payload, b"/repo");
}

/// The status is read from the root the PANE reports, never from an argument — there is no
/// argument, and a status verb that took one would be a second confinement question.
#[test]
fn a_git_status_is_taken_at_the_root_the_pane_reports() {
    let wired = Wired::over(Fake::answering());
    let answer = wired.ask(MetadataVerb::GitStatus, b"ignored");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    let decoded = decode_git_status(&answer.payload).expect("the reducer encodes what the codec decodes");
    assert_eq!(decoded.branch, "main");
    assert_eq!(wired.asked(), vec!["git_status(/repo)"]);
}

// MARK: - Confinement, which is the part with teeth

/// The anchor: a `..` escape is refused and the query is NEVER CALLED. Reverting the confinement
/// makes this fail, which is the only reason it can be trusted.
#[test]
fn a_git_diff_argument_that_escapes_the_root_is_refused_before_the_read() {
    let wired = Wired::over(Fake::answering());
    for escape in ["../secrets", "src/../../secrets", "..", "src/../.."] {
        let answer = wired.ask(MetadataVerb::GitDiff, escape.as_bytes());
        assert_eq!(status_of(&answer), MetadataStatus::Error, "{escape}");
    }
    assert!(wired.asked().is_empty(), "a refused path is a path git never saw");
}

/// The confined answer is NORMALISED, so one file has one spelling by the time it reaches git.
#[test]
fn a_confined_diff_path_reaches_git_normalised_and_still_relative() {
    let wired = Wired::over(Fake::answering());
    let answer = wired.ask(MetadataVerb::GitDiff, b"src//./main.rs");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    assert_eq!(answer.payload, b"--- a\n+++ b\n");
    assert_eq!(wired.asked(), vec!["git_diff(/repo, src/main.rs)"]);
}

/// The wire contract for this argument is a repo-relative pathspec. An absolute one is REFUSED
/// rather than confined, even when it names a file inside the root — accepting a second spelling
/// would be a loosening with nothing asking for it.
#[test]
fn an_absolute_diff_argument_is_refused_even_inside_the_root() {
    let wired = Wired::over(Fake::answering());
    let answer = wired.ask(MetadataVerb::GitDiff, b"/repo/src/main.rs");
    assert_eq!(status_of(&answer), MetadataStatus::Error);
    assert!(wired.asked().is_empty());
}

/// An empty argument is not a missing one: it is "the pane's own directory", which is the case the
/// client opens a tree on.
#[test]
fn an_empty_listing_argument_is_the_pane_cwd_and_the_root_itself_is_allowed() {
    let wired = Wired::over(Fake::answering());
    let answer = wired.ask(MetadataVerb::ListDirectory, b"");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    let entries = decode_dir_listing(&answer.payload).expect("a listing the codec decodes");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries.first().map(|entry| entry.name.as_str()), Some("src"));
    assert_eq!(wired.asked(), vec!["list_directory(/repo)"]);
}

/// Both spellings of an inside path are allowed for the listing verbs, and both arrive absolute and
/// normalised — the listing door joins nothing.
#[test]
fn a_listing_argument_may_be_relative_or_absolute_and_arrives_absolute() {
    let wired = Wired::over(Fake::answering());
    for spelling in ["src", "/repo/src", "./src/", "/repo/./src"] {
        let answer = wired.ask(MetadataVerb::ListDirectory, spelling.as_bytes());
        assert_eq!(status_of(&answer), MetadataStatus::Ok, "{spelling}");
    }
    assert_eq!(wired.asked(), vec!["list_directory(/repo/src)"; 4]);
}

/// The same anchor as the diff one, for the two listing verbs: escape, refusal, untouched door.
#[test]
fn a_listing_argument_that_escapes_the_root_is_refused_before_the_walk() {
    let wired = Wired::over(Fake::answering());
    for verb in [MetadataVerb::ListDirectory, MetadataVerb::ListAgentSessions] {
        for escape in ["../etc", "/etc", "src/../../etc", "/repo/../etc"] {
            let answer = wired.ask(verb, escape.as_bytes());
            assert_eq!(status_of(&answer), MetadataStatus::Error, "{verb:?} {escape}");
        }
    }
    assert!(
        wired.asked().is_empty(),
        "a refused path is a path nothing walked"
    );
}

/// The one confinement question the reducer cannot finish — the session roots live under the host's
/// `$HOME` — is answered as far as it can be, on SHAPE, without a syscall.
#[test]
fn a_session_id_that_is_not_a_confinable_absolute_path_is_refused_before_the_read() {
    let wired = Wired::over(Fake::answering());
    for bad in ["../../secrets", "relative/path", "/", "/home/../etc/passwd", ""] {
        let answer = wired.ask(MetadataVerb::ReadAgentSession, bad.as_bytes());
        assert_eq!(status_of(&answer), MetadataStatus::Error, "{bad}");
    }
    assert!(wired.asked().is_empty());
    let answer = wired.ask(
        MetadataVerb::ReadAgentSession,
        b"/home/me/.claude/projects/x/y.jsonl",
    );
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    assert_eq!(wired.asked(), vec![
        "read_agent_session(/home/me/.claude/projects/x/y.jsonl)"
    ]);
}

/// An argument that is not UTF-8 is refused, not lossily repaired: a path this reducer cannot spell
/// exactly is a path it must not confine.
#[test]
fn an_argument_that_is_not_utf8_is_refused_rather_than_repaired() {
    let wired = Wired::over(Fake::answering());
    for verb in [
        MetadataVerb::GitDiff,
        MetadataVerb::ListDirectory,
        MetadataVerb::ListAgentSessions,
        MetadataVerb::ReadAgentSession,
    ] {
        let answer = wired.ask(verb, &[0x66, 0xFF, 0xFE]);
        assert_eq!(status_of(&answer), MetadataStatus::Error, "{verb:?}");
    }
    assert!(wired.asked().is_empty());
}

// MARK: - The two failures that are not the same failure

/// A query that answers `None` is `notFound` — the thing is not there. A pane that cannot say where
/// it is, is `error`. Keeping them apart is what lets the client tell "no diff for this file" from
/// "ask me again".
#[test]
fn a_missing_answer_is_not_found_where_a_missing_root_is_an_error() {
    let wired = Wired::over(Fake {
        diff: None,
        entries: None,
        transcript: None,
        ..Fake::answering()
    });
    assert_eq!(
        status_of(&wired.ask(MetadataVerb::GitDiff, b"src/main.rs")),
        MetadataStatus::NotFound
    );
    assert_eq!(
        status_of(&wired.ask(MetadataVerb::ListDirectory, b"src")),
        MetadataStatus::NotFound
    );
    assert_eq!(
        status_of(&wired.ask(MetadataVerb::ReadAgentSession, b"/home/me/.claude/x.jsonl")),
        MetadataStatus::NotFound
    );
}

/// A project with no sessions yet is an ANSWER — an empty list — and not a miss. The client's
/// session rail renders "none" from it, and a `notFound` would render an error instead.
#[test]
fn a_project_with_no_sessions_answers_an_empty_list_rather_than_a_miss() {
    let wired = Wired::over(Fake::answering());
    let answer = wired.ask(MetadataVerb::ListAgentSessions, b"");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    assert!(
        decode_agent_session_list(&answer.payload)
            .expect("an empty list still decodes")
            .is_empty()
    );
}

// MARK: - The caps

/// The entry cap is a TRUNCATION, not a refusal: a directory with a hundred thousand files still
/// opens, showing the first page of them, rather than failing to open at all.
#[test]
fn a_directory_listing_past_the_cap_is_truncated_rather_than_refused() {
    let wired = Wired::capped(
        Fake {
            entries: Some(
                (0..10)
                    .map(|index| {
                        DirEntry {
                            is_dir: false,
                            name: format!("file-{index}"),
                        }
                    })
                    .collect(),
            ),
            ..Fake::answering()
        },
        3,
        MAX_OPAQUE_PAYLOAD_BYTES,
    );
    let answer = wired.ask(MetadataVerb::ListDirectory, b"");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    let entries = decode_dir_listing(&answer.payload).expect("a truncated listing is still a listing");
    assert_eq!(entries.len(), 3);
    assert_eq!(entries.first().map(|entry| entry.name.as_str()), Some("file-0"));
}

/// The opaque cap cuts by BYTE, and deliberately: the alternative is a cap a multi-byte sequence
/// can push past, and the client renders these best-effort anyway.
#[test]
fn an_opaque_answer_past_the_cap_is_cut_by_byte() {
    let wired = Wired::capped(
        Fake {
            diff: Some(b"abcdefghij".to_vec()),
            transcript: Some("\u{1F600}\u{1F600}".as_bytes().to_vec()),
            ..Fake::answering()
        },
        MAX_DIR_ENTRIES,
        6,
    );
    assert_eq!(wired.ask(MetadataVerb::GitDiff, b"a").payload, b"abcdef");
    let cut = wired.ask(MetadataVerb::ReadAgentSession, b"/home/me/.claude/x.jsonl");
    assert_eq!(cut.payload.len(), 6, "six bytes, which is one and a half emoji");
    assert_eq!(
        status_of(&cut),
        MetadataStatus::Ok,
        "a cut tail is still an answer"
    );
}

// MARK: - The two pane-agnostic reads

/// An unresolvable hostname is `error` rather than an empty `ok`: the client's chrome would render
/// the empty string as a host with no name.
#[test]
fn an_empty_host_name_is_refused_rather_than_answered_empty() {
    for absent in [None, Some(String::new())] {
        let wired = Wired::over(Fake {
            host_name: absent,
            ..Fake::answering()
        });
        assert_eq!(
            status_of(&wired.ask(MetadataVerb::HostInfo, b"")),
            MetadataStatus::Error
        );
    }
    let wired = Wired::over(Fake::answering());
    assert_eq!(
        wired.ask(MetadataVerb::HostInfo, b"").payload,
        b"mac-studio.local"
    );
}

/// A sampler that has only banked a baseline answers `error`, NOT `notFound`. The client reads that
/// as "ask again next poll" and keeps the number it has; a `notFound` would blank the readout every
/// time the sampler primes.
#[test]
fn a_vitals_reading_that_is_not_ready_yet_is_an_error_and_not_a_miss() {
    let priming = Wired::over(Fake {
        vitals: None,
        ..Fake::answering()
    });
    assert_eq!(
        status_of(&priming.ask(MetadataVerb::HostVitals, b"")),
        MetadataStatus::Error
    );

    let wired = Wired::over(Fake::answering());
    let answer = wired.ask(MetadataVerb::HostVitals, b"");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    let vitals = decode_host_vitals(&answer.payload).expect("the reducer encodes what the codec decodes");
    assert_eq!(vitals.cpu_percent, 7);
    assert_eq!(vitals.disk_free_mib, Some(1024));
}
