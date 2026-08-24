//! The `AF_UNIX` request loop: one thread per connection, one shared [`Registry`] behind a mutex.
//!
//! A thread that panics takes its own connection down and nothing else — the reason this crate
//! builds with `panic = "unwind"`: a malformed request from one pane must not blank every other
//! pane's detection. A poisoned mutex is therefore EXPECTED rather than fatal, and recovered into
//! (the registry's invariants are per-pane; a half-fed model self-heals on the next repaint,
//! exactly as an evicted one does).

use std::io::{BufReader, BufWriter, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use crate::detect::{detect, detection_text};
use crate::model::{MAX_COLS, MAX_ROWS, ScreenModel};
use crate::overprint::collapse;
use crate::protocol::{
    FLAG_AGENT_CHANGED, FLAG_REASSERT_INPUT_MODES, FLAG_REBUILD_REPLAY, FLAG_RESET, MAX_FRAME, Request,
    Status, Verb, decode_detect_payload, decode_request, encode_reply, hello_payload,
};
use crate::registry::Registry;
use crate::render::{render, render_transcript};
use crate::{boundary, inputmode, prompteol};

/// Scrollback lines a COMPOSE model captures.
///
/// The client's own scrollback cap is the real bound; this one bounds screend's memory during a
/// single composition.
pub const SCROLLBACK_LINE_BUDGET: usize = 10_000;

/// How long screend stays up holding NO connection before exiting.
///
/// screend is started on demand and is cheap to start again, so an engine nobody is talking to is
/// pure residue — and the tests make that concrete: `swift test --parallel` gives every worker
/// process its own private engine, and without this each run would leave a dozen daemons alive for
/// the rest of the machine's uptime. The criterion is CONNECTIONS, not requests: a live hostd keeps
/// pooled sockets open, so it is never mistaken for an idle one, while a dead client's sockets are
/// closed by the kernel whether it exited cleanly or not.
///
/// Losing a resident pane grid to this is the same non-event as losing one to eviction — the next
/// `feed` rebuilds from a blank screen and the next repaint fixes it (`registry.rs`).
pub const DEFAULT_IDLE_EXIT: Duration = Duration::from_mins(2);

/// The idle timeout in force: `$SLOPDESK_SCREEND_IDLE_EXIT` seconds, `0` for "never exit" (what the
/// `LaunchAgent` sets, because launchd owns that copy's lifetime and would relaunch it forever).
#[must_use]
pub fn idle_exit_timeout() -> Option<Duration> {
    parse_idle_exit(std::env::var("SLOPDESK_SCREEND_IDLE_EXIT").ok().as_deref())
}

/// Unset → the default; `0` → never; a positive integer → that many seconds. An unparseable value
/// is the default rather than an error: a typo in an env var must not stop the engine from serving.
#[must_use]
pub fn parse_idle_exit(value: Option<&str>) -> Option<Duration> {
    match value.map(str::trim) {
        None | Some("") => Some(DEFAULT_IDLE_EXIT),
        Some("0") => None,
        Some(text) => {
            text.parse::<u64>().map_or(Some(DEFAULT_IDLE_EXIT), |seconds| {
                Some(Duration::from_secs(seconds))
            })
        },
    }
}

/// Live connections, and when the last one closed — the whole state the idle watchdog needs.
#[derive(Debug)]
struct Activity {
    live: AtomicUsize,
    idle_since: Mutex<Instant>,
}

/// Exits the process once `timeout` passes with no connection open.
#[expect(
    clippy::exit,
    reason = "the whole point of the watchdog: the listener loop blocks in `accept` forever, so there is no \
              return value that would end this process — and there is nothing to unwind for, screend \
              holding no durable state at all"
)]
fn watch_for_idleness(activity: &Arc<Activity>, timeout: Duration) {
    let activity = Arc::clone(activity);
    // A detached thread: it either exits the process or the process outlives it.
    let spawned = std::thread::Builder::new()
        .name("screend-idle".to_owned())
        .spawn(move || {
            // A quarter of the timeout keeps the wakeups rare while bounding the overshoot.
            let tick = (timeout / 4).max(Duration::from_millis(250));
            loop {
                std::thread::sleep(tick);
                if activity.live.load(Ordering::Acquire) > 0 {
                    continue;
                }
                let since = *activity.idle_since.lock().unwrap_or_else(PoisonError::into_inner);
                if since.elapsed() >= timeout {
                    eprintln!("screend: idle for {}s, exiting", timeout.as_secs());
                    std::process::exit(0);
                }
            }
        });
    if let Err(error) = spawned {
        // Serving without the watchdog beats not serving: the cost is a daemon that lingers.
        eprintln!("screend: cannot spawn the idle watchdog: {error}");
    }
}

/// Serves connections on `path` until the process is killed, or until it has been idle for
/// [`idle_exit_timeout`].
///
/// Removes a stale socket first — screend is started by hostd (or launchd) with the same path every
/// time, and a leftover node from a killed predecessor would otherwise make `bind` fail forever.
///
/// # Errors
/// Propagates the `bind`/`accept` failure; a per-connection error is logged and dropped.
pub fn serve(path: &Path) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // Removing an existing node is safe here for the same reason it is in superd: the path is
    // private to this daemon, and a live predecessor holding it would have been terminated by the
    // supervisor before we were started.
    match std::fs::remove_file(path) {
        Ok(()) => {},
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {},
        Err(error) => return Err(error),
    }
    let listener = UnixListener::bind(path)?;
    eprintln!("screend: listening on {}", path.display());

    let registry = Arc::new(Mutex::new(Registry::new()));
    let activity = Arc::new(Activity {
        live: AtomicUsize::new(0),
        idle_since: Mutex::new(Instant::now()),
    });
    if let Some(timeout) = idle_exit_timeout() {
        watch_for_idleness(&activity, timeout);
    }
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let registry = Arc::clone(&registry);
                let held = Arc::clone(&activity);
                activity.live.fetch_add(1, Ordering::AcqRel);
                // A failed spawn (thread limit) costs this one connection, not the daemon.
                if let Err(error) =
                    std::thread::Builder::new()
                        .name("screend-conn".to_owned())
                        .spawn(move || {
                            handle_connection(&stream, &registry);
                            // Last one out starts the clock. The stamp is written BEFORE the count
                            // drops, so a watchdog that sees zero necessarily sees this instant too.
                            *held.idle_since.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
                            held.live.fetch_sub(1, Ordering::AcqRel);
                        })
                {
                    eprintln!("screend: cannot spawn connection thread: {error}");
                    activity.live.fetch_sub(1, Ordering::AcqRel);
                }
            },
            Err(error) => eprintln!("screend: accept failed: {error}"),
        }
    }
    Ok(())
}

/// Serves one connection to completion (EOF, or an unrecoverable transport error).
fn handle_connection(stream: &UnixStream, registry: &Mutex<Registry>) {
    let Ok(read_half) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::with_capacity(64 * 1024, read_half);
    let mut writer = BufWriter::with_capacity(64 * 1024, stream);
    loop {
        let body = match read_frame(&mut reader) {
            Ok(Some(body)) => body,
            Ok(None) => return, // clean EOF
            Err(error) => {
                eprintln!("screend: read failed: {error}");
                return;
            },
        };
        let (status, payload) = serve_request(&body, registry);
        if let Err(error) = writer
            .write_all(&encode_reply(status, &payload))
            .and_then(|()| writer.flush())
        {
            eprintln!("screend: write failed: {error}");
            return;
        }
    }
}

/// Reads one length-prefixed frame body, or `None` at a clean EOF.
fn read_frame(reader: &mut impl Read) -> std::io::Result<Option<Vec<u8>>> {
    let mut length = [0u8; 4];
    match reader.read_exact(&mut length) {
        Ok(()) => {},
        Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let declared = u32::from_be_bytes(length) as usize;
    if declared > MAX_FRAME {
        // Validate-then-drop: a length this size is either a bug or hostile, and either way the
        // stream can no longer be resynchronised — the connection ends rather than allocating.
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("frame of {declared} bytes"),
        ));
    }
    let mut body = vec![0u8; declared];
    reader.read_exact(&mut body)?;
    Ok(Some(body))
}

/// Decodes and serves one request body. Pure apart from the registry — the tests drive it directly.
#[must_use]
pub fn serve_request(body: &[u8], registry: &Mutex<Registry>) -> (Status, Vec<u8>) {
    let request = match decode_request(body) {
        Ok(request) => request,
        Err(error) => return (Status::BadRequest, error.to_string().into_bytes()),
    };
    let geometry_free = matches!(
        request.verb,
        Verb::Hello | Verb::Forget | Verb::Collapse | Verb::PromptEolMarks
    );
    if !geometry_free && !geometry_is_sane(&request) {
        return (
            Status::BadRequest,
            format!("geometry {}x{} out of range", request.rows, request.cols).into_bytes(),
        );
    }
    match request.verb {
        // `CARGO_PKG_VERSION` is read HERE, in the daemon's own crate, rather than inside
        // `hello_payload` — see that function for why the wire crate's version would be the wrong
        // string. This is the version of the process answering, not of the binary on disk.
        Verb::Hello => (Status::Ok, hello_payload(env!("CARGO_PKG_VERSION"))),
        Verb::Snapshot => {
            let mut model = ScreenModel::new(request.rows, request.cols);
            model.feed(request.raw);
            encode_snapshot(&model)
        },
        Verb::Feed => {
            let reset = request.flags & FLAG_RESET != 0;
            let mut guard = registry.lock().unwrap_or_else(PoisonError::into_inner);
            let model = guard.model_mut(request.pane, request.rows, request.cols, reset);
            model.feed(request.raw);
            let reply = encode_snapshot(model);
            drop(guard);
            reply
        },
        Verb::Forget => {
            registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .forget(request.pane);
            (Status::Ok, Vec::new())
        },
        Verb::Compose => {
            // The head only reaches the parser: a sequence or scalar the chunk cut in half would
            // otherwise be consumed and DROPPED, and the live tail's continuation bytes would then
            // render as garbage on their own.
            let (head, dangling) = boundary::split_trailing_incomplete(request.raw);
            let mut model = ScreenModel::with_scrollback(request.rows, request.cols, SCROLLBACK_LINE_BUDGET);
            model.feed(head);
            let mut out = render(&model.replay_snapshot(), &[]);
            if request.flags & FLAG_REASSERT_INPUT_MODES != 0 {
                // Computed from the head, not the rendered screen: the render reproduces a SCREEN,
                // and input modes are not screen state — nothing in it says `?1002h`.
                out.extend_from_slice(&inputmode::final_state(head).reassert_sequence());
            }
            // Last, so the reassert cannot land inside the split sequence.
            out.extend_from_slice(dangling);
            (Status::Ok, out)
        },
        Verb::Transcript => {
            // The dangling half is DROPPED rather than held back: this stream ended with the
            // process that wrote it, so no continuation will ever arrive to reunite with it.
            let (head, _dropped) = boundary::split_trailing_incomplete(request.raw);
            let mut model = ScreenModel::with_scrollback(request.rows, request.cols, SCROLLBACK_LINE_BUDGET);
            model.feed(head);
            (Status::Ok, render_transcript(&model.replay_snapshot()))
        },
        Verb::Collapse => (Status::Ok, collapse(request.raw)),
        Verb::PromptEolMarks => (Status::Ok, prompteol::strip(request.raw)),
        Verb::Detect => serve_detect(&request, registry),
    }
}

/// One detection tick: fold the pane's new bytes into its grid and its two trackers, then answer
/// the VERDICT — never the screen.
fn serve_detect(request: &Request<'_>, registry: &Mutex<Registry>) -> (Status, Vec<u8>) {
    let Some((agent, bytes)) = decode_detect_payload(request.raw) else {
        return (Status::BadRequest, b"detect payload truncated".to_vec());
    };
    let mut guard = registry.lock().unwrap_or_else(PoisonError::into_inner);
    let (model, pane) = guard.detect_mut(
        request.pane,
        request.rows,
        request.cols,
        request.flags & FLAG_RESET != 0,
    );
    // Both drops happen BEFORE this tick's bytes are folded: an agent change must not let the new
    // agent inherit the old one's title, and a rebuild replays a different stream than the one the
    // frame parser was positioned in.
    if request.flags & FLAG_AGENT_CHANGED != 0 {
        pane.osc.clear_retained();
    }
    if request.flags & FLAG_REBUILD_REPLAY != 0 {
        pane.sync.reset();
    }
    model.feed(bytes);
    pane.observe(bytes);
    let input = pane.input(detection_text(&model.snapshot().lines));
    let mut verdict = detect(agent, &input);
    verdict.frame_open = pane.sync.is_frame_open();
    verdict.frame_generation = pane.sync.generation();
    drop(guard);
    match serde_json::to_vec(&verdict) {
        Ok(payload) => (Status::Ok, payload),
        Err(error) => (Status::Internal, error.to_string().into_bytes()),
    }
}

/// A geometry the model would silently clamp is a CALLER bug (a mis-encoded frame, a zero size from
/// an un-sized PTY) — answered rather than served, so it surfaces instead of producing a screen at
/// the wrong width.
const fn geometry_is_sane(request: &Request<'_>) -> bool {
    request.rows >= 1 && request.rows <= MAX_ROWS && request.cols >= 1 && request.cols <= MAX_COLS
}

fn encode_snapshot(model: &ScreenModel) -> (Status, Vec<u8>) {
    match serde_json::to_vec(&model.snapshot()) {
        Ok(payload) => (Status::Ok, payload),
        Err(error) => (Status::Internal, error.to_string().into_bytes()),
    }
}

/// The default socket path, read out of this process's environment: `slopdesk-screend.sock` under
/// `$TMPDIR`, or wherever `$SLOPDESK_SCREEND_SOCKET` names.
///
/// The RULE is [`crate::protocol::socket_path`] and only the environment lookup is here, because
/// the client end resolves the same address and had been resolving it differently — see that
/// function. No pid in the name either way (`slopdesk-invariants` ratchets it): a child that
/// inherited the path must still find the service after a restart.
#[must_use]
pub fn default_socket_path() -> PathBuf {
    crate::protocol::socket_path(
        std::env::var_os(crate::protocol::SOCKET_ENV_KEY).as_deref(),
        std::env::var_os("TMPDIR").as_deref(),
    )
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use std::sync::Mutex;

    use super::{Registry, serve_request};
    use crate::protocol::{FLAG_RESET, HELLO_BANNER, Request, Status, Verb, encode_request};

    fn call(request: &Request<'_>, registry: &Mutex<Registry>) -> (Status, Vec<u8>) {
        let frame = encode_request(request);
        serve_request(&frame[4..], registry)
    }

    fn plain(verb: Verb, raw: &[u8]) -> Request<'_> {
        Request {
            verb,
            flags: 0,
            rows: 4,
            cols: 20,
            pane: "",
            raw,
        }
    }

    #[test]
    fn hello_still_leads_with_the_pinned_banner() {
        let registry = Mutex::new(Registry::new());
        let (status, payload) = call(&plain(Verb::Hello, b""), &registry);
        assert_eq!(status, Status::Ok);
        // A PREFIX, not an equality: the build version follows. Asserted as a prefix rather than
        // against the whole composed string because that is the promise the appended field makes —
        // every reader that only knows the banner keeps matching.
        assert!(payload.starts_with(HELLO_BANNER), "hello lost its banner prefix");
    }

    #[test]
    fn hello_carries_the_running_builds_version_after_the_banner() {
        let registry = Mutex::new(Registry::new());
        let (_, payload) = call(&plain(Verb::Hello, b""), &registry);
        let text = String::from_utf8(payload).expect("the hello payload is UTF-8");

        // `slopdesk-screend <protocol> <build version>` — the version is the THIRD field, and this
        // asserts the position rather than the string, for the reason the `--version` banner test
        // in `slopdesk-ctl` gives: hostd parses a position, so the position is the contract.
        let mut fields = text.split(' ');
        assert_eq!(fields.next(), Some("slopdesk-screend"));
        assert!(fields.next().is_some(), "the protocol digit went missing");
        assert_eq!(fields.next(), Some(env!("CARGO_PKG_VERSION")));
        assert_eq!(fields.next(), None, "hello grew a fourth field nothing parses");
    }

    #[test]
    fn a_stateless_snapshot_starts_from_a_blank_grid_every_time() {
        let registry = Mutex::new(Registry::new());
        let (_, first) = call(&plain(Verb::Snapshot, b"one"), &registry);
        let (_, second) = call(&plain(Verb::Snapshot, b"two"), &registry);
        let first: serde_json::Value = serde_json::from_slice(&first).expect("json");
        let second: serde_json::Value = serde_json::from_slice(&second).expect("json");
        assert_eq!(first["lines"][0], "one");
        assert_eq!(
            second["lines"][0], "two",
            "no state carried between stateless calls"
        );
    }

    #[test]
    fn a_feed_accumulates_per_pane_and_forget_drops_it() {
        let registry = Mutex::new(Registry::new());
        let mut request = plain(Verb::Feed, b"ab");
        request.pane = "p1";
        call(&request, &registry);
        request.raw = b"cd";
        let (_, payload) = call(&request, &registry);
        let value: serde_json::Value = serde_json::from_slice(&payload).expect("json");
        assert_eq!(value["lines"][0], "abcd");

        let mut forget = plain(Verb::Forget, b"");
        forget.pane = "p1";
        call(&forget, &registry);

        request.raw = b"ef";
        let (_, payload) = call(&request, &registry);
        let value: serde_json::Value = serde_json::from_slice(&payload).expect("json");
        assert_eq!(value["lines"][0], "ef", "the model was dropped");
    }

    #[test]
    fn a_reset_flag_rebuilds_the_resident_model() {
        let registry = Mutex::new(Registry::new());
        let mut request = plain(Verb::Feed, b"ab");
        request.pane = "p1";
        call(&request, &registry);
        request.flags = FLAG_RESET;
        request.raw = b"z";
        let (_, payload) = call(&request, &registry);
        let value: serde_json::Value = serde_json::from_slice(&payload).expect("json");
        assert_eq!(value["lines"][0], "z");
    }

    #[test]
    fn a_bad_frame_and_a_bad_geometry_answer_instead_of_trapping() {
        let registry = Mutex::new(Registry::new());
        let (status, _) = serve_request(&[9, 9], &registry);
        assert_eq!(status, Status::BadRequest, "truncated body");

        let mut request = plain(Verb::Snapshot, b"x");
        request.rows = 0;
        let (status, payload) = call(&request, &registry);
        assert_eq!(status, Status::BadRequest);
        assert!(String::from_utf8_lossy(&payload).contains("out of range"));
    }

    #[test]
    fn compose_renders_bytes_a_fresh_model_reproduces() {
        let registry = Mutex::new(Registry::new());
        let (status, rendered) = call(&plain(Verb::Compose, b"hello\r\nworld"), &registry);
        assert_eq!(status, Status::Ok);
        let (_, direct) = call(&plain(Verb::Snapshot, b"hello\r\nworld"), &registry);
        let (_, replayed) = call(&plain(Verb::Snapshot, &rendered), &registry);
        assert_eq!(replayed, direct, "the rendered stream reproduces the screen");
    }
}
