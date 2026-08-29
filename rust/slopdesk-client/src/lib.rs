//! `slopdesk-client` — the interactive remote terminal, over one pane driver.
//!
//! `docs/63` §G.5, second half. The first half moved the session itself into
//! `slopdesk-clientdriver`; this is what fell out afterwards, and the stage says so out loud:
//! *"arg parsing, a raw-mode guard, two byte pumps and a SIGWINCH resize, over crates that exist."*
//!
//! ## What it does
//! Dials `slopdesk-hostd`, opens one pane channel on it, and relays: local stdin to the host's PTY,
//! the host's output to local stdout. On a terminal it puts the line discipline into raw mode and
//! tracks `SIGWINCH`; on a pipe (or with `--no-raw`) it does neither, which is what makes
//! `echo 'exit' | slopdesk-client …` a scriptable thing. Status lines go to stderr, never to
//! stdout — stdout carries the session's bytes and nothing else.
//!
//! ## Three doors retired with the Swift this replaces
//! `slopdesk_tty_enter_raw`, `slopdesk_tty_restore` and `slopdesk_tty_install_restore_on_signals`
//! existed so `main.swift` could reach `slopdesk_posix::rawmode`, and `tty.rs`'s header named this
//! binary as the reason — *"the raw-mode trio is `slopdesk-client`'s, a macOS command-line
//! binary"*. A Rust `main` calls the crate, so all three lost their only caller, along with
//! `slopdesk_tty_window_size` and `slopdesk_fd_write_all`. A door whose far side went away is
//! `docs/55` §4b's own retirement criterion.
//!
//! ## A library and a bin, for the reason `slopdesk-cli` is
//! Everything a test can reach without two real descriptors is here; `main.rs` is the process
//! adapter that wires real argv and real stdio in. What needs the descriptors is in `tests/`, which
//! launches the shipped binaries — the crown-jewel proof `SubprocessE2ETests` used to be.

/// The command line, parsed.
pub mod args;
/// The process: the guard, the pumps and the loop.
pub mod relay;
