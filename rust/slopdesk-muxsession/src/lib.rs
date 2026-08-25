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
//!
//! [`detach_retention`] is the fourth, and the only one about a SET of sessions rather than one:
//! what the detached store keeps when an id arrives twice and when the opt-in cap is full. No
//! identity crosses — the near side answers `===` and the position, and every verdict comes back as
//! a position into the list it handed in.
//!
//! [`outbox`] is the fifth, and the first about BYTES — without holding any. It owns the order the
//! pane's outbound frames leave in: which queued chunks coalesce into one `.output`, where an
//! over-cap head splits, and that `.exit` is a barrier neither may cross. The queue holds
//! `(slot, len)`; hostd holds the payload each slot names, so the merge decision crosses and the
//! concatenation stays where the `Data` already is.
//!
//! [`fanout`] is the sixth, and the one about a SET of clients on one pane: the roster and its
//! order, each member's ack and delivery cursors, which of them has fallen too far behind to keep,
//! and how far retention may be released. Sockets and tasks stay where they are; what crosses is an
//! `id` and the cursors that decide what the pane does next.

pub mod bridge_router;
pub mod detach_retention;
pub mod fanout;
pub mod outbox;
pub mod resize_fold;
pub mod spawn_env;
