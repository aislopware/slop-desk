//! `slopdesk-inspectord` — the read-only inspector, as a daemon.
//!
//! ## What this is
//! Claude Code writes an append-only JSONL transcript per session. The inspector FOLLOWS that file
//! (and the `subagents/agent-*.jsonl` files beside it), folds each line into a typed
//! [`InspectorEvent`], keeps a bounded replay window, and serves `replay-then-live` to any number
//! of subscribers over the inspector's own length-prefixed TCP wire on `terminalPort + 1`.
//!
//! ## Why it is a daemon and not a library hostd links
//! The same reason `slopdesk-dropd` is (`docs/53`): the client already dials this port DIRECTLY, so
//! nothing was ever relayed through hostd — the only thing hostd contributed was the process. A
//! transcript tail that keeps running across `make host-restart` is strictly better than one that
//! dies with it, and a per-turn JSON fold does not belong on the process that owns every keystroke.
//!
//! ## The one-implementation rule
//! Everything here was DELETED from Swift in the same change (`CLAUDE.md`): `TranscriptLine`,
//! `TranscriptParser`, `TranscriptTailer`, `LineAccumulator`, `SubagentWatcher`, `EventBuilder`,
//! `InspectorEngine`, `InspectorReplayLog`, `InspectorSource` and hostd's `InspectorServer`.
//! `Sources/SlopDeskInspector` is now the CLIENT end only — the event types, the decode side of the
//! codec, `InspectorClient`, `InspectorViewModel` — plus `HookIngest`, which never fed the
//! inspector and exists for agent DETECTION (`docs/50`).
//!
//! The wire did NOT change and must not: a shipped client is one end of it. [`wire`] is the mirror
//! of `Sources/SlopDeskInspector/InspectorWire.swift`, and [`event`]'s serde shapes are pinned to
//! what Swift's synthesized `Codable` produces — that pinning is what the round-trip tests assert.

pub mod accumulator;
pub mod builder;
pub mod engine;
pub mod event;
pub mod json;
pub mod line;
pub mod parser;
pub mod replay;
pub mod server;
pub mod subagents;
pub mod tailer;
pub mod tool_render;
pub mod wire;

pub use event::InspectorEvent;
pub use replay::ReplayLog;
