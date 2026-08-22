//! # `slopdesk-tree`
//!
//! The session → tab → pane MODEL, and every pure operation on it.
//!
//! This is the half of the workspace document that [`slopdesk-wire`](https://docs.rs/slopdesk-wire)
//! actually encodes and applies. The wire carries the CHANNEL — the subscribe and intent
//! envelopes, the flat cell codec, the intent argument payloads — and reaches here for what an
//! intent MEANS.
//!
//! - [`geometry`] — the plane's coordinates and the sanitation every coordinate passes through
//!   before it can reach a bounding-box union.
//! - [`session`] — what a pane IS, and the session → tab → pane values that hold them.
//! - [`split_tree`] — the n-ary tiled tree and every pure operation on it: split, dock, close,
//!   resize, swap, rebalance.
//! - [`split_layout`] — the flex partition that turns that tree into rectangles, the solved
//!   geometry the renderer and the focus resolver both read, and the seams a drag moves.
//! - [`focus`] — moving focus by what is on screen rather than by tree position.
//! - [`tab_ordering`] — the sidebar's one bucketing rule, and where focus lands after a close.
//! - [`tree_ops`] — every operation a gesture or an intent performs on the arrangement.
//! - [`workspace`] — the whole arrangement, its one checkable invariant, and the repairs that turn
//!   a hand-edited file back into a usable one.
//!
//! ## Why this is not a module of `slopdesk-workspace`
//!
//! Because `slopdesk-wire` needs it and needs nothing else. While the tree lived beside the rail
//! titles, the phone keyboard, the git status line, the notification policy and every Settings
//! row, the golden-pinned protocol had all of them underneath it — an inversion nobody chose and
//! nothing enforced. A protocol depending on the model it serialises is not an inversion;
//! depending on the client's Settings page is. This crate is the line between those two
//! statements, and the reason it can hold is that nothing in here renders, persists or names a
//! surface.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`.**
//! * **One dependency, pointing DOWN at a leaf that has none.** [`slopdesk_ids`] carries the ids
//!   these values are keyed by. An edge out of this crate to anything above it is the inversion
//!   coming back.
//! * **Total functions over hostile input.** These rules used to run only on a client's main actor
//!   with trusted local input; through the workspace channel they now run against a network peer.
//!   Nothing here indexes, unwraps or panics — the lint table denies all three.

pub mod focus;
pub mod geometry;
pub mod session;
pub mod split_layout;
pub mod split_tree;
pub mod tab_ordering;
pub mod tree_ops;
pub mod workspace;

pub use focus::{FocusDirection, cycle, neighbor};
pub use geometry::{Point, Rect, Size};
pub use session::{DetachedPane, NewTabPosition, PaneKind, PaneSpec, Session, Tab, VideoEndpoint};
pub use split_layout::{Divider, SolvedLayout, dividers, solve};
pub use split_tree::{PaneDropEdge, SplitAxis, SplitNode, SplitWeight, WeightedChild};
pub use tab_ordering::successor_after_close;
pub use tree_ops::TileLayout;
pub use workspace::{CURRENT_SCHEMA_VERSION, TreeWorkspace};
