//! A pane that is only its answers.
//!
//! Every question [`slopdesk_hostserver::Pane`] asks is a fact about a pane rather than an effect
//! on one, and the effects it has — the shutdown, the relinquish, the write, the resize — are
//! counted here instead of performed. That is the whole reason the trait exists: a real
//! [`slopdesk_hostsession::PaneSession`] is a PTY, a superd socket and six threads, and a suite
//! that had to build one per entry would be testing the pane rather than the thing under test.
//!
//! ONE fake, shared by four suites. D.5 grew a second one — the store's `Ghost` answered the six
//! lifecycle methods and the dispatcher's `Fake` answered the twenty verb ones — because the two
//! traits were two. D.6 merged the traits, so the fakes merged with them, and the merge is worth
//! more than the tidiness: the host suite drives a `kill` that has to reap a pane AND fan its final
//! status, which is one object answering both halves.

use std::collections::BTreeMap;
use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_hostnet::link::ByteLink;
use slopdesk_hostnet::subchannel::SubChannel;
use slopdesk_hostserver::service::ServiceHandle;
use slopdesk_hostserver::{EvictionObserver, Pane, TeardownExecutor, Wires};
use slopdesk_hostsession::{
    BlockTap, BlockUpdate, CloseTap, OutputTap, PaneLatches, SessionObserver, TapToken,
};
use slopdesk_muxsession::registry::{self, Slot, Subscriber, Uuid};
use slopdesk_muxsession::resize_fold::Attachment;
use slopdesk_screenwire::payload::Snapshot;
use slopdesk_superwire::protocol::BlocksReply;

/// One tap registry, standing in for the three [`slopdesk_hostsession::PaneSession`] keeps.
///
/// Generic over the tap because the three differ only in what they are called with, and writing the
/// mint-insert-remove dance three times is how a suite comes to test two of them. The host's
/// cross-pane status table is a fourth user, which is why this is `pub`.
#[derive(Debug)]
pub struct Registered<T: ?Sized> {
    next: AtomicUsize,
    live: Mutex<Vec<(u64, Arc<T>)>>,
}

impl<T: ?Sized> Default for Registered<T> {
    fn default() -> Self {
        Self {
            next: AtomicUsize::new(1),
            live: Mutex::new(Vec::new()),
        }
    }
}

impl<T: ?Sized> Registered<T> {
    /// Files `tap` and answers the token that retires it.
    pub fn add(&self, tap: Arc<T>) -> TapToken {
        let key = self.next.fetch_add(1, Ordering::SeqCst) as u64;
        self.live
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((key, tap));
        TapToken::foreign(key)
    }

    /// The token for a tap that was fired instead of registered.
    ///
    /// Key 0, which [`Registered::add`] never mints — `next` starts at 1 for exactly this. Retiring
    /// it is a no-op rather than an error, which is what a late subscriber's `remove` must be.
    // No `unused_self` expectation: the lint spares an exported method by default, and this one is
    // `pub` now that four suites share the registry. The receiver stays because it reads as the
    // registry's own answer at the call site.
    pub const fn absent(&self) -> TapToken {
        TapToken::foreign(0)
    }

    /// Retires exactly the registration `token` names, so "the tap was retired" is an assertion
    /// about the token the caller held rather than about how many are left.
    pub fn remove(&self, token: TapToken) {
        self.live
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|(key, _)| TapToken::foreign(*key) != token);
    }

    /// Visits every live tap, OUTSIDE the lock — a tap that registers another must not deadlock.
    pub fn each(&self, mut visit: impl FnMut(&Arc<T>)) {
        let taps = self.live.lock().unwrap_or_else(PoisonError::into_inner).clone();
        for (_, tap) in &taps {
            visit(tap);
        }
    }

    /// How many are live.
    pub fn count(&self) -> usize {
        self.live.lock().unwrap_or_else(PoisonError::into_inner).len()
    }
}

/// A pane with no process behind it: what it will answer, and what it was asked to do.
#[derive(Debug)]
pub struct Ghost {
    id: Uuid,
    slot: Slot,
    exited: AtomicBool,
    members: AtomicUsize,
    shutdowns: AtomicUsize,
    relinquishes: AtomicUsize,
    written: Mutex<Vec<u8>>,
    resized: Mutex<Vec<(u16, u16)>>,
    reported: Mutex<Vec<(String, Option<String>)>>,
    folded: Mutex<Vec<(slopdesk_agent::ClaudeHookEvent, u8, Option<String>)>>,
    offered: Mutex<Vec<slopdesk_wire::message::ProjectGitStatus>>,
    window: Mutex<Option<(u16, u16)>>,
    foreground: Mutex<String>,
    status: Mutex<(String, Option<String>)>,
    present: AtomicBool,
    title: Mutex<String>,
    cwd: Mutex<Option<String>>,
    pid: Mutex<i32>,
    last_exit_code: Mutex<Option<i32>>,
    scrollback: Mutex<String>,
    lines: Mutex<Vec<String>>,
    screen: Mutex<Result<Snapshot, String>>,
    blocks: Mutex<Option<BlocksReply>>,
    outputs: Mutex<BTreeMap<u32, Vec<u8>>>,
    output_taps: Registered<dyn OutputTap>,
    close_taps: Registered<dyn CloseTap>,
    block_taps: Registered<dyn BlockTap>,
    /// Latched by [`Ghost::end`], read by [`Pane::add_close_tap`].
    ///
    /// A fake that just dropped a late registration would make the subscribe-races-exit case pass
    /// by never testing it, so it carries the same latch `slopdesk_hostsession::taps` does.
    ended: AtomicBool,
    // ----------------------------------------------------------------------------- the channels
    starts: AtomicUsize,
    seeded: Mutex<Vec<String>>,
    next_subscriber: AtomicU64,
    /// Every `join` asked for, and the verdict this pane will give.
    joins: Mutex<Vec<(Subscriber, bool)>>,
    joinable: AtomicBool,
    /// Every `rebind` asked for, and the verdict.
    rebinds: AtomicUsize,
    rebindable: AtomicBool,
    /// Says the child dies DURING the rebind — the race the claim cannot see.
    dies_on_rebind: AtomicBool,
    /// The exit handler the last successful `rebind` installed, so a test can fire it.
    exit: Mutex<Option<Arc<dyn SessionObserver>>>,
    /// Every replay asked for, as `(after, was_a_snapshot)`.
    replays: Mutex<Vec<i64>>,
    composes: AtomicBool,
    head: Mutex<i64>,
    /// Every member that LEFT, in order — the refcounted-leave ledger.
    departed: Mutex<Vec<Subscriber>>,
    /// How long a teardown of this pane takes, in milliseconds.
    ///
    /// Zero for every suite but one. A relinquish that returns instantly cannot tell a stop that
    /// JOINS from a stop that merely started N threads and got lucky, so the one test making that
    /// claim buys itself a window nothing else needs.
    stall_ms: AtomicU64,
    /// The size fold, as a ledger: every admit and every retire, in order.
    contributors: Mutex<Vec<(Subscriber, bool)>>,
    retired: Mutex<Vec<Subscriber>>,
    detached: AtomicBool,
    /// The handler the `detach` installed, so a test can say the parked child died.
    parked_exit: Mutex<Option<Arc<dyn SessionObserver>>>,
    /// Every repaint, as the verdict it was given.
    redraws: Mutex<Vec<bool>>,
    /// What a capture reads off this pane.
    latches: Mutex<PaneLatches>,
    /// The grid the fold resolved, and who is holding it there.
    attachments: Mutex<((u16, u16), Vec<Attachment>)>,
}

impl Ghost {
    /// A live pane serving conversation `id`, with a fresh object identity.
    #[must_use]
    pub fn new(id: Uuid) -> Arc<Self> {
        Arc::new(Self {
            id,
            slot: registry::mint_slot(),
            exited: AtomicBool::new(false),
            members: AtomicUsize::new(0),
            shutdowns: AtomicUsize::new(0),
            relinquishes: AtomicUsize::new(0),
            written: Mutex::new(Vec::new()),
            resized: Mutex::new(Vec::new()),
            reported: Mutex::new(Vec::new()),
            folded: Mutex::new(Vec::new()),
            offered: Mutex::new(Vec::new()),
            window: Mutex::new(Some((30, 100))),
            foreground: Mutex::new(String::from("zsh")),
            status: Mutex::new((String::from("idle"), None)),
            present: AtomicBool::new(false),
            title: Mutex::new(String::new()),
            cwd: Mutex::new(None),
            pid: Mutex::new(4242),
            last_exit_code: Mutex::new(None),
            scrollback: Mutex::new(String::new()),
            lines: Mutex::new(Vec::new()),
            screen: Mutex::new(Err(String::from("no engine"))),
            blocks: Mutex::new(None),
            outputs: Mutex::new(BTreeMap::new()),
            output_taps: Registered::default(),
            close_taps: Registered::default(),
            block_taps: Registered::default(),
            ended: AtomicBool::new(false),
            starts: AtomicUsize::new(0),
            seeded: Mutex::new(Vec::new()),
            // 1, so a reservation is never mistaken for the PRIMARY the registry spells `0`.
            next_subscriber: AtomicU64::new(1),
            joins: Mutex::new(Vec::new()),
            joinable: AtomicBool::new(true),
            rebinds: AtomicUsize::new(0),
            rebindable: AtomicBool::new(true),
            dies_on_rebind: AtomicBool::new(false),
            exit: Mutex::new(None),
            replays: Mutex::new(Vec::new()),
            composes: AtomicBool::new(false),
            head: Mutex::new(0),
            departed: Mutex::new(Vec::new()),
            stall_ms: AtomicU64::new(0),
            contributors: Mutex::new(Vec::new()),
            retired: Mutex::new(Vec::new()),
            detached: AtomicBool::new(false),
            parked_exit: Mutex::new(None),
            redraws: Mutex::new(Vec::new()),
            latches: Mutex::new(PaneLatches::default()),
            attachments: Mutex::new(((100, 30), Vec::new())),
        })
    }

    /// A pane under a conversation id built from one byte, for the suites that only need distinct
    /// ids and do not care what they are.
    #[must_use]
    pub fn numbered(id: u8) -> Arc<Self> {
        let mut bytes = [0_u8; 16];
        bytes[0] = id;
        Self::new(bytes)
    }

    // ------------------------------------------------------------------------------- the ledgers

    /// Says the shell has already exited.
    pub fn kill_child(&self) {
        self.exited.store(true, Ordering::SeqCst);
    }

    /// Says `count` members hold this pane.
    pub fn hold(&self, count: usize) {
        self.members.store(count, Ordering::SeqCst);
    }

    /// How many times the pane was ENDED.
    pub fn shutdowns(&self) -> usize {
        self.shutdowns.load(Ordering::SeqCst)
    }

    /// Spends this pane's configured teardown time. Zero by default, so it is free.
    fn stall(&self) {
        let millis = self.stall_ms.load(Ordering::SeqCst);
        if millis > 0 {
            std::thread::sleep(std::time::Duration::from_millis(millis));
        }
    }

    /// Says a teardown of this pane takes `millis` to finish.
    pub fn stalls_for(&self, millis: u64) {
        self.stall_ms.store(millis, Ordering::SeqCst);
    }

    /// Every member that LEFT this pane, in order.
    pub fn departed(&self) -> Vec<Subscriber> {
        self.departed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// How many times it was let GO.
    pub fn relinquishes(&self) -> usize {
        self.relinquishes.load(Ordering::SeqCst)
    }

    /// Every byte injected into this pane, in order.
    pub fn written(&self) -> Vec<u8> {
        self.written
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Every grid this pane was asked to take, in order.
    pub fn resized(&self) -> Vec<(u16, u16)> {
        self.resized
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Every self-report folded into this pane, in order.
    pub fn reported(&self) -> Vec<(String, Option<String>)> {
        self.reported
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Every hook event routed to this pane, in arrival order — the hook table's assertion.
    pub fn folded_hooks(&self) -> Vec<(slopdesk_agent::ClaudeHookEvent, u8, Option<String>)> {
        self.folded.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Every git summary OFFERED to this pane, in order.
    ///
    /// Offered rather than delivered: a real pane decides by its own latch, and a fake that
    /// reimplemented that decision would be asserting the fake's rule rather than the fan-in's.
    pub fn offered_git(&self) -> Vec<slopdesk_wire::message::ProjectGitStatus> {
        self.offered
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// How many close taps are live — the leak assertion.
    pub fn close_taps(&self) -> usize {
        self.close_taps.count()
    }

    /// How many output taps are live.
    pub fn output_taps(&self) -> usize {
        self.output_taps.count()
    }

    /// How many block taps are live.
    pub fn block_taps(&self) -> usize {
        self.block_taps.count()
    }

    // ------------------------------------------------------------------------------ the answers

    fn set<T>(cell: &Mutex<T>, value: T) {
        *cell.lock().unwrap_or_else(PoisonError::into_inner) = value;
    }

    /// Says the PTY reports this grid, or none at all.
    pub fn set_window(&self, grid: Option<(u16, u16)>) {
        Self::set(&self.window, grid);
    }

    /// Says this program holds the foreground group.
    pub fn set_foreground(&self, name: &str) {
        Self::set(&self.foreground, name.to_owned());
    }

    /// Says the pane stands at this supervision state and label.
    pub fn set_status(&self, state: &str, message: Option<&str>) {
        Self::set(&self.status, (state.to_owned(), message.map(str::to_owned)));
    }

    /// Says an agent is (or is not) present — the bit the four-token vocabulary cannot carry.
    pub fn set_present(&self, present: bool) {
        self.present.store(present, Ordering::SeqCst);
    }

    /// Says the pane's OSC title reads this.
    pub fn set_title(&self, title: &str) {
        Self::set(&self.title, title.to_owned());
    }

    /// Says the host has observed this working directory.
    pub fn set_cwd(&self, cwd: Option<&str>) {
        Self::set(&self.cwd, cwd.map(str::to_owned));
    }

    /// Says the shell has this pid.
    pub fn set_pid(&self, pid: i32) {
        Self::set(&self.pid, pid);
    }

    /// Says the last command finished with this `$?`.
    pub fn set_last_exit_code(&self, code: Option<i32>) {
        Self::set(&self.last_exit_code, code);
    }

    /// Says the scrollback reads this.
    pub fn set_scrollback(&self, text: &str) {
        Self::set(&self.scrollback, text.to_owned());
    }

    /// Says the scrollback splits into these logical lines.
    pub fn set_lines(&self, lines: Vec<String>) {
        Self::set(&self.lines, lines);
    }

    /// Says a render answers this — a grid, or the reason there is none.
    pub fn set_screen(&self, screen: Result<Snapshot, String>) {
        Self::set(&self.screen, screen);
    }

    /// Says the pane's block ring reads this, or that it has no tap.
    pub fn set_blocks(&self, blocks: Option<BlocksReply>) {
        Self::set(&self.blocks, blocks);
    }

    /// Says block `index` retained these bytes.
    pub fn set_block_output(&self, index: u32, payload: Vec<u8>) {
        drop(
            self.outputs
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(index, payload),
        );
    }

    // -------------------------------------------------------------------------------- the edges

    /// Fires every output tap, the way a read loop would.
    pub fn emit(&self, payload: &[u8]) {
        self.output_taps.each(|tap| tap.chunk(payload));
    }

    /// Fires every close tap, the way an exit thread would — and latches, so a LATER registration
    /// is answered rather than parked on an event that can no longer happen.
    pub fn end(&self) {
        self.ended.store(true, Ordering::SeqCst);
        self.close_taps.each(|tap| tap.closed());
    }

    /// Fires every block tap, the way the fold would.
    pub fn publish(&self, update: &BlockUpdate) {
        self.block_taps.each(|tap| tap.updated(update));
    }

    // ------------------------------------------------------------------------------ the channels

    /// How many times the pane's threads were started.
    pub fn starts(&self) -> usize {
        self.starts.load(Ordering::SeqCst)
    }

    /// Every directory the pane's By-Project truth was seeded from, in order.
    pub fn seeded(&self) -> Vec<String> {
        self.seeded.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Every join asked of this pane: the id it was handed, and its passivity.
    pub fn joins(&self) -> Vec<(Subscriber, bool)> {
        self.joins.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Says a join will REFUSE — the pane emptied, or the joining link died mid-transfer.
    pub fn refuse_joins(&self) {
        self.joinable.store(false, Ordering::SeqCst);
    }

    /// How many rebinds were asked of this pane.
    pub fn rebinds(&self) -> usize {
        self.rebinds.load(Ordering::SeqCst)
    }

    /// Says a rebind will REFUSE — finished channels, or a pane that is not detached.
    pub fn refuse_rebinds(&self) {
        self.rebindable.store(false, Ordering::SeqCst);
    }

    /// Says the child dies DURING the rebind, which is then refused because of it.
    ///
    /// The claim ran BEFORE this and saw a live child, so this is the one way a reattach reaches
    /// the recovery path holding a pane whose child is already gone.
    pub fn die_during_rebind(&self) {
        self.rebindable.store(false, Ordering::SeqCst);
        self.dies_on_rebind.store(true, Ordering::SeqCst);
    }

    /// Fires the exit handler the last successful rebind installed, the way a reaper would.
    pub fn exit_rebound(&self) {
        let handler = self.exit.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(handler) = handler {
            handler.exited(0);
        }
    }

    /// Fires the exit handler the detach installed: the shell died while the pane was parked.
    pub fn exit_parked(&self) {
        let handler = self
            .parked_exit
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(handler) = handler {
            handler.exited(0);
        }
    }

    /// Every replay asked of this pane, as the sequence number it was told to resume after.
    pub fn replays(&self) -> Vec<i64> {
        self.replays
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Says a replay COMPOSES a rendered snapshot rather than handing over raw bytes.
    pub fn compose_snapshots(&self) {
        self.composes.store(true, Ordering::SeqCst);
    }

    /// Says this pane has numbered frames up to `seq`.
    pub fn set_head(&self, seq: i64) {
        Self::set(&self.head, seq);
    }

    /// Every contributor admitted to the size fold, in order.
    pub fn contributors(&self) -> Vec<(Subscriber, bool)> {
        self.contributors
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Every contributor retired from the size fold, in order — the join's unwind.
    pub fn retired_contributors(&self) -> Vec<Subscriber> {
        self.retired
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Says what a capture will read off this pane.
    pub fn set_latches(&self, latches: PaneLatches) {
        *self.latches.lock().unwrap_or_else(PoisonError::into_inner) = latches;
    }

    /// Says what the size fold resolved for this pane, and who is holding it there.
    pub fn set_attachments(&self, resolved: (u16, u16), attachments: Vec<Attachment>) {
        *self.attachments.lock().unwrap_or_else(PoisonError::into_inner) = (resolved, attachments);
    }

    /// Every repaint this pane was asked for, as `true` for a jiggle and `false` for a nudge.
    pub fn redraws(&self) -> Vec<bool> {
        self.redraws
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl Pane for Ghost {
    fn id(&self) -> Uuid {
        self.id
    }

    fn slot(&self) -> Slot {
        self.slot
    }

    fn is_child_exited(&self) -> bool {
        self.exited.load(Ordering::SeqCst)
    }

    fn member_count(&self) -> usize {
        self.members.load(Ordering::SeqCst)
    }

    fn shutdown(&self) {
        self.stall();
        self.shutdowns.fetch_add(1, Ordering::SeqCst);
    }

    fn relinquish(&self) {
        self.stall();
        self.relinquishes.fetch_add(1, Ordering::SeqCst);
    }

    fn write_raw(&self, bytes: &[u8]) {
        self.written
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .extend_from_slice(bytes);
    }

    fn resize(&self, rows: u16, cols: u16) {
        self.resized
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((rows, cols));
    }

    fn window_size(&self) -> Option<(u16, u16)> {
        *self.window.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn foreground_name(&self) -> String {
        self.foreground
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn latches(&self) -> PaneLatches {
        self.latches
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn attachments(&self) -> ((u16, u16), Vec<Attachment>) {
        self.attachments
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn agent_status(&self) -> (String, Option<String>) {
        self.status.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn agent_present(&self) -> bool {
        self.present.load(Ordering::SeqCst)
    }

    fn title(&self) -> String {
        self.title.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn cwd(&self) -> Option<String> {
        self.cwd.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn pid(&self) -> i32 {
        *self.pid.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn last_exit_code(&self) -> Option<i32> {
        *self.last_exit_code.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn report_agent_status(&self, state: &str, message: Option<&str>) {
        self.reported
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((state.to_owned(), message.map(str::to_owned)));
    }

    fn fold_hook(&self, event: slopdesk_agent::ClaudeHookEvent, kind_byte: u8, prompt: Option<&str>) {
        self.folded.lock().unwrap_or_else(PoisonError::into_inner).push((
            event,
            kind_byte,
            prompt.map(str::to_owned),
        ));
    }

    fn push_git_status(&self, status: &slopdesk_wire::message::ProjectGitStatus) {
        self.offered
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(status.clone());
    }

    fn scrollback_text(&self, ansi_strip: bool) -> String {
        let text = self
            .scrollback
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if ansi_strip { text } else { format!("raw:{text}") }
    }

    fn render_screen(&self, rows: usize, cols: usize) -> Result<Snapshot, String> {
        let asked = self.screen.lock().unwrap_or_else(PoisonError::into_inner).clone();
        asked.map(|mut snapshot| {
            // The fake ECHOES the grid it was asked for, which is what makes the default-size and
            // the override cases distinguishable at all: every other field is a fixture.
            snapshot.rows = rows;
            snapshot.cols = cols;
            snapshot
        })
    }

    fn recent_lines(&self, limit: Option<usize>) -> Vec<String> {
        let lines = self.lines.lock().unwrap_or_else(PoisonError::into_inner).clone();
        limit.map_or_else(
            || lines.clone(),
            |keep| lines.iter().rev().take(keep).rev().cloned().collect(),
        )
    }

    fn blocks(&self, _limit: usize) -> Option<BlocksReply> {
        self.blocks.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn block_output(&self, index: u32) -> Option<Vec<u8>> {
        self.outputs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&index)
            .cloned()
    }

    fn add_output_tap(&self, tap: Arc<dyn OutputTap>) -> TapToken {
        self.output_taps.add(tap)
    }

    fn remove_output_tap(&self, token: TapToken) {
        self.output_taps.remove(token);
    }

    fn add_close_tap(&self, tap: Arc<dyn CloseTap>) -> TapToken {
        if self.ended.load(Ordering::SeqCst) {
            tap.closed();
            return self.close_taps.absent();
        }
        self.close_taps.add(tap)
    }

    fn remove_close_tap(&self, token: TapToken) {
        self.close_taps.remove(token);
    }

    fn add_block_tap(&self, tap: Arc<dyn BlockTap>) -> TapToken {
        self.block_taps.add(tap)
    }

    fn remove_block_tap(&self, token: TapToken) {
        self.block_taps.remove(token);
    }

    fn start(&self) {
        self.starts.fetch_add(1, Ordering::SeqCst);
    }

    fn seed_project(&self, cwd: &str) {
        self.seeded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(cwd.to_owned());
    }

    fn reserve_subscriber(&self) -> Subscriber {
        self.next_subscriber.fetch_add(1, Ordering::SeqCst)
    }

    fn join(&self, reserved: Subscriber, wires: Wires, size_passive: bool) -> Option<Subscriber> {
        // The wires are DROPPED rather than kept, and that is the fake being honest about what it
        // is: a receiver has one owner, and a pane that parked them somewhere a test could read
        // would be holding the sending half of a link nothing is draining.
        drop(wires);
        self.joins
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((reserved, size_passive));
        self.joinable.load(Ordering::SeqCst).then_some(reserved)
    }

    fn rebind(&self, wires: Wires, exit: Arc<dyn SessionObserver>) -> bool {
        drop(wires);
        self.rebinds.fetch_add(1, Ordering::SeqCst);
        if !self.rebindable.load(Ordering::SeqCst) {
            if self.dies_on_rebind.load(Ordering::SeqCst) {
                self.exited.store(true, Ordering::SeqCst);
            }
            return false;
        }
        // Installed only on SUCCESS, the way the real one threads it in under its own lock: a
        // refused rebind must leave the previous handler in place.
        Self::set(&self.exit, Some(exit));
        self.detached.store(false, Ordering::SeqCst);
        true
    }

    fn replay_tail(&self, after: i64, _channel: &SubChannel) -> bool {
        self.replays
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(after);
        self.composes.load(Ordering::SeqCst)
    }

    fn highest_assigned_seq(&self) -> i64 {
        *self.head.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn add_resize_contributor(&self, subscriber: Subscriber, size_passive: bool) {
        self.contributors
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((subscriber, size_passive));
    }

    fn remove_resize_contributor(&self, subscriber: Subscriber) {
        self.retired
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(subscriber);
    }

    fn detach(&self, on_detached_exit: Arc<dyn SessionObserver>) {
        Self::set(&self.parked_exit, Some(on_detached_exit));
        self.detached.store(true, Ordering::SeqCst);
    }

    fn is_detached(&self) -> bool {
        self.detached.load(Ordering::SeqCst)
    }

    fn remove_subscriber(&self, subscriber: Subscriber) -> bool {
        self.departed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(subscriber);
        // The real one recomputes from the SET and answers "is it now EMPTY", which is the whole
        // difference between a refcounted leave and a reap. So does this: a member leaves, and only
        // the last one out says so. An already-empty pane answers `true` — a departure from a pane
        // nobody holds is still a departure that ends it.
        let left = self.members.fetch_sub(1, Ordering::SeqCst);
        if left == 0 {
            self.members.store(0, Ordering::SeqCst);
            return true;
        }
        left == 1
    }

    fn redraw(&self, jiggle: bool) {
        self.redraws
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(jiggle);
    }
}

/// The trait-object handle the table and the store take.
///
/// The turbofish is load-bearing: `Arc::clone` takes its target type from the CONTEXT, and the
/// context here is the `dyn` return — so the bare spelling asks for an `&Arc<dyn Pane>` it was
/// never given. Naming the source type pins the clone and leaves the coercion to the return.
pub fn as_pane(ghost: &Arc<Ghost>) -> Arc<dyn Pane> {
    Arc::<Ghost>::clone(ghost)
}

/// The same, for an eviction ledger a test wants to keep a typed handle on.
pub fn as_observer(seen: &Arc<Evictions>) -> Arc<dyn EvictionObserver> {
    Arc::<Evictions>::clone(seen)
}

/// A supervised child that is only its answers — the [`ServiceHandle`] half of [`Ghost`].
///
/// A real one is a superd fork behind a PTY and a subscription, and a lifecycle suite that had to
/// build one per round would be testing Node's boot time.
#[derive(Debug)]
pub struct Backend {
    running: AtomicBool,
    terminates: AtomicUsize,
    relinquishes: AtomicUsize,
}

impl Backend {
    /// A child that is running.
    #[must_use]
    pub fn up() -> Arc<Self> {
        Arc::new(Self {
            running: AtomicBool::new(true),
            terminates: AtomicUsize::new(0),
            relinquishes: AtomicUsize::new(0),
        })
    }

    /// Says the child has exited — a crash, or superd going away.
    pub fn die(&self) {
        self.running.store(false, Ordering::SeqCst);
    }

    /// How many times the service was ENDED.
    pub fn terminates(&self) -> usize {
        self.terminates.load(Ordering::SeqCst)
    }

    /// How many times it was let GO.
    pub fn relinquishes(&self) -> usize {
        self.relinquishes.load(Ordering::SeqCst)
    }
}

impl ServiceHandle for Backend {
    fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    fn terminate(&self) {
        self.running.store(false, Ordering::SeqCst);
        self.terminates.fetch_add(1, Ordering::SeqCst);
    }

    fn relinquish(&self) {
        self.relinquishes.fetch_add(1, Ordering::SeqCst);
    }
}

/// The trait-object handle a lifecycle takes, turbofished for the reason [`as_pane`] is.
pub fn as_service(backend: &Arc<Backend>) -> Arc<dyn ServiceHandle> {
    Arc::<Backend>::clone(backend)
}

/// A link that swallows every byte and never answers.
///
/// Real sub-channels over a fake wire, rather than fake sub-channels: a `SubChannel` is where the
/// credit window lives, and the ladders hand one to a pane without ever sending on it. What a suite
/// needs is a `Wires` it can MOVE — the receivers have one owner each — and this is the cheapest
/// honest way to get one.
#[derive(Debug, Default, Clone, Copy)]
pub struct Sink;

impl ByteLink for Sink {
    fn send(&self, _bytes: &[u8]) -> io::Result<()> {
        Ok(())
    }

    fn recv(&self, _buf: &mut [u8]) -> io::Result<usize> {
        // A clean close, so nothing that reads this parks for ever waiting on a peer that is a
        // struct with no fields.
        Ok(0)
    }

    fn close(&self) {}
}

/// One client's two lanes over [`Sink`], for `channel`.
#[must_use]
pub fn wires(channel: u32) -> Wires {
    let link: Arc<dyn ByteLink> = Arc::new(Sink);
    let (control, control_inbound) = SubChannel::control(channel, Arc::clone(&link));
    // Both halves ride the SAME sink, which is what a real connection does too: the data lane's
    // credit grants are written on the control LINK, not on the control sub-channel.
    let (data, data_inbound) = SubChannel::data(channel, Arc::clone(&link), link);
    Wires {
        data,
        data_inbound,
        control,
        control_inbound,
    }
}

/// An executor that runs each kill on the calling thread, so a test never has to wait for one.
#[derive(Debug, Clone, Copy)]
pub struct Now;

impl TeardownExecutor for Now {
    fn submit(&self, kill: Box<dyn FnOnce() + Send>) {
        kill();
    }
}

/// Every pane the store said it evicted, in the order it said so.
#[derive(Debug, Default)]
pub struct Evictions {
    seen: Mutex<Vec<Uuid>>,
}

impl Evictions {
    /// The session ids reported, oldest first.
    pub fn seen(&self) -> Vec<Uuid> {
        self.seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

impl EvictionObserver for Evictions {
    fn evicted(&self, pane: &Arc<dyn Pane>) {
        self.seen
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(pane.id());
    }
}
