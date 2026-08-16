//! `slopdesk-superd` — the custodian of every long-lived child process.
//!
//! ## The problem, in one paragraph
//! Editing anything in hostd means restarting hostd, and restarting hostd kills every process it
//! forked — including a `claude` that has been working for twenty minutes. So you don't restart,
//! and the edit waits. superd removes the coupling: it forks and holds the children, hostd borrows
//! them. hostd can die, be rebuilt, and come back to the same live shells.
//!
//! ## The rule that produced this boundary
//! **hostd's pid may not appear in anything a live child remembers.** A running child remembers
//! two things — the master fd of its PTY, and its environment. The fd is a kernel object, so
//! passing it across `SCM_RIGHTS` is enough. The environment is a snapshot taken at `execve`, so
//! any socket path baked into it must already be stable — which is why the hook and ctl sockets
//! move here too, and lose their `-<pid>` suffix (`docs/51` §1, `paths`).
//!
//! ## Why superd is Rust
//! It is a small, long-lived, entirely non-UI daemon whose whole job is syscalls and bookkeeping,
//! and whose failure mode is losing every running agent at once. `nix` also removes the hand-rolled
//! `cmsghdr` arithmetic the Swift side needs, because `CMSG_*` are C macros Swift cannot see.
//!
//! ## Where the syscalls went
//! The `fork`/`execve` window and the four other calls with no safe wrapper are `slopdesk-posix`
//! (stage 28), which is why this crate is `forbid(unsafe_code)` and not `deny`. Nothing about the
//! daemon's job changed — a pane is still born by forking — but the obligation now has an address
//! outside these eleven thousand lines, so `forbid` here states a fact rather than an intention.
//!
//! ## What superd is NOT
//! Not a protocol relay. Its two continuing jobs are to hold each pane's master fd so hostd dying
//! does not `SIGHUP` the child, and to `read` that fd so the child never blocks on a full PTY
//! buffer while nobody is home ([`pump`]). Everything else it holds, it hands over: hostd gets a
//! *duplicate* of the master for `write`, `TIOCSWINSZ` and `tcgetpgrp`, so the keystroke path keeps
//! no extra hop and the foreground-pgrp probe stays a syscall rather than polled IPC. The same rule
//! decides the child-facing sockets ([`listeners`]) — superd owns the `bind`, because the address
//! has to outlive hostd's pid, and passes every accepted connection over `SCM_RIGHTS` without
//! reading a byte of it. What superd contains is what has to survive a hostd rebuild. Nothing else.

/// Which command lines deserve an automatic progress badge.
pub mod autoprogress;
/// The live half of the command-block tap: what to report, and what to keep.
pub mod blocks;
/// One record per command, segmented from the OSC 133 marks.
pub mod commandblocks;
/// Framing and `SCM_RIGHTS` fd passing.
pub mod frame;
/// The on-disk transcript of a pane whose process is gone.
pub mod journal;
/// The child-facing sockets superd binds and hostd serves.
pub mod listeners;
/// The stable, pid-free socket paths.
pub mod paths;
/// The version-skew-tolerant message set.
pub mod protocol;
/// One reader thread per pane — the always-on drain.
pub mod pump;
/// The pane table — what superd actually is.
pub mod registry;
/// A pane's retained output, addressed by absolute offset.
pub mod ring;
/// The accept loop and verb dispatch.
pub mod server;
/// The generated `ZDOTDIR` that makes a spawned zsh reprint its prompt and mark its commands.
pub mod shellintegration;
/// One pass over the outbound stream for everything the shell says out of band.
pub mod sniffer;
