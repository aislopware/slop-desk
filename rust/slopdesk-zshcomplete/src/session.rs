//! The captive zsh: one warm interactive shell, driven by file and answered by file.
//!
//! ## Why a shell of its own, and never the pane's
//! `CLAUDE.md`'s superd rule is the constraint: superd owns `read` on every pane PTY, and a second
//! reader steals bytes rather than observing them. Completion cannot ride the pane. It also must
//! not: a completion function may run arbitrary code, and running it in the shell the user's work
//! is in would let a stray `cd` or a clobbered variable follow them out of the request.
//!
//! ## Why one shell for the host and not one per pane
//! The drive widget takes the working directory as part of the REQUEST and `cd`s to it before
//! completing, so a pane contributes nothing a request cannot carry. One warm shell costs one idle
//! process; one per pane would cost the 4-second `~/.zshrc` warm-up per pane and hold a zsh open
//! for every tab a user ever splits.
//!
//! ## Why the warm-up is on a thread and the request is not
//! Sourcing a real `~/.zshrc` and `compinit` takes seconds — the user's plugins are the cost, and
//! there is nothing to optimise because the point of this whole design is that their setup runs
//! unchanged. A request costs 11–92 ms once that is paid. So the shell is started on a thread by
//! the first request, which answers nothing, and every request after it is served in place: the
//! trait's "an implementation MAY block" budget is for milliseconds, not for someone's plugin
//! manager.

use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};
use std::{process, thread};

use crate::parse::{self, CandidateGroup};
use crate::setup::SETUP;
use crate::whence::{self, WHENCE_SETUP, WordVerdict};

/// How long a request may wait for the shell before it is given up on.
///
/// Sized from measurement, not from taste: the slowest real request in this repository's checkout
/// is `git com` cold at 92 ms and `git checkout ` at 64 ms, so this is roughly four times the worst
/// observed answer. It is a latency budget rather than a correctness one — the caller gets the
/// local sources' candidates either way, and a completion that arrives after the user has typed
/// three more characters is not one they wanted.
pub const DEADLINE: Duration = Duration::from_millis(400);

/// How often the answer file is re-read while a request is outstanding. Small enough that the
/// median 25 ms request is not rounded up appreciably, large enough that a 400 ms wait is 200
/// `read`s of a file that is almost always in the page cache.
const POLL: Duration = Duration::from_millis(2);

/// How many consecutive deadline misses retire the shell.
///
/// One is a slow completion function — a `git` completion on a cold repository is genuinely slow
/// once. Two in a row is a shell that is wedged behind something that will not finish, and the
/// 4-second respawn is cheaper than never answering again.
const STRIKES_BEFORE_RESPAWN: u32 = 2;

/// What one request produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Answer {
    /// zsh answered. May be empty — a request with genuinely nothing to complete.
    Groups(Vec<CandidateGroup>),
    /// The shell is not warm yet, or this request did not finish inside [`DEADLINE`]. TRANSIENT:
    /// the next request may well be served, so a caller keeps asking.
    NotReady,
    /// This host's login shell is not zsh. PERMANENT for the life of the host, and distinct from
    /// [`Answer::NotReady`] precisely so a client can stop asking rather than retry a shell that
    /// will never exist. `docs/DECISIONS.md` item (6) keeps the bridge zsh-only.
    NotZsh,
}

/// What one [`ZshComplete::whence`] request produced.
///
/// Its own enum rather than a variant of [`Answer`], because the two verbs answer different
/// questions and a caller that took `Answer` would have to handle a `Groups` it can never get. The
/// two "no" arms carry the same meanings as [`Answer`]'s, and deliberately so — the fact that this
/// host has no zsh is one fact, and a client latches it once for both verbs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdicts {
    /// zsh answered. One record per word it was asked about, in the order they were asked, minus
    /// any the frame could not carry.
    Words(Vec<WordVerdict>),
    /// The shell is not warm yet, or this request did not finish inside [`whence::DEADLINE`].
    /// TRANSIENT.
    NotReady,
    /// This host's login shell is not zsh. PERMANENT, exactly as [`Answer::NotZsh`].
    NotZsh,
}

/// The bridge onto zsh's own completion system.
///
/// One per host. Cloneable through [`Arc`] by construction — the state is behind one, so a handle
/// costs a pointer and every clone drives the same shell.
#[derive(Debug)]
pub struct ZshComplete {
    shell: Option<String>,
    state: Arc<Mutex<State>>,
    deadline: Duration,
    /// The user's rc files, or the suite's synthetic setup instead. See [`ZshComplete::hermetic`].
    rc: Rc,
}

/// What the captive shell is set up from.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Rc {
    /// The user's own `~/.zshrc` and everything it installs. The whole point of the design, and the
    /// only variant a host ever uses.
    Users,
    /// `zsh -f` plus `compinit` plus the given zsh text. See [`ZshComplete::hermetic`].
    Synthetic(String),
}

impl ZshComplete {
    /// A bridge onto `shell`, which is the host's `$SHELL`.
    ///
    /// Nothing is spawned here. A shell whose basename is not `zsh` yields a handle that answers
    /// [`Answer::NotZsh`] for ever and never spawns anything at all — the honest shape, since this
    /// build has no capture half for any other shell.
    #[must_use]
    pub fn new(shell: &str) -> Self {
        let named = Path::new(shell).file_name().and_then(|name| name.to_str());
        Self {
            shell: (named == Some("zsh")).then(|| shell.to_owned()),
            state: Arc::new(Mutex::new(State::default())),
            deadline: DEADLINE,
            rc: Rc::Users,
        }
    }

    /// Whether there is a shell here this build can bridge to at all.
    ///
    /// Cheap and total: it reads the resolved shell name and nothing else — no lock, no request, no
    /// spawn. It has to be, because it is asked BEFORE every request in order to tell the permanent
    /// no from the transient one, and answering it by ASKING would run a completion of the empty
    /// buffer — every executable on `PATH` — on the way to every real completion, and a deadline
    /// missed doing so would count as a strike against the shell it was checking on.
    #[must_use]
    pub const fn bridged(&self) -> bool {
        self.shell.is_some()
    }

    /// A bridge onto `$SHELL`, or onto nothing when the environment names none.
    #[must_use]
    pub fn from_environment() -> Self {
        Self::new(&std::env::var("SHELL").unwrap_or_default())
    }

    /// The same bridge started from `zsh -f`, `compinit` and `prelude` instead of the user's rc.
    ///
    /// The suite's shape and nothing else, and it exists for one reason: the `compadd` scan is the
    /// part of this crate that no fixture can check, and checking it against whatever completions
    /// happen to be installed on the machine running the suite is not a test — the first attempt
    /// asserted things about `ls --`, which answers differently on a Mac than on the GNU coreutils
    /// the author's own shell had on its PATH. `prelude` is zsh text defining a completion whose
    /// answers the test knows, so what is being checked is the scan and nothing else.
    #[must_use]
    pub fn hermetic(mut self, prelude: &str) -> Self {
        self.rc = Rc::Synthetic(prelude.to_owned());
        self
    }

    /// The same bridge with a different deadline, for a test that must observe a miss.
    #[must_use]
    pub const fn with_deadline(mut self, deadline: Duration) -> Self {
        self.deadline = deadline;
        self
    }

    /// What zsh's own completion would offer for `buffer` with the caret at `cursor` characters in,
    /// run as if the shell were sitting in `cwd`.
    ///
    /// `cursor` is a CHARACTER index because zsh's `CURSOR` is one. The conversion is the caller's,
    /// and it is the only unit boundary in the whole bridge — every other quantity that crosses is
    /// a string.
    pub fn complete(&self, cwd: &str, buffer: &str, cursor: u32) -> Answer {
        let Some(shell) = self.shell.as_deref() else {
            return Answer::NotZsh;
        };
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(live) = state.live.as_mut() else {
            // The first request pays nothing and answers nothing; it starts the shell the ones
            // after it will use. `starting` is what stops every keystroke until the shell is up
            // from starting a shell of its own.
            if !state.starting {
                state.starting = true;
                start(Arc::clone(&self.state), shell.to_owned(), self.rc.clone());
            }
            return Answer::NotReady;
        };
        if let Some(groups) = live.request(cwd, buffer, cursor, self.deadline) {
            live.strikes = 0;
            return Answer::Groups(groups);
        }
        live.strikes += 1;
        if live.strikes >= STRIKES_BEFORE_RESPAWN {
            // Dropping the shell here rather than respawning in place keeps the restart on the same
            // lazy path as the first start: the NEXT request kicks the thread, and this one still
            // returns inside its deadline.
            state.live = None;
        }
        Answer::NotReady
    }

    /// What the user's own shell says each of `words` IS, asked from `cwd`.
    ///
    /// The question a prompt paints an unknown command from, and it rides this shell for the reason
    /// [`crate::whence`] opens with: `PATH` is the small half of the answer.
    ///
    /// ⚠️ **A miss here is not a strike.** [`whence::DEADLINE`] is a fraction of [`DEADLINE`],
    /// because this runs no completion function and has no business being slow — but that also
    /// makes it far likelier to be missed by a shell that is merely busy, and two such misses
    /// under [`STRIKES_BEFORE_RESPAWN`] would `SIGKILL` a perfectly healthy shell and cost the
    /// user a 4-second warm-up. The strike counter exists to retire a WEDGED shell, and a
    /// wedged shell misses completions too; letting the tighter deadline vote would be reading
    /// a different fact through the same counter.
    ///
    /// It does not start the shell either: the first request is a completion or nothing, so a
    /// colour never pays for a warm-up it would not live long enough to use.
    pub fn whence(&self, cwd: &str, words: &[String]) -> Verdicts {
        if self.shell.is_none() {
            return Verdicts::NotZsh;
        }
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(live) = state.live.as_mut() else {
            return Verdicts::NotReady;
        };
        let answered = live.whence(cwd, words);
        drop(state); // The next request may go out while this one is being shaped into an answer.
        answered.map_or(Verdicts::NotReady, Verdicts::Words)
    }
}

/// The shell, or the fact that one is being started.
#[derive(Debug, Default)]
struct State {
    live: Option<Live>,
    starting: bool,
}

/// Starts a shell on its own thread and installs it when it is warm.
///
/// A failure leaves `starting` false and `live` empty, so the next request tries again. That is the
/// right retry policy for the one failure mode there is — a machine that was momentarily out of
/// process slots or temp space.
fn start(state: Arc<Mutex<State>>, shell: String, rc: Rc) {
    // Detached deliberately: nothing waits on this handle. The shell installs itself when it is
    // ready and the requests in between answer `NotReady`, which is the same answer they would give
    // while holding a join handle nobody may block on.
    drop(thread::spawn(move || {
        let live = Live::start(&shell, &rc);
        let mut held = state.lock().unwrap_or_else(PoisonError::into_inner);
        held.starting = false;
        held.live = live;
    }));
}

/// One warm captive shell and the two files it is spoken to through.
#[derive(Debug)]
struct Live {
    /// The PTY master, for the one keystroke that drives a request. `zle` needs a terminal; nothing
    /// is ever read back from it here — see [`drain`].
    master: File,
    pid: i32,
    home: PathBuf,
    request: PathBuf,
    output: PathBuf,
    seq: u64,
    strikes: u32,
    /// Whether an abandoned request may still be writing. While it is, the answer file must NOT be
    /// truncated: the late records are what the sequence window discards, and a truncation would
    /// instead race the writer's offset.
    dirty: bool,
}

impl Live {
    /// Spawns the shell, sources the setup into it and waits for the readiness marker.
    ///
    /// Seconds, and on a thread for exactly that reason. `None` on any failure — there is no
    /// partial success to hold on to, and every caller's answer for "no shell" is already
    /// [`Answer::NotReady`].
    fn start(shell: &str, rc: &Rc) -> Option<Self> {
        let home = session_directory()?;
        let request = home.join("request");
        let output = home.join("answer");
        let setup = home.join("setup.zsh");
        // The setup is written to a file and sourced rather than typed, because the pty is in
        // canonical mode and truncates an input line at `MAX_CANON` — about 1024 bytes, and this is
        // several times that. The one line that IS typed is the `source`.
        fs::write(&setup, script(rc)).ok()?;
        fs::write(&request, "").ok()?;
        fs::write(&output, "").ok()?;

        let mut environment: Vec<String> = std::env::vars()
            .filter(|(name, _ignored)| !name.starts_with("SLOPDESK_ZC_"))
            .map(|(name, value)| format!("{name}={value}"))
            .collect();
        environment.push(format!("SLOPDESK_ZC_REQ={}", request.display()));
        environment.push(format!("SLOPDESK_ZC_OUT={}", output.display()));
        environment.push(format!("SLOPDESK_ZC_SETUP={}", setup.display()));
        // A terminal name zsh will run `zle` under, and a window big enough that no completion
        // function decides to paginate. Neither is ever rendered: nothing reads the master.
        environment.push("TERM=xterm-256color".to_owned());
        environment.push("COLUMNS=200".to_owned());
        environment.push("LINES=1000".to_owned());

        // `-i` because only an interactive shell has `zle`, which is the only context
        // `_main_complete` is legal in. `-f` additionally skips the user's rc files, which is the
        // suite's shape and never the host's.
        let arguments: Vec<String> = match *rc {
            Rc::Users => vec!["-i".to_owned()],
            Rc::Synthetic(_) => vec!["-f".to_owned(), "-i".to_owned()],
        };
        let spawned = slopdesk_posix::pty::spawn_pty(&slopdesk_posix::pty::SpawnPlan {
            executable: shell,
            argv0: None,
            arguments: &arguments,
            environment: &environment,
            cwd: home.to_str(),
            rows: 1000,
            cols: 200,
        })
        .ok()?;

        let mut master = File::from(spawned.master);
        // The shell echoes its prompt, its redraws and every completion's terminal output onto the
        // master. Nobody wants any of it, and a pty whose buffer fills BLOCKS the writer — so it is
        // read and dropped for the shell's whole life. The thread ends when the shell does, because
        // the read then fails.
        drain(master.try_clone().ok()?);

        let live = Self {
            master: master.try_clone().ok()?,
            pid: spawned.pid,
            home,
            request,
            output,
            seq: 0,
            strikes: 0,
            dirty: false,
        };
        master.write_all(b"source $SLOPDESK_ZC_SETUP\n").ok()?;
        live.await_marker()?;
        Some(live)
    }

    /// Waits for the setup's readiness line.
    ///
    /// The budget is generous on purpose: it is bounded by the user's `~/.zshrc`, which this design
    /// exists to run unmodified, and a plugin manager that installs something on first run is a
    /// real and legitimate reason for a slow start.
    fn await_marker(&self) -> Option<()> {
        let until = Instant::now() + Duration::from_secs(30);
        while Instant::now() < until {
            if read(&self.output).lines().any(|line| line == "READY") {
                return Some(());
            }
            thread::sleep(POLL);
        }
        None
    }

    /// The request path, whole, for every widget bound in the setup. `None` on a deadline miss.
    ///
    /// ⚠️ **One function and not one per verb.** The `dirty` contract is the reason: an abandoned
    /// request keeps writing, so the answer file must not be truncated while it is set — and the
    /// two verbs share that ONE file, so a late completion record and the next whence request
    /// are the same race as two completions. A second hand-copied poll loop is where that check
    /// goes missing.
    ///
    /// `body` is given the sequence because every frame's first line is it; `key` is the widget's
    /// binding; `answered` is the verb's own reader, which returns `None` until its `END` lands.
    fn ask<T>(
        &mut self,
        body: impl FnOnce(u64) -> String,
        key: &[u8],
        deadline: Duration,
        answered: impl Fn(&str, u64) -> Option<T>,
    ) -> Option<T> {
        self.seq += 1;
        let seq = self.seq;
        if !self.dirty {
            // Safe only because the previous request finished: nothing else holds this file open
            // for writing.
            drop(fs::write(&self.output, ""));
        }
        fs::write(&self.request, body(seq)).ok()?;
        // One keystroke rather than a typed command, so the request's text never crosses the
        // terminal at all.
        self.master.write_all(key).ok()?;

        let until = Instant::now() + deadline;
        loop {
            if let Some(answer) = answered(&read(&self.output), seq) {
                self.dirty = false;
                return Some(answer);
            }
            if Instant::now() >= until {
                self.dirty = true;
                return None;
            }
            thread::sleep(POLL);
        }
    }

    /// One completion request, start to finish.
    fn request(
        &mut self,
        cwd: &str,
        buffer: &str,
        cursor: u32,
        deadline: Duration,
    ) -> Option<Vec<CandidateGroup>> {
        // Line 1 is the sequence, 2 the caret, 3 the directory, and everything after it the buffer
        // — joined back with newlines by the widget, so a multi-line command survives the trip and
        // no text ever has to be escaped for a terminal.
        self.ask(
            |seq| format!("{seq}\n{cursor}\n{cwd}\n{buffer}\n"),
            COMPLETE_KEY,
            deadline,
            parse::answer,
        )
    }

    /// One whence request, start to finish.
    fn whence(&mut self, cwd: &str, words: &[String]) -> Option<Vec<WordVerdict>> {
        self.ask(
            |seq| whence::request(seq, cwd, words),
            whence::DRIVE_KEY,
            whence::DEADLINE,
            whence::answer,
        )
    }
}

/// The keystroke the setup bound the completion widget to.
const COMPLETE_KEY: &[u8] = b"\x18\x01";

impl Drop for Live {
    fn drop(&mut self) {
        // `SIGKILL` rather than `SIGHUP`: this shell has no work to finish and no state to save,
        // and a wedged completion function is exactly the case a catchable signal would not end.
        let pid = nix::unistd::Pid::from_raw(self.pid);
        let _ignored = nix::sys::signal::kill(pid, nix::sys::signal::Signal::SIGKILL);
        // Reaped here and not left to the host: hostd is long-lived, so an unreaped completion
        // shell would be a zombie for the machine's whole uptime.
        let _reaped = nix::sys::wait::waitpid(pid, None);
        drop(fs::remove_dir_all(&self.home));
    }
}

/// Reads and discards `master` until the shell ends. See [`Live::start`] for why.
fn drain(mut master: File) {
    drop(thread::spawn(move || {
        let mut scratch = [0_u8; 4096];
        while std::io::Read::read(&mut master, &mut scratch).is_ok_and(|read| read > 0) {}
    }));
}

/// The file's text, lossily. Empty when it cannot be read, which is the same thing as "the answer
/// has not arrived" to the one caller that reads it.
///
/// Lossy rather than strict because a candidate can be a FILENAME, and a filename is bytes: a
/// directory holding one non-UTF-8 name would otherwise cost every other candidate in the same
/// answer. The replacement characters land in a candidate that then simply does not match.
fn read(path: &Path) -> String {
    fs::read(path)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .unwrap_or_default()
}

/// A private directory for one shell's three files, or `None` when it cannot be made.
///
/// Named by pid and a counter rather than randomly: two hostds on one machine have different pids,
/// and two bridges in one process differ by the counter. `create_dir` rather than `create_dir_all`
/// so an existing path is an ERROR — this must never adopt a directory it did not make.
fn session_directory() -> Option<PathBuf> {
    static NONCE: AtomicU64 = AtomicU64::new(0);
    let nonce = NONCE.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("slopdesk-zshcomplete-{}-{nonce}", process::id()));
    fs::create_dir(&path).ok()?;
    Some(path)
}

/// The setup text, with the hermetic variant's `compinit` in front of it and its prelude after.
///
/// The prelude goes AFTER because it defines completions, and `compdef` needs the completion system
/// loaded. `-D` skips the dump file, so a hermetic run neither reads a stale `.zcompdump` nor
/// writes one into whoever's home directory the suite happens to run under.
fn script(rc: &Rc) -> String {
    match *rc {
        Rc::Users => format!("{SETUP}\n{WHENCE_SETUP}\n"),
        Rc::Synthetic(ref prelude) => {
            format!("autoload -Uz compinit\ncompinit -D\n{SETUP}\n{WHENCE_SETUP}\n{prelude}\n")
        },
    }
}
