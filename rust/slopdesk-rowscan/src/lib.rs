//! The scans over terminal ROWS that need a regex engine.
//!
//! Two of them, and they answer the same shape: rows in, `(row, column, length)` spans out, ordered
//! the way the eye reads them. [`hint`] finds what a two-letter Hint Mode label can pin to;
//! [`find`] finds what the ⌘F bar highlights. Neither renders anything and neither holds state.
//!
//! ## Why they share a crate, and why it is not `slopdesk-terminal`
//!
//! Because of the one dependency both need. A `hint-pattern` and a ⌘F regex are PATTERNS a human
//! typed, run against rows a remote program wrote — the two places in the tree where untrusted
//! input meets untrusted input. `regex` is the answer to exactly that pairing: a finite automaton
//! with no backtracking, so a match costs time linear in the row no matter what the pattern says.
//! The Swift both replaced used `NSRegularExpression`, which backtracks — so a pattern pasted off
//! the internet could hang the overlay, or the find bar, on one long line, and no bound on the SCAN
//! fixes a pathological MATCH.
//!
//! `slopdesk-terminal` takes no external dependency, and its manifest says why: everything it
//! parses is untrusted and it sits on the PTY hot path. The honest reading of that rule is not to
//! smuggle a crate in beside the tracker, so the modules that need one live here and take the link
//! scan as a sibling. That boundary is the whole reason this crate exists — and it is why a THIRD
//! module belongs here too, if one ever needs a pattern engine over rows.
//!
//! ## What is NOT here
//!
//! Anything a caller does with the spans. Assigning two-letter labels, walking next/previous with
//! wrap, keeping a selection anchored across a recompute — those are list arithmetic over the
//! answer, they run per keystroke beside the surface that holds them, and they stay in Swift.

pub mod find;
pub mod hint;
