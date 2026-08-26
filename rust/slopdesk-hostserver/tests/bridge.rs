//! The bridge socket against a fake extension host on a real `AF_UNIX` socket.
//!
//! The Swift original was "compiled and code-reviewed only — never bound in a unit test", and the
//! pure halves under it were tested instead. Those halves are `slopdesk-muxsession`'s and have
//! their own suite; what that position left uncovered is precisely what this file is: the bind, the
//! accept, the line splitting, the two directions and the stop.
//!
//! The load-bearing one is [`a_stop_unlinks_only_the_socket_file_it_bound`]. Every other case here
//! fails loudly; that one fails by deleting a DIFFERENT live host's socket name, after which its
//! workbench windows reconnect for five minutes to a name nobody holds and nothing anywhere says
//! why.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::io::{BufRead as _, BufReader, Write as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::Value;
use slopdesk_hostserver::bridge::{CodeBridgeServer, RunOutcome, TerminalRunner};
use slopdesk_hostserver::code::CodeBridge as _;
use slopdesk_muxsession::bridge_router::MAX_LINE_BYTES;

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

/// Long enough to prove nothing is coming, short enough to pay for eight times.
const BRIEF: Duration = Duration::from_millis(150);

// MARK: - The harness

/// A bound server and the path it is bound at.
struct Served {
    server: Arc<CodeBridgeServer>,
    path: PathBuf,
}

impl Served {
    fn up() -> Self {
        Self::with_runner(None)
    }

    fn with_runner(runner: Option<TerminalRunner>) -> Self {
        let path = a_socket_path();
        let server = CodeBridgeServer::new(None);
        server.set_terminal_runner(runner);
        server.start(&path.to_string_lossy());
        assert_eq!(
            server.bound_path().as_deref(),
            Some(path.as_path()),
            "the bind is the precondition of every case here",
        );
        Self { server, path }
    }

    /// Dials in as one workbench window and announces `root`, then waits until the server has
    /// recorded it — a `hello` that has not landed yet routes nowhere, which would read as a
    /// routing failure rather than as a race.
    fn window(&self, root: &str) -> Extension {
        let known = self.server.roots().len();
        let extension = Extension::dial(&self.path);
        waited_until(|| self.server.roots().len() > known);
        extension.say(&format!(r#"{{"t":"hello","root":"{root}"}}"#));
        // The root is recorded on the read thread, so the wait is for the RECORD rather than for a
        // routing attempt — probing with an `open` would write a line into this window's stream and
        // every `heard()` after it would be reading the probe.
        waited_until(|| self.server.roots().iter().any(|held| held == root));
        extension
    }

    fn stop(self) {
        self.server.stop();
        let _ignored = std::fs::remove_file(&self.path);
    }
}

/// One connected workbench window, from the extension's side.
struct Extension {
    writing: std::os::unix::net::UnixStream,
    reading: BufReader<std::os::unix::net::UnixStream>,
}

impl Extension {
    fn dial(path: &Path) -> Self {
        let stream = std::os::unix::net::UnixStream::connect(path).expect("the bridge is listening");
        stream
            .set_read_timeout(Some(GENEROUS))
            .expect("a read bound so a silent server fails rather than hangs");
        let reading = BufReader::new(stream.try_clone().expect("a second handle on the socket"));
        Self {
            writing: stream,
            reading,
        }
    }

    /// Sends one NDJSON line.
    fn say(&self, line: &str) {
        let mut socket = &self.writing;
        socket.write_all(line.as_bytes()).expect("the line goes out");
        socket.write_all(b"\n").expect("the terminator goes out");
        socket.flush().expect("the line is flushed");
    }

    /// Sends `bytes` with no terminator at all — what a peer that never sends a newline looks like.
    fn babble(&self, bytes: &[u8]) {
        let mut socket = &self.writing;
        socket.write_all(bytes).expect("the bytes go out");
        socket.flush().expect("the bytes are flushed");
    }

    /// The next line the host sent, parsed. Fails rather than hangs — the read bound is set above.
    fn heard(&mut self) -> Value {
        let mut line = String::new();
        let read = self.reading.read_line(&mut line).expect("the host answers");
        assert!(read > 0, "the host closed the connection instead of answering");
        serde_json::from_str(&line).expect("the host speaks NDJSON")
    }

    /// Whether the host said nothing for `bound`. A shorter read timeout for the duration, because
    /// proving silence is the assertion.
    fn silent_for(&mut self, bound: Duration) -> bool {
        self.reading
            .get_ref()
            .set_read_timeout(Some(bound))
            .expect("a shorter bound");
        let mut line = String::new();
        let quiet = self.reading.read_line(&mut line).is_err();
        self.reading
            .get_ref()
            .set_read_timeout(Some(GENEROUS))
            .expect("the bound back");
        quiet && line.is_empty()
    }
}

/// A socket path this test process owns alone. Short, because `sun_path` is 104 bytes on Darwin and
/// `$TMPDIR` is already most of them.
fn a_socket_path() -> PathBuf {
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    std::env::temp_dir().join(format!(
        "sd-bridge-{}-{}.sock",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed),
    ))
}

/// Blocks until `settled` answers true, or fails. The bridge's effects land on threads this suite
/// does not own, so the only alternative is to assert on a race.
fn waited_until(mut settled: impl FnMut() -> bool) {
    let deadline = Instant::now() + GENEROUS;
    while Instant::now() < deadline {
        if settled() {
            return;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    panic!("the bridge never reached the asserted state");
}

/// Every request the installed runner was handed, and what it answered.
#[derive(Debug, Default)]
struct Ledger {
    seen: Mutex<Vec<String>>,
}

impl Ledger {
    /// A runner that lands everything in one named pane and records the text it was given.
    fn runner(self: &Arc<Self>) -> TerminalRunner {
        let ledger = Arc::clone(self);
        Arc::new(move |request| {
            ledger
                .seen
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(request.text.clone());
            RunOutcome::landed("zsh — slop-desk")
        })
    }

    fn all(&self) -> Vec<String> {
        self.seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

// MARK: - The tests

/// The routing rule the CLI cannot express: nested checkouts open as separate windows, and a file
/// inside the inner one belongs to the inner one.
#[test]
fn the_deepest_workspace_folder_claims_the_file() {
    let served = Served::up();
    let mut outer = served.window("/w/proj");
    let mut inner = served.window("/w/proj/vendor/dep");

    assert!(served.server.open("/w/proj/vendor/dep/src/main.rs"));

    let opened = inner.heard();
    assert_eq!(opened.get("t").and_then(Value::as_str), Some("open"));
    assert_eq!(
        opened.get("path").and_then(Value::as_str),
        Some("/w/proj/vendor/dep/src/main.rs"),
    );
    assert!(
        outer.silent_for(BRIEF),
        "the enclosing window must not also be told, or the file opens twice",
    );
    served.stop();
}

/// The fallback signal. No window claims the path, so nothing is written and the caller reaches for
/// `code-server -r` rather than dropping a file into an unrelated project.
#[test]
fn a_path_no_window_contains_is_refused_rather_than_misrouted() {
    let served = Served::up();
    let mut window = served.window("/w/proj");

    assert!(!served.server.open("/elsewhere/notes.md"));
    assert!(window.silent_for(BRIEF));

    // And the same for a window that has not said `hello` yet: connected is not routable.
    let mut mute = Extension::dial(&served.path);
    waited_until(|| served.server.roots().len() == 2);
    assert!(!served.server.open("/anything/at/all.txt"));
    assert!(mute.silent_for(BRIEF));
    served.stop();
}

/// The `:line:col` tail is split off by the link detector's own splitter and crosses as numbers,
/// because a path with `:42:7` still on it does not exist on disk.
#[test]
fn the_line_and_column_ride_as_numbers_and_leave_the_path_alone() {
    let served = Served::up();
    let mut window = served.window("/w/proj");

    assert!(served.server.open("/w/proj/src/lib.rs:42:7"));
    let opened = window.heard();
    assert_eq!(
        opened.get("path").and_then(Value::as_str),
        Some("/w/proj/src/lib.rs"),
    );
    assert_eq!(opened.get("line").and_then(Value::as_i64), Some(42));
    assert_eq!(opened.get("col").and_then(Value::as_i64), Some(7));

    // No suffix means no keys at all, which is "keep your own position" rather than "go to line 0".
    assert!(served.server.open("/w/proj/README.md"));
    let plain = window.heard();
    assert!(plain.get("line").is_none() && plain.get("col").is_none());
    served.stop();
}

/// The other direction, and the correlation id is what makes it answerable at all.
#[test]
fn a_run_is_answered_on_the_same_connection_with_its_own_id() {
    let ledger = Arc::new(Ledger::default());
    let served = Served::with_runner(Some(ledger.runner()));
    let mut window = served.window("/w/proj");

    window.say(r#"{"t":"run","id":"r-1","root":"/w/proj","cwd":"/w/proj/src","text":"cargo test"}"#);
    let result = window.heard();

    assert_eq!(result.get("t").and_then(Value::as_str), Some("result"));
    assert_eq!(result.get("id").and_then(Value::as_str), Some("r-1"));
    assert_eq!(result.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        result.get("pane").and_then(Value::as_str),
        Some("zsh — slop-desk"),
    );
    assert_eq!(ledger.all(), vec!["cargo test".to_owned()]);
    served.stop();
}

/// A `cd` is a `run` whose text the HOST builds, so the shell-quoting rule has one tested home
/// rather than a second copy written in JavaScript.
#[test]
fn a_cd_is_typed_as_a_command_line_the_host_quoted() {
    let ledger = Arc::new(Ledger::default());
    let served = Served::with_runner(Some(ledger.runner()));
    let mut window = served.window("/w/proj");

    window.say(r#"{"t":"cd","id":"c-1","root":"/w/proj","path":"/w/proj/a dir"}"#);
    assert_eq!(window.heard().get("ok").and_then(Value::as_bool), Some(true));

    let typed = ledger.all();
    let line = typed.first().expect("the runner was handed one line");
    assert!(line.starts_with("cd "), "{line}");
    assert!(
        line.contains("a dir") && line.len() > "cd /w/proj/a dir".len(),
        "the space must be quoted rather than typed bare: {line}",
    );
    served.stop();
}

/// No runner installed reads as a REFUSAL, never as silence — the editor is waiting on this line to
/// tell the user something.
#[test]
fn a_request_with_nobody_to_type_it_is_refused_in_words() {
    let served = Served::up();
    let mut window = served.window("/w/proj");

    window.say(r#"{"t":"run","id":"r-2","root":"/w/proj","text":"ls"}"#);
    let result = window.heard();

    assert_eq!(result.get("ok").and_then(Value::as_bool), Some(false));
    assert!(
        result
            .get("message")
            .and_then(Value::as_str)
            .is_some_and(|message| message.contains("terminal pane")),
        "{result}",
    );
    assert!(result.get("pane").is_none(), "a refusal names no pane");
    served.stop();
}

/// Validate-then-drop, three ways. A workbench window is expensive to replace, and one bad line
/// says nothing about the next — so every one of these leaves the connection exactly as it was.
#[test]
fn a_line_the_host_will_not_believe_is_dropped_and_the_window_survives() {
    let ledger = Arc::new(Ledger::default());
    let served = Served::with_runner(Some(ledger.runner()));
    let mut window = served.window("/w/proj");

    // Malformed JSON, an unknown verb, and text carrying an ESC — which is a keybinding at a live
    // shell prompt, not text.
    window.say("{not json");
    window.say(r#"{"t":"detonate","root":"/w/proj"}"#);
    window.say(r#"{"t":"run","id":"r-3","root":"/w/proj","text":"ls\u001b[A"}"#);
    // Longer than the host will ever look at, with no newline in it either.
    window.babble(&vec![b'x'; MAX_LINE_BYTES + 4096]);
    window.say("");

    assert!(window.silent_for(BRIEF), "silence is the whole answer");
    assert!(ledger.all().is_empty(), "nothing reached the shell");

    // And the connection still works, which is the half that would be missed by asserting silence
    // alone: a host that dropped the window would also be silent.
    window.say(r#"{"t":"run","id":"r-4","root":"/w/proj","text":"echo alive"}"#);
    assert_eq!(window.heard().get("id").and_then(Value::as_str), Some("r-4"));
    served.stop();
}

/// The load-bearing one. The socket name is pid-free by design, so between this server's bind and
/// its stop a SECOND host may have taken the name — and an unconditional unlink would delete a live
/// host's socket out from under it, with nothing to put it back.
#[test]
fn a_stop_unlinks_only_the_socket_file_it_bound() {
    let served = Served::up();
    let ours = std::fs::metadata(&served.path).expect("the bind made a file");

    // A second host does exactly what `start` does: unlink the name, bind its own.
    let successor = CodeBridgeServer::new(None);
    successor.start(&served.path.to_string_lossy());
    let theirs = std::fs::metadata(&served.path).expect("the successor bound the same name");
    assert_ne!(
        std::os::unix::fs::MetadataExt::ino(&ours),
        std::os::unix::fs::MetadataExt::ino(&theirs),
        "a rebind is a new inode, always — this is what the stop compares",
    );

    served.server.stop();
    assert!(
        served.path.exists(),
        "the first host's stop must leave the successor's name alone",
    );
    // And the successor is still reachable, which is the fact the file's existence stands for.
    drop(Extension::dial(&served.path));

    successor.stop();
    assert!(
        !served.path.exists(),
        "the host that owns the name is the one that takes it away",
    );
    served.stop();
}

/// Both ends of the lifecycle are idempotent, because both are called from teardown paths that do
/// not coordinate.
#[test]
fn a_second_start_is_a_no_op_and_a_second_stop_is_harmless() {
    let served = Served::up();
    let first = std::fs::metadata(&served.path)
        .map(|info| std::os::unix::fs::MetadataExt::ino(&info))
        .expect("the bind made a file");

    served.server.start(&served.path.to_string_lossy());
    let after = std::fs::metadata(&served.path)
        .map(|info| std::os::unix::fs::MetadataExt::ino(&info))
        .expect("still bound");
    assert_eq!(first, after, "a second start must not rebind under itself");

    // The window dialled after the second start proves the ORIGINAL accept loop is still the one
    // running: a rebind would have left it accepting on a socket nobody can reach.
    let mut window = served.window("/w/proj");
    assert!(served.server.open("/w/proj/a.txt"));
    assert_eq!(window.heard().get("t").and_then(Value::as_str), Some("open"));

    served.server.stop();
    served.server.stop();
    assert!(!served.path.exists());
    assert_eq!(served.server.bound_path(), None);
    served.stop();
}

/// A stop wakes every read thread through a duplicate handle rather than closing a descriptor one
/// of them is inside — so the extension sees a clean EOF and the table empties.
#[test]
fn a_stop_ends_every_window_and_the_extension_sees_the_close() {
    let served = Served::up();
    let mut one = served.window("/w/one");
    let mut other = served.window("/w/two");
    assert_eq!(served.server.roots().len(), 2);

    served.server.stop();

    for window in [&mut one, &mut other] {
        let mut line = String::new();
        assert_eq!(
            window.reading.read_line(&mut line).ok(),
            Some(0),
            "a stop is an EOF to the extension, not a hang and not a half line",
        );
    }
    waited_until(|| served.server.roots().is_empty());
    assert!(!served.server.open("/w/one/a.txt"), "nothing is routable now");
    served.stop();
}
