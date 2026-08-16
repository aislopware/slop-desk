//! The scans over terminal TEXT that need a regex engine.
//!
//! Three of them. [`hint`] finds what a two-letter Hint Mode label can pin to and [`find`] finds
//! what the ⌘F bar highlights — both answer the same shape, rows in and spans out, ordered the way
//! the eye reads them. [`waituntil`] is the one that holds state, because its text is not a buffer
//! that exists: it is a live PTY stream an agent is blocked on, arriving a chunk at a time.
//!
//! ## Why they share a crate, and why it is not `slopdesk-terminal`
//!
//! Because of the one dependency all three need. A `hint-pattern`, a ⌘F regex and a `wait --until`
//! marker are PATTERNS a human typed, run against text a remote program wrote — the places in the
//! tree where untrusted input meets untrusted input. `regex` is the answer to exactly that pairing:
//! a finite automaton with no backtracking, so a match costs time linear in the text no matter what
//! the pattern says. The Swift all three replaced used `NSRegularExpression`, which backtracks — so
//! a pattern pasted off the internet could hang the overlay, or the find bar, or the PTY read loop,
//! on one long line, and no bound on the SCAN fixes a pathological MATCH.
//!
//! `slopdesk-terminal` takes no external dependency, and its manifest says why: everything it
//! parses is untrusted and it sits on the PTY hot path. `slopdesk-sanitize` says the same about
//! itself. The honest reading of that rule is not to smuggle a crate in beside the tracker or the
//! stripper, so the modules that need one live here and take both as siblings. That boundary is the
//! whole reason this crate exists — and it is where a FOURTH module belongs, if one ever needs a
//! pattern engine over terminal text.
//!
//! ## What is NOT here
//!
//! Anything a caller does with the answer. Assigning two-letter labels, walking next/previous with
//! wrap, keeping a selection anchored across a recompute, blocking a socket connection on a
//! condition variable — those are arithmetic and scheduling around the scan, they run beside the
//! thing that holds them, and they stay in Swift.

pub mod find;
pub mod hint;
pub mod waituntil;
