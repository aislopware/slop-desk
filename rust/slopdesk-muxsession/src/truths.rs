//! The pane's LATCHED TRUTHS, and the fold that produces them.
//!
//! ## What a truth is
//! A pane says things out of band — a window title, a command starting and ending, an OSC 9;4
//! progress badge, a working directory, a desktop notification, a command block opening and
//! closing. Most of those are EVENTS: they happen, they ship, they are gone. A handful are also
//! STATE, because somebody who was not listening at the time still has to be told: a client that
//! reconnects mid-command asks what is running NOW, and no new event will ever arrive to answer it.
//!
//! That handful is what lives here. Every field is the freshest answer to a question a reattaching
//! client, the `list-panes` verb or the workspace document asks — and nothing else. hostd used to
//! keep them as seven separate stored properties behind seven separate `NSLock`s, each written on
//! the read-loop thread and read from a control socket's, which is seven chances to read two truths
//! that never held at the same instant.
//!
//! ## Why one struct
//! The locks were separate because the FIELDS were separate, not because the truths are. They are
//! folded from ONE batch, in ONE pass, on ONE thread: the title, the command edge, the progress
//! badge and the block that carries them all arrive in the same sniffed batch riding the same PTY
//! chunk. Splitting that fold across seven acquisitions bought no concurrency (the writer is
//! serial) and cost every reader the chance of a torn view.
//!
//! So: one struct, folded once per chunk, and hostd holds it under exactly one lock.
//!
//! ## What deliberately did NOT come here
//! - **The clock.** Both stamps are parameters ([`Stamps`]). Two different clocks are in play on
//!   purpose — a title stamp is compared against superd's `command_running_since`
//!   (`timeIntervalSinceReferenceDate`, a clock that survives sleep) while the agent detector folds
//!   on `systemUptime` — and a fold that read either one itself could not be tested.
//! - **The agent detector.** It is its own machine with its own feeds (`rust/slopdesk-agent`), and
//!   two handles never hold each other. What crosses is a VALUE: hostd reads the detector's
//!   `suppresses_child_notifications` and hands it to [`Truths::ingest_sniffed`] as a gate.
//! - **The wire vocabulary.** A [`Verdict`] names a KIND and a ROUTE, not a frame. Turning a kind
//!   byte into a wire message is the marshaller's job, and the OSC 9;4 grammar that decides what a
//!   progress body MEANS is `slopdesk-wire`'s — this crate never learns either.
//! - **The strings.** A [`Fact`] BORROWS its text and a [`Verdict`] names the fact it came from by
//!   index, so a batch of ten titles crossing the fold allocates nothing.

/// What one thing the shell said turned out to be.
///
/// The two batches superd pushes — the sniffed OSC events and the command-block tap — normalise
/// into ONE vocabulary here, because the fold treats them the same way: a progress badge latches
/// the same latch whether the sniffer saw the escape or the block tap synthesised it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Kind {
    /// An OSC 0/2 window title, already deduplicated by superd.
    Title = 1,
    /// A real terminal bell.
    Bell = 2,
    /// A command began executing (OSC 133 `C`).
    CommandRunning = 3,
    /// The shell returned to a prompt (OSC 133 `D`).
    CommandIdle = 4,
    /// The shell's working directory (OSC 7), already verified local and percent-decoded.
    Cwd = 5,
    /// A desktop notification (OSC 9 / 777 / 99).
    Notification = 6,
    /// An OSC 9;4 progress badge, already parsed into `(state, percent)` by the wire crate.
    Progress = 7,
    /// A command block was created, changed or finished.
    Block = 8,
}

impl Kind {
    /// The kind a raw discriminant names, or `None` for one this build has no name for.
    ///
    /// Validate-then-drop, like every other decode on this path: a batch member from a newer superd
    /// is skipped rather than guessed at.
    #[must_use]
    pub const fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            1 => Some(Self::Title),
            2 => Some(Self::Bell),
            3 => Some(Self::CommandRunning),
            4 => Some(Self::CommandIdle),
            5 => Some(Self::Cwd),
            6 => Some(Self::Notification),
            7 => Some(Self::Progress),
            8 => Some(Self::Block),
            _ => None,
        }
    }
}

/// Every NUMBER one fact can carry, flat.
///
/// Flat rather than a payload per enum variant because this is also the shape that crosses to the
/// marshaller: a block carries seven of these fields and a bell carries none, and an enum whose
/// variants differ that much in size is a lint this crate denies — for the same reason the crossing
/// wants it flat.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Scalars {
    /// The command's exit status, `None` for the code-less `D` mark that carries no new truth.
    pub exit_code: Option<i32>,
    /// superd-measured C→D wall clock, `None` on an open block.
    pub duration_ms: Option<u32>,
    /// The OSC 9;4 state, already validated (`0` clear, `1` determinate, `2` error, `3` busy).
    pub progress_state: u8,
    /// The OSC 9;4 percentage, already clamped.
    pub progress_percent: u8,
    /// The block's index in the pane's block ring.
    pub index: u32,
    /// How many bytes of output superd has retained for the block.
    pub output_len: u32,
    /// Which prompt the block belongs to.
    pub prompt_ordinal: u32,
    /// Whether the block is closed.
    pub complete: bool,
}

/// One thing the shell said, with its text BORROWED from the caller's arena.
///
/// Borrowed on purpose: the batch is decoded once, upstream, into a row table and a byte arena, and
/// a fold that copied each string into an owned `String` would allocate per event on the pane's
/// output path for text the caller already holds and will hold until the fold returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fact<'arena> {
    /// What it is.
    pub kind: Kind,
    /// Title / cwd / notification title / block command text, by kind. Empty when the kind has
    /// none.
    pub primary: &'arena str,
    /// Notification body. Empty for every other kind.
    pub secondary: &'arena str,
    /// Everything numeric.
    pub scalars: Scalars,
}

impl<'arena> Fact<'arena> {
    /// A fact of `kind` carrying no text and no numbers.
    #[must_use]
    pub const fn bare(kind: Kind) -> Self {
        Self {
            kind,
            primary: "",
            secondary: "",
            scalars: Scalars::new(),
        }
    }

    /// A fact of `kind` carrying one string.
    #[must_use]
    pub const fn text(kind: Kind, primary: &'arena str) -> Self {
        Self {
            kind,
            primary,
            secondary: "",
            scalars: Scalars::new(),
        }
    }
}

impl Scalars {
    /// All zero — the shape a bell or a title carries.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            exit_code: None,
            duration_ms: None,
            progress_state: 0,
            progress_percent: 0,
            index: 0,
            output_len: 0,
            prompt_ordinal: 0,
            complete: false,
        }
    }
}

/// Where a fact's message goes once the fold has had it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Route {
    /// Rides the pane's output FIFO, interleaved byte-faithfully with the chunk it came from.
    Fifo = 0,
    /// Goes to every subscriber's CONTROL sender, off the data drain — a block's metadata must
    /// never wait behind the bytes it describes.
    Broadcast = 1,
    /// Made a message the pane still needs and the CLIENT must not receive: the raw OSC-7 cwd,
    /// which is host-gated single-source and reaches the client only as a resolved project key.
    Withheld = 2,
}

/// One decision the fold took about one fact.
///
/// Names the fact by INDEX rather than repeating its text: the caller still holds the arena that
/// fed the fold, so a verdict is sixteen bytes and a batch of them is one allocation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Verdict {
    /// Which fact of the ingested slice this is about.
    pub fact: u32,
    /// What it is, repeated so the marshaller can switch without indexing back.
    pub kind: Kind,
    /// Where its message goes.
    pub route: Route,
}

/// The two clocks a fold may stamp with, supplied rather than read.
///
/// They are DIFFERENT clocks, deliberately. `reference` is `timeIntervalSinceReferenceDate` — the
/// scale superd's `command_running_since` uses, and the title stamp is COMPARED against it, so a
/// laptop that slept must not make the comparison meaningless. `uptime` is monotonic
/// `systemUptime`, the scale every agent-detection fold runs on.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stamps {
    /// Wall-clock seconds since the reference date — the title stamp's scale.
    pub reference: f64,
    /// Monotonic uptime seconds — the command-running stamp's scale.
    pub uptime: f64,
}

/// The pane's latched truths: everything a listener who was not there still has to be told.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Truths {
    title: String,
    title_at: Option<f64>,
    pending_title_coalescing_reset: bool,
    title_anchor_retirements: u64,
    progress: Option<(u8, u8)>,
    last_exit: Option<i32>,
    last_duration: Option<u32>,
    command_running_since: Option<f64>,
    completion_epoch: u32,
    last_completion_status: u8,
    running_command: Option<String>,
    echo_last_emitted: bool,
    echo_warmed_up: bool,
}

impl Truths {
    /// A pane that has said nothing yet.
    ///
    /// `echo_last_emitted` starts TRUE because echo-on is the canonical baseline the client also
    /// assumes: the detector stays silent until a sample DIFFERS from it, which is what keeps the
    /// control stream byte-identical on a pane that never sees a password prompt.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            title: String::new(),
            title_at: None,
            pending_title_coalescing_reset: false,
            title_anchor_retirements: 0,
            progress: None,
            last_exit: None,
            last_duration: None,
            command_running_since: None,
            completion_epoch: 0,
            last_completion_status: 0,
            running_command: None,
            echo_last_emitted: true,
            echo_warmed_up: false,
        }
    }

    // ---------------------------------------------------------------- the fold

    /// Folds one SNIFFED batch and answers what to do with each member.
    ///
    /// `suppress_child_notifications` is the agent detector's verdict, read by the caller under the
    /// same lock and handed over as a value: while a pane's agent announces its own edges through
    /// the hook feed, its OSC notification duplicates the type-27 the client already banners, so
    /// one blocked prompt must raise ONE notification. A hook-free pane keeps the OSC path — it
    /// is that pane's only signal.
    ///
    /// The cwd is [`Route::Withheld`] rather than dropped: the pane still needs it (it seeds the
    /// project-key resolve and the reattach re-assert), and the CLIENT must not see the raw one.
    pub fn ingest_sniffed(
        &mut self,
        facts: &[Fact<'_>],
        stamps: Stamps,
        suppress_child_notifications: bool,
    ) -> Vec<Verdict> {
        let mut verdicts = Vec::with_capacity(facts.len());
        for (index, fact) in facts.iter().enumerate() {
            let route = match fact.kind {
                Kind::Title => {
                    self.title.clear();
                    self.title.push_str(fact.primary);
                    self.title_at = Some(stamps.reference);
                    Route::Fifo
                },
                Kind::CommandRunning => {
                    // Stamped on RECEIPT rather than carried in the event: the scale that matters is
                    // the one `pane/titleFresh` compares against, which is this process's, and
                    // superd's clock is not it. The two differ by one socket hop.
                    self.command_running_since = Some(stamps.uptime);
                    Route::Fifo
                },
                Kind::CommandIdle => {
                    // The duration arrives on EVERY `D`, including the code-less one the exit latch
                    // below deliberately ignores; the same `D` closes the running latch.
                    self.last_duration = fact.scalars.duration_ms;
                    self.command_running_since = None;
                    if let Some(code) = fact.scalars.exit_code {
                        self.last_exit = Some(code);
                    }
                    Route::Fifo
                },
                Kind::Progress => {
                    self.latch_progress(fact.scalars);
                    Route::Fifo
                },
                Kind::Cwd => Route::Withheld,
                Kind::Notification if suppress_child_notifications => continue,
                Kind::Bell | Kind::Notification | Kind::Block => Route::Fifo,
            };
            verdicts.push(Verdict {
                fact: u32::try_from(index).unwrap_or(u32::MAX),
                kind: fact.kind,
                route,
            });
        }
        verdicts
    }

    /// Folds one BLOCK batch. Every member broadcasts — block metadata rides the control sender so
    /// it never stalls behind the output it describes.
    ///
    /// The running command line is latched here rather than fetched, because the liveness capture
    /// that reads it runs for every pane on every reconciler tick and has to stay one lock
    /// acquisition. A closed block, or one whose text is only whitespace, latches nothing running.
    pub fn ingest_blocks(&mut self, facts: &[Fact<'_>]) -> Vec<Verdict> {
        let mut verdicts = Vec::with_capacity(facts.len());
        for (index, fact) in facts.iter().enumerate() {
            match fact.kind {
                Kind::Block => {
                    let text = fact.primary.trim();
                    self.running_command = if fact.scalars.complete || text.is_empty() {
                        None
                    } else {
                        Some(String::from(text))
                    };
                },
                // A synthetic badge is a second source of the SAME reattach truth, so it latches
                // through the same door the sniffed one does.
                Kind::Progress => self.latch_progress(fact.scalars),
                _ => {},
            }
            verdicts.push(Verdict {
                fact: u32::try_from(index).unwrap_or(u32::MAX),
                kind: fact.kind,
                route: Route::Broadcast,
            });
        }
        verdicts
    }

    /// Latches the progress pair, where a CLEAR latches nothing — the badge came down.
    const fn latch_progress(&mut self, scalars: Scalars) {
        self.progress = if scalars.progress_state == 0 {
            None
        } else {
            Some((scalars.progress_state, scalars.progress_percent))
        };
    }

    // ---------------------------------------------------------------- the title

    /// The pane's current window title. Empty means either "never said one" or "the agent that
    /// owned it handed it back" — see [`Truths::retire_title`].
    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }

    /// When the title was sniffed, on the `reference` scale. `None` once retired.
    #[must_use]
    pub const fn title_at(&self) -> Option<f64> {
        self.title_at
    }

    /// Records that the agent that owned the title has gone: the title is dropped, its freshness
    /// verdict with it, and the sniffer's coalescing anchor is asked to retire.
    ///
    /// The anchor request is a FLAG rather than a call because the retirement can be folded from
    /// any of the detector's feeds — the foreground poll, the scan task, the hook socket —
    /// while the anchor belongs to the read-loop thread. Without it the next agent's opening
    /// title, which is very often byte-identical to the one just retired, would be deduped away
    /// and the pane would stay untitled.
    pub fn retire_title(&mut self) {
        self.title.clear();
        self.title_at = None;
        self.pending_title_coalescing_reset = true;
    }

    /// TAKES the pending coalescing-reset request, counting it when there was one.
    ///
    /// Take rather than read: the read loop asks once per chunk and must act at most once per
    /// retirement, and the count is what the suite pinning WHEN the retirement is asked for reads.
    pub const fn take_title_coalescing_reset(&mut self) -> bool {
        if self.pending_title_coalescing_reset {
            self.pending_title_coalescing_reset = false;
            self.title_anchor_retirements = self.title_anchor_retirements.wrapping_add(1);
            true
        } else {
            false
        }
    }

    /// How many times the read loop has been asked to retire the title anchor.
    #[must_use]
    pub const fn title_anchor_retirements(&self) -> u64 {
        self.title_anchor_retirements
    }

    // ---------------------------------------------------------------- the command

    /// The freshest OSC 9;4 pair, `None` when cleared or never reported.
    #[must_use]
    pub const fn progress(&self) -> Option<(u8, u8)> {
        self.progress
    }

    /// The freshest code-carrying `D` exit status, `None` until the first one.
    #[must_use]
    pub const fn last_exit(&self) -> Option<i32> {
        self.last_exit
    }

    /// The host-measured C→D duration of the last completed command.
    #[must_use]
    pub const fn last_duration(&self) -> Option<u32> {
        self.last_duration
    }

    /// When the command now running started, on the `uptime` scale. `None` at a prompt.
    #[must_use]
    pub const fn command_running_since(&self) -> Option<f64> {
        self.command_running_since
    }

    /// The command line the pane is running, `None` at a prompt or with block tracking off.
    #[must_use]
    pub fn running_command(&self) -> Option<&str> {
        self.running_command.as_deref()
    }

    // ---------------------------------------------------------------- the turn counter

    /// Folds one detected status TRANSITION and answers the epoch it leaves standing.
    ///
    /// `mints` is `slopdesk-agent`'s own verdict on whether `previous → next` is the shape of a
    /// finished turn; the VETO is this fold's. A `quiet` transition — a `/compact` boundary, an
    /// Esc-cancelled dialog, a screen watchdog correcting a hook block it outlasted — still moves
    /// the status everywhere it shows, and must not count as work somebody did. Without the veto
    /// every one of them lands on the hook-less completion shape and mints an unread badge for
    /// every attached client over nothing.
    ///
    /// Called at the ONE place every detector feed funnels a real transition through, which is why
    /// two feeds observing the same edge cannot double-bump the count.
    pub const fn fold_completion(&mut self, status: u8, quiet: bool, mints: bool) -> u32 {
        self.last_completion_status = status;
        if !quiet && mints {
            self.completion_epoch = self.completion_epoch.wrapping_add(1);
        }
        self.completion_epoch
    }

    /// How many turns have finished on this pane. The host holds ZERO per-client acknowledgement
    /// state: it publishes the count, and each viewer compares it against its own device-local one.
    #[must_use]
    pub const fn completion_epoch(&self) -> u32 {
        self.completion_epoch
    }

    /// The status the epoch last stood at — the previous half of the next transition test.
    #[must_use]
    pub const fn last_completion_status(&self) -> u8 {
        self.last_completion_status
    }

    // ---------------------------------------------------------------- the echo edge

    /// The echo state the pane last emitted a type-31 for.
    #[must_use]
    pub const fn echo_last_emitted(&self) -> bool {
        self.echo_last_emitted
    }

    /// Folds one termios `ECHO` sample, answering the state to emit — or `None` for no edge.
    ///
    /// `is_edge` is the dedupe, asked of the caller rather than restated: a freshly connected PTY
    /// master reads `ECHO`-cleared for a sample or two before the line discipline settles, and
    /// treating that transient as a real edge would latch the client's Secure-Input pill on an
    /// ordinary prompt. So a no-echo reading is suppressed ENTIRELY — not folded, not emitted —
    /// until a confirmed echo-ON sample has warmed this connection up.
    pub fn fold_echo(&mut self, echo_on: bool, is_edge: impl FnOnce(bool, bool) -> bool) -> Option<bool> {
        if !self.echo_warmed_up {
            if !echo_on {
                return None;
            }
            self.echo_warmed_up = true;
        }
        if !is_edge(echo_on, self.echo_last_emitted) {
            return None;
        }
        self.echo_last_emitted = echo_on;
        Some(echo_on)
    }

    /// RE-ANCHORS the echo detector to the canonical baseline and folds `echo_on` against it — the
    /// reattach re-assert, which is NOT gated by the warm-up.
    ///
    /// The re-anchor is the load-bearing step. Echo state is by design not in the replayed output
    /// bytes (it is a host termios attribute carried only as a type-31), and a client resets its
    /// mirror on reconnect, so re-folding an unchanged state would emit nothing and leave a
    /// returning client's keyboard unprotected for the rest of a password entry.
    pub fn reanchor_echo(&mut self, echo_on: bool, is_edge: impl FnOnce(bool, bool) -> bool) -> Option<bool> {
        self.echo_last_emitted = true;
        if !is_edge(echo_on, true) {
            return None;
        }
        self.echo_last_emitted = echo_on;
        Some(echo_on)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The dedupe the host's echo door applies, restated here only as a test double.
    fn edge(sample: bool, last: bool) -> bool {
        sample != last
    }

    const STAMPS: Stamps = Stamps {
        reference: 100.0,
        uptime: 7.0,
    };

    fn idle(exit_code: Option<i32>, duration_ms: u32) -> Fact<'static> {
        Fact {
            kind: Kind::CommandIdle,
            primary: "",
            secondary: "",
            scalars: Scalars {
                exit_code,
                duration_ms: Some(duration_ms),
                ..Scalars::new()
            },
        }
    }

    fn progress(state: u8, percent: u8) -> Fact<'static> {
        Fact {
            kind: Kind::Progress,
            primary: "",
            secondary: "",
            scalars: Scalars {
                progress_state: state,
                progress_percent: percent,
                ..Scalars::new()
            },
        }
    }

    fn block(text: &str, complete: bool) -> Fact<'_> {
        Fact {
            kind: Kind::Block,
            primary: text,
            secondary: "",
            scalars: Scalars {
                complete,
                ..Scalars::new()
            },
        }
    }

    #[test]
    fn a_fresh_pane_has_said_nothing() {
        let truths = Truths::new();
        assert!(truths.title().is_empty());
        assert_eq!(truths.title_at(), None);
        assert_eq!(truths.progress(), None);
        assert_eq!(truths.last_exit(), None);
        assert_eq!(truths.command_running_since(), None);
        assert_eq!(truths.running_command(), None);
        assert_eq!(truths.completion_epoch(), 0);
        assert!(truths.echo_last_emitted());
    }

    #[test]
    fn a_title_latches_with_the_reference_stamp_not_the_uptime_one() {
        let mut truths = Truths::new();
        let verdicts = truths.ingest_sniffed(&[Fact::text(Kind::Title, "vi .")], STAMPS, false);
        assert_eq!(truths.title(), "vi .");
        assert_eq!(truths.title_at(), Some(STAMPS.reference));
        assert_eq!(verdicts.len(), 1);
        assert_eq!(verdicts.first().map(|v| v.route), Some(Route::Fifo));
    }

    #[test]
    fn a_command_edge_opens_and_closes_the_running_latch() {
        let mut truths = Truths::new();
        drop(truths.ingest_sniffed(&[Fact::bare(Kind::CommandRunning)], STAMPS, false));
        assert_eq!(truths.command_running_since(), Some(STAMPS.uptime));
        drop(truths.ingest_sniffed(&[idle(Some(3), 1200)], STAMPS, false));
        assert_eq!(truths.command_running_since(), None);
        assert_eq!(truths.last_exit(), Some(3));
        assert_eq!(truths.last_duration(), Some(1200));
    }

    #[test]
    fn a_code_less_close_keeps_the_prior_exit_and_still_records_its_duration() {
        let mut truths = Truths::new();
        drop(truths.ingest_sniffed(&[idle(Some(42), 10)], STAMPS, false));
        drop(truths.ingest_sniffed(&[idle(None, 99)], STAMPS, false));
        assert_eq!(
            truths.last_exit(),
            Some(42),
            "a bare D carries no new truth to replace it with"
        );
        assert_eq!(
            truths.last_duration(),
            Some(99),
            "the duration arrives on every D"
        );
    }

    #[test]
    fn a_clear_takes_the_progress_badge_down_rather_than_latching_zero() {
        let mut truths = Truths::new();
        drop(truths.ingest_sniffed(&[progress(1, 40)], STAMPS, false));
        assert_eq!(truths.progress(), Some((1, 40)));
        drop(truths.ingest_sniffed(&[progress(0, 0)], STAMPS, false));
        assert_eq!(truths.progress(), None);
    }

    #[test]
    fn a_synthetic_badge_latches_the_same_truth_the_sniffed_one_does() {
        let mut truths = Truths::new();
        let verdicts = truths.ingest_blocks(&[progress(3, 0)]);
        assert_eq!(truths.progress(), Some((3, 0)));
        assert_eq!(verdicts.first().map(|v| v.route), Some(Route::Broadcast));
    }

    #[test]
    fn a_raw_cwd_is_withheld_from_the_client_and_still_answered_to_the_pane() {
        let mut truths = Truths::new();
        let verdicts = truths.ingest_sniffed(&[Fact::text(Kind::Cwd, "/tmp")], STAMPS, false);
        assert_eq!(verdicts.first().map(|v| v.route), Some(Route::Withheld));
        assert_eq!(verdicts.first().map(|v| v.kind), Some(Kind::Cwd));
    }

    #[test]
    fn a_notification_is_dropped_only_while_the_agent_announces_its_own_edges() {
        let facts = [Fact {
            kind: Kind::Notification,
            primary: "hi",
            secondary: "there",
            scalars: Scalars::new(),
        }];
        let mut hooked = Truths::new();
        assert!(hooked.ingest_sniffed(&facts, STAMPS, true).is_empty());
        let mut bare = Truths::new();
        assert_eq!(bare.ingest_sniffed(&facts, STAMPS, false).len(), 1);
    }

    #[test]
    fn a_suppressed_notification_does_not_shift_the_indices_of_what_survives() {
        let facts = [
            Fact {
                kind: Kind::Notification,
                primary: "n",
                secondary: "",
                scalars: Scalars::new(),
            },
            Fact::text(Kind::Title, "after"),
        ];
        let mut truths = Truths::new();
        let verdicts = truths.ingest_sniffed(&facts, STAMPS, true);
        assert_eq!(verdicts.len(), 1);
        assert_eq!(
            verdicts.first().map(|v| v.fact),
            Some(1),
            "the index names the FACT, not the verdict"
        );
    }

    #[test]
    fn an_open_block_latches_its_command_line_and_a_closed_one_clears_it() {
        let mut truths = Truths::new();
        drop(truths.ingest_blocks(&[block("  cargo test  ", false)]));
        assert_eq!(
            truths.running_command(),
            Some("cargo test"),
            "trimmed on the way in"
        );
        drop(truths.ingest_blocks(&[block("cargo test", true)]));
        assert_eq!(truths.running_command(), None);
    }

    #[test]
    fn a_whitespace_only_block_is_not_a_running_command() {
        let mut truths = Truths::new();
        drop(truths.ingest_blocks(&[block("   ", false)]));
        assert_eq!(truths.running_command(), None);
    }

    #[test]
    fn one_batch_folds_every_truth_it_carries_in_order() {
        let mut truths = Truths::new();
        let verdicts = truths.ingest_sniffed(
            &[
                Fact::text(Kind::Title, "make"),
                Fact::bare(Kind::CommandRunning),
                progress(1, 10),
                Fact::bare(Kind::Bell),
                idle(Some(0), 5),
            ],
            STAMPS,
            false,
        );
        assert_eq!(verdicts.len(), 5);
        assert!(verdicts.iter().all(|v| v.route == Route::Fifo));
        assert_eq!(truths.title(), "make");
        assert_eq!(
            truths.command_running_since(),
            None,
            "the D in the same batch closed the C"
        );
        assert_eq!(truths.last_exit(), Some(0));
        assert_eq!(truths.progress(), Some((1, 10)));
    }

    #[test]
    fn a_retirement_drops_the_title_its_stamp_and_asks_the_anchor_to_forget() {
        let mut truths = Truths::new();
        drop(truths.ingest_sniffed(&[Fact::text(Kind::Title, "claude")], STAMPS, false));
        truths.retire_title();
        assert!(truths.title().is_empty());
        assert_eq!(truths.title_at(), None, "no title, no freshness verdict");
        assert!(truths.take_title_coalescing_reset());
        assert_eq!(truths.title_anchor_retirements(), 1);
    }

    #[test]
    fn the_coalescing_reset_is_taken_once_per_retirement() {
        let mut truths = Truths::new();
        truths.retire_title();
        assert!(truths.take_title_coalescing_reset());
        assert!(!truths.take_title_coalescing_reset());
        assert_eq!(
            truths.title_anchor_retirements(),
            1,
            "an empty take counts nothing"
        );
    }

    #[test]
    fn a_quiet_transition_moves_the_status_without_minting_a_turn() {
        let mut truths = Truths::new();
        assert_eq!(truths.fold_completion(2, false, true), 1);
        assert_eq!(truths.fold_completion(3, true, true), 1, "quiet vetoes the mint");
        assert_eq!(truths.last_completion_status(), 3, "and still moves the status");
        assert_eq!(
            truths.fold_completion(4, false, false),
            1,
            "a non-completion shape mints nothing"
        );
        assert_eq!(truths.fold_completion(5, false, true), 2);
    }

    #[test]
    fn the_echo_edge_stays_silent_until_a_confirmed_echo_on_warms_it_up() {
        let mut truths = Truths::new();
        assert_eq!(
            truths.fold_echo(false, edge),
            None,
            "a startup transient must not latch the pill"
        );
        assert!(truths.echo_last_emitted(), "and must not move the anchor either");
        assert_eq!(
            truths.fold_echo(true, edge),
            None,
            "the warm-up sample matches the baseline"
        );
        assert_eq!(
            truths.fold_echo(false, edge),
            Some(false),
            "now a real prompt is an edge"
        );
        assert_eq!(truths.fold_echo(false, edge), None, "and it deduped");
        assert_eq!(truths.fold_echo(true, edge), Some(true));
    }

    #[test]
    fn a_reattach_re_anchors_so_a_spanning_no_echo_prompt_is_re_told() {
        let mut truths = Truths::new();
        _ = truths.fold_echo(true, edge);
        assert_eq!(truths.fold_echo(false, edge), Some(false));
        assert_eq!(
            truths.reanchor_echo(false, edge),
            Some(false),
            "re-anchored, so it is an edge again"
        );
        assert_eq!(
            truths.reanchor_echo(true, edge),
            None,
            "an echo-on pane has nothing to re-tell"
        );
    }

    #[test]
    fn an_empty_batch_folds_nothing_and_allocates_no_verdicts() {
        let mut truths = Truths::new();
        assert!(truths.ingest_sniffed(&[], STAMPS, false).is_empty());
        assert!(truths.ingest_blocks(&[]).is_empty());
        assert_eq!(truths, Truths::new());
    }

    #[test]
    fn every_named_kind_round_trips_its_discriminant() {
        for kind in [
            Kind::Title,
            Kind::Bell,
            Kind::CommandRunning,
            Kind::CommandIdle,
            Kind::Cwd,
            Kind::Notification,
            Kind::Progress,
            Kind::Block,
        ] {
            assert_eq!(Kind::from_raw(kind as u8), Some(kind));
        }
        assert_eq!(Kind::from_raw(0), None);
        assert_eq!(
            Kind::from_raw(9),
            None,
            "a kind a newer superd names is skipped, not guessed"
        );
    }
}
