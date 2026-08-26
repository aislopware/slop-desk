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

use slopdesk_hostsession::{BlockTap, CloseTap, OutputTap, TapToken};
use slopdesk_muxsession::registry::{Slot, Uuid};
use slopdesk_screenwire::payload::Snapshot;
use slopdesk_superwire::protocol::BlocksReply;

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
