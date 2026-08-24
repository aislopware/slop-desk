//! How `slopdesk-hostd` was started: the argv grammar it accepts, and the record it publishes.
//!
//! Two modules and one domain. [`args`] is what the daemon's command line MEANS; [`record`] is what
//! the running daemon says about the command line it was actually given, once the bound port is
//! known. `slopdesk-ops restart-hostd` reads the second and re-derives the first from it — that
//! pairing is why they are one crate. See `docs/51-process-supervision.md` §9.
//!
//! Everything here is a value transform plus, in [`record`], a read and a write of one file. No
//! socket, no process, no `exit`: the daemon supplies the two facts it alone knows (the bound port
//! and its build version) and this asks the process for the rest.

pub mod args;
pub mod record;
pub mod stamp;
