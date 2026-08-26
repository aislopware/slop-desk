//! hostd's end of the `slopdesk-superd` control socket: framing, verbs, and the thread that reads
//! them.
//!
//! `docs/60-hostd-in-rust.md` stage C's prerequisite. superd is the only process in the system that
//! forks a pane and the only one that reads a PTY master, so every pane verb hostd has goes through
//! this socket. That end of it was `Sources/SlopDeskSupervisor` — 2,657 lines of Swift — and the
//! plan did not budget it, because the line counts were taken over `Sources/SlopDeskHost` alone.
//! Nothing above this can be written until it exists.
//!
//! ## The shape
//!
//! ```text
//!   verbs ──▶ writer thread ──▶ [tag│len│body] ──▶ superd
//!                                                    │
//!   waiters ◀── reader thread ◀── [tag│len│body] ◀───┘
//!   sinks   ◀──────┘  (pane output, on the reader's own thread, borrowed)
//!   observer ◀─────┘  (exited · connection · disconnected)
//! ```
//!
//! - [`frame`] — the tag byte a descriptor rides on, the length, the body. hostd's lane only: it
//!   receives descriptors and sends none.
//! - [`connection`] — one connected socket: the write lock, and a hang-up that wakes the reader.
//! - [`client`] — the verbs, the reply-waiter table, the two threads, and the sinks.
//!
//! ## What this crate does not decide
//!
//! What a request LOOKS like and what a reply MEANS are `slopdesk_superwire`'s, shared with superd
//! by construction — that crate's own header records what it cost to have them spelled twice. And
//! nothing here is about a PANE: this crate hands over the bytes superd read and the descriptor
//! superd sent, and what either means to a shell belongs to the stage above.
//!
//! ## Absent superd is fatal to panes, and says so
//!
//! There is no fallback and no local `openpty`. A failed [`client::SupervisorClient::connect`]
//! means no pane can open, and the caller has to say so in as many words rather than degrade
//! quietly. That is the deliberate cost of having exactly one implementation of the spawn path.

pub mod client;
pub mod connection;
pub mod frame;
