//! The video seams either end owns — the cursor overlay, the two session machines, the input
//! normaliser, the scroll hint, the gesture policies, the streamable order and the send schedule.
//!
//! Ported from the deleted `check-supervisor.sh`. What these have in common is the failure they
//! share: each is small enough to re-type at the call site rather than call, and each is wrong in a
//! way that reads as "the remote machine feels off" rather than as a crash. A click half a
//! letterbox bar from the cursor, a modifier that stays latched, a retry that hellos a window that
//! is gone.
//!
//! ## The four seams whose HOST end stopped being Swift
//!
//! Five of the rules here are about the client and are untouched. The other four had a host face
//! too — the streamable arrangement, the scroll hint's encoder, the send lane and the session
//! machine — and `docs/61` deleted every one of those files. `rust/slopdesk-videohostd` links
//! `slopdesk-video` as an ordinary Rust dependency, so there is no `(ptr, len)` left to prove a
//! call across and no C door left to name; a message that still named one would be describing a
//! symbol that does not exist.
//!
//! So the door half of each is re-aimed rather than dropped: "the law is asked, not re-derived" is
//! now a [`Claim::MentionsUnder`] over the DAEMON's directory, naming the `slopdesk_video` module
//! the rule was always about. It reads the directory rather than a file because the daemon's
//! modules are still being split, and a claim pinned to a filename would go red on an ordinary
//! module divide — drift the rule was never about.
//!
//! The "no Swift brings this back" half is not restated here. It lives ONCE, tree-wide and at full
//! strength, in [`crate::rules::deleted_video_swift`]: no Swift target may DECLARE a video-host
//! type, which is stronger than the per-file bans it replaces. What each rule below keeps is the
//! ban that only makes sense here — the interior, respelled in the daemon's own language, because
//! Rust is now the one language it could come back in.

use crate::claim::{Claim, RUST, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The daemon that IS the GUI video host — `docs/61`.
///
/// A directory rather than a file for the reason the module doc gives: which module holds which of
/// the deleted faces is still moving, and the claim is about the HALF rather than about any file in
/// it.
const DAEMON: &str = "rust/slopdesk-videohostd";

/// The cursor OVERLAY placement, the progress GRAMMAR and the windowList ARRANGEMENT — three small
///
/// rules that were each written twice. Small is exactly why: a rule that is two multiplies, a
/// parser that is one split and a partition that is two lines are what get re-typed at the call
/// site instead of called, and each of the three has a failure the type checker cannot see. The
/// overlay must land on the pixel the input encoder targets — a multiply-add contracted on one
/// side moves the cursor away from where the click goes. The parser and the byte builders are one
/// grammar, so a second copy is how a spinner survives the command that raised it. And an
/// arrangement that drops the wrong side closes a pane on a window the host was mid-rescue on.
///
/// The first two are still asked from Swift, because the surfaces that ask them are the client's
/// compositor and the protocol library's progress state, and both are live. The arrangement is the
/// one that moved: its face was `StreamableWindowListOrder.swift`, `docs/61` deleted it, and the
/// daemon's discovery reply asks `capture_recovery::arrange_streamable_windows` directly.
///
/// Nothing about WHY the arrangement must be single was Swift's. `arrange_streamable_windows`
/// partitions on `is_on_screen` and keeps an off-screen window only when it has a title, and both
/// halves of that are load-bearing in opposite directions: an on-screen-only reply makes a freshly
/// picked minimized window resolve to nothing and closes the pane the host was mid-rescue for, and
/// admitting the untitled ones drowns the picker in panel services. A daemon that partitions the
/// list itself is that same second answer, typed in the one language left to type it in — and
/// cheaper to type there than it ever was in Swift, because the closure is three characters.
#[must_use]
pub fn cursor_lands_where_click_does(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: "Sources/SlopDeskVideoClient/ClientCursorCompositor.swift",
            entries: &[
                "slopdesk_cursor_layer_frame_scalar",
                "slopdesk_cursor_layer_frame_fit",
                "slopdesk_cursor_bottom_left_origin_y",
                "slopdesk_cursor_is_placeable",
                "slopdesk_cursor_rendered_shape_size",
            ],
            message: "Sources/SlopDeskVideoClient/ClientCursorCompositor.swift no longer calls {entry} — \
                      that rule is rust/slopdesk-video's or rust/slopdesk-wire's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskProtocol/ProgressState.swift",
            entries: &["slopdesk_osc_parse_progress"],
            message: "Sources/SlopDeskProtocol/ProgressState.swift no longer calls {entry} — that rule is \
                      rust/slopdesk-video's or rust/slopdesk-wire's",
        },
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["arrange_streamable_windows"],
            message: "the daemon stopped asking {entry} — the streamable order is rust/slopdesk-video's \
                      capture_recovery, and a host that stopped asking it has started deciding it (docs/61 \
                      §3)",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskVideoClient/ClientCursorCompositor.swift",
                "Sources/SlopDeskProtocol/ProgressState.swift",
            ],
            pattern: r#"AspectFit\.|parentHeight - topLeftY|isFinite,|split\(separator: ";""#,
            view: View::Code,
            message: "{files} re-derives the overlay placement or the progress grammar — those live in \
                      cursor_overlay.rs and osc.rs",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"partition\(.*on_screen|\(on_screen, *off_screen\)|filter\(\|[a-z_]+\| *!?[a-z_.]*is_on_screen|\btitle[a-z_.()]*\.is_empty\(\)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon splits the window list on screen-ness or on an empty title itself in \
                      {files} — that arrangement is capture_recovery.rs's arrange_streamable_windows, and a \
                      copy that drops the wrong side closes a pane on a window the mint path was mid-rescue \
                      on (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

/// A client video session decides once
///
/// `rust/slopdesk-video`'s `client_session` owns the lifecycle: what the client says to the host,
/// what it does with the answers, how fast it retries a lost hello, and when the reconnecting scrim
/// goes up. The machine crosses BY VALUE — every field is read on the Swift side, so there is
/// nothing for a handle to own — and each transition answers its effects through lent buffers. Two
/// failures are invisible to the type checker and both are outages. A second copy of the transition
/// table lets the refusal path REBUILD and re-hello forever on a window that is gone, which is the
/// mint-failure retry wedge. And a second hello ENCODER lets the two disagree by a byte on the
/// datagram that opens every session, which the golden vectors pin precisely because nothing else
/// would catch it.
#[must_use]
pub fn client_session_decides_once_hello(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            names: &[
                "slopdesk_video_client_new",
                "slopdesk_video_client_start",
                "slopdesk_video_client_resend_hello",
                "slopdesk_video_client_stop",
                "slopdesk_video_client_handle_control",
                "slopdesk_video_client_media_flowing",
                "slopdesk_video_client_requested_window_id",
                "slopdesk_video_client_hello_retry_delay",
                "slopdesk_stall_scrim_note_reconnecting",
                "slopdesk_stall_scrim_apply",
            ],
            message: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift no longer calls {entry} — \
                      that decision is rust/slopdesk-video's client_session",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift"],
            pattern: r"state = \.|helloMessage|\.sendControl\(\.|initialDelay \* Double|guard state == ",
            view: View::Code,
            message: "{files} re-derives a transition, the hello or the retry cadence — those live in \
                      client_session.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The same file holds six rules about the SIZE the pane was given, and `client_view` holds them
/// too.
///
/// Each is two or three sizes wide, which is exactly why they get re-typed at the call site instead
/// of called — and each has a failure the type checker cannot see. The pan gate and its clamp must
/// key off the same ZOOMED size or a zoomed-in window's overflow is unreachable, or only half
/// reachable. The adoption gates must reject an in-flight old-size frame or the cursor mis-scales
/// for a beat. And the debounce must rebase on a client-side snap WITHOUT minting an epoch, or the
/// snap echoes a resize request that re-triggers the snap: a feedback loop with the host's window
/// in it.
#[must_use]
pub fn pane_pans_scales_adopts_snaps(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            names: &[
                "slopdesk_client_is_navigable",
                "slopdesk_client_max_pan_offset",
                "slopdesk_client_video_scale",
                "slopdesk_frame_decodability",
                "slopdesk_resize_should_adopt",
                "slopdesk_resize_debounce_default",
                "slopdesk_resize_debounce_new",
                "slopdesk_resize_debounce_decide",
                "slopdesk_resize_debounce_note_requested",
                "slopdesk_resize_debounce_note_adopted",
                "slopdesk_snap_target_points",
                "slopdesk_snap_inferred_capture_scale",
                "slopdesk_snap_should_snap",
                "slopdesk_snap_epsilon",
            ],
            message: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift no longer calls {entry} — \
                      that rule is rust/slopdesk-video's client_view",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift"],
            pattern: r"zoom > pane\.|< 0\.02|>= epsilon|/ s,|lastEpoch &\+|width / decodedSize",
            view: View::Code,
            message: "{files} re-derives the pan clamp, the aspect gate, the snap or the epoch — those live \
                      in client_view.rs",
        },
    ];
    check_all(tree, &claims)
}

/// And the two accumulators the presentation buffer is sized by. `client_jitter` owns both. The
///
/// estimate must stay in the CLIENT's own clock — folding the host's send stamp in would re-admit
/// cross-machine skew and read it as jitter — and the controller must stay asymmetric: a symmetric
/// one thrashes a link sitting on the boundary, judder the user sees as the picture breathing.
#[must_use]
pub fn buffer_sized_by_one_estimate(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            names: &[
                "slopdesk_owd_jitter_new",
                "slopdesk_owd_jitter_note",
                "slopdesk_owd_jitter_micros",
                "slopdesk_adaptive_jitter_default_safety",
                "slopdesk_adaptive_jitter_default_cooldown",
                "slopdesk_adaptive_jitter_new",
                "slopdesk_adaptive_jitter_note_frame",
                "slopdesk_adaptive_jitter_note_underrun",
            ],
            message: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift no longer calls {entry} — \
                      that rule is rust/slopdesk-video's client_jitter",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift"],
            pattern: r"/ 16$|jitterSeconds \+=|shrinkRun|rounded\(\.up\)|1_000_000",
            view: View::Code,
            message: "{files} re-derives the jitter smoothing or the shrink hysteresis — those live in \
                      client_jitter.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The pointer inverse and the modifier latch, which `client_input` owns. The inverse is the one
///
/// piece of client math a second copy gets subtly WRONG rather than loudly broken: a click that
/// lands near the pixel under the cursor instead of on it reads as a remote machine that feels off,
/// and it is golden-pinned precisely because nothing else would catch a drift of half a letterbox
/// bar. The latch's failure is louder and worse — a swallowed key-up leaves ⌘ stuck on the host's
/// shared event source, so every later plain scroll is a ⌘-scroll and the remote page zooms.
#[must_use]
pub fn click_lands_where_cursor_no(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            names: &[
                "slopdesk_input_normalize",
                "slopdesk_input_next_tag",
                "slopdesk_modifier_latch_new",
                "slopdesk_modifier_latch_is_empty",
                "slopdesk_modifier_latch_is_down",
                "slopdesk_modifier_latch_note",
                "slopdesk_modifier_latch_capacity",
                "slopdesk_modifier_latch_drain",
            ],
            message: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift no longer calls {entry} — \
                      that rule is rust/slopdesk-video's client_input",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            names: &[
                "slopdesk_cursor_shape_default_interval",
                "slopdesk_cursor_shape_is_known",
                "slopdesk_cursor_shape_note_arrived",
                "slopdesk_cursor_shape_should_request",
            ],
            message: "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift no longer calls {entry} — \
                      the shape self-heal is client_input's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift"],
            pattern: r"nextTag &\+=|panLimit|invZoom|downKeyCodes|capsLockKeyCode|knownShapeIDs|lastRequested\[",
            view: View::Code,
            message: "{files} re-derives the pointer inverse, the latch or the shape budget — \
                      client_input.rs owns them",
        },
    ];
    check_all(tree, &claims)
}

/// The scroll hint is ONE encoding, spelled once
///
/// The host measures the true per-frame pixel shift and sends it as ten-thousandths of the frame
/// extent; the client turns it back into a velocity. Two ends, one scale — and a scale spelled on
/// both sides is a scale that drifts: change the host's rounding or the band's
/// inclusive-to-exclusive step alone and the picture warps by a hair on every scrolled frame, with
/// nothing failing. The cadence knob is the same shape of rule (an env string in, a tick interval
/// out), so it is guarded beside it.
///
/// The DECODING end is still the client's `VideoWindowPipeline.swift` and is unchanged. The
/// ENCODING end was `WindowCapturer.swift`, which `docs/61` deleted; the daemon's capture loop
/// measures through `scroll_shift::estimate_nv12` and packs through `scroll_reproject::ScrollHint`,
/// so the claim that the host asks rather than spells is now made of the daemon's directory.
///
/// The ban follows the encoder rather than the language. `ScrollHint::SCALE` is the only `10_000.0`
/// on this path in either half, and it is the only one that may exist: a daemon that multiplies a
/// fraction by ten thousand itself has re-derived the wire scale, and the two ends then disagree by
/// a rounding step that shows up as the picture warping on every scrolled frame and as nothing at
/// all in a test. The pattern is deliberately the ARITHMETIC — a bare `10_000.0` is an ordinary
/// number elsewhere in a media daemon, and banning it outright would fire on a threshold that has
/// nothing to do with this scale.
#[must_use]
pub fn scroll_hint_one_encoding_far(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["scroll_reproject", "scroll_shift"],
            message: "the daemon stopped asking {entry} — the per-frame shift estimate and the \
                      ten-thousandths packing are rust/slopdesk-video's, and the client's decoder reads the \
                      scale from the same module (docs/61 §3)",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift",
            names: &[
                "ScrollReprojector.Hint(",
                "hint.velocity(contentFps:",
                "hint.band()",
            ],
            message: "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift no longer decodes through \
                      ScrollReprojector.Hint — the two ends must share one scale",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/VideoWindowPipeline.swift"],
            pattern: r"10000\.0|10_000\.0",
            view: View::Code,
            message: "{files} respells the ten-thousandths scale — ScrollHint::SCALE is the only place it \
                      lives",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"[*/] *10_?000\.0|10_?000\.0 *[*/]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon scales by ten thousand itself in {files} — that scale is \
                      scroll_reproject.rs's ScrollHint::SCALE, and an encoder that rounds its own way warps \
                      the picture by a hair on every scrolled frame while both suites stay green (docs/61 \
                      §3)",
        },
        Claim::Names {
            path: "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift",
            needle: "slopdesk_input_motion_interval",
            message: "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift no longer reads its motion \
                      cadence through client_input.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The client's gesture policies are asked, not spelled
///
/// Four rules that belong to a view no test may instantiate — no Metal, no VT. The two stateful
/// ones cross BY VALUE because their owner is a `SwiftUI` view the framework copies at will, and a
/// handle it copied would be one accumulator serving two gestures; the denylist is a handle because
/// it carries a runtime extension SET, the swipe-nav config's reason exactly (docs/55 §4b).
#[must_use]
pub fn client_gesture_policies_are_asked(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskVideoClient/PinchZoomKeyPlanner.swift",
            needle: "slopdesk_pinch_planner_plan",
            message: "Sources/SlopDeskVideoClient/PinchZoomKeyPlanner.swift accumulates the pinch again — \
                      the residual and its step cap are client_gestures.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/PinchZoomKeyPlanner.swift"],
            pattern: r"stepThreshold|maxStepsPerEvent|residual [-+]=",
            view: View::Code,
            message: "{files} spells a pinch threshold again — the ladder is one number, over there",
        },
        Claim::Names {
            path: "Sources/SlopDeskVideoClient/ScrollRoutePinner.swift",
            needle: "slopdesk_scroll_pin_route",
            message: "Sources/SlopDeskVideoClient/ScrollRoutePinner.swift re-derives the route again — the \
                      pin is client_gestures.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/ScrollRoutePinner.swift"],
            pattern: r"scrollPhase == 1|scrollPhase == 128|scrollPhase == 8|momentumPhase == 3",
            view: View::Code,
            message: "{files} names a phase code again — which phase begins or ends a gesture is the pin's \
                      rule",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskVideoClient/BackgroundPointerPolicy.swift",
            names: &[
                "slopdesk_gesture_forwards_pointer",
                "slopdesk_gesture_background_click",
            ],
            message: "Sources/SlopDeskVideoClient/BackgroundPointerPolicy.swift no longer asks {entry} — a \
                      background surface's two gates are one rule",
        },
        Claim::Names {
            path: "Sources/SlopDeskVideoClient/PinchZeroPolicy.swift",
            needle: "slopdesk_zoom_reset_allowed",
            message: "Sources/SlopDeskVideoClient/PinchZeroPolicy.swift answers the denylist again — it is \
                      a handle, parsed once",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/PinchZeroPolicy.swift"],
            pattern: r#"unsafeAppNames|"Xcode""#,
            view: View::Code,
            message: "{files} names an unsafe app again — the list lives beside the chord rule it protects",
        },
    ];
    check_all(tree, &claims)
}

/// The paced-send schedule is one answer, and the datagrams stay put
///
/// The lane's sleeps and its abort generation are the runtime's and stay there; the chunk
/// boundaries, their ABSOLUTE deadlines and the skip-the-lane test are `send_pacing`'s. The frame's
/// datagrams never cross — a chunk names the caller's own array by index. What this pins hardest is
/// the one-shot test: the session used to spell it to pick the inline path and the lane spelled it
/// again to send in one shot, with a comment at the first promising it "mirrors" the second.
///
/// Both faces are deleted — `VideoSendLane.swift` and `SlopDeskVideoHostSession.swift` went with
/// `docs/61` — and the schedule they used to ask across a door is now
/// `slopdesk_video::send_pacing`, asked as a plain Rust call by the daemon's `sendlane`. The rule
/// is the same rule: `pace_plan` answers the boundaries and their deadlines, `may_send_inline`
/// answers whether the lane can be skipped at all, and neither is allowed a second author.
///
/// Deleting the Swift did not retire the failure, it made it cheaper. The two mirrored one-shot
/// tests drifted precisely because each was one comparison, and one comparison is easier to type
/// than to look up in any language — `docs/61 §3` records the same drift arriving from the other
/// direction, where the Swift computed pacing separately in two drains and the second could not see
/// `keyframe`, so it floored a recovery IDR at the delta pace floor. The daemon owns a `SendJob`
/// and passes `chunk_fragments` INTO it, which is asking; slicing a range by that field, or
/// comparing a count against it, is deciding.
#[must_use]
pub fn paced_send_schedule_one_answer(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["send_pacing", "pace_plan", "may_send_inline"],
            message: "the daemon stopped asking {entry} — the chunk boundaries, their absolute deadlines \
                      and the skip-the-lane test are rust/slopdesk-video's send_pacing, and a lane that \
                      stopped asking has started scheduling (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"gap_nanos *== *0|[+] *[a-z_.]*\bchunk_fragments|<= *[a-z_.]*\bchunk_fragments|let +single_shot",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon splits the job into chunks or mirrors the one-shot test itself in {files} \
                      — the boundaries and the inline test are send_pacing.rs's pace_plan and \
                      may_send_inline, and the two copies this rule was written for had already drifted \
                      once (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

/// The host session machine is the handshake's other end, and it holds no rule twice
///
/// `client_session` already owns the client's half of the hello negotiation; `session_state` is
/// the host's, and it has held the real machine all along. `VideoSessionLogic.swift` never had a
/// decision in it — `docs/61 §3` says so in as many words: `SLOPDESK_VIDEO_SESSION_*` and
/// `SlopDeskVideoSessionEffect` were C spellings of that module, the way `LiveCongestionController`
/// and `FPSGovernor` were spellings of `congestion` and `fps_governor`. Deleting the face deleted
/// the spellings and left the machine exactly where it was, so this rule points at the daemon that
/// composes it and asks the same question of it.
///
/// What it pins hardest is unchanged, because it was never about a language: the rules that were
/// spelled on BOTH sides. The stale-epoch test, the resize clamp, the two stream-settings bands
/// and the stream-id mint are each one comparison or one pair of numbers, which is exactly the size
/// of thing that gets re-typed rather than called. Their failures are all silent in the same way.
/// An epoch test that drifts by one applies a resize the client has already superseded, so the
/// capture settles at a size nobody asked for. A band re-typed a digit short accepts a wire value
/// the law would have rejected, and the encoder runs at a ceiling the negotiation never agreed to.
/// A stream id minted twice hands two sessions the same lane.
///
/// The stale-epoch half is banned as the `<=` COMPARISON rather than as the operand's name, and the
/// distinction is the whole rule. `is_stale_epoch` answers the PRE-commit question — may this
/// request be admitted — and its answer is `epoch <= last_applied`. A daemon that asks the same
/// question with `<` is asking a different one, which `session_resize.rs` does on purpose: by the
/// time an effect runs the machine has already committed that epoch, so only a strictly NEWER one
/// supersedes it. Banning the name would have made the correct post-commit guard unwritable and
/// pushed it back into the module that must not know about effect ordering; banning the comparison
/// leaves it alone and still catches the re-typing this rule exists for.
///
/// `protocol_version` is banned as a COMPARISON, not as a name: the daemon legitimately sets it
/// when it builds a hello, and only reading it to decide the handshake is a second answer.
/// Matching on `VideoControlMessage::Hello` is not banned at all — the daemon decodes and
/// constructs hellos on several paths, and the mint switch that must not be copied is already
/// [`crate::rules::video_host::host_mux`]'s `dispatch_decision` claim.
#[must_use]
pub fn host_session_machine_crosses_by(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["session_state", "VideoSessionStateMachine"],
            message: "the daemon stopped asking {entry} — the host session's law is rust/slopdesk-video's \
                      session_state, which held the real machine even while the Swift face existed, so a \
                      daemon that stopped composing it has started deciding (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"epoch *<= *[a-z_.()]*last|\blast_[a-z_]+(\(\))? *>= *[a-z_.()]*epoch|\bclamp_axis\b|\b(fps_cap_range|bitrate_ceiling_range)\b|\(5, *120\)|500_000, *200_000_000",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon spells a session rule again in {files} — the stale-epoch test, the capture \
                      clamp and both stream-settings bands are session_state.rs's is_stale_epoch, \
                      clamp_capture_size, FPS_CAP_RANGE and BITRATE_CEILING_RANGE, and a band re-typed a \
                      digit short runs the encoder at a ceiling the negotiation never agreed to (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"next_stream_id *\+=|protocol_version *==",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon decides the handshake again in {files} — minting a stream id and testing \
                      the wire version are session_state.rs's, and an id minted twice hands two sessions \
                      the same lane (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_cursor_lands_where_click_does(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoClient/ClientCursorCompositor.swift",
                "slopdesk_cursor_layer_frame_scalar(\nslopdesk_cursor_layer_frame_fit(\\
                 nslopdesk_cursor_bottom_left_origin_y(\nslopdesk_cursor_is_placeable(\\
                 nslopdesk_cursor_rendered_shape_size(\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskProtocol/ProgressState.swift",
                "slopdesk_osc_parse_progress(\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/discovery.rs",
                "use slopdesk_video::capture_recovery::arrange_streamable_windows;\n",
            );
    }

    #[test]
    fn cursor_lands_where_click_does_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("cursor-lands-where-click-does");
        write_cursor_lands_where_click_does(&fixture);
        assert!(super::cursor_lands_where_click_does(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoClient/ClientCursorCompositor.swift", "");
        assert!(!super::cursor_lands_where_click_does(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_cursor_lands_where_click_does(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/ClientCursorCompositor.swift",
            "AspectFit.\n",
        );
        assert!(!super::cursor_lands_where_click_does(&fixture.tree()).is_clean());
    }

    /// The arrangement's face is deleted, so the drift is a daemon that stopped composing the
    /// crate's answer — the discovery reply then decides the streamable order itself.
    #[test]
    fn a_daemon_that_stops_asking_the_streamable_order_is_caught() {
        let fixture = Fixture::new("streamable-order-unasked");
        write_cursor_lands_where_click_does(&fixture);
        assert!(super::cursor_lands_where_click_does(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-videohostd/src/discovery.rs",
            "use slopdesk_video::window_feed_host::includes_window;\n",
        );
        let report = super::cursor_lands_where_click_does(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped asking arrange_streamable_windows")),
            "{report:?}"
        );
    }

    /// The partition itself, re-typed in the daemon: three characters of closure, and a minimized
    /// window the mint path was rescuing stops being offered at all.
    #[test]
    fn a_streamable_partition_growing_back_in_the_daemon_is_caught() {
        let fixture = Fixture::new("streamable-order-partitioned");
        write_cursor_lands_where_click_does(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/discovery.rs",
            "let (on_screen, off_screen): (Vec<Candidate>, Vec<Candidate>) =\n    \
             candidates.into_iter().partition(|candidate| candidate.is_on_screen);\n",
        );
        let report = super::cursor_lands_where_click_does(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("splits the window list")),
            "{report:?}"
        );
    }

    fn write_client_session_decides_once_hello(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "slopdesk_video_client_new\nslopdesk_video_client_start\nslopdesk_video_client_resend_hello\\
             nslopdesk_video_client_stop\nslopdesk_video_client_handle_control\\
             nslopdesk_video_client_media_flowing\nslopdesk_video_client_requested_window_id\\
             nslopdesk_video_client_hello_retry_delay\nslopdesk_stall_scrim_note_reconnecting\\
             nslopdesk_stall_scrim_apply\nkept so the ban has a haystack\n",
        );
    }

    #[test]
    fn client_session_decides_once_hello_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("client-session-decides-once-hello");
        write_client_session_decides_once_hello(&fixture);
        assert!(super::client_session_decides_once_hello(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift", "");
        assert!(!super::client_session_decides_once_hello(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_client_session_decides_once_hello(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "state = .\n",
        );
        assert!(!super::client_session_decides_once_hello(&fixture.tree()).is_clean());
    }

    fn write_pane_pans_scales_adopts_snaps(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "slopdesk_client_is_navigable\nslopdesk_client_max_pan_offset\nslopdesk_client_video_scale\\
             nslopdesk_frame_decodability\nslopdesk_resize_should_adopt\nslopdesk_resize_debounce_default\\
             nslopdesk_resize_debounce_new\nslopdesk_resize_debounce_decide\\
             nslopdesk_resize_debounce_note_requested\nslopdesk_resize_debounce_note_adopted\\
             nslopdesk_snap_target_points\nslopdesk_snap_inferred_capture_scale\nslopdesk_snap_should_snap\\
             nslopdesk_snap_epsilon\nkept so the ban has a haystack\n",
        );
    }

    #[test]
    fn pane_pans_scales_adopts_snaps_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("pane-pans-scales-adopts-snaps");
        write_pane_pans_scales_adopts_snaps(&fixture);
        assert!(super::pane_pans_scales_adopts_snaps(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift", "");
        assert!(!super::pane_pans_scales_adopts_snaps(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_pane_pans_scales_adopts_snaps(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "zoom > pane.\n",
        );
        assert!(!super::pane_pans_scales_adopts_snaps(&fixture.tree()).is_clean());
    }

    fn write_buffer_sized_by_one_estimate(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "slopdesk_owd_jitter_new\nslopdesk_owd_jitter_note\nslopdesk_owd_jitter_micros\\
             nslopdesk_adaptive_jitter_default_safety\nslopdesk_adaptive_jitter_default_cooldown\\
             nslopdesk_adaptive_jitter_new\nslopdesk_adaptive_jitter_note_frame\\
             nslopdesk_adaptive_jitter_note_underrun\nkept so the ban has a haystack\n",
        );
    }

    #[test]
    fn buffer_sized_by_one_estimate_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("buffer-sized-by-one-estimate");
        write_buffer_sized_by_one_estimate(&fixture);
        assert!(super::buffer_sized_by_one_estimate(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift", "");
        assert!(!super::buffer_sized_by_one_estimate(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_buffer_sized_by_one_estimate(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "/ 16\n",
        );
        assert!(!super::buffer_sized_by_one_estimate(&fixture.tree()).is_clean());
    }

    fn write_click_lands_where_cursor_no(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "slopdesk_input_normalize\nslopdesk_input_next_tag\nslopdesk_modifier_latch_new\\
             nslopdesk_modifier_latch_is_empty\nslopdesk_modifier_latch_is_down\\
             nslopdesk_modifier_latch_note\nslopdesk_modifier_latch_capacity\nslopdesk_modifier_latch_drain\\
             nslopdesk_cursor_shape_default_interval\nslopdesk_cursor_shape_is_known\\
             nslopdesk_cursor_shape_note_arrived\nslopdesk_cursor_shape_should_request\nkept so the ban has \
             a haystack\n",
        );
    }

    #[test]
    fn click_lands_where_cursor_no_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("click-lands-where-cursor-no");
        write_click_lands_where_cursor_no(&fixture);
        assert!(super::click_lands_where_cursor_no(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift", "");
        assert!(!super::click_lands_where_cursor_no(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_click_lands_where_cursor_no(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "nextTag &+=\n",
        );
        assert!(!super::click_lands_where_cursor_no(&fixture.tree()).is_clean());
    }

    fn write_scroll_hint_one_encoding_far(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-videohostd/src/capture.rs",
                "use slopdesk_video::scroll_reproject::ScrollHint;\nuse \
                 slopdesk_video::scroll_shift::estimate_nv12;\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift",
                "ScrollReprojector.Hint(\nhint.velocity(contentFps:\nhint.band()\\
                 nslopdesk_input_motion_interval\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn scroll_hint_one_encoding_far_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("scroll-hint-one-encoding-far");
        write_scroll_hint_one_encoding_far(&fixture);
        assert!(super::scroll_hint_one_encoding_far(&fixture.tree()).is_clean());

        // The decoding end stopped asking — the client turned the hint back into a velocity itself.
        fixture.write("Sources/SlopDeskVideoClient/VideoWindowPipeline.swift", "");
        assert!(!super::scroll_hint_one_encoding_far(&fixture.tree()).is_clean());

        // And the scale it was banned from respelling, respelled on the client side.
        write_scroll_hint_one_encoding_far(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift",
            "10000.0\n",
        );
        assert!(!super::scroll_hint_one_encoding_far(&fixture.tree()).is_clean());
    }

    /// The encoding end is the daemon's now, so its drift is a capture loop that stopped measuring
    /// through the crate — at which point the two ends no longer share a module, only a number.
    #[test]
    fn a_daemon_that_stops_asking_the_scroll_estimate_is_caught() {
        let fixture = Fixture::new("scroll-hint-unasked");
        write_scroll_hint_one_encoding_far(&fixture);
        assert!(super::scroll_hint_one_encoding_far(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-videohostd/src/capture.rs",
            "use slopdesk_video::scroll_reproject::ScrollHint;\n",
        );
        let report = super::scroll_hint_one_encoding_far(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("scroll_shift")),
            "{report:?}"
        );
    }

    /// The wire scale, re-derived in the daemon's own arithmetic. Nothing fails; the picture warps
    /// by a rounding step on every scrolled frame.
    #[test]
    fn a_respelt_ten_thousandths_scale_in_the_daemon_is_caught() {
        let fixture = Fixture::new("scroll-hint-scale-respelt");
        write_scroll_hint_one_encoding_far(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/capture.rs",
            "let packed = (fraction * 10_000.0).round() as u16;\n",
        );
        let report = super::scroll_hint_one_encoding_far(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("scales by ten thousand")),
            "{report:?}"
        );
    }

    fn write_client_gesture_policies_are_asked(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoClient/PinchZoomKeyPlanner.swift",
                "slopdesk_pinch_planner_plan\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/ScrollRoutePinner.swift",
                "slopdesk_scroll_pin_route\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/BackgroundPointerPolicy.swift",
                "slopdesk_gesture_forwards_pointer\nslopdesk_gesture_background_click\nkept so the ban has \
                 a haystack\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/PinchZeroPolicy.swift",
                "slopdesk_zoom_reset_allowed\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn client_gesture_policies_are_asked_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("client-gesture-policies-are-asked");
        write_client_gesture_policies_are_asked(&fixture);
        assert!(super::client_gesture_policies_are_asked(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoClient/PinchZoomKeyPlanner.swift", "");
        assert!(!super::client_gesture_policies_are_asked(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_client_gesture_policies_are_asked(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/PinchZoomKeyPlanner.swift",
            "stepThreshold\n",
        );
        assert!(!super::client_gesture_policies_are_asked(&fixture.tree()).is_clean());
    }

    fn write_paced_send_schedule_one_answer(fixture: &Fixture) {
        fixture.write(
            "rust/slopdesk-videohostd/src/sendlane.rs",
            "use slopdesk_video::send_pacing::{SendJob, may_send_inline, pace_plan};\n",
        );
    }

    #[test]
    fn paced_send_schedule_one_answer_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("paced-send-schedule-one-answer");
        write_paced_send_schedule_one_answer(&fixture);
        assert!(super::paced_send_schedule_one_answer(&fixture.tree()).is_clean());

        // The lane stopped asking — a schedule grew back where the call used to be.
        fixture.write(
            "rust/slopdesk-videohostd/src/sendlane.rs",
            "use slopdesk_video::send_pacing::SendJob;\n",
        );
        let report = super::paced_send_schedule_one_answer(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("pace_plan")),
            "{report:?}"
        );
    }

    /// The chunk boundary, sliced by hand in the daemon. It is the same drift the two Swift copies
    /// had, now one `saturating_add` rather than one `min`.
    #[test]
    fn a_hand_split_chunk_boundary_in_the_daemon_is_caught() {
        let fixture = Fixture::new("paced-send-chunked-by-hand");
        write_paced_send_schedule_one_answer(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/sendlane.rs",
            "let end = index + job.chunk_fragments;\n",
        );
        let report = super::paced_send_schedule_one_answer(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("splits the job into chunks")),
            "{report:?}"
        );
    }

    /// The one-shot test, mirrored a second time. This is the exact pair that had already drifted
    /// once, and the mirror is cheaper to type in Rust than the comment promising it was accurate.
    #[test]
    fn a_mirrored_one_shot_test_in_the_daemon_is_caught() {
        let fixture = Fixture::new("paced-send-one-shot-mirror");
        write_paced_send_schedule_one_answer(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/sendlane.rs",
            "let single_shot = job.spec().gap_nanos == 0;\n",
        );
        assert!(!super::paced_send_schedule_one_answer(&fixture.tree()).is_clean());
    }

    fn write_host_session_machine_crosses_by(fixture: &Fixture) {
        fixture.write(
            "rust/slopdesk-videohostd/src/session.rs",
            "use slopdesk_video::session_state::{SessionEffect, VideoSessionStateMachine};\n",
        );
    }

    #[test]
    fn host_session_machine_crosses_by_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("host-session-machine-crosses-by");
        write_host_session_machine_crosses_by(&fixture);
        assert!(super::host_session_machine_crosses_by(&fixture.tree()).is_clean());

        // The daemon stopped composing the machine — so it has started being one.
        fixture.write(
            "rust/slopdesk-videohostd/src/session.rs",
            "use slopdesk_video::recovery_routing::VideoChannel;\n",
        );
        let report = super::host_session_machine_crosses_by(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("session_state")),
            "{report:?}"
        );
    }

    /// The stale-epoch test and a stream-settings band, re-typed in the daemon. Both are one
    /// comparison, both are silent, and one of them applies a resize the client has superseded.
    #[test]
    fn a_respelt_session_rule_in_the_daemon_is_caught() {
        for line in [
            "if epoch <= last_applied { return; }\n",
            "if state.last_resize_epoch() >= epoch { return; }\n",
            "let (low, high) = (5, 120);\n",
            "const BITRATE_BAND: (i64, i64) = (500_000, 200_000_000);\n",
        ] {
            let fixture = Fixture::new("host-session-rule-respelt");
            write_host_session_machine_crosses_by(&fixture);
            assert!(
                super::host_session_machine_crosses_by(&fixture.tree()).is_clean(),
                "{line}"
            );

            fixture.append("rust/slopdesk-videohostd/src/session.rs", line);
            let report = super::host_session_machine_crosses_by(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("spells a session rule")),
                "{line}: {report:?}"
            );
        }
    }

    /// The other side of that ban, and the reason it is written as a comparison.
    ///
    /// `session_resize.rs`'s post-commit guard is a STRICT `<` against the same field, because the
    /// machine has already committed this epoch by the time the effect runs and only a newer one
    /// supersedes it. That is not the pre-commit admission test and must stay writable in the
    /// daemon; a ban on the operand's name would have made it red.
    #[test]
    fn the_post_commit_supersede_guard_is_not_a_respelt_stale_test() {
        let fixture = Fixture::new("host-session-post-commit");
        write_host_session_machine_crosses_by(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/session.rs",
            "fn resize_is_current(epoch: u32, last_applied: u32) -> bool { epoch < last_applied }\n",
        );
        assert!(super::host_session_machine_crosses_by(&fixture.tree()).is_clean());
    }

    /// The mint, taken back into the daemon. Two sessions on one lane, and no error anywhere.
    #[test]
    fn a_stream_id_minted_in_the_daemon_is_caught() {
        let fixture = Fixture::new("host-session-mint");
        write_host_session_machine_crosses_by(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/session.rs",
            "self.next_stream_id += 1;\n",
        );
        let report = super::host_session_machine_crosses_by(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("decides the handshake")),
            "{report:?}"
        );
    }

    /// A `MentionsUnder` over a directory that stripped to nothing must FAIL rather than pass. A
    /// drained daemon satisfies every ban here and answers no ask at all, which is the
    /// healthiest-looking result these rules can print and means nothing.
    #[test]
    fn a_drained_daemon_cannot_satisfy_the_host_asks() {
        let fixture = Fixture::new("video-seams-daemon-drained");
        write_cursor_lands_where_click_does(&fixture);
        write_scroll_hint_one_encoding_far(&fixture);
        fixture
            .remove("rust/slopdesk-videohostd/src/discovery.rs")
            .remove("rust/slopdesk-videohostd/src/capture.rs");
        assert!(!super::cursor_lands_where_click_does(&fixture.tree()).is_clean());
        assert!(!super::scroll_hint_one_encoding_far(&fixture.tree()).is_clean());
        assert!(!super::paced_send_schedule_one_answer(&fixture.tree()).is_clean());
        assert!(!super::host_session_machine_crosses_by(&fixture.tree()).is_clean());
    }
}
