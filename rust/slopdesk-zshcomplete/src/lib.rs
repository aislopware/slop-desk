//! The host's bridge onto the user's OWN zsh completion system.
//!
//! ## The one decision this crate is
//! A rich prompt has to know what the shell would complete. The usual answer is a spec database —
//! a curated set of descriptions for the hundred commands someone thought of — which is why every
//! terminal that ships one also silently breaks the completions its users actually installed: the
//! plugin manager's, the company's internal CLI's, the ones a package dropped into
//! `site-functions`. This crate takes the other side of that trade. It runs the user's completion
//! system, unmodified, in a shell of its own, and reads what it produces.
//!
//! ## How
//! zsh's completions are not data. A completion function is program text that runs inside `zle`,
//! reaches for the shell's own dynamic scope, and reports what it found by CALLING `compadd` —
//! whose `-a`/`-k`/`-d` flags name arrays that exist only in that function's frame at that instant.
//! There is no file to read and no process to ask. So the bridge is a captive interactive zsh with
//! `compadd` overridden to REPORT and fall through: everything the user's setup decides is decided
//! by the user's setup, and this side only writes down what it decided.
//!
//! The split is two modules and it falls at the first newline:
//!
//! - [`setup`] is the zsh half, a constant — the smallest program that can be inside zsh while the
//!   answer is being produced. It emits flat, line-oriented records.
//! - [`parse`] is the reader for those records. Pure, and tested against verbatim captures from a
//!   real interactive shell.
//! - [`session`] is the lifecycle between them: one warm shell per host, a file in, a file out, a
//!   deadline, and a respawn.
//!
//! ## What it never does
//! It never changes what accepting a completion would insert. The `compadd` override always reaches
//! the builtin, so its caller reads the real status; an unknown flag makes the call report NOTHING
//! rather than report it under a guess; and `-U` matches — which zsh never compared against the
//! line — are dropped rather than offered against a replacement range that would be invented. Every
//! one of those is one-sided on purpose: a missing candidate costs a completion, and a wrong one
//! writes the user's command line for them.
//!
//! ## Scope
//! zsh only, by decision — `docs/DECISIONS.md` item (6). The capture half is not a shape another
//! shell has: bash's `complete -F` and fish's `complete` report through entirely different
//! mechanisms, and a bridge for either is a second capture half, not a flag on this one.

pub mod parse;
pub mod session;
pub mod setup;

pub use parse::{CandidateGroup, MAX_CANDIDATES, MAX_GROUPS, ShellCandidate};
pub use session::{Answer, DEADLINE, ZshComplete};
