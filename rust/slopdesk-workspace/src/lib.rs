//! # `slopdesk-workspace`
//!
//! The workspace document's DOMAIN rules, in safe Rust. Stage 12 of moving `SlopDesk` off Swift
//! (`docs/DECISIONS.md`), and the first one outside the video path.
//!
//! [`slopdesk-wire`](https://docs.rs/slopdesk-wire) already carries this document's CHANNEL: the
//! subscribe and intent envelopes, the flat cell codec, the intent argument payloads. What it
//! deliberately does not carry is what an intent MEANS. That is here.
//!
//! - [`geometry`] — the plane's coordinates, the pan-only camera, and the sanitation every
//!   coordinate passes through before it can reach a bounding-box union.
//! - [`canvas`] — the plane itself: the document a tab lays its panes on, and every pure operation
//!   over it — add, close, raise, align, distribute, tidy, group.
//! - [`canvas_geometry`] — where a pane goes: the eight-anchor resize whose pinned edge never
//!   creeps, new-pane placement that is bounded rather than merely usually-terminating, the culling
//!   asymmetry between a terminal and a video pane, and the two overlays for panes off-screen.
//! - [`canvas_snap`] — where a pane WANTS to go: the magnetic solver, its asymmetric hold, and the
//!   order-independent selection that keeps a drag from depending on the order its neighbours
//!   arrived in.
//! - [`canvas_non_overlap`] — where a pane is ALLOWED to go: the swept slide that runs after the
//!   snapper, and the make-space relaxation that parts the neighbours on an insert.
//! - [`identity`] — the ids of the session → tab → pane hierarchy, the reason none of them can be
//!   minted here, and their canonical text form.
//! - [`json`] — the subset of JSON both persistence files are written in, and why that is not a
//!   crack in the manual-binary rule.
//! - [`persist`] — the client's workspace file: the plane, the trees and the presets on disk, and
//!   the repairs that bring a hand-edited one back rather than trapping on it.
//! - [`split_tree`] — the n-ary tiled tree and every pure operation on it: split, dock, close,
//!   resize, swap, rebalance.
//! - [`split_layout`] — the flex partition that turns that tree into rectangles, and the solved
//!   geometry the renderer and the focus resolver both read.
//! - [`focus`] — moving focus by what is on screen rather than by tree position.
//! - [`listen`] — the other end of that: what port the HOST may bind, and how to tell a bind
//!   collision apart from a network that has not come up yet.
//! - [`send_keys`] — text with control tokens in it, turned into the bytes a PTY receives.
//! - [`shell_quoting`] — any text as one shell word, for everything that types a path into a shell.
//! - [`session`] — what a pane IS, and the session → tab → pane values that hold them.
//! - [`tab_ordering`] — the sidebar's one bucketing rule, and where focus lands after a close.
//! - [`templates`] — the two things that spawn panes, and the bytes they type into them.
//! - [`tree_ops`] — every operation a gesture or an intent performs on the arrangement.
//! - [`workspace`] — the whole arrangement, its one checkable invariant, and the repairs that turn
//!   a hand-edited file back into a usable one.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`.**
//! * **Zero dependencies.** The domain is arithmetic and ordering; anything it needed from a crate
//!   would be a sign a decision had leaked into it.
//! * **Total functions over hostile input.** These rules used to run only on a client's main actor
//!   with trusted local input; through the workspace channel they now run against a network peer.
//!   Nothing here indexes, unwraps or panics — the lint table denies all three.

pub mod canvas;
pub mod canvas_arrange;
pub mod canvas_geometry;
pub mod canvas_non_overlap;
pub mod canvas_snap;
pub mod focus;
pub mod frecency;
pub mod geometry;
pub mod identity;
pub mod json;
pub mod jump;
pub mod listen;
pub mod persist;
pub mod secrets;
pub mod send_keys;
pub mod session;
pub mod shell_quoting;
pub mod split_layout;
pub mod split_tree;
pub mod state_codec;
pub mod tab_ordering;
pub mod templates;
pub mod tree_ops;
pub mod workspace;

pub use canvas::{AlignEdge, Canvas, CanvasItem, LayoutPreset, PaneGroup};
pub use canvas_geometry::{OffscreenBeacon, OverviewLayout, PlacedPane, ResizeAnchor, placement, resizing};
pub use canvas_non_overlap::{Body, BodyId, NonOverlapConfig, make_space, separate, slide};
pub use canvas_snap::{Guide, GuideKind, SnapConfig, Stick, snap_move, snap_resize};
pub use focus::{FocusDirection, cycle, neighbor};
pub use frecency::{FolderEntry, ReferenceSeconds};
pub use geometry::{Camera, Point, Rect, Size, sanitize, sanitize_preserving_size};
pub use identity::{
    IdSource, LayoutPresetId, PaneGroupId, PaneId, SessionId, SplitNodeId, TabId, parse_uuid, uuid_text,
};
pub use json::{Json, JsonError};
pub use jump::JumpResolution;
pub use persist::{
    decode_canvas, decode_preset, decode_spec, decode_split_node, encode_canvas, encode_preset, encode_spec,
    encode_split_node,
};
pub use session::{DetachedPane, NewTabPosition, PaneKind, PaneSpec, Session, Tab, VideoEndpoint};
pub use split_layout::{SolvedLayout, solve};
pub use split_tree::{PaneDropEdge, SplitAxis, SplitNode, SplitWeight, WeightedChild};
pub use tab_ordering::{bucketed_by_project, successor_after_close};
pub use templates::{LaunchPreset, SessionTemplate, TemplateNode, TemplatePane};
pub use tree_ops::TileLayout;
pub use workspace::{CURRENT_SCHEMA_VERSION, TreeWorkspace};
