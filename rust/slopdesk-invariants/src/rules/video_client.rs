//! The client's folds: the gradient, the decoder's admission, the audio stage, the present queue,
//! the parameter sets, the two scroll laws, the swipe pair, the two reassemblies and the keepalive.
//!
//! Ported from `scripts/check-supervisor.sh`. Every rule here is the same argument in a different
//! costume: a law that decides what the viewer SEES lives once, in `rust/slopdesk-video`, and the
//! Swift file that used to hold it is a face. What each rule adds on top of its door list is the
//! ban — the shapes a re-implementation would grow back — because a door can be called AND
//! second-guessed, and the second guess is what diverges on the link that was already in trouble.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The GRADIENT detector — `rust/slopdesk-video`'s `trendline`, through the door of the same name.
///
/// A Swift struct its owner copies, so it folds by value with the regression WINDOW aboard.
///
/// The regression itself, and the constants it runs against: a second OLS accumulator is a second
/// slope; a Swift copy of kUp/kDown or the reset gap is a number no test compares across languages.
#[must_use]
pub fn gradient(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: "Sources/SlopDeskVideoClient/TrendlineEstimator.swift",
            entries: &[
                "slopdesk_trendline_config_default",
                "slopdesk_trendline_config_apply",
                "slopdesk_trendline_constants",
                "slopdesk_trendline_new",
                "slopdesk_trendline_note",
                "slopdesk_trendline_is_stale",
                "slopdesk_trendline_pack_milli",
                "slopdesk_trendline_pack_flags",
                "slopdesk_trendline_eq",
                "slopdesk_trend_sampler_new",
                "slopdesk_trend_sampler_should_sample",
            ],
            message: "Sources/SlopDeskVideoClient/TrendlineEstimator.swift no longer calls {entry} — the \
                      gradient detector is rust/slopdesk-video's",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"meanX\b|meanY\b|smoothedDelayMs\b|accumulatedDelayMs\b|overuseStartMs\b|= 0\.0087|= 0\.039",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift OLS accumulator or threshold gain is back in {files} — the gradient law lives \
                      in trendline.rs",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r#""SLOPDESK_TREND_"#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a SLOPDESK_TREND_* name is spelled in Swift ({files}) — the door knows its own knobs",
        },
    ];
    check_all(tree, &claims)
}

/// What the decoder is allowed to see, and in what order — `decode_admission` behind the door of
/// the same name. Four folds: the frontier, the gate, the sequencer, the budget.
///
/// The state a re-implementation would grow back: the sequencer's two SETS are the state a fold
/// reads — which ids are outstanding, not how many — so a Swift `lostAhead`, a second
/// `nextExpected` arithmetic or a second flush order is a second ordering law. The gate's two loss
/// bounds and the frontier's keep-newest are the same story. What Swift legitimately keeps is a bag
/// of PAYLOADS keyed by id (`frames`), because the law never reads a compressed byte. Scoped to
/// `Sources/`, because the tests are the parity evidence: they name the state they drive.
///
/// The valves and the caps are the door's numbers: the capacities that carry the sets across are
/// proved against them, so a Swift literal is a bound the two languages could stop agreeing on.
#[must_use]
pub fn decode_admission(tree: &Tree) -> Report {
    const SEQUENCER: &str = "Sources/SlopDeskVideoClient/DecodeSequencer.swift";
    const BUDGET: &str = "Sources/SlopDeskVideoClient/DecodeAdmissionBudget.swift";

    let claims = [
        Claim::Doors {
            path: "Sources/SlopDeskVideoClient/DecodeFrontier.swift",
            entries: &[
                "slopdesk_decode_frontier_new",
                "slopdesk_decode_frontier_note_decoded",
                "slopdesk_decode_frontier_wire_value",
            ],
            message: "Sources/SlopDeskVideoClient/DecodeFrontier.swift no longer calls {entry} — the \
                      frontier is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoClient/DecodeGate.swift",
            entries: &[
                "slopdesk_decode_gate_new",
                "slopdesk_decode_gate_note_loss",
                "slopdesk_decode_gate_note_hard_decode_failure",
                "slopdesk_decode_gate_note_awaiting_keyframe",
                "slopdesk_decode_gate_submits",
                "slopdesk_decode_gate_note_decode_succeeded",
            ],
            message: "Sources/SlopDeskVideoClient/DecodeGate.swift no longer calls {entry} — the \
                      drop-until-anchor law is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: SEQUENCER,
            entries: &[
                "slopdesk_decode_sequencer_constants",
                "slopdesk_decode_sequencer_new",
                "slopdesk_decode_sequencer_note_completed",
                "slopdesk_decode_sequencer_note_lost",
            ],
            message: "Sources/SlopDeskVideoClient/DecodeSequencer.swift no longer calls {entry} — the \
                      ordering law is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: BUDGET,
            entries: &[
                "slopdesk_decode_budget_default",
                "slopdesk_decode_budget_new",
                "slopdesk_decode_budget_admit",
                "slopdesk_decode_budget_complete",
            ],
            message: "Sources/SlopDeskVideoClient/DecodeAdmissionBudget.swift no longer calls {entry} — the \
                      admission budget is rust/slopdesk-video's",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"lostAhead\b|func drainContiguous\(|func flushAll\(|distanceWrapped\(from: (expected|mn|mx)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift hold set / flush branch is back in {files} — those laws live in \
                      decode_admission.rs",
        },
        Claim::NoneOf {
            paths: &[SEQUENCER, BUDGET],
            pattern: r"defaultMaxHeld = [0-9]|defaultMaxGap = [0-9]|maxPendingCount: Int = |16 << 20",
            view: View::Code,
            message: "a Swift valve or cap literal is back in {files} — decode_admission.rs owns both bands",
        },
    ];
    check_all(tree, &claims)
}

/// The audio jitter STAGE — `audio_jitter`, through the door of the same name.
///
/// This one is a HANDLE, and the reason is the mirror of the sequencer's: the stage's whole product
/// IS the samples, so they live where the decisions are. Exactly one free per new, and the free is
/// the owner's `deinit` — a handle whose Swift owner stops freeing it leaks a stage per session,
/// which no test would notice.
///
/// The SPSC hand-off ring stays Swift ON PURPOSE — it is raw storage partitioned by two atomics so
/// a real-time render thread never blocks on the producer, and it belongs to the runtime that owns
/// the audio unit. If it ever grows a door entry, that decision needs a DECISIONS entry, not a
/// commit.
#[must_use]
pub fn audio_stage(tree: &Tree) -> Report {
    const SWIFT_AUDIO: &str = "Sources/SlopDeskVideoClient/AudioJitterBuffer.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_AUDIO,
            entries: &[
                "slopdesk_audio_stage_new",
                "slopdesk_audio_stage_free",
                "slopdesk_audio_stage_shape",
                "slopdesk_audio_stage_stats",
                "slopdesk_audio_stage_primed",
                "slopdesk_audio_stage_pending_frames",
                "slopdesk_audio_stage_available_samples",
                "slopdesk_audio_stage_push",
                "slopdesk_audio_stage_pull",
                "slopdesk_audio_stage_drain_available",
                "slopdesk_audio_stage_note_consumer_starved",
                "slopdesk_audio_stage_drop_oldest_pending",
                "slopdesk_audio_stage_clear",
                "slopdesk_audio_stage_shed_to_depth_bound",
                "slopdesk_audio_ring_target_samples",
                "slopdesk_audio_consumer_starved",
            ],
            message: "Sources/SlopDeskVideoClient/AudioJitterBuffer.swift no longer calls {entry} — the \
                      jitter stage is rust/slopdesk-video's",
        },
        Claim::Names {
            path: SWIFT_AUDIO,
            needle: "deinit { slopdesk_audio_stage_free",
            message: "Sources/SlopDeskVideoClient/AudioJitterBuffer.swift's owner no longer frees its stage \
                      in deinit — one _free per _new (docs/55)",
        },
        // A Swift block list is a second reorder law and a second play frontier; the pump's two
        // sample budgets and its starvation test are the door's too.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"consumedBlocks\b|headSampleOffset\b|playFrontier\b|effectiveFrontier\b|func copyAvailable\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift jitter block list or play frontier is back in {files} — that law lives in \
                      audio_jitter.rs",
        },
        Claim::Lacks {
            path: SWIFT_AUDIO,
            pattern: r"slopdesk_audio_ring_new|slopdesk_audio_ring_produce|slopdesk_audio_ring_consume",
            view: View::Code,
            message: "the SPSC hand-off ring crossed the door — that is a design change (docs/55, DECISIONS)",
        },
    ];
    check_all(tree, &claims)
}

/// The PRESENTATION queue — `present_queue`, through the door of the same name.
///
/// By value, like the decoder's admission and for the same reason: the queue is the big part and
/// the near side never reads it, only the handle to present and the handles to let go of.
///
/// The state a re-implementation would grow back: a Swift frame array with its lockstep timestamps,
/// a second priming latch, a second underflow run. What Swift legitimately keeps is a bag of IMAGES
/// keyed by handle (`images`), because the law never dereferences a handle — and `lastShownFrame`,
/// which outlives every handle the queue held. The leading `[^/]*` keeps prose out of it: the
/// header and `PacerDepthPolicy` both NAME these, and a doc comment is not a second implementation.
#[must_use]
pub fn present_queue(tree: &Tree) -> Report {
    const SWIFT_PACER: &str = "Sources/SlopDeskVideoClient/FramePacer.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_PACER,
            entries: &[
                "slopdesk_present_queue_new",
                "slopdesk_present_queue_submit",
                "slopdesk_present_queue_step",
                "slopdesk_present_queue_set_live_depth",
                "slopdesk_present_queue_adopt_live_depth",
                "slopdesk_present_clamped_playout_seconds",
                "slopdesk_present_playout_recompute_due",
                "slopdesk_present_deadline_for_arrival",
                "slopdesk_present_deadline_due",
                "slopdesk_present_should_render",
                "slopdesk_present_should_present_on_arrival",
                "slopdesk_present_resolve_tick_rate",
            ],
            message: "Sources/SlopDeskVideoClient/FramePacer.swift no longer calls {entry} — the \
                      presentation law is rust/slopdesk-video's",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"^[^/]*(queueSubmittedAt\b|underflowRun (\+=|= 0)|primed = true|queue: \[CVImageBuffer\])",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift present queue or priming latch is back in {files} — that law lives in \
                      present_queue.rs",
        },
        // The bands are the door's numbers: the crossing's fixed capacity is proved against the
        // depth cap, and the schedule's clamps are what keep a nonsense configuration off the screen.
        Claim::Lacks {
            path: SWIFT_PACER,
            pattern: r"min\(240, max\(30|min\(200\.0, max\(0\.0|playoutRecomputeEvery = [0-9]|0\.0005\)",
            view: View::Code,
            message: "a Swift tick, playout or render-cap literal is back — present_queue.rs owns every band",
        },
    ];
    check_all(tree, &claims)
}

/// The HEVC parameter sets — `hevc_parameter_sets`.
///
/// The bytes do not cross: an access unit is most of a frame and Swift is holding it, so the door
/// answers WHERE the three sets sit, exactly as `slopdesk_nal_split` does one layer down. The walk
/// and the numbers a re-implementation would grow back are the six-bit shift, the three types, and
/// the split-then-classify loop the door replaced.
#[must_use]
pub fn hevc_parameter_sets(tree: &Tree) -> Report {
    const SWIFT_HEVC: &str = "Sources/SlopDeskVideoClient/HEVCParameterSets.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_HEVC,
            entries: &[
                "slopdesk_hevc_types",
                "slopdesk_hevc_nal_type",
                "slopdesk_hevc_parameter_sets",
            ],
            message: "Sources/SlopDeskVideoClient/HEVCParameterSets.swift no longer calls {entry} — the \
                      extraction is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_HEVC,
            pattern: r">> 1\) & 0x3F|vpsType: UInt8 = |spsType: UInt8 = |ppsType: UInt8 = |NALUnit\.split",
            view: View::Code,
            message: "Sources/SlopDeskVideoClient/HEVCParameterSets.swift spells the NAL header or the set \
                      types again — those live in hevc_parameter_sets.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The two SCROLL laws — `scroll_reproject` on the pane's side and `scroll_resample` on the
/// injector's.
///
/// Seven scalars and six, so both cross by value. The arithmetic is why the reprojection went: the
/// separate multiply and add that must never fuse, the ordered clamps, the ease-out and its rest
/// epsilon — none of which may be spelled twice. `exp` is in its ban because the decay is a
/// GEOMETRIC ease-out with a snap, not a call into libm: a Swift `exp` here would be a second law
/// that disagrees in the last bits and never snaps to rest.
///
/// What may never come back on the resampler's side is the drain arithmetic: the whole-pixel
/// truncation that CARRIES its fraction is what makes the integer outputs sum to the float input.
/// The phase numbers are CoreGraphics', but which of them ends a gesture is this law's, and a
/// second copy of that answer is how a `Changed` lands after an `Ended`.
#[must_use]
pub fn scroll_laws(tree: &Tree) -> Report {
    const SWIFT_REPROJECT: &str = "Sources/SlopDeskVideoProtocol/ScrollReprojector.swift";
    const SWIFT_RESAMPLE: &str = "Sources/SlopDeskVideoProtocol/ScrollResampler.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_REPROJECT,
            entries: &[
                "slopdesk_scroll_reprojector_defaults",
                "slopdesk_scroll_reprojector_new",
                "slopdesk_scroll_reprojector_note_velocity",
                "slopdesk_scroll_reprojector_advance",
                "slopdesk_scroll_reprojector_note_real_frame",
                "slopdesk_scroll_reprojector_reset",
            ],
            message: "Sources/SlopDeskVideoProtocol/ScrollReprojector.swift no longer calls {entry} — the \
                      reprojection law is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_REPROJECT,
            pattern: r"0\.125|0\.12|1\.25e-4|func applyDecay|func clampToBand|exp\(",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/ScrollReprojector.swift spells a band, a time constant \
                      or the ease-out again — those live in scroll_reproject.rs",
        },
        Claim::Doors {
            path: SWIFT_RESAMPLE,
            entries: &[
                "slopdesk_scroll_resampler_defaults",
                "slopdesk_scroll_resampler_new",
                "slopdesk_scroll_resampler_ingest",
                "slopdesk_scroll_resampler_drain",
                "slopdesk_scroll_resampler_is_idle",
                "slopdesk_scroll_resampler_reset",
            ],
            message: "Sources/SlopDeskVideoProtocol/ScrollResampler.swift no longer calls {entry} — the \
                      resampling law is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_RESAMPLE,
            pattern: r"func drainAxis|func flushResidual|rounded\(\.towardZero\)|scrollChanged|momentumContinue|= 48\.0|= 4096\.0",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/ScrollResampler.swift spells the drain, the flush or a \
                      knob again — those live in scroll_resample.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The SWIPE-NAV recogniser and its client-side mirror — `swipe_recognizer` and `swipe_peel`.
///
/// The recogniser is the one law in this stretch that TWO processes run: the host's injector
/// decides the fire, and the client's peel planner predicts it over the same events without a round
/// trip. Two implementations would not merely duplicate the rule, they would let the overlay
/// promise a navigation the host then declines. The thresholds are field-tuned against a 320-lift
/// log; a second copy of them is a second recogniser. The ALLOWLIST half is not pinned here: it is
/// a question about an operating point, and the one thing that holds one is `swipe_nav_config`.
///
/// The mirror folds by value for the same reason: it only earns its keep if it reaches the host's
/// verdict over the host's events, and a second copy of the quantum or the show threshold is a chip
/// that fills at a different rate than it commits at. The glass progress is named because it
/// RATCHETS across the momentum boundary — a second copy that simply tracked the live candidate
/// would let the chip fall back on lift, mid-commit.
#[must_use]
pub fn swipe_nav(tree: &Tree) -> Report {
    const SWIFT_SWIPE: &str = "Sources/SlopDeskVideoProtocol/SwipeNavRecognizer.swift";
    const SWIFT_PEEL: &str = "Sources/SlopDeskVideoClient/SwipePeelPlanner.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_SWIPE,
            entries: &[
                "slopdesk_swipe_constants",
                "slopdesk_swipe_recognizer_new",
                "slopdesk_swipe_recognizer_ingest",
                "slopdesk_swipe_live_candidate",
                "slopdesk_swipe_slow_required_travel",
            ],
            message: "Sources/SlopDeskVideoProtocol/SwipeNavRecognizer.swift no longer calls {entry} — the \
                      swipe law is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_SWIPE,
            pattern: r"func liftDecision|func ingestMomentum|func flushResidual|lastMomentum|Double = 3$|Double = 4$|Double = 2$|= 0\.45|= 0\.70|= 0\.25|com\.apple\.Safari",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/SwipeNavRecognizer.swift spells a decision, a threshold \
                      or the allow-list again — those live in swipe_recognizer.rs",
        },
        Claim::Doors {
            path: SWIFT_PEEL,
            entries: &[
                "slopdesk_peel_constants",
                "slopdesk_peel_new",
                "slopdesk_peel_ingest",
                "slopdesk_peel_cancel",
            ],
            message: "Sources/SlopDeskVideoClient/SwipePeelPlanner.swift no longer calls {entry} — the peel \
                      law is rust/slopdesk-video's",
        },
        Claim::Names {
            path: "Sources/SlopDeskVideoProtocol/SwipeNavStatusCodec.swift",
            needle: "slopdesk_peel_history_gated(",
            message: "SwipeNavStatusCodec.swift no longer calls slopdesk_peel_history_gated — the history \
                      gate is swipe_peel.rs's",
        },
        Claim::Lacks {
            path: SWIFT_PEEL,
            pattern: r"glassProgress|shownDirection|showTravel|1\.0 / 32\.0|\* 0\.3|rounded\(\.down\)",
            view: View::Code,
            message: "Sources/SlopDeskVideoClient/SwipePeelPlanner.swift spells the chip state, the quantum \
                      or the show fraction again — those live in swipe_peel.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The CLIENT mux pool and the two loop policies — `mux_client_pool` and `mux_flow`.
///
/// The pool is a handle because the lane sets and the id allocator are its state; the registry
/// keeps only the flow OBJECTS, which the crate cannot hold. The mask is named in the ban because
/// it is what separates two clients' id RANGES: a copy that counted from one would put both
/// clients' first lane on the same id, and the host's reply maps are keyed by the bare id.
///
/// The receive-loop re-arm and the send-path mapping are ONE type each, in the module both ends
/// import. They used to be byte-identical twins in the host and client modules, each commented with
/// the fact that the other existed — a contract kept by reading rather than by the compiler.
#[must_use]
pub fn client_mux(tree: &Tree) -> Report {
    const SWIFT_POOL: &str = "Sources/SlopDeskVideoClient/Mux/VideoConnectionRegistry.swift";
    const SWIFT_LOOP: &str = "Sources/SlopDeskVideoProtocol/UDPFlowPolicy.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_POOL,
            entries: &[
                "slopdesk_video_pool_new",
                "slopdesk_video_pool_free",
                "slopdesk_video_pool_shared_flow_count",
                "slopdesk_video_pool_lane_count",
                "slopdesk_video_pool_acquire",
                "slopdesk_video_pool_release",
            ],
            message: "Sources/SlopDeskVideoClient/Mux/VideoConnectionRegistry.swift no longer calls {entry} \
                      — the flow pool is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_POOL,
            pattern: r"channelIDs\.insert|nextChannelID|&\+= 1|0x0FFF_FFFF",
            view: View::Code,
            message: "Sources/SlopDeskVideoClient/Mux/VideoConnectionRegistry.swift spells the refcount or \
                      the lane allocator again — those live in mux_client_pool.rs",
        },
        Claim::Doors {
            path: SWIFT_LOOP,
            entries: &[
                "slopdesk_mux_should_rearm",
                "slopdesk_mux_receive_backoff",
                "slopdesk_mux_send_path_viability",
            ],
            message: "Sources/SlopDeskVideoProtocol/UDPFlowPolicy.swift no longer calls {entry} — the loop \
                      policies are rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_LOOP,
            pattern: r"0\.005|0\.25|1 << exponent|baseBackoff",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/UDPFlowPolicy.swift spells the backoff rungs again — \
                      they live in mux_flow.rs",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoHost/Mux/UDPReceiveLoopPolicy.swift",
            message: "the loop policy is ONE type, in SlopDeskVideoProtocol",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoClient/Mux/UDPReceiveLoopPolicy.swift",
            message: "the loop policy is ONE type, in SlopDeskVideoProtocol",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoClient/Mux/UDPSendPathPolicy.swift",
            message: "the send-path policy is ONE type, in SlopDeskVideoProtocol",
        },
    ];
    check_all(tree, &claims)
}

/// The two REASSEMBLIES and the keepalive contract — `blob`, `window_feed` and `keepalive`.
///
/// Both reassemblies are handles, because the product IS what accumulates across many calls and the
/// caps are what keeps an untrusted sender from growing the map. The FNV constants are named in the
/// blob's ban because an icon's id is a function of its bundle id on BOTH ends of the wire: a
/// second hash that drifts would ask the host for a blob it never cached. The feed's chunk-order
/// concatenation is named because arrival order is NOT chunk order — a second loop that forgot that
/// would reorder the window list on every lossy renewal.
///
/// The keepalive is five numbers that are ONE argument: the stall threshold tolerates two lost host
/// heartbeats, and the reaper tick is what makes the worst-case reclaim `idleTimeout + reaperTick`.
/// A Swift copy of any one of them drifts the pair.
#[must_use]
pub fn reassembly(tree: &Tree) -> Report {
    const SWIFT_BLOB: &str = "Sources/SlopDeskVideoProtocol/BlobAssembler.swift";
    const SWIFT_FEED: &str = "Sources/SlopDeskVideoProtocol/WindowFeedAssembler.swift";
    const SWIFT_KEEPALIVE: &str = "Sources/SlopDeskVideoProtocol/KeepaliveTiming.swift";

    let claims = [
        Claim::Doors {
            path: SWIFT_BLOB,
            entries: &[
                "slopdesk_blob_kinds",
                "slopdesk_blob_max_bytes",
                "slopdesk_blob_assembler_new",
                "slopdesk_blob_assembler_free",
                "slopdesk_blob_assembler_fold",
                "slopdesk_blob_assembler_take",
                "slopdesk_blob_assembler_reset",
                "slopdesk_blob_validates",
                "slopdesk_blob_looks_like_png",
                "slopdesk_blob_looks_like_jpeg",
                "slopdesk_blob_chunk_count",
                "slopdesk_blob_encoded_chunk",
                "slopdesk_blob_id_of",
            ],
            message: "Sources/SlopDeskVideoProtocol/BlobAssembler.swift no longer calls {entry} — the blob \
                      law is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_BLOB,
            pattern: r"0x89, 0x50|0xFF, 0xD8|0xCBF2_9CE4|0x0000_0100|received\[|insertionOrder",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/BlobAssembler.swift spells the accumulator, the magic \
                      or the id hash again — those live in blob.rs",
        },
        Claim::Doors {
            path: SWIFT_FEED,
            entries: &[
                "slopdesk_window_feed_bounds",
                "slopdesk_window_feed_new",
                "slopdesk_window_feed_free",
                "slopdesk_window_feed_fold",
                "slopdesk_window_feed_take",
                "slopdesk_window_feed_reset",
            ],
            message: "Sources/SlopDeskVideoProtocol/WindowFeedAssembler.swift no longer calls {entry} — the \
                      feed reassembly is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_FEED,
            pattern: r"insertionOrder|partials\[|maxPartialGenerations = |maxRecordsPerGeneration = |for index in 0\.\.<chunkCount",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/WindowFeedAssembler.swift spells the accumulator or its \
                      bounds again — those live in window_feed.rs",
        },
        Claim::Names {
            path: SWIFT_KEEPALIVE,
            needle: "slopdesk_keepalive_timing()",
            message: "Sources/SlopDeskVideoProtocol/KeepaliveTiming.swift no longer calls \
                      slopdesk_keepalive_timing — the contract is rust/slopdesk-video's",
        },
        Claim::NoneOf {
            paths: &[
                SWIFT_KEEPALIVE,
                "Sources/SlopDeskVideoProtocol/StreamStallPolicy.swift",
            ],
            pattern: r"TimeInterval = (5|30|1|3)\.0",
            view: View::Code,
            message: "a keepalive or stall cadence is spelled in Swift again ({files}) — those live in \
                      keepalive.rs",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::claim::{Claim, View, check_all};
    use crate::tests::Fixture;

    /// A `NoneOf` ban whose file was renamed away must FAIL, not quietly drop its share of the
    /// scope. This is the shell's silent pass — `grep -qE pat a b c` over a missing `b` is
    /// still exit 1.
    #[test]
    fn a_multi_file_ban_over_a_missing_file_fails_instead_of_narrowing() {
        let fixture = Fixture::new("none-of-missing");
        fixture.write("Sources/A.swift", "let x = 1\n");
        let claims = [Claim::NoneOf {
            paths: &["Sources/A.swift", "Sources/B.swift"],
            pattern: "banned",
            view: View::Code,
            message: "banned appears in {files}",
        }];
        let report = check_all(&fixture.tree(), &claims);
        assert!(
            report.violations().iter().any(|v| v.contains("is gone")),
            "{report:?}"
        );
    }

    /// And it names EVERY offender, because a diagnostic that stops at the first file sends the
    /// reader back for a second run to find the rest.
    #[test]
    fn a_multi_file_ban_names_every_offender() {
        let fixture = Fixture::new("none-of-offenders");
        fixture
            .write("Sources/A.swift", "banned()\n")
            .write("Sources/B.swift", "fine()\n")
            .write("Sources/C.swift", "banned()\n");
        let claims = [Claim::NoneOf {
            paths: &["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"],
            pattern: "banned",
            view: View::Code,
            message: "banned appears in {files}",
        }];
        let report = check_all(&fixture.tree(), &claims);
        assert_eq!(report.violations().len(), 1, "{report:?}");
        assert!(
            report.violations()[0].contains("Sources/A.swift, Sources/C.swift"),
            "{report:?}"
        );
    }

    /// A handle whose Swift owner stops freeing it leaks a stage per session, which no test
    /// notices.
    #[test]
    fn an_audio_stage_that_is_never_freed_is_caught() {
        let fixture = Fixture::new("audio-free");
        fixture.write(
            "Sources/SlopDeskVideoClient/AudioJitterBuffer.swift",
            &format!("{AUDIO_DOORS}deinit {{ slopdesk_audio_stage_free(handle) }}\n"),
        );
        assert!(super::audio_stage(&fixture.tree()).is_clean());

        fixture.write("Sources/SlopDeskVideoClient/AudioJitterBuffer.swift", AUDIO_DOORS);
        let report = super::audio_stage(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("one _free per _new")),
            "{report:?}"
        );
    }

    /// The SPSC ring crossing the door is a DESIGN change, not a commit — so it fails even though
    /// every other door is still called.
    #[test]
    fn the_spsc_ring_crossing_the_door_is_caught() {
        let fixture = Fixture::new("spsc-ring");
        fixture.write(
            "Sources/SlopDeskVideoClient/AudioJitterBuffer.swift",
            &format!(
                "{AUDIO_DOORS}deinit {{ slopdesk_audio_stage_free(handle) \
                 }}\nslopdesk_audio_ring_produce(x)\n"
            ),
        );
        let report = super::audio_stage(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("design change")),
            "{report:?}"
        );
    }

    /// The twin that used to live in both mux modules must stay ONE type — a returning file is the
    /// contract going back to being kept by reading rather than by the compiler.
    #[test]
    fn a_returning_loop_policy_twin_is_caught() {
        let fixture = Fixture::new("loop-twin");
        fixture
            .write(
                "Sources/SlopDeskVideoClient/Mux/VideoConnectionRegistry.swift",
                POOL_DOORS,
            )
            .write("Sources/SlopDeskVideoProtocol/UDPFlowPolicy.swift", LOOP_DOORS);
        assert!(super::client_mux(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoHost/Mux/UDPReceiveLoopPolicy.swift",
            "struct UDPReceiveLoopPolicy {}\n",
        );
        let report = super::client_mux(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("ONE type")),
            "{report:?}"
        );
    }

    const AUDIO_DOORS: &str = "\
slopdesk_audio_stage_new(x)
slopdesk_audio_stage_free(x)
slopdesk_audio_stage_shape(x)
slopdesk_audio_stage_stats(x)
slopdesk_audio_stage_primed(x)
slopdesk_audio_stage_pending_frames(x)
slopdesk_audio_stage_available_samples(x)
slopdesk_audio_stage_push(x)
slopdesk_audio_stage_pull(x)
slopdesk_audio_stage_drain_available(x)
slopdesk_audio_stage_note_consumer_starved(x)
slopdesk_audio_stage_drop_oldest_pending(x)
slopdesk_audio_stage_clear(x)
slopdesk_audio_stage_shed_to_depth_bound(x)
slopdesk_audio_ring_target_samples(x)
slopdesk_audio_consumer_starved(x)
";
    const POOL_DOORS: &str = "\
slopdesk_video_pool_new(x)
slopdesk_video_pool_free(x)
slopdesk_video_pool_shared_flow_count(x)
slopdesk_video_pool_lane_count(x)
slopdesk_video_pool_acquire(x)
slopdesk_video_pool_release(x)
";
    const LOOP_DOORS: &str = "\
slopdesk_mux_should_rearm(x)
slopdesk_mux_receive_backoff(x)
slopdesk_mux_send_path_viability(x)
";
}
