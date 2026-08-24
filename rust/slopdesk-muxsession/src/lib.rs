//! The policy half of one hostd pane session.
//!
//! `MuxChannelSession` owns a PTY, four relay tasks and a teardown ladder. None of that is here.
//! What is here is what it DECIDES — today, the grid fold of docs/45 §8.3 — expressed over small
//! integers so it can be exercised without a descriptor, a client or a runloop.
//!
//! The split is the same one the rest of the tree makes: the ioctl stays where the descriptor is,
//! and the arithmetic that chose its argument lives somewhere a test can reach.

pub mod resize_fold;
