//! The policy half of one hostd pane session.
//!
//! `MuxChannelSession` owns a PTY, four relay tasks and a teardown ladder. None of that is here.
//! What is here is what it DECIDES — the grid fold of docs/45 §8.3, and the environment a pane's
//! login shell is spawned into — expressed over small integers and plain strings so each can be
//! exercised without a descriptor, a client or a runloop.
//!
//! The split is the same one the rest of the tree makes: the ioctl stays where the descriptor is,
//! the `posix_spawn` stays where the PTY master is, and everything that chose their arguments lives
//! somewhere a test can reach.
//!
//! [`bridge_router`] is the third decision of that shape and the only one about a pane other than
//! its own: which of the host's live sessions a command issued from the embedded editor should be
//! typed into. It is here because the answer is a ranking over pane facts — a cwd, an agent flag, a
//! foreground basename — and none of those needs a descriptor either.

pub mod bridge_router;
pub mod resize_fold;
pub mod spawn_env;
