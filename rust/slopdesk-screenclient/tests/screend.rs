//! The client against a FAKE screend — a real `AF_UNIX` listener answering with
//! [`slopdesk_screenwire`]'s own encoder.
//!
//! Fake rather than the real daemon on purpose. Every property this suite is about is the CLIENT's
//! — the retry rule, the pool, the address invalidation, the backoff — and each of them needs a
//! screend that hangs up mid-exchange, or answers garbage, or is not there at all. A real screend
//! does none of those on request, and a suite that could only test the happy path would be testing
//! the wire crate a third time.
//!
//! The reply bytes come from `encode_reply`, so the fake cannot drift from the daemon on framing:
//! there is one encoder and both ends call it.

#![expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::io::{Read as _, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use slopdesk_screenclient::{ClientError, DetectFlags, ScreenClient, Snapshot, State, Status};
use slopdesk_screenwire::{
    LENGTH_PREFIX_LEN, Verdict, encode_body, encode_reply, hello_payload, reply_body_length,
};

/// What the fake does with one request.
#[derive(Clone)]
enum Answer {
    /// A well-formed `ok` reply carrying these bytes.
    Ok(Vec<u8>),
    /// A well-formed refusal. The connection stays open, which is the point of the case.
    Rejected(&'static str),
    /// Close the connection without answering — a screend that died holding the answer.
    Hangup,
    /// Four bytes that name a length this end will not read.
    Garbage,
}

/// A screend that is not one.
struct Fake {
    path: PathBuf,
    /// Requests answered, across every connection.
    requests: Arc<AtomicUsize>,
    /// Connections accepted. The pool's whole observable effect.
    connections: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
}

impl Fake {
    /// Binds at `/tmp/sd-sc-<name>.sock` and answers `answers` in order, repeating the last one.
    ///
    /// `/tmp` rather than the temp dir because `sun_path` is 104 bytes and a per-user
    /// `/var/folders/…` prefix plus a test name gets close enough to matter.
    fn start(name: &str, answers: Vec<Answer>) -> Self {
        let path = PathBuf::from(format!("/tmp/sd-sc-{name}.sock"));
        let _ignored = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let requests = Arc::new(AtomicUsize::new(0));
        let connections = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));

        let fake = Self {
            path,
            requests: Arc::clone(&requests),
            connections: Arc::clone(&connections),
            stop: Arc::clone(&stop),
        };
        std::thread::spawn(move || {
            for accepted in listener.incoming() {
                if stop.load(Ordering::SeqCst) {
                    return;
                }
                let Ok(stream) = accepted else { return };
                connections.fetch_add(1, Ordering::SeqCst);
                let answers = answers.clone();
                let requests = Arc::clone(&requests);
                std::thread::spawn(move || serve(stream, &answers, &requests));
            }
        });
        fake
    }

    fn client(&self) -> ScreenClient {
        ScreenClient::pinned(self.path.clone(), None, false)
    }
}

impl Drop for Fake {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Wakes the accept loop so the thread returns rather than parking for the process's life.
        let _ignored = UnixStream::connect(&self.path);
        let _ignored = std::fs::remove_file(&self.path);
    }
}

/// One connection: read frames until EOF, answer each from the script.
fn serve(mut stream: UnixStream, answers: &[Answer], requests: &AtomicUsize) {
    loop {
        let mut prefix = [0_u8; LENGTH_PREFIX_LEN];
        if stream.read_exact(&mut prefix).is_err() {
            return;
        }
        let Some(length) = reply_body_length(prefix) else {
            return;
        };
        let mut body = vec![0_u8; length];
        if stream.read_exact(&mut body).is_err() {
            return;
        }
        let index = requests.fetch_add(1, Ordering::SeqCst);
        let answer = answers.get(index).or_else(|| answers.last());
        let frame = match answer {
            Some(Answer::Ok(payload)) => encode_reply(Status::Ok, payload),
            Some(Answer::Rejected(message)) => encode_reply(Status::BadRequest, message.as_bytes()),
            Some(Answer::Garbage) => vec![0, 0, 0, 0],
            Some(Answer::Hangup) | None => return,
        };
        if stream.write_all(&frame).is_err() {
            return;
        }
    }
}

fn a_snapshot() -> Snapshot {
    Snapshot {
        rows: 1,
        cols: 3,
        cursor_row: 0,
        cursor_col: 2,
        cursor_visible: true,
        alt_screen: false,
        lines: vec!["ab".to_owned()],
    }
}

#[test]
fn a_hello_round_trips_and_names_the_build_that_answered() {
    let fake = Fake::start("hello", vec![Answer::Ok(hello_payload("9.9.9"))]);
    let client = fake.client();
    assert_eq!(client.hello().unwrap(), "slopdesk-screend 1 9.9.9");
    assert_eq!(client.build_version().unwrap().as_deref(), Some("9.9.9"));
}

#[test]
fn a_screend_that_predates_the_version_field_is_unknown_and_not_current() {
    let fake = Fake::start("old-hello", vec![Answer::Ok(b"slopdesk-screend 1".to_vec())]);
    assert_eq!(fake.client().build_version().unwrap(), None);
}

#[test]
fn a_snapshot_reply_decodes_into_the_wire_crates_type() {
    let snapshot = a_snapshot();
    let fake = Fake::start("snapshot", vec![Answer::Ok(encode_body(&snapshot).unwrap())]);
    assert_eq!(fake.client().snapshot(b"ab", 1, 3).unwrap(), snapshot);
    assert_eq!(fake.client().feed("pane", b"ab", 1, 3, true).unwrap(), snapshot);
}

#[test]
fn a_detect_reply_decodes_into_a_verdict() {
    let verdict = Verdict {
        state: State::Blocked,
        visible_blocker: true,
        frame_generation: 4,
        ..Verdict::none()
    };
    let fake = Fake::start("detect", vec![Answer::Ok(encode_body(&verdict).unwrap())]);
    let answered = fake
        .client()
        .detect("pane", "claude", b"?", 1, 3, DetectFlags {
            reset: true,
            rebuild_replay: false,
            agent_changed: true,
        })
        .unwrap();
    assert_eq!(answered, verdict);
}

/// A REJECTION is screend answering, not the transport failing — retrying would only ask the same
/// malformed question again.
#[test]
fn a_rejection_is_reported_and_never_retried() {
    let fake = Fake::start("rejected", vec![Answer::Rejected("rows out of range")]);
    assert_eq!(
        fake.client().snapshot(b"ab", 0, 0),
        Err(ClientError::Rejected {
            status: Status::BadRequest,
            message: "rows out of range".to_owned(),
        }),
    );
    assert_eq!(fake.requests.load(Ordering::SeqCst), 1);
}

/// The overwhelmingly likely cause of a transport failure is a pooled socket whose screend was
/// restarted between calls, so one retry on a FRESH connection is the whole recovery.
#[test]
fn a_transport_failure_is_retried_once_on_a_fresh_connection() {
    let snapshot = a_snapshot();
    let fake = Fake::start("retry", vec![
        Answer::Hangup,
        Answer::Ok(encode_body(&snapshot).unwrap()),
    ]);
    assert_eq!(fake.client().snapshot(b"ab", 1, 3).unwrap(), snapshot);
    assert_eq!(fake.requests.load(Ordering::SeqCst), 2);
    assert_eq!(fake.connections.load(Ordering::SeqCst), 2);
}

#[test]
fn a_second_transport_failure_is_reported_rather_than_retried_forever() {
    let fake = Fake::start("retry-twice", vec![Answer::Hangup]);
    assert!(matches!(
        fake.client().snapshot(b"ab", 1, 3),
        Err(ClientError::Transport { .. })
    ));
    assert_eq!(fake.requests.load(Ordering::SeqCst), 2);
}

/// A lost frame boundary is not recoverable on the same socket, so the socket is dropped rather
/// than pooled — and the retry gets a new one.
#[test]
fn a_malformed_reply_is_retried_and_then_reported() {
    let fake = Fake::start("garbage", vec![Answer::Garbage]);
    assert_eq!(fake.client().hello(), Err(ClientError::MalformedReply));
    assert_eq!(fake.connections.load(Ordering::SeqCst), 2);
}

#[test]
fn a_socket_goes_back_to_the_pool_and_the_next_call_reuses_it() {
    let fake = Fake::start("pool", vec![Answer::Ok(hello_payload("1.0.0"))]);
    let client = fake.client();
    for _ in 0..5 {
        client.hello().unwrap();
    }
    assert_eq!(fake.requests.load(Ordering::SeqCst), 5);
    assert_eq!(fake.connections.load(Ordering::SeqCst), 1);
}

/// A rejected request leaves the connection good — `Status::BadRequest`'s own contract — so it goes
/// back in the pool. The Swift original recycled it and then closed it from the catch block, which
/// left a closed descriptor for the next caller to draw.
#[test]
fn a_rejection_does_not_cost_the_caller_its_socket() {
    let fake = Fake::start("rejected-pool", vec![
        Answer::Rejected("no"),
        Answer::Ok(hello_payload("1.0.0")),
    ]);
    let client = fake.client();
    assert!(client.hello().is_err());
    assert_eq!(client.hello().unwrap(), "slopdesk-screend 1 1.0.0");
    assert_eq!(fake.connections.load(Ordering::SeqCst), 1);
}

/// Pooled sockets lead to a specific engine. A changed address makes every one of them wrong.
#[test]
fn a_changed_address_invalidates_the_whole_pool() {
    let first = Fake::start("address-a", vec![Answer::Ok(hello_payload("1.0.0"))]);
    let second = Fake::start("address-b", vec![Answer::Ok(hello_payload("2.0.0"))]);
    let aim = Arc::new(std::sync::Mutex::new(first.path.clone()));
    let resolver = Arc::clone(&aim);
    let client = ScreenClient::with_resolvers(
        Box::new(move || resolver.lock().unwrap().clone()),
        Box::new(|| None),
        false,
    );

    assert_eq!(client.hello().unwrap(), "slopdesk-screend 1 1.0.0");
    *aim.lock().unwrap() = second.path.clone();
    assert_eq!(client.hello().unwrap(), "slopdesk-screend 1 2.0.0");

    assert_eq!(first.connections.load(Ordering::SeqCst), 1);
    assert_eq!(second.connections.load(Ordering::SeqCst), 1);
}

#[test]
fn nothing_listening_and_no_autostart_is_unavailable_and_not_a_panic() {
    let client = ScreenClient::pinned(PathBuf::from("/tmp/sd-sc-absent.sock"), None, false);
    let _ignored = std::fs::remove_file("/tmp/sd-sc-absent.sock");
    assert!(matches!(
        client.snapshot(b"ab", 1, 3),
        Err(ClientError::Unavailable { .. })
    ));
    // Best-effort by contract: a caller with nothing to do about the failure is handed nothing.
    client.forget("pane");
}

/// A screend that cannot start must not be re-forked once per detection tick across every pane.
#[test]
fn a_missing_binary_is_reported_once_and_then_backed_off() {
    let path = PathBuf::from("/tmp/sd-sc-nobinary.sock");
    let _ignored = std::fs::remove_file(&path);
    let client = ScreenClient::pinned(path, None, true);
    assert_eq!(
        client.hello(),
        Err(ClientError::Unavailable {
            reason: "no slopdesk-screend binary (SLOPDESK_SCREEND_BIN)".to_owned(),
        }),
    );
    assert_eq!(
        client.hello(),
        Err(ClientError::Unavailable {
            reason: "screend start backing off".to_owned(),
        }),
    );
}

/// The bind wait is BOUNDED: a binary that starts and never listens becomes a fallback rather than
/// a hang. Costs one `START_TIMEOUT` of wall clock, which is what buys the proof.
#[test]
fn a_binary_that_never_binds_times_out_rather_than_hanging() {
    let path = PathBuf::from("/tmp/sd-sc-neverbinds.sock");
    let _ignored = std::fs::remove_file(&path);
    let client = ScreenClient::pinned(path.clone(), Some(PathBuf::from(sleeper())), true);
    let started = std::time::Instant::now();
    assert_eq!(
        client.hello(),
        Err(ClientError::Unavailable {
            reason: format!("screend did not bind {} in time", path.display()),
        }),
    );
    assert!(started.elapsed() >= std::time::Duration::from_secs(3));
}

/// A real executable that exits at once. `true(1)` is on every machine this tree builds on, and the
/// spawn is what is under test — not what the child does.
fn sleeper() -> &'static str {
    if Path::new("/usr/bin/true").exists() {
        "/usr/bin/true"
    } else {
        "/bin/true"
    }
}
