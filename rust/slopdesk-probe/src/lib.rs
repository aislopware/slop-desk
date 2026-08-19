//! `slopdesk-probe` — the questions hostd asks about the machine it is running on.
//!
//! ## What is here, and what stayed in hostd
//! The Swift `HostMetadataProbe` answered ten queries for the pure `MetadataResponseBuilder`. Four
//! of them are subprocesses and filesystem walks with nothing behind them but a path, and those are
//! here: `gitDiff`, `listDirectory`, `listAgentSessions`, `readAgentSession`. The terminfo
//! resolution joined them for the same reason — it is one `stat` sweep and one `infocmp`.
//!
//! `gitStatus` was the fifth and is no longer a fork at all: `rust/slopdesk-git` is LINKED into
//! hostd and answers it from an open repository handle, so the verb the repo watcher polls on a
//! cadence costs zero spawns. See that crate's manifest for why it is a library and not a program.
//!
//! Five stayed, each because a forked program does not have what it needs:
//!
//! - `paneWorkingDirectory` and `processes`/`ports` are anchored to the pane's PTY master fd
//!   (`tcgetpgrp`, `ptsname`) and to `proc_pidinfo` over every live pid. hostd holds that fd, and
//!   CLAUDE.md is explicit that holding it for `ioctl`/`tcgetpgrp` is the one thing a second reader
//!   may do — passing it across an exec to save four Darwin calls is a trade nobody wants.
//! - `hostVitals` is a DELTA between two tick snapshots, so it needs state that outlives a request.
//!   A forked program has none, and giving it a file to keep a baseline in would be inventing
//!   durability for a number that is meaningless after a gap.
//! - `hostName` is one `ProcessInfo` field and is not worth a spawn.
//!
//! That split is the reason this is a fork rather than a daemon: nothing here remembers anything.
//!
//! ## Why it is a program at all
//! Every verb left here rides a PERSON: a folder someone expanded, a diff someone opened, a session
//! list someone asked for, a pane someone just opened. A fork per click is affordable in a way a
//! fork per filesystem event is not, which is exactly the line `gitStatus` crossed when it left.
//!
//! And it is TESTABLE. The Swift probe carried a standing note that it was compiled and
//! code-reviewed only, never unit-tested, because spinning a real `git` in a test is precisely what
//! the hang-safety rule exists to keep out of the suite. Here the process boundary is at the edge
//! and everything behind it is a function over strings and directories.

pub mod files;
pub mod git;
pub mod run;
pub mod terminfo;
