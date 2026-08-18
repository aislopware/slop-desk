//! # `slopdesk-workspace`
//!
//! The workspace document's DOMAIN rules, in safe Rust. Stage 12 of moving `SlopDesk` off Swift
//! (`docs/DECISIONS.md`), and the first one outside the video path.
//!
//! [`slopdesk-wire`](https://docs.rs/slopdesk-wire) already carries this document's CHANNEL: the
//! subscribe and intent envelopes, the flat cell codec, the intent argument payloads. What it
//! deliberately does not carry is what an intent MEANS. That is here.
//!
//! - [`geometry`] — the plane's coordinates and the sanitation every coordinate passes through
//!   before it can reach a bounding-box union.
//! - [`identity`] — the ids of the session → tab → pane hierarchy, the reason none of them can be
//!   minted here, and their canonical text form.
//! - [`json`] — the subset of JSON both persistence files are written in, and why that is not a
//!   crack in the manual-binary rule.
//! - [`rail_title`] — what a pane is CALLED, in the one precedence every surface that names one
//!   shares, and what its second line says once the surface has said the rest.
//! - [`rail_list`] — what happens to that pane once it is standing next to every other one:
//!   filtered, sectioned, ordered, and told apart from its namesakes.
//! - [`list_nav`] — where the highlight goes when an arrow, a page key, a Tab or a `⌘1–9` chord
//!   arrives over any of those lists.
//! - [`responsive`] — the one switch between the two projections, and the live-video ceiling that
//!   scales with the machine behind it.
//! - [`search_rank`] — the one ranking behind every search field, and why a title hit outranks a
//!   subtitle hit that scored higher.
//! - [`persist`] — the client's workspace file: the trees and their specs on disk, and the repairs
//!   that bring a hand-edited one back rather than trapping on it.
//! - [`split_tree`] — the n-ary tiled tree and every pure operation on it: split, dock, close,
//!   resize, swap, rebalance.
//! - [`split_layout`] — the flex partition that turns that tree into rectangles, the solved
//!   geometry the renderer and the focus resolver both read, and the seams a drag moves.
//! - [`focus`] — moving focus by what is on screen rather than by tree position.
//! - [`listen`] — the other end of that: what port the HOST may bind, and how to tell a bind
//!   collision apart from a network that has not come up yet.
//! - [`notify`] — when the app is allowed to speak: the banner's two gates, the badge a background
//!   pane keeps, the two cues, and the bound on what a remote shell can ask for.
//! - [`chrome`] — what the window shows AROUND the panes: the tabs panel that must not fight a
//!   manual collapse, the close prompt, and the Dock tile.
//! - [`send_keys`] — text with control tokens in it, turned into the bytes a PTY receives.
//! - [`phone_key`] — the other end of the same PTY: a live phone key press, split between the two
//!   input paths a touch device is forced to have, and encoded under the mode the far side set.
//! - [`shell_quoting`] — any text as one shell word, for everything that types a path into a shell.
//! - [`session`] — what a pane IS, and the session → tab → pane values that hold them.
//! - [`settings_catalog`] — what Settings OFFERS: the sections, the choices in every group, and the
//!   scalar ladders' stops and readouts.
//! - [`settings_rows`] — the other half of the same page: every setting as a ROW, with the one
//!   label and the one description it carries wherever it appears.
//! - [`tab_ordering`] — the sidebar's one bucketing rule, and where focus lands after a close.
//! - [`templates`] — the two things that spawn panes, and the bytes they type into them.
//! - [`tree_ops`] — every operation a gesture or an intent performs on the arrangement.
//! - [`workdir`] — where a freshly-opened pane starts, and why naming no directory is an answer.
//! - [`workspace`] — the whole arrangement, its one checkable invariant, and the repairs that turn
//!   a hand-edited file back into a usable one.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`.**
//! * **Two dependencies, each a notation rather than a decision.** `regex` because a credential
//!   shape belongs written as one, and `slopdesk-fuzzy` because a ranking that scored with a second
//!   matcher would order the same list two ways. Everything else here is arithmetic and ordering,
//!   where reaching for a crate would be a sign a decision had leaked in.
//! * **Total functions over hostile input.** These rules used to run only on a client's main actor
//!   with trusted local input; through the workspace channel they now run against a network peer.
//!   Nothing here indexes, unwraps or panics — the lint table denies all three.

pub mod cheat_sheet;
pub mod chrome;
pub mod drop_action;
pub mod drop_zone;
pub mod focus;
pub mod frecency;
pub mod geometry;
pub mod identity;
pub mod json;
pub mod jump;
pub mod list_nav;
pub mod listen;
pub mod notify;
pub mod persist;
pub mod phone_key;
pub mod rail_list;
pub mod rail_title;
pub mod responsive;
pub mod search_rank;
pub mod secrets;
pub mod send_keys;
pub mod session;
pub mod settings_catalog;
pub mod settings_layout;
pub mod settings_rows;
pub mod shell_quoting;
pub mod split_layout;
pub mod split_tree;
pub mod state_codec;
pub mod tab_ordering;
pub mod templates;
pub mod tree_ops;
pub mod window_size;
pub mod workdir;
pub mod workspace;

pub use focus::{FocusDirection, cycle, neighbor};
pub use frecency::{FolderEntry, ReferenceSeconds};
pub use geometry::{Point, Rect, Size};
pub use identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId, parse_uuid, uuid_text};
pub use json::{Json, JsonError};
pub use jump::JumpResolution;
pub use persist::{decode_spec, decode_split_node, encode_spec, encode_split_node};
pub use session::{DetachedPane, NewTabPosition, PaneKind, PaneSpec, Session, Tab, VideoEndpoint};
pub use split_layout::{Divider, SolvedLayout, dividers, solve};
pub use split_tree::{PaneDropEdge, SplitAxis, SplitNode, SplitWeight, WeightedChild};
pub use tab_ordering::{bucketed_by_project, successor_after_close};
pub use templates::{LaunchPreset, SessionTemplate, TemplateNode, TemplatePane};
pub use tree_ops::TileLayout;
pub use workspace::{CURRENT_SCHEMA_VERSION, TreeWorkspace};
