//! `slopdesk-posix` — the whole of slopdesk's `unsafe`, in one place.
//!
//! ## What this crate is for
//! Rust's safety guarantee is only as strong as the smallest region you have to audit by hand.
//! Spreading five `unsafe` blocks through an eleven-thousand-line daemon does not make them fewer;
//! it makes them unfindable, and it forces the whole daemon down from `forbid(unsafe_code)` to
//! `deny`, which any file in it can lift with one attribute. Collecting them here inverts that:
//! every other crate in the repository now carries `forbid`, which no downstream `allow` can undo,
//! and the code a reviewer must actually reason about is this directory.
//!
//! ## The admission test
//! A syscall with no safe wrapper in `std` or `nix`, plus the obligation that makes it sound —
//! and nothing else. **If the safety comment cannot be written without naming slopdesk, the
//! function belongs in the caller.** A local obligation is the only kind a crate this small can
//! discharge; "the registry holds this fd open" is not a fact about a syscall, it is a fact about
//! a pane table, and it has to be argued where the pane table is.
//!
//! That test is why [`pty::spawn_pty`] is here whole rather than as a `fork` primitive: the thing
//! that is unsafe about forking is not the call, it is the window afterwards, and a window can only
//! be made sound by owning every instruction in it.
//!
//! ## What is deliberately NOT here
//! Adopting a raw descriptor. `OwnedFd::from_raw_fd` is unsafe because nothing about the integer
//! proves it is unowned, so a `pub fn adopt(RawFd) -> OwnedFd` would be a safe function with an
//! unsound signature — the exact shape this crate exists to abolish. The one place superd needs it
//! is the descriptor `recvmsg` has just installed, so [`fdpass::recv_tagged`] does the receive AND
//! the adoption together and hands back an `OwnedFd`: the proof never leaves the function that can
//! give it.
//!
//! ## Crate layout
//! One module per kind of syscall, so a reviewer can take them one at a time.

/// Resolving a symbol at run time, and calling it.
pub mod dynsym;
/// Moving every byte over a bare descriptor, EINTR and short transfers folded in.
pub mod fdio;
/// One-byte-plus-descriptor `recvmsg`, the receiving half of `SCM_RIGHTS`.
pub mod fdpass;
/// The disassembly pin on [`pty`]'s fork-to-exec window.
///
/// A module rather than `tests/`: an integration test links only the library code it references,
/// and the window is private, so its symbol never reaches that binary. Here it is compiled into
/// the same object as the function it guards.
#[cfg(test)]
mod fork_window_contract;
/// The machine's own counters — Mach host statistics, `sysctl` scalars, `statfs`.
pub mod hoststats;
/// Reading another process.
pub mod proc;
/// `openpty` + `fork` + `execve`, and the descriptor flags around them.
pub mod pty;
/// A LOCAL terminal's line discipline, restored from a signal handler.
pub mod rawmode;
/// Process-wide signal dispositions.
pub mod signal;
/// Socket options with no `nix` wrapper taking a bare descriptor.
pub mod sock;
