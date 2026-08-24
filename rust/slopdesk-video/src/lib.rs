//! # `slopdesk-video`
//!
//! The PATH-2 video protocol's pure logic, in safe Rust. Stage 5 of moving `slopdesk-hostd` and the
//! video host off Swift (`docs/DECISIONS.md`); it opens at the bottom of the stack, with the
//! forward-error-correction math every frame on the wire passes through.
//!
//! - [`gf256`] — arithmetic over GF(2^8): the field the erasure code lives in.
//! - [`rs_matrix`] — the Cauchy parity block and a Gauss-Jordan inverse over that field.
//! - [`fec`] — the systematic Reed-Solomon erasure codec the packetizer and the reassembler drive.
//! - [`error`] / [`bytes`] — the video path's own failure vocabulary and big-endian primitives.
//! - [`geometry`] / [`coordinate_mapping`] — the aspect-fit transform and the pointer mapping that
//!   must invert each other exactly.
//! - [`nal_unit`] — AVCC length-prefixed NAL-unit split and join. LINKED, through `slopdesk-ffi`'s
//!   `cursor_wire`: the split answers WHERE each unit sits, because an IDR's units are most of a
//!   frame and the caller passed that frame in.
//! - [`ycbcr`] — the BT.709 coefficients the client's Metal shader is pinned to.
//! - [`window_geometry`] / [`cursor`] / [`swipe_nav`] — the host→client metadata channels. All
//!   three are LINKED — the first two through `slopdesk-ffi`'s `metadata_wire`, `cursor` through
//!   its `cursor_wire`: a non-finite coordinate reaching a `CALayer` is a dead client, the swipe
//!   status must never promise a navigation the host would refuse, and the cursor's PNG crosses as
//!   an offset rather than a copy.
//! - [`cursor_sampling`] — what fills the cursor channel on the host: when to re-read the shape,
//!   where the pointer is in the captured window, which id a shape gets and what size to render it
//!   at. LINKED, through `slopdesk-ffi`'s `cursor_sampler`, which drives it alongside the two reads
//!   it cannot make itself — `slopdesk-apple-cursor` for the shape and `slopdesk-posix`'s `dynsym`
//!   for the window server's change counter.
//! - [`swipe_recognizer`] — what fills that channel: reading a two-finger page-swipe out of the
//!   forwarded scroll stream, which no browser can recognise from injected events itself.
//! - [`input_event`] — the client→host input events, in normalised window space. LINKED, through
//!   `slopdesk-ffi`'s `input_event`: the shortest path from a hostile datagram to a window-server
//!   call, so its finite check is a decode guard and there is one of it.
//! - [`audio_wire`] — the host→client app-audio datagram. LINKED, through the same shim: the
//!   datagram declares its own payload length, so the cap and the bounds check exist once.
//! - [`video_control`] — session bring-up, discovery, the window feed and the live knobs. LINKED,
//!   through `slopdesk-ffi`'s `video_control`: 28 arms, five of them carrying lists of strings, is
//!   the largest surface on which two hand-written codecs could drift, and it is the one where a
//!   drift shows up as a window feed that is silently short a row.
//! - [`fragment`] / [`mux_header`] — the 19-byte per-datagram header, and its muxed sibling. Both
//!   are LINKED, through `slopdesk-ffi`'s `video_fragment` and `mux_header`: one wire layout each,
//!   reached by both paths and by the golden generator.
//! - [`adaptive_fec`] — the tier ladder: how measured loss becomes a per-frame FEC shape. LINKED,
//!   through `slopdesk-ffi`'s `adaptive_fec`: a threshold that drifted would de-sync a host from a
//!   client mid-session rather than fail a test.
//! - [`interleaver`] / [`packetizer`] — the host send path, from an encoded frame to datagrams.
//!   LINKED: `slopdesk-ffi`'s `video_packetize` is the handle Swift drives them through.
//! - [`reassembler`] — the client receive path, and where hostile UDP meets per-frame allocation.
//!   LINKED, through `slopdesk-ffi`'s `video_reassemble`: the guards run here, not twice.
//! - [`recovery`] — the client→host loss-recovery channel and the escalation policy. LINKED,
//!   through `slopdesk-ffi`'s `recovery`: the second place hostile input is parsed, and the
//!   trailing-bytes rejection the host's byte-keyed dedup depends on.
//! - [`frame_hash`] — the per-frame and per-row luma hash the capture measurements are built on.
//! - [`scroll_shift`] / [`adaptive_qp`] — what those row hashes are for: how far the picture moved,
//!   and how much of it changed.
//! - [`scroll_resample`] / [`scroll_reproject`] — the two halves of making a remote scroll look
//!   local: metering injection up to the rate the source app renders at, and warping the last frame
//!   on the ticks between real ones.
//! - [`blob_list`] — the one shape the FEC boundary carries to Swift, in both directions: a
//!   length-prefixed run of blobs, flattened by value (`docs/55` §4d says why not descriptors).
//! - [`blob`] / [`window_feed`] — the chunked side channels: icons, previews and the host-windows
//!   feed, reassembled under a cap.
//! - [`playout`] / [`keepalive`] — the client's jitter buffer, and the liveness contract that tells
//!   a healthily idle window from a dead host.
//! - [`idle_reap`] / [`recovery_dedupe`] / [`frame_gate`] / [`recovery_idr`] / [`ltr`] /
//!   [`qp_control`] — the host's decisions, each one a pure rule sitting beside the actor that acts
//!   on it: when a silent flow is dead, which redundant request to act on once, which frame may be
//!   skipped, whether a recovery request has earned a keyframe, whether a cheap re-anchor is legal,
//!   and how the constant quantiser answers the link.
//! - [`live_bitrate`] / [`retransmit_ring`] / [`capture_recovery`] — the rest of the host's send
//!   side: sizing the budget to the pixels actually encoded, answering a negative acknowledgement
//!   from a bounded send history, and the ladders for a capture or a virtual display lost out from
//!   under a live session.
//! - [`network_estimate`] / [`congestion`] — the control loop over the link itself: the clock-skew-
//!   free fold of the client's report, and the additive-increase, multiplicative-decrease law whose
//!   every stability rule was bought with a measurement.
//! - [`swipe_nav_config`] / [`mint_rescue`] — the host's one parse of the swipe operating point, so
//!   the client's feedback cannot lie about it; and rescuing an off-screen window pick at mint
//!   time, where the settle gate stops a mid-animation frame from cropping the stream for good.
//! - [`client_view`] — the pane's geometry decisions, written together because the renderer, the
//!   input inverse and the resize loop all have to agree on the same displayed size.
//! - [`client_session`] — the client's own lifecycle: the hello it retries, the farewell that
//!   rebuilds where a local stop must not, and the scrim that stays up through the recovery.
//! - [`client_input`] — what the client sends when the user touches the pane: the exact inverse of
//!   the render transform, plus the modifier latch and the cursor-shape re-request that each exist
//!   because a single lost edge would otherwise stay wrong for the rest of the session.
//! - [`present_queue`] — which decoded frame this refresh shows: the slack the pacer holds, the
//!   homeostasis that stops the latency ratcheting, and the schedule the deadline mode presents on.
//! - [`client_jitter`] — how much slack the client holds before presenting: the clock-skew-immune
//!   arrival measure, and the deliberately asymmetric controller that grows on the first sign of
//!   trouble and gives depth back one frame at a time.
//! - [`cursor_overlay`] — where the client draws the host's cursor and which way up, through the
//!   same forward transform the input path inverts, so the pointer and the click cannot drift.
//! - [`client_gestures`] / [`swipe_peel`] — the client's pointer and gesture rules, and the mirror
//!   of the host's recogniser that exists so something reacts while the fingers are still down.
//! - [`decode_admission`] / [`hevc_parameter_sets`] — what reaches the client's decoder and in what
//!   order, each rule closing a measured failure class; and the parameter sets it must be
//!   configured from before the first slice.
//! - [`audio_source`] — the capture side's three pure rules: the fold to the stereo wire layout,
//!   the 480-frame chunking, and the `s16le` pack. The mirror of `audio_wire`'s decode half.
//! - [`audio_jitter`] — every buffering decision on the audio path: prime, conceal, reorder and
//!   skip forward, because stale audio is worse than a click and latency is never the answer.
//! - [`trendline`] — congestion read from the queue's SLOPE rather than its level, which is visible
//!   a quarter of a second before the smoothed-RTT path can see anything at all.
//! - [`pacer_depth`] — what one frame of standing latency is paid FOR: the one-way-delay spike a
//!   slack frame absorbs, and never the arrival gap that only means the host went quiet.
//! - [`send_pacing`] — the paced-send lane's schedule, on absolute deadlines rather than relative
//!   sleeps, so a fat keyframe cannot amplify one lost packet into an eleven-frame send hole.
//! - [`mux_client_pool`] — the client half of one flow per host: who shares it, when it closes, and
//!   why the lane allocator is seeded rather than started at one.
//! - [`mux_flow`] — the flow ledger under the shared socket: which flow answers a lane, which one
//!   the reaper may close, and what a client wedged against a restarted daemon is told.
//! - [`mux_routing`] — which session a muxed datagram belongs to, and the reconnect-generation rule
//!   that keeps a dead lane's bytes out of the session that replaced it.
//! - [`window_feed_host`] — the host end of the window feed, from what the enumeration is allowed
//!   to list through to who gets pushed to and how often.
//! - [`recovery_routing`] — the host's side of the DEDICATED recovery channel, the still-screen
//!   re-encode timer, and the scheduler that puts each finished message on its own channel.
//! - [`key_capture`] — what the immersive tap does with one key, and the two chords that must stay
//!   reachable no matter what the rest of it says.
//! - [`key_naming`] — what one key event is CALLED, so the chord the dispatcher builds and the
//!   chord the recorder persists are the same chord.
//! - [`window_restore`] — which window a crashed daemon left stranded, and may therefore be moved
//!   back on the next launch; every uncertainty resolves to leaving it where it is.
//! - [`input_routing`] — what happens to an input datagram between the socket and the injector: the
//!   raise rule, the motion coalescer, the button and modifier ledger, and the metered scroll
//!   accumulator — every one of them there because injection itself is synchronous and expensive.
//! - [`session_state`] — the session lifecycle: validating the hello, minting the stream, and
//!   gating whether media may flow — plus the resize and live-override negotiations riding on it.
//! - [`fps_governor`] — frame rate as a second control axis, on two independent bottlenecks: the
//!   link, and the hardware encoder — actuated through one schedule-anchored cadence gate so a
//!   governed rate is a metronome rather than an alternating skip.
//! - [`ax_probe`] — what the host does with what the accessibility tree answers: which candidate
//!   element is the window it meant, which pids are worth re-sweeping this tick, and what a
//!   window's absence from a sweep proves. LINKED, through `slopdesk-ffi`'s `ax`, which drives it
//!   alongside `slopdesk-apple-ax`. Every arm here was previously unreachable by any test: the
//!   Swift it came from needed an Accessibility grant to run a line of it.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`** — and here that is the reason the port
//!   exists, not a side benefit. The Swift original reaches a C SIMD kernel through
//!   `UnsafeBufferPointer`, `withUnsafeTemporaryAllocation` and a `force_unwrapping` exemption, on
//!   a path fed by hostile UDP datagrams. This crate cannot express any of that.
//! * **No dependencies.** `serde_json` is a dev-dependency of the golden test and nothing else.
//! * **Never panics on untrusted input.** A corrupt datagram leaves the hole it arrived with; the
//!   only `assert!`s are on construction-time configuration, which is code, not input.
//!
//! ## Parity is proven, not asserted
//!
//! `golden/golden_vectors.json` was generated from the Swift implementation and predates this
//! crate. `tests/golden_vectors.rs` re-encodes its `fecParity` group and re-runs its `fecRecover`
//! group, comparing bytes. "Did moving this change the wire" is answered by a file nobody wrote for
//! the answer.

#![forbid(unsafe_code)]

pub mod adaptive_fec;
pub mod adaptive_qp;
pub mod annexb;
pub mod audio_jitter;
pub mod audio_source;
pub mod audio_wire;
pub mod ax_probe;
pub mod blob;
pub mod blob_list;
pub mod bytes;
pub mod capture_config;
pub mod capture_recovery;
pub mod capture_region;
pub mod client_gestures;
pub mod client_input;
pub mod client_jitter;
pub mod client_session;
pub mod client_view;
pub mod congestion;
pub mod coordinate_mapping;
pub mod cursor;
pub mod cursor_overlay;
pub mod cursor_sampling;
pub mod decode_admission;
pub mod decoder_state;
pub mod encoder_ceiling;
pub mod encoder_config;
pub mod encoder_state;
pub mod error;
pub mod fec;
pub mod fps_governor;
pub mod fragment;
pub mod frame_gate;
pub mod frame_hash;
pub mod geometry;
pub mod gf256;
pub mod hevc_parameter_sets;
pub mod idle_reap;
pub mod input_event;
pub mod input_routing;
pub mod interleaver;
pub mod keepalive;
pub mod key_capture;
pub mod key_naming;
pub mod live_bitrate;
pub mod loopback;
pub mod ltr;
pub mod mint_rescue;
pub mod mux_client_pool;
pub mod mux_flow;
pub mod mux_header;
pub mod mux_routing;
pub mod nal_unit;
pub mod nav_history;
pub mod network_estimate;
pub mod pacer_depth;
pub mod packetizer;
pub mod playout;
pub mod present_queue;
pub mod qp_control;
pub mod reassembler;
pub mod recovery;
pub mod recovery_dedupe;
pub mod recovery_idr;
pub mod recovery_routing;
pub mod retransmit_ring;
pub mod rs_matrix;
pub mod scroll_reproject;
pub mod scroll_resample;
pub mod scroll_shift;
pub mod send_pacing;
pub mod session_state;
pub mod stream_stall;
pub mod swipe_nav;
pub mod swipe_nav_config;
pub mod swipe_peel;
pub mod swipe_recognizer;
pub mod trendline;
pub mod video_control;
pub mod window_feed;
pub mod window_feed_host;
pub mod window_geometry;
pub mod window_list;
pub mod window_placement;
pub mod window_restore;
pub mod ycbcr;

pub use adaptive_fec::TierState;
pub use adaptive_qp::{QpCurve, QpDecision};
pub use audio_jitter::{AudioJitterBuffer, AudioJitterStats};
pub use audio_source::BlockAccumulator;
pub use audio_wire::{AudioChannelMessage, AudioStreamConfig, AudioWireFormat};
pub use blob::{BlobAssembler, BlobChunk, CompleteBlob, OneShotBlobFetch};
pub use bytes::{ByteReader, ByteWriter};
pub use capture_recovery::{CaptureFailureAction, VirtualDisplayRecreateGate};
pub use client_gestures::{PinchZoomKeyPlanner, ScrollRoutePinner};
pub use client_input::{CursorShapeRequestTracker, ModifierLatchTracker, PointerMapping};
pub use client_jitter::{AdaptiveJitterController, OwdJitterEstimator};
pub use client_session::{
    ClientEffect, RoutedDatagram, StallScrimLatch, VideoClientState, VideoClientStateMachine,
    VideoStreamTarget,
};
pub use client_view::{FrameDecodability, ResizeDebounce, ResizeDecision};
pub use congestion::{
    CongestionConfig, CongestionDecision, CutReason, LiveCongestionController, is_material_change,
};
pub use cursor::{CursorChannelMessage, CursorShapeMessage, CursorUpdate};
pub use cursor_overlay::{layer_frame_fit, layer_frame_scalar};
pub use decode_admission::{
    DecodeAdmissionBudget, DecodeFrontier, DecodeGate, DecodeSequencer, DecodeSequencerSnapshot, GateMode,
    GateVerdict, SequencerStep,
};
pub use error::{Result, VideoProtocolError};
pub use fec::ReedSolomonFec;
pub use fps_governor::{
    EncodeCadenceGate, EncodeLoadPacer, EncodeLoadPacerConfig, FpsGovernor, FpsGovernorConfig,
};
pub use fragment::{Flags, FrameFragment, FrameFragmentHeader};
pub use frame_gate::{FrameObligations, StillnessCrispDecider};
pub use frame_hash::{LumaPlane, StreamHasher};
pub use geometry::{VideoContentMode, VideoPoint, VideoRect, VideoSize};
pub use hevc_parameter_sets::{ParameterSets, extract as extract_parameter_sets};
pub use idle_reap::{FlowRecord, IdleReapDecider};
pub use input_event::{InputEvent, InputModifiers, MouseButton};
pub use input_routing::{
    CoalescedSlot, InjectionPlan, InputButtonBalance, PlannedSlot, ScrollAccumulator, ScrollCoalescePlanner,
    coalesce_motion, coalesce_plan,
};
pub use keepalive::{StallInputs, StallVerdict, StreamStallPolicy};
pub use ltr::{LtrController, RecoveryAction, RecoveryRequestKind};
pub use mint_rescue::{DeminiaturizeOutcome, Observation, Rescue, Step};
pub use mux_client_pool::{AcquireOutcome, FlowEndpoint, ReleaseOutcome, VideoFlowPool};
pub use mux_flow::{
    ConnectionStateKind, FlowId, MuxFlowTable, UnboundByeRateLimiter, send_path_viability, warrants_bye,
};
pub use mux_header::MuxFrameFragmentHeader;
pub use mux_routing::{
    BootstrapAction, DispatchDecision, MuxDecision, VideoMuxRouter, bootstrap_action, dispatch_decision,
};
pub use network_estimate::NetworkEstimate;
pub use pacer_depth::{
    GapClass, OwdLateConfig, OwdLateDetector, OwdLateSnapshot, PacerDepthConfig, PacerDepthEnv,
    PacerDepthPolicy, PacerDepthSnapshot, PacerTelemetrySnapshot,
};
pub use packetizer::{PacketizeOptions, VideoPacketizer};
pub use playout::PlayoutConfig;
pub use present_queue::{
    DroppedHandles, PresentOutcome, PresentQueue, PresentQueueSnapshot, PresentStep, QueuedFrame, Submission,
};
pub use qp_control::{QpConfig, QpController};
pub use reassembler::{FrameReassembler, ReassembledFrame, ReassemblyResult};
pub use recovery::{NetworkStatsReport, RecoveryMessage, RecoveryPolicy};
pub use recovery_dedupe::RecoveryRequestDeduper;
pub use recovery_idr::{IdrVerdict, RecoveryIdrConfig, RecoveryIdrPolicy};
pub use recovery_routing::{Outgoing, RecoveryDecision, StaticIdrDecider, VideoChannel, route_recovery};
pub use retransmit_ring::RetransmitRing;
pub use scroll_reproject::{ScrollPhase, ScrollReprojector};
pub use scroll_resample::{ScrollResampler, SubEvent};
pub use scroll_shift::ShiftEstimate;
pub use send_pacing::{PacedChunk, SendJob, may_send_inline, pace_plan};
pub use session_state::{SessionEffect, VideoSessionState, VideoSessionStateMachine};
pub use stream_stall::{Liveness, StreamVerdict};
pub use swipe_nav::{SwipeDirection, SwipeNavStatusMessage};
pub use swipe_nav_config::{NavHistoryFlags, SwipeNavHostConfig};
pub use swipe_peel::{PeelPlannerState, PeelVerdict, SwipePeelChipState, SwipePeelPlanner};
pub use swipe_recognizer::{LiveCandidate, RecognizerState, SwipeNavRecognizer};
pub use trendline::{TrendSampler, TrendState, TrendlineConfig, TrendlineEstimator, TrendlineSnapshot};
pub use video_control::VideoControlMessage;
pub use window_feed::{CompleteSnapshot, WindowFeedAssembler};
pub use window_feed_host::{
    FeedChange, FeedReply, PushPolicyState, WindowFeedCache, WindowFeedPushPolicy, WindowFeedSourceWindow,
    WindowFeedSubscriberTable,
};
pub use window_geometry::WindowGeometryMessage;
pub use ycbcr::{ColorRange, YCbCrCoefficients};
