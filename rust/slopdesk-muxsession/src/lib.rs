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
//!
//! [`open_route`] is the seventh, and the one that decides whether a pane session EXISTS: which of
//! seven exits an inbound `channelOpen` takes, and the three numbers a reattach turns on. It is the
//! first thing here that reads a wire vocabulary — the open's class byte, through the enum that
//! owns it — because routing a class this build does not serve into the PTY path forks a shell
//! nobody asked for, and a second copy of "0 is a pane" is how that happens.
//!
//! [`metadata_admission`] is the eighth, and the one about a pane's OTHER sub-channel: how many
//! host-metadata work items one session may have in flight, and which performer owns a verb. The
//! Finder call, the pasteboard write and the child spawn stay where the frameworks are; what
//! crosses is whether there is room and who is being asked.
//!
//! [`registry`] is the ninth, and the only one about ALL of hostd's panes rather than one: which
//! channel names which pane, which subscriber of it a channel is, where a pane's agent hooks route,
//! and which document id a project path has. A fanned-out pane is ONE session object under N
//! channel keys, so every event is either about one member or about all of them, and the two used
//! to be told apart by two dictionaries that had to agree. Object identity crosses as a `slot`; the
//! objects stay in hostd, which is the one thing that cannot.
//!
//! [`lifecycle`] is the tenth, and the one about a pane session's own arc: whether this `detach` is
//! the one that tears down, whether a returning client may rebind at all, where its subscription
//! re-opens, and the two latches the exit task waits on before it may yield `.exit` and fire
//! `onExit`. The tasks and the stream stay in hostd; what crosses is a guard and a cursor.

pub mod bridge_router;
pub mod detach_retention;
pub mod fanout;
pub mod lifecycle;
pub mod metadata_admission;
pub mod open_route;
pub mod outbox;
pub mod registry;
pub mod resize_fold;
pub mod spawn_env;
pub mod truths;
