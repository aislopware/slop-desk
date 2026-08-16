//! The workspace DOCUMENT — the state every client mirrors, and the intents that change it.
//!
//! Three layers, deliberately separate:
//!
//! - [`state`] — the document itself: an addressable cell, an entry, a diff, and the flat map they
//!   live in, with the diff/apply algebra that makes a duplicated or reordered frame a no-op.
//! - [`codec`] — the bytes: snapshots, diffs, the tab layout structure, and every single-cell value
//!   codec.
//! - [`intent`] — the verb-3 argument payloads, one shape per topology change a client may ask for.
//! - [`fields`] — the field vocabulary each object kind is addressed by, frozen the moment a golden
//!   vector carries one.
//! - [`liveness`] — one pane's running-process facts as a retained VALUE, so a client that missed
//!   the edge can still ask what is true.
//! - [`topology`] — the other half of a pane's facts: what the person ARRANGED, projected into
//!   cells and read back out of them, with the predicate that says which half a key belongs to.
//! - [`apply`] — the rule that turns one intent into the next topology, or into a refusal. Shared
//!   by the host and by every client's optimistic overlay, so the two cannot disagree.
//! - [`state_file`] — which half of the document survives a restart, and its on-disk shape.
//!
//! ## Where this sits
//! [`crate::message`] frames the type-17 / type-37 ENVELOPE and treats its payload as opaque.
//! [`crate::workspace`] decodes the channel's own request and event bodies — subscribe, presence,
//! the intent header — and likewise treats the argument bytes as opaque. This module is the last
//! layer in: what those opaque payloads actually say.
//!
//! The split is not decoration. `SlopDeskProtocol` could never parse workspace state because the
//! model types lived in a different Swift target, which is why the envelope and the document were
//! two files that never imported each other. Here they are two modules of one crate that still do
//! not import each other, so the layering survived the port instead of dissolving into it.

pub mod apply;
pub mod codec;
pub mod fields;
pub mod intent;
pub mod liveness;
pub mod state;
pub mod state_file;
pub mod topology;

pub use apply::{IntentOutcome, apply, no_project_keys};
pub use codec::{
    MAX_ENTRY_COUNT, MAX_LAYOUT_DEPTH, MAX_STRING_BYTES, SplitAxis, SplitWeight, VideoEndpoint,
    WorkspaceLayoutNode, decode_bool, decode_detached_panes, decode_diff, decode_i32, decode_i64,
    decode_layout, decode_snapshot, decode_string, decode_u8, decode_u8_pair, decode_u16_pair, decode_u32,
    decode_uuid, decode_uuid_list, decode_video_target, decode_weight, decode_weights, encode_bool,
    encode_detached_panes, encode_diff, encode_i32, encode_i64, encode_key, encode_layout, encode_snapshot,
    encode_string, encode_u8, encode_u8_pair, encode_u16_pair, encode_u32, encode_uuid, encode_uuid_list,
    encode_video_target, encode_weight, encode_weights,
};
pub use fields::{PaneLivenessState, title_is_fresh};
pub use intent::{
    DockArgs, MAX_BLOB_BYTES, MAX_NAME_BYTES, MAX_TAB_COUNT, MoveArgs, NewSessionArgs, NewTabPosition,
    PaneDropEdge, PaneKind, SpawnDetachedArgs, SpawnTabArgs, SplitArgs, WorkspaceIntentOp,
    decode_divider_weight, decode_dock_at_tab_edge, decode_flag, decode_identity, decode_move, decode_name,
    decode_new_session, decode_reopen_closed_tab, decode_reorder_tabs, decode_set_pane_video_target,
    decode_set_tab_layout, decode_spawn_detached_pane, decode_spawn_tab, decode_split, decode_swap_panes,
    encode_divider_weight, encode_dock_at_tab_edge, encode_flag, encode_identity, encode_move, encode_name,
    encode_new_session, encode_reopen_closed_tab, encode_reorder_tabs, encode_set_pane_video_target,
    encode_set_tab_layout, encode_spawn_detached_pane, encode_spawn_tab, encode_split, encode_swap_panes,
};
pub use liveness::{
    AgentState, Grid, LIVENESS_FIELDS, PaneLiveness, Progress, TOPOLOGY_FIELDS, mark_pane_dead,
    merge_pane_liveness,
};
pub use state::{
    HostWorkspaceState, ROOT_OBJECT_ID, WorkspaceEntry, WorkspaceKey, WorkspaceObjectKind, WorkspaceStateDiff,
};
pub use state_file::{FileError, is_persisted, persisting};
pub use topology::{
    CLOSED_TAB_RING_CAP, ClosedTab, FOCUS_MRU_CAP, RESERVED_ROOT_FIELDS, WorkspaceTopology, is_topology,
    layout_of, write_topology,
};
