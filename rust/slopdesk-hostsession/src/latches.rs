//! One pane's latched truths as a VALUE — everything a reader outside this crate can learn about a
//! pane without touching its PTY.
//!
//! ## Why a struct rather than accessors
//!
//! Almost every field here already had an accessor — `foreground` is the exception, and the latch
//! it reads is the one this batch added to `PaneDetector` — and
//! [`PaneSession::latches`](crate::PaneSession::latches) is what replaced calling them in a row.
//! The reason is CONSISTENCY rather than speed: the folds lock is taken by the read loop on every
//! sniffed batch, so one acquisition per accessor leaves a window between each pair in which a
//! command edge can land — and a record whose `title` was read before that edge and whose
//! `running_command` was read after it describes a pane that never existed.
//!
//! Speed is the second reason and it is real too: the workspace document's reconciler captures
//! EVERY pane on every tick.
//!
//! ## What is deliberately NOT here
//!
//! The GRID, because it lives behind the PTY's own lock rather than the folds lock, and this crate
//! does not nest the two. `PaneSession::window_size` answers it beside the call.
//!
//! The LIVENESS — attached, detached or dead — because it is a fact about the SERVER's session
//! maps and not about the pane. A pane cannot know whether anybody is holding it in a table it
//! cannot see, and guessing renders a dead pane as fake-live.

/// Every latch one pane holds, read together.
///
/// Cloned out rather than borrowed: the fields live under a lock the caller must not still be
/// holding when it composes a record out of them.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PaneLatches {
    /// The window title the shell last asserted, `""` when it has asserted none.
    pub title: String,
    /// When that title was sniffed, on the host reference timeline. `None` once the agent that
    /// owned it handed it back — which is a different state from an empty title, and stays one.
    pub title_at: Option<f64>,
    /// When the command now running started, on the monotonic timeline. `None` at a prompt.
    pub command_started_at: Option<f64>,
    /// The command line the pane is running, `None` at a prompt or with block tracking off.
    pub running_command: Option<String>,
    /// The freshest host-observed working directory.
    pub cwd: Option<String>,
    /// The By-Project key that directory resolved to.
    pub project_key: Option<String>,
    /// The freshest OSC 9;4 `(state, percent)` pair, `None` when the badge is down.
    pub progress: Option<(u8, u8)>,
    /// The freshest code-carrying OSC-133-D exit status.
    pub last_exit_code: Option<i32>,
    /// The host-measured duration of the last completed command.
    pub last_duration_ms: Option<u32>,
    /// How many turns have finished on this pane.
    pub completion_epoch: u32,
    /// The urgency byte the type-27 stream stands at. Zero is "no agent has ever spoken".
    pub agent_state: u8,
    /// The notification class beside it.
    pub agent_kind: u8,
    /// The agent's short human label.
    pub agent_label: Option<String>,
    /// What the agent says it is doing (type 36).
    pub agent_intent: Option<String>,
    /// The canonical name of whatever held the terminal at the last foreground POLL.
    ///
    /// The poll's latch, never a fresh probe: resolving it costs a `tcgetpgrp` and a
    /// `proc_pidpath`, and a caller reading it for every pane at once would pay that pair per pane
    /// for an answer the poll already took. `None` before the first sample; `Some("")` is the real
    /// state between one child exiting and the next starting.
    pub foreground: Option<String>,
}
