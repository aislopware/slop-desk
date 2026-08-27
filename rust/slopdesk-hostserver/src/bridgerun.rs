//! "Run this in my terminal" — the whole of it, assembled from the pure router and the pane table.
//!
//! The port of `HostServer.installCodeBridgeTerminalRunner()`, `codeBridgePanes()` and
//! `writeCodeBridgeKeystrokes(_:toPane:)` — three Swift members that were one thought split by
//! where their pieces happened to live.
//!
//! [`crate::bridge::CodeBridgeServer`] has held a [`TerminalRunner`] seam since stage E and nothing
//! installed one, so every `run` the workbench extension sent came back refused with "no terminal
//! runner is installed". [`bridge_router`] has held the DECISION for just as long, tested on
//! synthetic panes. This is the ten lines between them: the live pane table flattened into what the
//! router reads, and the router's answer turned into a `write(2)`.
//!
//! ## The candidate set is the terminals ON SCREEN
//! [`Sessions::live_panes`] — attached mux panes, deduped to one entry per pane rather than one per
//! watching client — and NOT the control listing. A detached pane's shell is live but nobody is
//! looking at it, and a standalone control pane belongs to an orchestrator that owns its input;
//! typing a user's command into either would put it where the user cannot see it happen. The
//! editor's command is a hand gesture towards a terminal on screen, so the candidates are exactly
//! the terminals on screen.
//!
//! ## Two syscalls per pane, and the lock is not held across them
//! `cwd` and `foreground_name` each cost a probe. The pane handles are cloned out under the
//! sessions lock and every probe runs after it is dropped — the Swift did the same, and the reason
//! is that this runs on the bridge socket's READ thread, which must not be able to park the mux.
//!
//! ## A pane that went away between the choice and the write is a REFUSAL
//! Not a silent drop: the extension is waiting on the reply line to tell the user something, and
//! "it went somewhere, probably" is the one answer that cannot be acted on. The `Arc` keeps the
//! pane object alive across the gap, so what is re-checked is whether its CHILD is gone — the
//! narrower and more honest question.

use std::sync::{Arc, Weak};

use slopdesk_ids::uuid_text;
use slopdesk_muxsession::bridge_router::{self, BridgePane, Refusal, RunRequest};

use crate::bridge::{RunOutcome, TerminalRunner};
use crate::host::Host;
use crate::pane::Pane;

/// The live panes, flattened for the router, WITH the handle each row came from.
///
/// Two parallel vectors rather than a row that owns its pane: [`bridge_router::choose`] takes a
/// `&[BridgePane]` and gives back a borrow into it, so the row type is the router's to define and
/// this side keeps the handles beside it in the same order.
struct Candidates {
    rows: Vec<BridgePane>,
    panes: Vec<Arc<dyn Pane>>,
}

impl Candidates {
    /// Every attached pane whose child is still running, in one pass.
    fn of(host: &Host) -> Self {
        let live: Vec<Arc<dyn Pane>> = host.sessions().live_panes();
        let mut rows = Vec::with_capacity(live.len());
        let mut panes = Vec::with_capacity(live.len());
        for pane in live {
            if pane.is_child_exited() {
                continue;
            }
            rows.push(BridgePane {
                pane_id: uuid_text(pane.id()),
                cwd: pane.cwd(),
                has_agent: pane.agent_present(),
                foreground: pane.foreground_name(),
            });
            panes.push(pane);
        }
        Self { rows, panes }
    }

    /// The handle behind the row the router picked.
    ///
    /// By id rather than by index arithmetic on the borrow: the two vectors are built in lockstep,
    /// but a lookup that would break silently if that ever stopped being true is not worth the
    /// handful of string comparisons it saves.
    fn pane_named(&self, pane_id: &str) -> Option<&Arc<dyn Pane>> {
        let index = self.rows.iter().position(|row| row.pane_id == pane_id)?;
        self.panes.get(index)
    }
}

/// What happens when the workbench asks to type into a terminal pane.
///
/// Install it on the [`CodeBridgeServer`](crate::bridge::CodeBridgeServer) the composition holds;
/// the server itself never learns what a pane is.
///
/// Holds the host WEAKLY. The server outlives no host in this daemon, but it is owned by the panel
/// table rather than by the host, and a strong handle here would make the shutdown order decide
/// whether the process exits — see the `[weak self]` the Swift carried for the same reason. A dead
/// handle refuses with [`Refusal::NoPaneInProject`], which is the truth about a host that is gone.
#[must_use]
pub fn terminal_runner(host: &Arc<Host>) -> TerminalRunner {
    let held = Arc::downgrade(host);
    Arc::new(move |request: &RunRequest| run(&held, request))
}

/// One request, start to finish.
fn run(host: &Weak<Host>, request: &RunRequest) -> RunOutcome {
    let Some(host) = host.upgrade() else {
        return RunOutcome::refused(Refusal::NoPaneInProject.message());
    };
    let candidates = Candidates::of(&host);
    let chosen = match bridge_router::choose(&candidates.rows, &request.root, request.directory.as_deref()) {
        Ok(pane) => pane,
        Err(refusal) => return RunOutcome::refused(refusal.message()),
    };
    let Some(pane) = candidates.pane_named(&chosen.pane_id) else {
        return RunOutcome::refused(Refusal::NoPaneInProject.message());
    };
    if pane.is_child_exited() {
        return RunOutcome::refused(Refusal::NoPaneInProject.message());
    }
    pane.write_raw(&bridge_router::keystrokes(&request.text));
    RunOutcome::landed(&pane.title())
}
