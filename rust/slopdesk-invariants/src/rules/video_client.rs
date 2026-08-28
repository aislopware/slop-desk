//! The client's folds: the gradient, the decoder's admission, the audio stage, the present queue,
//! the parameter sets, the two scroll laws, the swipe pair, the two reassemblies and the keepalive.
//!
//! Ported from the deleted `check-supervisor.sh`. Every rule here is the same argument in a
//! different costume: a law that decides what the viewer SEES lives once, in `rust/slopdesk-video`,
//! and the Swift file that used to hold it is a face. What each rule adds on top of its door list
//! is the ban — the shapes a re-implementation would grow back — because a door can be called AND
//! second-guessed, and the second guess is what diverges on the link that was already in trouble.

use crate::claim::{Claim, RUST, SWIFT, View, check_all};
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

const SWIFT_DECODER: &str = "Sources/SlopDeskVideoClient/AudioStreamDecoder.swift";
const SWIFT_PLAYER: &str = "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift";

/// The Rust host, which holds the SENDING half of the row now.
const DAEMON: &str = "rust/slopdesk-videohostd";

/// The faces ask their doors, the daemon asks its crates, and each face that holds a handle frees
/// it in `deinit`.
const fn audio_faces() -> [Claim; 5] {
    [
        // The sending half. `AudioStreamEncoder` and the host session were the two Swift faces
        // here, and `docs/61` deleted both; the same two questions — is the encode still
        // `slopdesk-apple-audio`'s, and are the codec pick and the bitrate band still
        // `audio_source`'s — are now asked of the daemon that replaced them. The fallback is the
        // whole decision on that second one: an unrecognised codec name must land on AAC-ELD and a
        // bitrate that is not a number must land on the default rather than the floor, which is a
        // rule with exactly one right answer and therefore exactly one home. `audio_wire` is named
        // beside them because the eleven-byte header and the config flag are what the encoder's
        // output has to become (docs/57 §5, docs/61 §3).
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["audio_source", "audio_wire", "slopdesk_apple_audio"],
            message: "rust/slopdesk-videohostd stopped naming {entry} — the block cadence and the two knobs \
                      are slopdesk_video::audio_source's, the datagram header is \
                      slopdesk_video::audio_wire's and the AAC-ELD encode is rust/slopdesk-apple-audio's, \
                      so a daemon that no longer asks for one of them is spelling it itself (docs/61 §3)",
        },
        Claim::Doors {
            path: SWIFT_DECODER,
            entries: &[
                "slopdesk_audio_decoder_new",
                "slopdesk_audio_decoder_free",
                "slopdesk_audio_decoder_decode",
            ],
            message: "Sources/SlopDeskVideoClient/AudioStreamDecoder.swift no longer calls {entry} — the \
                      decode is rust/slopdesk-apple-audio's",
        },
        Claim::Doors {
            path: SWIFT_PLAYER,
            entries: &[
                "slopdesk_audio_player_new",
                "slopdesk_audio_player_free",
                "slopdesk_audio_player_enqueue",
                "slopdesk_audio_player_flush",
                "slopdesk_audio_player_start",
                "slopdesk_audio_player_stop",
            ],
            message: "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift no longer calls {entry} — the \
                      output stream is rust/slopdesk-audio-out's",
        },
        // Each handle is freed by its owner's `deinit`; a face that stops leaks one per session,
        // and for the player that is a device thread as well as an allocation. The ENCODER's
        // `deinit` used to be pinned the same way and no longer can be: its handle went with the
        // Swift face, and the daemon owns an encoder by move, so the compiler answers what that
        // claim was standing in for. `rust/slopdesk-apple-audio` carries the leak test for the
        // framework side of it (docs/57).
        Claim::Names {
            path: SWIFT_DECODER,
            needle: "if let handle { slopdesk_audio_decoder_free",
            message: "Sources/SlopDeskVideoClient/AudioStreamDecoder.swift no longer frees its decoder in \
                      deinit — one _free per _new (docs/55)",
        },
        Claim::Names {
            path: SWIFT_PLAYER,
            needle: "if let handle { slopdesk_audio_player_free",
            message: "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift no longer frees its player in \
                      deinit — one _free per _new, and this one joins a device thread (docs/55)",
        },
    ]
}

/// And the state a re-implementation is made of stays out of `Sources` — and, for the sending
/// half, out of the daemon.
const fn audio_bans() -> [Claim; 6] {
    [
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
        // And the knobs themselves: a second reader of either variable is a second fallback rule,
        // which is the part the doors above exist to own.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"SLOPDESK_AUDIO_CODEC|SLOPDESK_AUDIO_BITRATE",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} reads an audio knob out of the environment — the codec pick and the bitrate \
                      band are audio_source.rs's, behind slopdesk_audio_wire_format and \
                      slopdesk_audio_bitrate_bps",
        },
        // The encoder's half of the same ban: the remainder the capture cadence leaves behind, and
        // the fold that turns whatever ScreenCaptureKit delivered into the wire's stereo.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"func encodePCM\(|func packS16LE\(|aacInputProc\b|func resetAccumulator\(|func resetConverterState\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift audio accumulator or channel fold is back in {files} — that law lives in \
                      audio_source.rs",
        },
        // The hand-off ring is `rtrb` and the output stream is `cpal`. A door for either would mean
        // the near side had grown a producer or a render callback again.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"slopdesk_audio_ring_|slopdesk_audio_stage_",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} reaches for a ring or stage door — both are inside rust/slopdesk-audio-out \
                      now, and a door for either is a design change (DECISIONS)",
        },
        // The encoder's half again, in the language the sending side is written in now. The
        // remainder the capture cadence leaves behind, the fold that turns whatever
        // ScreenCaptureKit delivered into the wire's stereo, the packing, the block size and the
        // header size are all `slopdesk_video`'s — every one of them a constant two implementations
        // would agree on until a device arrives with a layout nobody tested. `rust/slopdesk-video`
        // is deliberately out of scope: it IS the accumulator.
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"fn pack_s16le *\(|struct BlockAccumulator\b|fn fold_(interleaved|planar)_to_stereo *\(|\bconst (FRAMES_PER_BLOCK|HEADER_SIZE)\b|\b32768\.0",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd spells the audio accumulator, the channel fold or a wire \
                      constant in {files} — the 480-frame block, the stereo fold, the S16LE packing and the \
                      eleven-byte header live in slopdesk_video::audio_source and \
                      slopdesk_video::audio_wire (docs/61 §3)",
        },
        // And the two knobs, on the side that resolves them. `View::Code` is why the prose in
        // `audio.rs` that NAMES them is not a violation: a doc line explaining that a knob now
        // honours `video-prefs.json` is the explanation, not a second reader.
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"SLOPDESK_AUDIO_CODEC|SLOPDESK_AUDIO_BITRATE",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd reads an audio knob by name in {files} — the codec pick and \
                      the bitrate band are slopdesk_video::audio_source's, fallbacks included, and a second \
                      reader is a second clamp that no test can hold in step (docs/61 §3)",
        },
    ]
}

/// The audio ROW — the codec through `slopdesk-apple-audio`, the speakers through
/// `slopdesk-audio-out`.
///
/// This rule used to be about the jitter STAGE alone, and the stage was the only Rust in the row:
/// fifteen door entries existed so a Swift `AudioPlaybackPump` could drive it, between a Swift
/// `AudioStreamDecoder` and a Swift `AUHAL`/`RemoteIO` render callback. The comment here said the
/// SPSC hand-off ring stayed Swift on purpose, "raw storage partitioned by two atomics", and that
/// moving it would need a DECISIONS entry rather than a commit. It got one: `rtrb` is that ring,
/// `cpal` is that render callback, and neither is code this repo maintains.
///
/// So what the row keeps in Swift is two FACES that marshal, and what this rule asks is that they
/// stay faces. Each names its door; a face that stops calling one has grown an implementation.
///
/// The row's SENDING half is no longer Swift at all. `AudioStreamEncoder` and the host session
/// were the other two faces, and `docs/61` deleted both — so the two questions they answered are
/// asked of `rust/slopdesk-videohostd` instead, by directory rather than by filename, because the
/// daemon's modules are still being split and a claim pinned to a guessed one would go wrong for a
/// reason this rule was never about.
///
/// The BANS ride along, every one of them on state a re-implementation is made of, and they now
/// run down both sides of the row. The stage's ordering law — a block list, a play frontier, a
/// sample budget — is `audio_jitter`'s wherever it appears in `Sources`. The encoder's is
/// `audio_source`'s: an interleaved accumulator carrying a sub-block remainder, and the channel
/// fold that fills it — banned in the daemon now, since the daemon is the only thing that could
/// grow one. And the row's two knobs are read by `audio_source` too, so the environment name
/// itself may appear in neither `Sources` nor the daemon: a second reader of either is a second
/// clamp, and two clamps that must agree cannot be tested for.
///
/// Every ban is scoped away from `rust/slopdesk-video` and `rust/slopdesk-apple-audio` on purpose.
/// Those crates spell every one of these names, because they are what owns them.
#[must_use]
pub fn audio_row(tree: &Tree) -> Report {
    let claims: Vec<Claim> = audio_faces().into_iter().chain(audio_bans()).collect();
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

/// The two SCROLL laws — `scroll_reproject` on the pane's side and `scroll_resample` on the
/// injector's.
///
/// Seven scalars and six, so both cross by value. The arithmetic is why the reprojection went: the
/// separate multiply and add that must never fuse, the ordered clamps, the ease-out and its rest
/// epsilon — none of which may be spelled twice. `exp` is in its ban because the decay is a
/// GEOMETRIC ease-out with a snap, not a call into libm: a Swift `exp` here would be a second law
/// that disagrees in the last bits and never snaps to rest.
///
/// The resampler's side is a plain BAN now rather than a door list, because its Swift face is gone:
/// the law runs inside the injector handle, on the pump thread that posts, and it is reached
/// through no door at all. What the ban protects is the drain arithmetic — the whole-pixel
/// truncation that CARRIES its fraction is what makes the integer outputs sum to the float input —
/// and the answer to which phase ends a gesture, a second copy of which is how a `Changed` lands
/// after an `Ended`. A file back at that path could only be a second caller, since there is nothing
/// left to call.
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
        Claim::Absent {
            path: SWIFT_RESAMPLE,
            message: "Sources/SlopDeskVideoProtocol/ScrollResampler.swift is back — the resampler runs \
                      INSIDE the injector handle now (rust/slopdesk-ffi/src/injector.rs), on the thread \
                      that posts, so a Swift face for it would be a second caller of one law",
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

    /// A handle whose Swift owner stops freeing it leaks one per session, which no test notices —
    /// and for the player it leaks a device thread as well as an allocation.
    #[test]
    fn an_audio_handle_that_is_never_freed_is_caught() {
        let fixture = Fixture::new("audio-free");
        write_audio_row(&fixture);
        assert!(super::audio_row(&fixture.tree()).is_clean());

        // The player's deinit, and only the player's, drops its free.
        fixture.write(
            "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift",
            PLAYER_DOORS,
        );
        let report = super::audio_row(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("joins a device thread")),
            "{report:?}"
        );
    }

    /// A face that stops calling its door has grown an implementation behind it.
    #[test]
    fn a_face_that_stops_asking_its_door_is_caught() {
        let fixture = Fixture::new("audio-door");
        write_audio_row(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/AudioStreamDecoder.swift",
            "deinit { if let handle { slopdesk_audio_decoder_free(handle) } \
             }\nslopdesk_audio_decoder_new(x)\n",
        );
        let report = super::audio_row(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk_audio_decoder_decode")),
            "{report:?}"
        );
    }

    /// The ring and the stage are inside `slopdesk-audio-out` now. A door for either would mean the
    /// near side had grown a producer or a render callback back, which is a DESIGN change.
    #[test]
    fn reaching_for_a_ring_or_stage_door_is_caught() {
        let fixture = Fixture::new("spsc-ring");
        write_audio_row(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift",
            &format!(
                "{PLAYER_DOORS}deinit {{ if let handle {{ slopdesk_audio_player_free(handle) }} \
                 }}\nslopdesk_audio_ring_produce(x)\n"
            ),
        );
        let report = super::audio_row(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("design change")),
            "{report:?}"
        );
    }

    /// The encoder's accumulator and channel fold are `audio_source`'s, wherever in `Sources` they
    /// reappear — the ban is not scoped to the file that used to hold them, and
    /// `SlopDeskVideoClient` is a LIVE target, so nothing about this seed is a deleted
    /// directory.
    #[test]
    fn a_returning_swift_audio_accumulator_is_caught() {
        let fixture = Fixture::new("audio-accumulator");
        write_audio_row(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/SomethingElse.swift",
            "func encodePCM(_ s: [Float]) {}\n",
        );
        let report = super::audio_row(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("audio_source.rs")),
            "{report:?}"
        );
    }

    /// The same law, in the language the sending half is written in now.
    ///
    /// Every one of these is a line the compiler accepts and no suite can see: the daemon still
    /// calls `audio_source`, and now also carries its own block size, its own packing or its own
    /// idea of full scale beside it. The two agree until a device arrives with a channel layout
    /// nobody tested.
    #[test]
    fn a_daemon_that_respells_the_audio_accumulator_is_caught() {
        for line in [
            "fn pack_s16le(samples: &[f32]) -> Vec<u8> { Vec::new() }\n",
            "struct BlockAccumulator { pending: Vec<f32> }\n",
            "fn fold_interleaved_to_stereo(src: &[f32]) -> Option<Vec<f32>> { None }\n",
            "fn fold_planar_to_stereo(left: &[f32]) -> Option<Vec<f32>> { None }\n",
            "const FRAMES_PER_BLOCK: usize = 480;\n",
            "const HEADER_SIZE: usize = 11;\n",
            "let scaled = sample * 32768.0;\n",
        ] {
            let fixture = Fixture::new("daemon-audio-accumulator");
            write_audio_row(&fixture);
            assert!(super::audio_row(&fixture.tree()).is_clean(), "{line}");

            fixture.append(DAEMON_AUDIO, line);
            let report = super::audio_row(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("audio accumulator, the channel fold")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// A knob read by name on the side that is supposed to be asking for it. `audio_source` owns
    /// the fallbacks — AAC-ELD for an unrecognised codec, the default rather than the floor for a
    /// bitrate that is not a number — and a second reader is a second set of them.
    #[test]
    fn a_daemon_that_reads_an_audio_knob_by_name_is_caught() {
        let fixture = Fixture::new("daemon-audio-knob");
        write_audio_row(&fixture);
        assert!(super::audio_row(&fixture.tree()).is_clean());

        fixture.append(
            DAEMON_AUDIO,
            "let raw = std::env::var(\"SLOPDESK_AUDIO_BITRATE\").ok();\n",
        );
        let report = super::audio_row(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("reads an audio knob by name")),
            "{report:?}"
        );
    }

    /// `docs/61` left the knob names in the daemon's own doc comments, explaining that they now
    /// honour `video-prefs.json`. `View::Code` is what keeps the explanation from reading as a
    /// second reader — this is the test that says so.
    #[test]
    fn a_doc_comment_naming_an_audio_knob_is_not_a_second_reader() {
        let fixture = Fixture::new("daemon-audio-prose");
        write_audio_row(&fixture);
        fixture.append(
            DAEMON_AUDIO,
            "/// `SLOPDESK_AUDIO_CODEC` and `SLOPDESK_AUDIO_BITRATE` now honour video-prefs.json.\n",
        );
        assert!(super::audio_row(&fixture.tree()).is_clean());
    }

    /// The ask going quiet is the failure this re-aim exists to make impossible: a daemon that
    /// stopped naming `audio_wire` is not one that stopped sending audio, it is one composing the
    /// eleven-byte header somewhere the crate's golden vectors do not reach.
    #[test]
    fn a_daemon_that_stopped_asking_the_audio_crates_is_caught() {
        let fixture = Fixture::new("daemon-audio-drained");
        write_audio_row(&fixture);
        assert!(super::audio_row(&fixture.tree()).is_clean());

        fixture.write(
            DAEMON_AUDIO,
            "\
use slopdesk_apple_audio::AacEldEncoder;
use slopdesk_video::audio_source::CHANNEL_COUNT;
",
        );
        let report = super::audio_row(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped naming audio_wire")),
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

    /// The daemon file the sending half's ask reads, and the drift every break-test seeds into it.
    const DAEMON_AUDIO: &str = "rust/slopdesk-videohostd/src/audio.rs";
    const DAEMON_AUDIO_ASKS: &str = "\
use slopdesk_apple_audio::AacEldEncoder;
use slopdesk_video::audio_source::{self, CHANNEL_COUNT, SAMPLE_RATE};
use slopdesk_video::audio_wire::{AudioStreamConfig, AudioWireFormat};
";

    /// The two surviving faces, each calling every door its `Claim::Doors` names and freeing its
    /// handle, plus the daemon that holds the sending half.
    fn write_audio_row(fixture: &Fixture) {
        fixture
            .write(DAEMON_AUDIO, DAEMON_AUDIO_ASKS)
            .write(
                "Sources/SlopDeskVideoClient/AudioStreamDecoder.swift",
                &format!(
                    "{DECODER_DOORS}deinit {{ if let handle {{ slopdesk_audio_decoder_free(handle) }} }}\n"
                ),
            )
            .write(
                "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift",
                &format!(
                    "{PLAYER_DOORS}deinit {{ if let handle {{ slopdesk_audio_player_free(handle) }} }}\n"
                ),
            );
    }

    const DECODER_DOORS: &str = "\
slopdesk_audio_decoder_new(x)
slopdesk_audio_decoder_free(x)
slopdesk_audio_decoder_decode(x)
";
    const PLAYER_DOORS: &str = "\
slopdesk_audio_player_new(x)
slopdesk_audio_player_free(x)
slopdesk_audio_player_enqueue(x)
slopdesk_audio_player_flush(x)
slopdesk_audio_player_start(x)
slopdesk_audio_player_stop(x)
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

    /// The resampler's Swift face was not ported — it was DELETED, into the thread that posts. A
    /// file back at that path cannot be a face over a door, because the doors went with it; it can
    /// only be a second copy of the drain, which is the exact drift this rule exists to catch.
    #[test]
    fn the_resamplers_swift_face_coming_back_is_caught() {
        let fixture = Fixture::new("scroll-resampler-return");
        write_scroll_laws(&fixture);
        assert!(super::scroll_laws(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoProtocol/ScrollResampler.swift",
            "public struct ScrollResampler {}\n",
        );
        let report = super::scroll_laws(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("ScrollResampler.swift is back")),
            "{report:?}"
        );
    }

    /// The reprojector's face, which DID stay — the half of the rule the ban above sits beside.
    fn write_scroll_laws(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskVideoProtocol/ScrollReprojector.swift",
            REPROJECTOR_DOORS,
        );
    }

    const REPROJECTOR_DOORS: &str = "\
slopdesk_scroll_reprojector_defaults()
slopdesk_scroll_reprojector_new(a, b)
slopdesk_scroll_reprojector_note_velocity(r, v)
slopdesk_scroll_reprojector_advance(r, t)
slopdesk_scroll_reprojector_note_real_frame(r)
slopdesk_scroll_reprojector_reset(r)
";
}
