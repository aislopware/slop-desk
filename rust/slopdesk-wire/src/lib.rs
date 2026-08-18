//! The PATH-1 terminal wire codec: framing, the message table, encode and decode.
//!
//! ```text
//! [u32 BE payload_length][u8 message_type][body…]
//!  \__ excludes these 4 __/\____ payload_length counts these ____/
//! ```
//!
//! Two connections carry a session — DATA for the PTY byte stream, CONTROL for everything else — so
//! a burst of output cannot delay a resize. Both use identical framing, and this crate is
//! transport-agnostic: nothing here opens a socket, reads a clock, or allocates a thread.
//!
//! The [`mux`] module is the layer ABOVE this framing: the envelope that carries many logical
//! channels over one connection, plus its decoder, channel table and credit flow control. A
//! [`MuxFrame::ChannelData`] body is one of the frames described here, carried opaquely.
//!
//! ## What is guaranteed
//! - **No `unsafe`.** `#![forbid(unsafe_code)]`, so not even a downstream `allow` can reintroduce
//!   it.
//! - **No panics on hostile input.** Every length is validated before it is read, indexing goes
//!   through `get`, and integer conversions are total. A corrupt frame is a [`WireError`], never an
//!   abort.
//! - **No dependencies.** A codec that parses bytes from the network is the last place to widen a
//!   supply chain. `serde_json` appears only under `[dev-dependencies]`, to read the golden corpus
//!   the parity test diffs against.
//!
//! ## Parity
//! `tests/golden_vectors.rs` re-encodes every terminal vector pinned in
//! `golden/golden_vectors.json` and compares the hex byte-for-byte. That file predates this crate
//! and is generated from the Swift codec, so it answers "did the port change the wire" with
//! evidence that was not written alongside the port.

#![forbid(unsafe_code)]

pub mod bytes;
pub mod codec;
pub mod document;
pub mod error;
pub mod frame;
pub(crate) mod framing;
pub mod message;
pub mod metadata;
pub mod mux;
pub mod osc;
pub mod replay;
pub mod workspace;

pub use bytes::{ByteReader, ByteWriter};
pub use document::{
    HostWorkspaceState, IntentOutcome, SplitAxis, SplitWeight, VideoEndpoint, WorkspaceEntry,
    WorkspaceIntentOp, WorkspaceKey, WorkspaceLayoutNode, WorkspaceObjectKind, WorkspaceStateDiff,
    WorkspaceTopology,
};
pub use error::{Result, WireError};
pub use frame::FrameDecoder;
pub use message::{
    Channel, CommandStatus, NEW_SESSION_ID, ProjectGitStatus, RawUuid, SESSION_ID_BYTE_COUNT, WireMessage,
};
pub use metadata::{MetadataStatus, MetadataVerb};
pub use mux::{
    BoundedQueuePolicy, ChannelState, ChannelTable, ConsumeResult, FlowCreditPolicy, MuxChannelClass,
    MuxCloseReason, MuxFlowControl, MuxFrame, MuxFrameDecoder, MuxFrameType, ReceiveWindowAccountant,
};
pub use osc::{ProgressState, ProgressUpdate, WATCH_NOTIFICATION_MARKER, is_watch_notification};
pub use replay::{DrainState, ReplayBuffer, RingFoldSource, ScrollbackDistiller, SnapshotSource};
pub use workspace::{
    ROSTER_ATTACHMENT_BYTES, ROSTER_CLIENT_MIN_BYTES, ROSTER_PANE_MIN_BYTES, WorkspaceClientKind,
    WorkspaceEventKind, WorkspaceIntent, WorkspaceIntentResult, WorkspaceIntentStatus,
    WorkspacePresenceRoster, WorkspacePresenceUpdate, WorkspaceRequestVerb, WorkspaceRosterAttachment,
    WorkspaceRosterClient, WorkspaceRosterPane, WorkspaceSubscribe,
};

/// The wire version this crate speaks.
///
/// The host accepts only this value and there is no negotiation — host and client are deployed
/// together — so a version bump is a coordinated break, while a new message TYPE is additive and
/// costs nothing.
pub const PROTOCOL_VERSION: u16 = 1;

/// Largest payload a single frame may declare, in bytes.
///
/// A prefix above this is rejected BEFORE the body is waited for, so a peer cannot make a receiver
/// hold a buffer open for an arbitrarily large frame that will never arrive. 16 MiB is far above
/// any legitimate message: the biggest real one is a `.output` chunk, three orders of magnitude
/// smaller.
pub const MAX_FRAME_PAYLOAD_LENGTH: usize = 16 * 1024 * 1024;
