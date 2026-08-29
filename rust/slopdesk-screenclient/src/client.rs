//! The client itself: the address, the pool, the autostart and the ten verbs.
//!
//! The port of hostd's Swift screend client, deleted in `docs/60` Batch B.
//!
//! ## Why the engine is not in this process
//! Parsing a terminal stream into an attributed grid is the hottest byte path hostd has: a cold
//! reattach composes the whole retained ring, and iOS drops TCP seconds after backgrounding, so
//! every foreground does it again. In Swift the grid was `[[Cell]]` with a `String` per cell, and
//! the ARC traffic plus the nested-array uniqueness check on every printed character measured
//! 17.9 MiB/s against 186 MiB/s for the same corpus in Rust. That is a structural gap, not a tuning
//! one — hence a separate binary over a socket.
//!
//! That argument decided the DAEMON, and it still holds now that the caller is Rust too: screend is
//! installed as a `LaunchAgent` and outlives hostd's build, it holds forty panes' grids that hostd
//! must not carry across its own restarts, and a screen model that panics takes down a daemon whose
//! state is a cache rather than the host that owns every PTY.
//!
//! ## Blocking on purpose
//! Every call site is a synchronous transform in the middle of a byte pipeline (the replay
//! composer, the detection scan, the `screen` verb). A round trip on an `AF_UNIX` socket is ~11 µs
//! of transport; making these `async` would restructure four call sites to save nothing.
//!
//! ## Absent screend degrades, never crashes
//! The daemon holds no durable state — its per-pane models are a cache a repaint refills — so a
//! missing or crashed screend is recoverable by construction. Each verb's caller has a documented
//! PASSTHROUGH answer, never a second parser.

use std::fmt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use slopdesk_screenwire::{
    FLAG_AGENT_CHANGED, FLAG_REASSERT_INPUT_MODES, FLAG_REBUILD_REPLAY, FLAG_RESET, Request, Snapshot,
    Status, Verb, Verdict, decode_reply, decode_snapshot, decode_verdict, encode_detect_payload,
    encode_request,
};

use crate::paths;
use crate::transport::{ClientError, exchange};

/// Seconds between spawn attempts.
const START_BACKOFF: Duration = Duration::from_secs(2);

/// How long to wait for a freshly spawned screend to bind.
const START_TIMEOUT: Duration = Duration::from_secs(3);

/// How often the bind wait re-dials while it waits.
const START_POLL: Duration = Duration::from_millis(10);

/// Idle connections kept for reuse.
///
/// Above this the extra sockets are closed rather than pooled — a burst of parallel composes should
/// not leave hostd holding descriptors for the day.
const POOL_LIMIT: usize = 8;

/// Which of `detect`'s three independent questions this call is answering yes to.
///
/// Three separate questions, and a caller answers each on its own. `reset` rebuilds the grid;
/// `rebuild_replay` additionally restarts the synchronized-frame parser, because a scrollback
/// REBUILD is not the same event as a geometry drift the stream continued through; `agent_changed`
/// drops the retained OSC title and progress first, so the previous process's evidence cannot be
/// read as the new one's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DetectFlags {
    /// Rebuild the resident model before folding these bytes.
    pub reset: bool,
    /// These bytes are a scrollback REBUILD replay.
    pub rebuild_replay: bool,
    /// A different agent now holds the pane's foreground.
    pub agent_changed: bool,
}

impl DetectFlags {
    /// The wire's flag byte.
    const fn bits(self) -> u8 {
        let mut flags = 0;
        if self.reset {
            flags |= FLAG_RESET;
        }
        if self.rebuild_replay {
            flags |= FLAG_REBUILD_REPLAY;
        }
        if self.agent_changed {
            flags |= FLAG_AGENT_CHANGED;
        }
        flags
    }
}

/// The idle sockets, and the address they lead to.
#[derive(Debug, Default)]
struct Pool {
    idle: Vec<std::os::unix::net::UnixStream>,
    /// A changed address invalidates them all — they lead to a different engine, or to nothing.
    path: Option<PathBuf>,
}

/// hostd's client for `slopdesk-screend`.
pub struct ScreenClient {
    /// Resolved PER CALL, not captured at construction.
    ///
    /// [`shared`] is a process-wide singleton, so whoever touches it first would otherwise freeze
    /// the address for the process — and in a test run that is whichever suite happens to sort
    /// first, before the fixture has pointed the environment at its private engine. Reading the
    /// environment each time costs a `getenv` against a round trip, and makes the aiming order
    /// irrelevant.
    resolve_socket_path: Box<dyn Fn() -> PathBuf + Send + Sync>,
    resolve_binary_path: Box<dyn Fn() -> Option<PathBuf> + Send + Sync>,
    autostart: bool,
    pool: Mutex<Pool>,
    /// Held across a whole spawn attempt, and holding the monotonic time of the last one.
    ///
    /// One lock rather than a lock plus a field: the rate limit and the spawn are the same critical
    /// section, and a screend that cannot start (missing binary, a crash loop) must not be
    /// re-forked once per detection tick across every pane.
    last_start_attempt: Mutex<Option<Instant>>,
}

impl fmt::Debug for ScreenClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let pooled = self
            .pool
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .idle
            .len();
        formatter
            .debug_struct("ScreenClient")
            .field("autostart", &self.autostart)
            .field("pooled", &pooled)
            .finish_non_exhaustive()
    }
}

impl Default for ScreenClient {
    fn default() -> Self {
        Self::new()
    }
}

/// The process-wide client, addressed from the environment.
///
/// A single instance so the connection pool is shared: the detection scans of forty panes are forty
/// callers, and each holding its own socket would be forty threads parked in screend.
#[must_use]
pub fn shared() -> &'static ScreenClient {
    static SHARED: OnceLock<ScreenClient> = OnceLock::new();
    SHARED.get_or_init(ScreenClient::new)
}

impl ScreenClient {
    /// The general form: the address is a QUESTION, asked whenever one is needed.
    #[must_use]
    pub fn new() -> Self {
        Self::with_resolvers(
            Box::new(paths::request_socket_from_env),
            Box::new(paths::binary_from_env),
            true,
        )
    }

    /// A client pinned to one address — the test fixture's private engine, or a gate's.
    #[must_use]
    pub fn pinned(socket_path: PathBuf, binary_path: Option<PathBuf>, autostart: bool) -> Self {
        Self::with_resolvers(
            Box::new(move || socket_path.clone()),
            Box::new(move || binary_path.clone()),
            autostart,
        )
    }

    /// The form the other two are made of.
    #[must_use]
    pub fn with_resolvers(
        resolve_socket_path: Box<dyn Fn() -> PathBuf + Send + Sync>,
        resolve_binary_path: Box<dyn Fn() -> Option<PathBuf> + Send + Sync>,
        autostart: bool,
    ) -> Self {
        Self {
            resolve_socket_path,
            resolve_binary_path,
            autostart,
            pool: Mutex::new(Pool::default()),
            last_start_attempt: Mutex::new(None),
        }
    }

    // ------------------------------------------------------------------ verbs

    /// Parses `raw` into a FRESH grid and answers what it shows. Nothing is retained.
    ///
    /// # Errors
    /// [`ClientError`], every variant.
    pub fn snapshot(&self, raw: &[u8], rows: usize, cols: usize) -> Result<Snapshot, ClientError> {
        let body = self.request(&Request {
            verb: Verb::Snapshot,
            flags: 0,
            rows,
            cols,
            pane: "",
            raw,
        })?;
        decode_snapshot(&body).map_err(|_| ClientError::MalformedReply)
    }

    /// Appends `raw` to `pane`'s resident model and answers what it shows.
    ///
    /// `reset` rebuilds the model first — a resize, a ring overflow, the first scan. A geometry
    /// change resets implicitly on screend's side: a VT model cannot be reflowed, so a model at the
    /// wrong size is not a model that needs adjusting, it is the wrong model.
    ///
    /// # Errors
    /// [`ClientError`], every variant.
    pub fn feed(
        &self,
        pane: &str,
        raw: &[u8],
        rows: usize,
        cols: usize,
        reset: bool,
    ) -> Result<Snapshot, ClientError> {
        let body = self.request(&Request {
            verb: Verb::Feed,
            flags: if reset { FLAG_RESET } else { 0 },
            rows,
            cols,
            pane,
            raw,
        })?;
        decode_snapshot(&body).map_err(|_| ClientError::MalformedReply)
    }

    /// Folds `raw` into `pane`'s grid, OSC tracker and synchronized-frame parser, and answers what
    /// the screen now SAYS about `agent`.
    ///
    /// One round trip where there used to be four walks of the same chunk: the grid across this
    /// socket, then the OSC tracker, the frame parser and ~20 backtracking regexes in hostd, over a
    /// whole grid shipped back as JSON every ~300 ms per pane. The bytes go one way now and ~150
    /// bytes of verdict come back.
    ///
    /// An EMPTY `agent` folds without running the ladder — the answer is then `unknown` with the
    /// frame fields still filled in.
    ///
    /// # Errors
    /// [`ClientError`], every variant.
    pub fn detect(
        &self,
        pane: &str,
        agent: &str,
        raw: &[u8],
        rows: usize,
        cols: usize,
        flags: DetectFlags,
    ) -> Result<Verdict, ClientError> {
        let payload = encode_detect_payload(agent, raw);
        let body = self.request(&Request {
            verb: Verb::Detect,
            flags: flags.bits(),
            rows,
            cols,
            pane,
            raw: &payload,
        })?;
        decode_verdict(&body).map_err(|_| ClientError::MalformedReply)
    }

    /// Drops `pane`'s resident model.
    ///
    /// Best-effort and returns nothing: screend evicts on its own when the table is full, so a lost
    /// `forget` costs memory until then and nothing else. A caller with nothing to do about the
    /// failure should not be handed one to ignore.
    pub fn forget(&self, pane: &str) {
        let _ignored = self.request(&Request {
            verb: Verb::Forget,
            flags: 0,
            rows: 0,
            cols: 0,
            pane,
            raw: &[],
        });
    }

    /// Renders the minimal VT stream that reproduces what `raw` puts on a `rows`×`cols` screen.
    ///
    /// `reassert_input_modes` appends the net input-mode state of `raw` after the render — computed
    /// from the RAW bytes, because a render reproduces a SCREEN and input modes are not screen
    /// state: nothing in a rendered grid says `?1002h`.
    ///
    /// # Errors
    /// [`ClientError`], every variant.
    pub fn compose(
        &self,
        raw: &[u8],
        rows: usize,
        cols: usize,
        reassert_input_modes: bool,
    ) -> Result<Vec<u8>, ClientError> {
        self.request(&Request {
            verb: Verb::Compose,
            flags: if reassert_input_modes {
                FLAG_REASSERT_INPUT_MODES
            } else {
                0
            },
            rows,
            cols,
            pane: "",
            raw,
        })
    }

    /// Renders `raw` as a plain transcript — scrollback and grid, no modes re-asserted.
    ///
    /// # Errors
    /// [`ClientError`], every variant.
    pub fn transcript(&self, raw: &[u8], rows: usize, cols: usize) -> Result<Vec<u8>, ClientError> {
        self.request(&Request {
            verb: Verb::Transcript,
            flags: 0,
            rows,
            cols,
            pane: "",
            raw,
        })
    }

    /// Drops the superseded revisions of every line a progress reporter overprints with `CR`.
    ///
    /// # Errors
    /// [`ClientError`], every variant.
    pub fn collapse(&self, raw: &[u8]) -> Result<Vec<u8>, ClientError> {
        self.request(&Request {
            verb: Verb::Collapse,
            flags: 0,
            rows: 0,
            cols: 0,
            pane: "",
            raw,
        })
    }

    /// Normalises zsh's `PROMPT_SP` mark+fill clusters, and nothing else — for the caller holding
    /// one captured command block, where the rest of the transform would be wrong.
    ///
    /// # Errors
    /// [`ClientError`], every variant.
    pub fn prompt_eol_marks(&self, raw: &[u8]) -> Result<Vec<u8>, ClientError> {
        self.request(&Request {
            verb: Verb::PromptEolMarks,
            flags: 0,
            rows: 0,
            cols: 0,
            pane: "",
            raw,
        })
    }

    /// Round-trips a `hello`. Used by the gates and the test fixture to wait for a bind.
    ///
    /// # Errors
    /// [`ClientError`], every variant. A reply that is not UTF-8 is
    /// [`ClientError::MalformedReply`] — the banner is ASCII by construction, so anything else is a
    /// different protocol on this socket.
    pub fn hello(&self) -> Result<String, ClientError> {
        let body = self.request(&Request {
            verb: Verb::Hello,
            flags: 0,
            rows: 0,
            cols: 0,
            pane: "",
            raw: &[],
        })?;
        String::from_utf8(body).map_err(|_| ClientError::MalformedReply)
    }

    /// The crate version of the screend actually serving this socket, or `None` when it predates
    /// the field. One round trip; the caller compares it against `slopdesk-screend --version`
    /// on disk.
    ///
    /// # Errors
    /// [`ClientError`], every variant.
    pub fn build_version(&self) -> Result<Option<String>, ClientError> {
        let hello = self.hello()?;
        Ok(slopdesk_screenwire::build_version(&hello).map(ToOwned::to_owned))
    }

    // -------------------------------------------------------------- transport

    /// One request, one reply.
    ///
    /// Retries ONCE on a transport failure with a fresh connection, because the overwhelmingly
    /// likely cause is a pooled socket whose screend was restarted between calls — `just screend`
    /// during a dev loop, or launchd replacing a crashed one. A second failure is reported.
    ///
    /// An `Unavailable` is NOT retried and does not even reach the loop's second turn: nothing was
    /// listening and nothing could be started, and asking again inside the same microsecond cannot
    /// change that. It propagates out of [`Self::connection`] directly.
    ///
    /// ## Where this diverges from the Swift, deliberately
    /// The original recycled the descriptor into the pool BEFORE decoding the reply, then closed
    /// that same descriptor from the catch block when the decode threw — so a rejected request left
    /// a closed fd in the pool for the next caller to draw. Ownership makes that unspellable here,
    /// and the split is the honest one: a REJECTION is screend answering on a connection that is
    /// still good (`Status::BadRequest`'s own doc says one bad request does not cost the caller its
    /// socket), so that socket goes back in the pool; a MALFORMED reply is a lost frame boundary,
    /// which no stream resynchronises from, so that socket is dropped.
    fn request(&self, request: &Request<'_>) -> Result<Vec<u8>, ClientError> {
        let frame = encode_request(request);
        let mut last_error = None;
        for attempt in 0..2_u8 {
            // A pooled socket is only reused on the FIRST attempt: if it just failed, the second
            // attempt must not draw another corpse from the same pool.
            let path = (self.resolve_socket_path)();
            let stream = self.connection(&path, attempt == 0)?;
            match exchange(&stream, &frame) {
                Ok(body) => {
                    match decode_reply(&body) {
                        Ok((Status::Ok, payload)) => {
                            let payload = payload.to_vec();
                            self.recycle(stream, &path);
                            return Ok(payload);
                        },
                        Ok((status, message)) => {
                            let message = String::from_utf8_lossy(message).into_owned();
                            self.recycle(stream, &path);
                            return Err(ClientError::Rejected { status, message });
                        },
                        Err(_) => {
                            drop(stream);
                            last_error = Some(ClientError::MalformedReply);
                        },
                    }
                },
                Err(error) => {
                    drop(stream);
                    last_error = Some(error);
                },
            }
        }
        Err(last_error.unwrap_or(ClientError::MalformedReply))
    }

    // ------------------------------------------------------------ connections

    fn connection(
        &self,
        path: &Path,
        allow_pooled: bool,
    ) -> Result<std::os::unix::net::UnixStream, ClientError> {
        if allow_pooled && let Some(pooled) = self.take_pooled(path) {
            return Ok(pooled);
        }
        if let Some(stream) = dial(path) {
            return Ok(stream);
        }
        if !self.autostart {
            return Err(ClientError::Unavailable {
                reason: format!("nothing listening at {}", path.display()),
            });
        }
        self.start(path)?;
        dial(path).ok_or_else(|| {
            ClientError::Unavailable {
                reason: format!("screend did not answer at {}", path.display()),
            }
        })
    }

    fn take_pooled(&self, path: &Path) -> Option<std::os::unix::net::UnixStream> {
        let mut pool = self.pool.lock().unwrap_or_else(PoisonError::into_inner);
        let stale = if pool.path.as_deref() == Some(path) {
            Vec::new()
        } else {
            pool.path = Some(path.to_path_buf());
            std::mem::take(&mut pool.idle)
        };
        let pooled = pool.idle.pop();
        drop(pool);
        // Closed outside the lock: a pool that changed address may be holding eight descriptors,
        // and no other caller should wait behind eight `close(2)`s to learn that.
        drop(stale);
        pooled
    }

    fn recycle(&self, stream: std::os::unix::net::UnixStream, path: &Path) {
        let mut pool = self.pool.lock().unwrap_or_else(PoisonError::into_inner);
        let keep = pool.idle.len() < POOL_LIMIT && pool.path.as_deref() == Some(path);
        if keep {
            pool.idle.push(stream);
        }
        drop(pool);
    }

    /// Starts a screend and waits for it to bind.
    ///
    /// Rate-limited; a caller that arrives during the backoff window fails fast and falls back
    /// rather than queueing behind a daemon that is not coming.
    #[expect(
        clippy::significant_drop_tightening,
        reason = "the lock IS the serialisation: released after the rate-limit stamp, as the lint suggests, \
                  two threads would each fork a screend and race to bind the same address"
    )]
    fn start(&self, socket_path: &Path) -> Result<(), ClientError> {
        let mut last_attempt = self
            .last_start_attempt
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        // Another thread may have started one while this one waited for the lock.
        if let Some(stream) = dial(socket_path) {
            drop(stream);
            return Ok(());
        }
        let now = Instant::now();
        if let Some(previous) = *last_attempt
            && now.duration_since(previous) < START_BACKOFF
        {
            return Err(ClientError::Unavailable {
                reason: "screend start backing off".to_owned(),
            });
        }
        *last_attempt = Some(now);
        let Some(binary) = (self.resolve_binary_path)() else {
            return Err(ClientError::Unavailable {
                reason: format!("no slopdesk-screend binary ({})", paths::BINARY_ENV_KEY),
            });
        };

        let child = Command::new(&binary)
            .arg(socket_path)
            .stdin(Stdio::null())
            .stdout(log_sink())
            .stderr(log_sink())
            .spawn()
            .map_err(|error| {
                ClientError::Unavailable {
                    reason: format!("cannot start {}: {error}", binary.display()),
                }
            })?;
        reap(child);

        // A bounded probe for a service to come up, not a sleep: it returns the instant the socket
        // answers, and the ceiling is what turns a screend that will never bind into a fallback
        // rather than a hang.
        let deadline = Instant::now() + START_TIMEOUT;
        while Instant::now() < deadline {
            if let Some(stream) = dial(socket_path) {
                drop(stream);
                return Ok(());
            }
            std::thread::sleep(START_POLL);
        }
        Err(ClientError::Unavailable {
            reason: format!("screend did not bind {} in time", socket_path.display()),
        })
    }
}

/// Connects, or `None`.
///
/// ## Where the `SO_NOSIGPIPE` went
/// The Swift original set it by hand on every descriptor, and had to: the default disposition of
/// `SIGPIPE` is to KILL THE PROCESS, and this client writes to a peer that a `just screend` during
/// a dev loop makes vanish. `SupervisorConnection.swift` carries the same seven lines one lane
/// over.
///
/// Neither is needed here. Rust's std sets `SO_NOSIGPIPE` on every socket it creates on Darwin, so
/// a write to a screend that just died is the `EPIPE` [`crate::transport`] reports rather than a
/// signal — and this crate links INTO hostd, where a process-wide disposition would not have been
/// its to set anyway. `slopdesk-androidd/src/net.rs` records the same disappearance for the same
/// reason.
fn dial(path: &Path) -> Option<std::os::unix::net::UnixStream> {
    std::os::unix::net::UnixStream::connect(path).ok()
}

/// Where a started screend's stdout and stderr go.
///
/// A FILE, never this process's stdio: a screend that outlives its parent while holding the write
/// end of an inherited pipe is how a test harness hangs reading for an EOF that cannot arrive.
/// When the file cannot be opened the answer
/// is `/dev/null` rather than inheritance — the Swift original fell through to inheriting, which is
/// the hang it had just finished explaining.
///
/// APPEND, where the Swift truncated the file on every spawn. A crash loop is the case this log
/// exists for, and truncating means the second attempt erases the first attempt's reason two
/// seconds after it was written — so the one run anybody wants to read is the one that is gone. The
/// growth that buys is bounded by how often a screend gets STARTED, which [`START_BACKOFF`]
/// rate-limits and which is zero on a host whose daemon is already up.
fn log_sink() -> Stdio {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths::log_file(home.as_deref()))
        .map_or_else(|_| Stdio::null(), Stdio::from)
}

/// Waits on a spawned screend from a thread of its own, so a crash loop cannot fill hostd's process
/// table with zombies.
///
/// Foundation's `Process` reaps for you; [`Child`] does not, and a `Child` that is merely dropped
/// leaves the kernel holding an exit status forever. One thread per attempt is affordable because
/// [`START_BACKOFF`] is what bounds the attempts — the pathological case is one thread every two
/// seconds, and each of them exits the moment its screend does.
fn reap(mut child: Child) {
    let _ignored = std::thread::Builder::new()
        .name("screend-reaper".to_owned())
        .spawn(move || {
            let _ignored = child.wait();
        });
}
