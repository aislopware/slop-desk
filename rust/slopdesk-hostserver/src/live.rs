//! The [`Pane`] a real hostd puts in the table: one [`PaneSession`], plus the two identities the
//! session itself deliberately does not carry.
//!
//! [`PaneSession`] knows about a PTY, its members and the wire between them, and it knows nothing
//! about being ONE OF MANY — no session id, no slot, no table. That is not an omission: a crate
//! that named its own position in a collection could not be tested apart from the collection, and
//! `docs/60` stage C.2 spent its whole scoping keeping that line. So the identities are pinned on
//! HERE, at the join, which is the first place both halves are in scope.
//!
//! ## D.5 widened it, and the shape held
//!
//! The agent-control verbs need a pane too, and D.5 read what they need off [`PaneSession`] rather
//! than wishing for it: every method below is ONE call into the session — `write_for_control`,
//! `set_ctl_size`, `agent_status`, the three tap registries. Only [`Pane::render_screen`] does work
//! here, and only the work a fake cannot: the round trip to screend. D.6 merged the two traits
//! (see [`crate::pane`]) and this file lost an `impl` block, nothing else.

use std::sync::Arc;

use slopdesk_agent::supervision::SupervisionState;
use slopdesk_agent::{ClaudeHookEvent, ClaudeStatus};
use slopdesk_hostnet::subchannel::SubChannel;
use slopdesk_hostsession::{
    BlockTap, CloseTap, OutputTap, PaneLatches, PaneSession, SessionObserver, TapToken,
};
use slopdesk_muxsession::registry::{self, Slot, Subscriber, Uuid};
use slopdesk_muxsession::resize_fold::Attachment;
use slopdesk_screenwire::payload::Snapshot;
use slopdesk_superwire::protocol::BlocksReply;
use slopdesk_wire::message::ProjectGitStatus;

use crate::pane::{Pane, Wires};

/// The most scrollback `screen` will hand screend for ONE reconstruction.
///
/// A ring holding more than this contributes only its NEWEST whole messages, which is safe for the
/// thing this feeds: a full-screen program repaints, so a truncated prefix converges after one
/// redraw cycle. The same property the ring's own truncation already relies on, and the same eight
/// megabytes the Swift passed.
const SCREEN_REPLAY_CAP_BYTES: usize = 8 * 1024 * 1024;

/// A live pane in hostd: the session, the conversation it serves, and its object identity.
#[derive(Debug)]
pub struct LivePane {
    session: Arc<PaneSession>,
    id: Uuid,
    slot: Slot,
}

impl LivePane {
    /// Adopts `session` as the pane serving conversation `id`, minting it a fresh slot.
    ///
    /// The mint happens HERE, exactly once per object, because a slot minted anywhere else could be
    /// minted twice for one pane — and two slots for one pane is two entries in every enumeration
    /// hostd has, which shuts the same PTY twice.
    #[must_use]
    pub fn adopt(session: Arc<PaneSession>, id: Uuid) -> Arc<Self> {
        Arc::new(Self {
            session,
            id,
            slot: registry::mint_slot(),
        })
    }

    /// The session underneath, for the callers that steer the pane rather than file it.
    #[must_use]
    pub const fn session(&self) -> &Arc<PaneSession> {
        &self.session
    }
}

impl Pane for LivePane {
    fn id(&self) -> Uuid {
        self.id
    }

    fn slot(&self) -> Slot {
        self.slot
    }

    fn is_child_exited(&self) -> bool {
        self.session.is_child_exited()
    }

    fn member_count(&self) -> usize {
        self.session.member_count()
    }

    fn shutdown(&self) {
        self.session.shutdown();
    }

    fn relinquish(&self) {
        self.session.relinquish();
    }

    fn write_raw(&self, bytes: &[u8]) {
        self.session.write_for_control(bytes);
    }

    fn resize(&self, rows: u16, cols: u16) {
        // `(cols, rows)` — the session's size vocabulary is width-first, the control verb's is
        // height-first, and the swap is here rather than at either end because this is the only
        // place both spellings are in scope.
        self.session.set_ctl_size(cols, rows);
    }

    fn window_size(&self) -> Option<(u16, u16)> {
        self.session.window_size()
    }

    fn foreground_name(&self) -> String {
        self.session.foreground_name()
    }

    fn title(&self) -> String {
        self.session.title()
    }

    fn cwd(&self) -> Option<String> {
        self.session.cwd()
    }

    fn pid(&self) -> i32 {
        self.session.pid()
    }

    fn last_exit_code(&self) -> Option<i32> {
        self.session.last_exit_code()
    }

    fn latches(&self) -> PaneLatches {
        self.session.latches()
    }

    fn attachments(&self) -> ((u16, u16), Vec<Attachment>) {
        (self.session.resolved_grid(), self.session.size_contributions())
    }

    fn agent_status(&self) -> (String, Option<String>) {
        let (status, label) = self.session.agent_status();
        // The five-way host reading collapses onto the four-way ctl vocabulary here, through the
        // one conversion `slopdesk-agent` owns: `None` and `Idle` are both `idle` on the wire,
        // because an orchestrator asking "is this pane blocked" has no use for the difference and
        // a fifth token would be one every ctl client had to learn.
        (String::from(SupervisionState::from_status(status).name()), label)
    }

    fn agent_present(&self) -> bool {
        // The RAW reading, before the collapse `agent_status` performs: presence is exactly "the
        // detector has seen an agent", which is every status but `None`.
        self.session.agent_status().0 != ClaudeStatus::None
    }

    fn report_agent_status(&self, state: &str, message: Option<&str>) {
        self.session.report_agent_status(state, message);
    }

    fn fold_hook(&self, event: ClaudeHookEvent, kind_byte: u8, prompt: Option<&str>) {
        self.session.fold_hook(event, kind_byte, prompt);
    }

    fn push_git_status(&self, status: &ProjectGitStatus) {
        self.session.push_project_git_status(status);
    }

    fn scrollback_text(&self, ansi_strip: bool) -> String {
        self.session.scrollback_text(ansi_strip)
    }

    fn render_screen(&self, rows: usize, cols: usize) -> Result<Snapshot, String> {
        // The process-wide client, not one per pane: a screend connection is pooled and forty panes
        // asking is forty callers, not forty sockets. Reached HERE rather than from the dispatcher
        // so the verb stays drivable by a fake — see [`Pane::render_screen`].
        slopdesk_screenclient::shared()
            .snapshot(&self.session.scrollback_raw(SCREEN_REPLAY_CAP_BYTES), rows, cols)
            .map_err(|error| error.to_string())
    }

    fn recent_lines(&self, limit: Option<usize>) -> Vec<String> {
        self.session.recent_lines(limit)
    }

    fn blocks(&self, limit: usize) -> Option<BlocksReply> {
        self.session.blocks(limit)
    }

    fn block_output(&self, index: u32) -> Option<Vec<u8>> {
        self.session.block_output(index)
    }

    fn add_output_tap(&self, tap: Arc<dyn OutputTap>) -> TapToken {
        self.session.add_output_tap(tap)
    }

    fn remove_output_tap(&self, token: TapToken) {
        self.session.remove_output_tap(token);
    }

    fn add_close_tap(&self, tap: Arc<dyn CloseTap>) -> TapToken {
        self.session.add_close_tap(tap)
    }

    fn remove_close_tap(&self, token: TapToken) {
        self.session.remove_close_tap(token);
    }

    fn add_block_tap(&self, tap: Arc<dyn BlockTap>) -> TapToken {
        self.session.add_block_tap(tap)
    }

    fn remove_block_tap(&self, token: TapToken) {
        self.session.remove_block_tap(token);
    }

    fn start(&self) {
        self.session.start();
    }

    fn seed_project(&self, cwd: &str) {
        self.session.seed_project(cwd);
    }

    fn reserve_subscriber(&self) -> Subscriber {
        self.session.reserve_subscriber_id()
    }

    fn join(&self, reserved: Subscriber, wires: Wires, size_passive: bool) -> Option<Subscriber> {
        self.session.join(
            Some(reserved),
            wires.data,
            wires.data_inbound,
            wires.control,
            wires.control_inbound,
            size_passive,
        )
    }

    fn rebind(&self, wires: Wires, exit: Arc<dyn SessionObserver>) -> bool {
        self.session.rebind(
            wires.data,
            wires.data_inbound,
            wires.control,
            wires.control_inbound,
            exit,
        )
    }

    fn replay_tail(&self, after: i64, channel: &SubChannel) -> bool {
        self.session.replay_tail(after, channel)
    }

    fn highest_assigned_seq(&self) -> i64 {
        self.session.highest_assigned_seq()
    }

    fn add_resize_contributor(&self, subscriber: Subscriber, size_passive: bool) {
        self.session.add_resize_contributor(subscriber, size_passive);
    }

    fn remove_resize_contributor(&self, subscriber: Subscriber) {
        self.session.remove_resize_contributor(subscriber);
    }

    fn detach(&self, on_detached_exit: Arc<dyn SessionObserver>) {
        self.session.detach(on_detached_exit);
    }

    fn is_detached(&self) -> bool {
        self.session.is_detached()
    }

    fn remove_subscriber(&self, subscriber: Subscriber) -> bool {
        self.session.remove_subscriber(subscriber)
    }

    fn redraw(&self, jiggle: bool) {
        self.session.redraw(jiggle);
    }
}
