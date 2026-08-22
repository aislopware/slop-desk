//! # `slopdesk-ids`
//!
//! The three NOTATIONS the rest of the tree writes itself down in — an id, a JSON value, a shell
//! word — and nothing else.
//!
//! - [`identity`] — the ids of the session → tab → pane hierarchy, the reason none of them can be
//!   minted here, and their canonical text form.
//! - [`json`] — the subset of JSON both persistence files are written in, and why that is not a
//!   crack in the manual-binary rule.
//! - [`shell_quoting`] — any text as one shell word, for everything that types a path into a shell.
//!
//! ## Why they are a crate
//!
//! Each of the three is a SPELLING rather than a decision: there is no policy in them to disagree
//! with, only a form the data takes when it has to leave a process. All three used to live in
//! `slopdesk-workspace`, which meant `slopdesk-wire` — the golden-pinned protocol — took a
//! 25,000-line domain crate to read a uuid, and `slopdesk-terminal` took the same crate to quote
//! one path. Both edges now point here.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`.**
//! * **No dependencies, ours or anyone else's.** That is the property the callers are buying, not
//!   an accident of the current contents: a leaf that cannot grow an edge back into the domain
//!   cannot re-create the inversion this crate was carved out to remove. Anything that needs to
//!   know what a pane IS belongs one layer up, in `slopdesk-tree`.
//! * **Total functions over hostile input.** Every one of these parses bytes a network peer chose.
//!   Nothing here indexes, unwraps or panics — the lint table denies all three.

pub mod identity;
pub mod json;
pub mod shell_quoting;

pub use identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId, parse_uuid, uuid_text};
pub use json::{Json, JsonError};
