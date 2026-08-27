//! One pane, as everything in this crate that is not a pane sees it.
//!
//! `HostSessionRegistry` and `DetachedSessionStore` between them touch a `MuxChannelSession` in
//! exactly six ways: its two identities, whether its child has exited, how many members hold it,
//! and the two ends of its life. Everything else those two files do is bookkeeping ABOUT panes
//! rather than to them. Naming that surface is what lets the retention be driven in a suite: a real
//! [`slopdesk_hostsession::PaneSession`] is a PTY, a superd socket and six threads, and a store
//! test that had to build one would be testing the pane instead of the store.
//!
//! It is the same seam [`slopdesk_hostsession::ScreenOracle`] and
//! [`slopdesk_hostsession::ResolveExecutor`] already are, for the same reason each of those exists:
//! a decision that would otherwise drag a daemon in behind it.
//!
//! ## Why the control verbs' surface is the SAME trait
//!
//! D.5 carved a second trait, `ControlPane`, for the eleven agent-control verbs, and made it a
//! supertrait of this one so that "one adapter serves both". D.6 is what showed the two were always
//! one: [`crate::host::Host`] answers `list-panes` out of the very registry and store this trait
//! was carved for, so those tables have to hand back something a verb can ASK — a grid, a
//! foreground name, a status — and a `dyn Pane` cannot be widened back to a `dyn ControlPane` it
//! was coerced from. Keeping the split meant keeping the same pane in two tables, one per trait,
//! kept in step by hand. `LivePane` is the only implementor either trait ever had, so the split
//! bought a layering that nothing was layered on. `CLAUDE.md`'s "one implementation, never two" is
//! about languages, but the reasoning is the same one.
//!
//! What the split was really protecting is preserved: the six lifecycle methods below are still the
//! only ones [`crate::sessions`] and [`crate::detached`] call, and the suite still drives all
//! eleven verbs against a pane with no PTY behind it.

use core::fmt;
use std::sync::Arc;
use std::sync::mpsc::Receiver;

use slopdesk_agent::ClaudeHookEvent;
use slopdesk_hostnet::subchannel::SubChannel;
use slopdesk_hostsession::{BlockTap, CloseTap, OutputTap, PaneLatches, SessionObserver, TapToken};
use slopdesk_muxsession::registry::{Slot, Subscriber, Uuid};
use slopdesk_muxsession::resize_fold::Attachment;
use slopdesk_screenwire::payload::Snapshot;
use slopdesk_superwire::protocol::BlocksReply;
use slopdesk_wire::WireMessage;
use slopdesk_wire::message::ProjectGitStatus;

/// One client's two sub-channels, and the two queues its frames arrive on.
///
/// Four values that are never apart: a member IS its channel pair, so handing them over one at a
/// time is how a pane comes to hold a data lane from one client and a control lane from another.
/// Passed BY VALUE for the same reason — the receiving halves are `mpsc::Receiver`s, which have
/// exactly one owner, and moving them is what makes "who drains this" a compile-time question.
///
/// Not `Clone`, not `Sync`, and neither is an oversight.
#[derive(Debug)]
pub struct Wires {
    /// The DATA lane: output, input, replay.
    pub data: Arc<SubChannel>,
    /// Frames the peer sent on the data lane.
    pub data_inbound: Receiver<WireMessage>,
    /// The CONTROL lane: resize, metadata, status.
    pub control: Arc<SubChannel>,
    /// Frames the peer sent on the control lane.
    pub control_inbound: Receiver<WireMessage>,
}

/// One pane, as the composition sees it.
///
/// ## The two identities, and why there are two
/// [`Pane::id`] is the SESSION id — the UUID the client sent in its `channelOpen`, the name of a
/// conversation that survives a disconnect, a reattach and a hostd restart. [`Pane::slot`] is the
/// OBJECT id — minted once per live pane and dead the moment that pane is. They are different
/// questions and conflating them is the bug the detach window exists to make visible: a fresh pane
/// can be minted under an id its predecessor is still winding down on, so "is this the same
/// conversation" and "is this the same pane" have different answers for the length of that window.
/// Every `===` hostd's Swift asks is a slot comparison here.
///
/// ## The three groups
/// The six LIFECYCLE methods are what the table and the store need. The rest is what the eleven
/// agent-control verbs need, and every one of those is already
/// [`slopdesk_hostsession::PaneSession`]'s under a different name — this is a NARROWING of that
/// type, not a wish list, and the two gaps (the agent's self-report and the live `TIOCGWINSZ` read)
/// are named where they land rather than worked around.
pub trait Pane: Send + Sync + fmt::Debug {
    // ------------------------------------------------------------------------------- lifecycle

    /// The session id — the conversation's name, stable across reattach.
    fn id(&self) -> Uuid;

    /// The object id — this pane's identity, minted once and never reused.
    fn slot(&self) -> Slot;

    /// Whether the shell has an exit code already.
    ///
    /// An ALREADY-REAPED exit, not a `waitpid`: an unspawned pane answers `false`, which is the
    /// honest answer rather than an oversight. The store asks it OUTSIDE its own lock — see
    /// [`crate::detached`].
    fn is_child_exited(&self) -> bool;

    /// How many members hold this pane. Zero means nobody is watching it.
    fn member_count(&self) -> usize;

    /// Ends the pane: the child is signalled, waited for, and superd is told the pane is over.
    fn shutdown(&self);

    /// Lets the pane GO without ending it: the child is neither signalled nor waited for, superd
    /// still holds the master, and the next hostd adopts it back. `docs/51`'s line between "this
    /// daemon is going away" and "this pane is over".
    fn relinquish(&self);

    // ------------------------------------------------------------------------------- the verbs

    /// Injects bytes into the PTY. Fire-and-forget: a blocking `write(2)` on a stalled PTY must not
    /// park the connection thread, which is serving other verbs.
    fn write_raw(&self, bytes: &[u8]);

    /// Applies a `TIOCSWINSZ`. The kernel delivers the `SIGWINCH` itself.
    fn resize(&self, rows: u16, cols: u16);

    /// The pane's LIVE grid, or `None` when the PTY is gone.
    ///
    /// The live size rather than the resolved one, and the difference is the point: a ctl `resize`
    /// moves what the program sees without moving what the attached clients negotiated, and
    /// `screen` must render what the program drew.
    fn window_size(&self) -> Option<(u16, u16)>;

    /// The canonical name of the program holding this pane's PTY foreground group, or `""` when
    /// nothing holds it.
    ///
    /// CANONICAL rather than the raw basename, because the Claude Code native installer names its
    /// executable by version — a raw basename would read `2.1.218`, which is not a program the
    /// sensitive set can recognise either way.
    fn foreground_name(&self) -> String;

    /// Every latch a workspace CAPTURE reads, in ONE acquisition.
    ///
    /// Grouped rather than added as a method per field, and the reason is not brevity:
    /// [`crate::workspace::Panes::capture`] runs for EVERY pane on every reconciler tick, so a call
    /// per field would take the pane's fold lock once per field and leave a window between each
    /// pair for a command edge to land in — a record whose title was read before that edge and
    /// whose running command was read after it describes a pane that never existed.
    ///
    /// The GRID is not among them and is asked through [`Pane::window_size`] beside this call: it
    /// lives behind the PTY's lock rather than the folds', and the two are not nested.
    fn latches(&self) -> PaneLatches;

    /// The grid the size fold RESOLVED across this pane's attached clients, and who is holding it
    /// there.
    ///
    /// The resolved grid rather than [`Pane::window_size`]'s live one, and the roster wants this
    /// one: it is what the clients NEGOTIATED, so a client that is not driving the size can
    /// letterbox against it instead of guessing. A pane nobody is watching keeps its last resolved
    /// grid and answers no attachments — which is what says nobody is watching.
    fn attachments(&self) -> ((u16, u16), Vec<Attachment>);

    /// The pane's supervision state and the label attached to it.
    fn agent_status(&self) -> (String, Option<String>);

    /// Whether an agent is present in this pane AT ALL.
    ///
    /// A separate question from [`Pane::agent_status`], and it has to be: that answer speaks the
    /// four-token ctl vocabulary, where a pane with no agent and a pane whose agent is resting both
    /// read `idle`. Two callers need the difference. The cross-pane stream carries it as a field
    /// (see `AgentStatusEvent::agent_present`), because the agent-GONE edge lands on the same
    /// `idle` string the pane already reported. And the teardown fan is GATED on it: a plain shell
    /// that never had an agent must not emit a final clearing transition, or every closed tab
    /// publishes a supervision event about nothing.
    fn agent_present(&self) -> bool;

    /// The pane's OSC title, or the shell's own when none was set.
    fn title(&self) -> String;

    /// The pane's working directory as the host observed it, or `None` until it has been.
    fn cwd(&self) -> Option<String>;

    /// The shell's pid, or `-1` once the child is gone.
    fn pid(&self) -> i32;

    /// The freshest OSC-133-D exit code, or `None` until a command finished with a reported `$?`.
    fn last_exit_code(&self) -> Option<i32>;

    /// An agent self-declares its state. Authoritative — it beats the foreground-process floor.
    fn report_agent_status(&self, state: &str, message: Option<&str>);

    /// One hook event, already read off the record — the MOST authoritative of the four feeds.
    ///
    /// Here rather than on the session for D.5's reason and one more: the hook listener is keyed by
    /// the pane's env-baked id and holds `Arc<dyn Pane>`, so a route that had to recover a
    /// `PaneSession` would either downcast or keep a second table beside the first.
    ///
    /// The DECODE is the caller's — see `PaneSession::fold_hook`. The bytes→event mapping is
    /// `slopdesk_agent::signal::hook_event_of`, and it exists once.
    fn fold_hook(&self, event: ClaudeHookEvent, kind_byte: u8, prompt: Option<&str>);

    /// One repo's git summary, offered to this pane — delivered iff its latch names that repo.
    ///
    /// The fan-in offers the same value to every live pane rather than looking up which panes sit
    /// under the repo: the latch is the pane's, moves on the pane's own thread, and a caller that
    /// read it to filter would be filtering on a value that may already have changed. Panes that do
    /// not match return without sending, which is the cheap half of a compare.
    fn push_git_status(&self, status: &ProjectGitStatus);

    /// The scrollback as text, optionally ANSI-stripped.
    fn scrollback_text(&self, ansi_strip: bool) -> String;

    /// The pane's scrollback RENDERED into a grid — what `screen` answers with.
    ///
    /// Behind the door rather than called from the dispatcher, and that is a departure from the
    /// Swift on purpose. Rendering means a round trip to screend, so a dispatcher that reached for
    /// `slopdesk_screenclient::shared()` directly would make `screen` the one verb of eleven this
    /// crate's suite could not drive — a global socket client is not something a test can hand in.
    /// Swift had the same coupling and also could not test it; parity with a limitation is not a
    /// reason to keep one. The live adapter is the round trip; a fake is a grid.
    ///
    /// # Errors
    /// A human-readable reason, which is answered rather than faked: the raw bytes are one verb
    /// away, and a synthesised grid would be a lie about what the pane shows. screend being down
    /// and a render that timed out both land here.
    fn render_screen(&self, rows: usize, cols: usize) -> Result<Snapshot, String>;

    /// The scrollback as LOGICAL lines — joined chunks, ANSI-stripped, split on hard newlines — so
    /// an agent's regex is robust to read-chunk boundaries. `limit` keeps the last N.
    fn recent_lines(&self, limit: Option<usize>) -> Vec<String>;

    /// The last `limit` closed command blocks plus the running one, or `None` when this pane has no
    /// block tap. One round trip, because the recent blocks and the running one have to be read
    /// together or they can disagree about which command is which.
    fn blocks(&self, limit: usize) -> Option<BlocksReply>;

    /// One block's retained output bytes, or `None` for an evicted or unknown index.
    fn block_output(&self, index: u32) -> Option<Vec<u8>>;

    /// Watches this pane's raw output.
    fn add_output_tap(&self, tap: Arc<dyn OutputTap>) -> TapToken;
    /// Retires a watcher [`Pane::add_output_tap`] handed back.
    fn remove_output_tap(&self, token: TapToken);

    /// Watches this pane's end.
    ///
    /// A LATE registration must be answered, not dropped: on a pane that has already closed, this
    /// fires `tap` at once and registers nothing. That is a contract rather than an implementation
    /// detail, and `slopdesk_hostsession::taps` states why — the check and the insertion have to be
    /// ONE operation, because a caller doing `is_closed()` then `add_close_tap()` has the race
    /// back. The Swift latched nothing here, and a `subscribe` that raced its pane's exit
    /// waited out its own timeout for an event that could no longer happen.
    fn add_close_tap(&self, tap: Arc<dyn CloseTap>) -> TapToken;
    /// Retires a watcher [`Pane::add_close_tap`] handed back.
    fn remove_close_tap(&self, token: TapToken);

    /// Watches this pane's command blocks.
    fn add_block_tap(&self, tap: Arc<dyn BlockTap>) -> TapToken;
    /// Retires a watcher [`Pane::add_block_tap`] handed back.
    fn remove_block_tap(&self, token: TapToken);

    // ----------------------------------------------------------------------------- the channels

    /// Starts the pane's threads: the relay, the drain, the detectors.
    ///
    /// Separate from whatever built the pane, because the host has to FILE it in between — a pane
    /// that produced its first output byte before the table knew about it has dropped its own
    /// opening, and every ladder below spawns, files, then starts.
    fn start(&self);

    /// Seeds this pane's By-Project truth from the directory it actually landed in.
    ///
    /// Server-side and pre-shell, so the sidebar's sections are right from the first frame even for
    /// a shell that emits no OSC-7 — the warm-up gate would otherwise hold the key hostage to a
    /// prompt edge that never comes.
    fn seed_project(&self, cwd: &str);

    /// Reserves the member id a [`Pane::join`] will use, WITHOUT admitting a member.
    ///
    /// The reservation is what makes the async window of a join attributable. Composing a joiner's
    /// screen is O(retained history) and then ships through that client's credit window; a link
    /// drop anywhere in there has to retire THIS member, and a table key naming no subscriber
    /// resolves to the pane's primary — so the incumbent would be retired instead.
    fn reserve_subscriber(&self) -> Subscriber;

    /// Admits a SECOND (third, …) client to a pane somebody is already watching.
    ///
    /// `None` when the pane emptied or the joining link died while the screen was being composed.
    /// The caller owns the unwind — see [`Pane::remove_resize_contributor`].
    fn join(&self, reserved: Subscriber, wires: Wires, size_passive: bool) -> Option<Subscriber>;

    /// Swaps a DETACHED pane's transport for a returning client's, and restarts its relay.
    ///
    /// `exit` rides in rather than being assigned after, and that is the point: a shell exiting
    /// between the rebind returning and a later assignment would fire the STALE detached-exit
    /// handler. `false` refuses — finished channels, or a pane that is not detached.
    fn rebind(&self, wires: Wires, exit: Arc<dyn SessionObserver>) -> bool;

    /// Replays the buffered tail to a channel, skipping everything at or below `after`.
    ///
    /// `true` means the replay was a RENDERED snapshot rather than raw bytes, which is half of what
    /// decides whether the repaint below is a nudge or a jiggle.
    fn replay_tail(&self, after: i64, channel: &SubChannel) -> bool;

    /// The highest sequence number this pane has ever issued — the clamp a resume verdict takes.
    fn highest_assigned_seq(&self) -> i64;

    /// Admits `subscriber` to the size fold at the passivity its connection resolved.
    fn add_resize_contributor(&self, subscriber: Subscriber, size_passive: bool);

    /// Drops `subscriber` from the size fold — a reservation that was never used.
    fn remove_resize_contributor(&self, subscriber: Subscriber);

    /// Parks the pane: the client goes, the shell stays, and `on_detached_exit` hears the child if
    /// it dies while parked.
    fn detach(&self, on_detached_exit: Arc<dyn SessionObserver>);

    /// Whether the pane is parked right now.
    fn is_detached(&self) -> bool;

    /// Retires one member. `true` when the pane still has members afterwards.
    fn remove_subscriber(&self, subscriber: Subscriber) -> bool;

    /// Makes the foreground program repaint, after a reattach handed it a fresh surface.
    ///
    /// `jiggle` picks between the two, and the difference is not cosmetic. A plain `SIGWINCH` is
    /// enough for a shell; a differential renderer IGNORES a same-size one for the rows it believes
    /// are already painted, so a transform-collapsed replay leaves its status line blank for ever.
    /// Only a REAL size change forces the re-layout, which is what the jiggle is — and the hold
    /// between the two signals belongs to whoever implements this, because it has to be long enough
    /// for the program's event loop to observe the intermediate size.
    fn redraw(&self, jiggle: bool);
}

/// Two panes are the same pane when they are the same OBJECT, which is what the slot is for.
///
/// Spelled as a function rather than `Arc::ptr_eq` on purpose: pointer equality on a `dyn` value
/// compares the vtable as well as the data, and two `Arc<dyn Pane>` handles on one pane can be
/// built through different coercion sites. The slot has no such caveat — it is the identity, and
/// comparing it is what the far side does too.
#[must_use]
pub fn same_pane(left: &Arc<dyn Pane>, right: &Arc<dyn Pane>) -> bool {
    left.slot() == right.slot()
}
