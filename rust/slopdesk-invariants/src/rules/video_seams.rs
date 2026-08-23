//! The client's own video seams — the cursor overlay, the session machine, the input
//! normaliser, the scroll hint, the gesture policies, and the two send schedules.
//!
//! Ported from `scripts/check-supervisor.sh`. What these have in common is the failure they share:
//! each is small enough to re-type at the call site rather than call, and each is wrong in a way
//! that reads as "the remote machine feels off" rather than as a crash. A click half a letterbox
//! bar from the cursor, a modifier that stays latched, a retry that hellos a window that is gone.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The cursor OVERLAY placement, the progress GRAMMAR and the windowList ARRANGEMENT — three small
///
/// rules that were each written twice. Small is exactly why: a rule that is two multiplies, a
/// parser that is one split and a filter that is one line are what get re-typed at the call site
/// instead of called, and each of the three has a failure the type checker cannot see. The overlay
/// must land on the pixel the input encoder targets — a contracted multiply-add on one side moves
/// the cursor away from where the click goes. The parser and the byte builders are one grammar, so
/// a second copy is how a spinner survives the command that raised it. And an arrangement that
/// drops the wrong side closes a pane on a window the host was mid-rescue on.
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
        Claim::Doors {
            path: "Sources/SlopDeskVideoHost/StreamableWindowListOrder.swift",
            entries: &["slopdesk_arrange_streamable_windows"],
            message: "Sources/SlopDeskVideoHost/StreamableWindowListOrder.swift no longer calls {entry} — \
                      that rule is rust/slopdesk-video's or rust/slopdesk-wire's",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskVideoClient/ClientCursorCompositor.swift",
                "Sources/SlopDeskProtocol/ProgressState.swift",
                "Sources/SlopDeskVideoHost/StreamableWindowListOrder.swift",
            ],
            pattern: r#"AspectFit\.|parentHeight - topLeftY|isFinite,|split\(separator: ";"|windows\.filter"#,
            view: View::Code,
            message: "{files} re-derives the overlay placement, the progress grammar or the arrangement — \
                      those live in cursor_overlay.rs, osc.rs and capture_recovery.rs",
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
#[must_use]
pub fn scroll_hint_one_encoding_far(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskVideoHost/WindowCapturer.swift",
            needle: "ScrollReprojector.Hint(",
            message: "Sources/SlopDeskVideoHost/WindowCapturer.swift no longer encodes through \
                      ScrollReprojector.Hint — that scale is scroll_reproject.rs",
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
            paths: &[
                "Sources/SlopDeskVideoHost/WindowCapturer.swift",
                "Sources/SlopDeskVideoClient/VideoWindowPipeline.swift",
            ],
            pattern: r"10000\.0|10_000\.0",
            view: View::Code,
            message: "{files} respells the ten-thousandths scale — ScrollHint::SCALE is the only place it \
                      lives",
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
/// The lane's sleeps and its abort generation are Swift concurrency and stay there; the chunk
/// boundaries, their ABSOLUTE deadlines and the skip-the-lane test are `send_pacing`'s. The frame's
/// datagrams never cross — a chunk names the caller's own array by index. What this pins hardest is
/// the one-shot test: the session used to spell it to pick the inline path and the lane spelled it
/// again to send in one shot, with a comment at the first promising it "mirrors" the second.
#[must_use]
pub fn paced_send_schedule_one_answer(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoHost/VideoSendLane.swift",
            names: &["slopdesk_send_pace_plan", "slopdesk_send_may_inline"],
            message: "Sources/SlopDeskVideoHost/VideoSendLane.swift no longer asks {entry} — the schedule \
                      is send_pacing.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/VideoSendLane.swift"],
            pattern: r"gapNanos == 0|min\(i \+ job\.chunkFragments|count <= job\.chunkFragments",
            view: View::Code,
            message: "{files} splits the job into chunks again — the boundaries and the one-shot test are \
                      one answer",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/SlopDeskVideoHostSession.swift"],
            pattern: r"let singleShot",
            view: View::Code,
            message: "{files} mirrors the lane's one-shot test again — ask trySendInline, which asks the \
                      door",
        },
    ];
    check_all(tree, &claims)
}

/// The host session machine is the handshake's other end, and it holds no rule twice
///
/// `client_session` already crosses the client's half of the hello negotiation; `session_state` is
/// the host's, and it crosses the same way — the machine by value (nine scalars an actor field
/// copies), the acknowledgement as its ENCODED BYTES, and the three size resolvers as pre-resolved
/// ANSWERS rather than callbacks, because exactly one can matter per message and the message's own
/// variant decides which. What this pins hardest is the rules that were spelled on BOTH sides: the
/// accept/reject path, the resize clamp, the stale-epoch test and the two stream-settings bands.
#[must_use]
pub fn host_session_machine_crosses_by(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            names: &[
                "slopdesk_video_session_new",
                "slopdesk_video_session_start",
                "slopdesk_video_session_stop",
                "slopdesk_video_session_control",
                "slopdesk_video_session_media_flowing",
                "slopdesk_video_session_clamp_capture",
                "slopdesk_video_session_stale_epoch",
                "slopdesk_video_fps_cap_from_wire",
                "slopdesk_video_bitrate_ceiling_from_wire",
                "slopdesk_video_effective_fps",
            ],
            message: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift no longer asks {entry} — the host \
                      session's law is session_state.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/VideoSessionLogic.swift"],
            pattern: r"epoch <= lastApplied|clampAxis|fpsCapRange|bitrateCeilingRange",
            view: View::Code,
            message: "{files} spells a session rule again — the epoch test, the clamp and both bands are \
                      one answer",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/VideoSessionLogic.swift"],
            pattern: r"case \.hello|nextStreamID \+= 1|protocolVersion == ",
            view: View::Code,
            message: "{files} decides the handshake again — accepting, rejecting and minting a stream id \
                      are the law's",
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
                "Sources/SlopDeskVideoHost/StreamableWindowListOrder.swift",
                "slopdesk_arrange_streamable_windows(\nkept so the ban has a haystack\n",
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
                "Sources/SlopDeskVideoHost/WindowCapturer.swift",
                "ScrollReprojector.Hint(\nkept so the ban has a haystack\n",
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

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoHost/WindowCapturer.swift", "");
        assert!(!super::scroll_hint_one_encoding_far(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_scroll_hint_one_encoding_far(&fixture);
        fixture.append("Sources/SlopDeskVideoHost/WindowCapturer.swift", "10000.0\n");
        assert!(!super::scroll_hint_one_encoding_far(&fixture.tree()).is_clean());
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
        fixture
            .write(
                "Sources/SlopDeskVideoHost/VideoSendLane.swift",
                "slopdesk_send_pace_plan\nslopdesk_send_may_inline\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskVideoHost/SlopDeskVideoHostSession.swift",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn paced_send_schedule_one_answer_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("paced-send-schedule-one-answer");
        write_paced_send_schedule_one_answer(&fixture);
        assert!(super::paced_send_schedule_one_answer(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoHost/VideoSendLane.swift", "");
        assert!(!super::paced_send_schedule_one_answer(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_paced_send_schedule_one_answer(&fixture);
        fixture.append("Sources/SlopDeskVideoHost/VideoSendLane.swift", "gapNanos == 0\n");
        assert!(!super::paced_send_schedule_one_answer(&fixture.tree()).is_clean());
    }

    fn write_host_session_machine_crosses_by(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            "slopdesk_video_session_new\nslopdesk_video_session_start\nslopdesk_video_session_stop\\
             nslopdesk_video_session_control\nslopdesk_video_session_media_flowing\\
             nslopdesk_video_session_clamp_capture\nslopdesk_video_session_stale_epoch\\
             nslopdesk_video_fps_cap_from_wire\nslopdesk_video_bitrate_ceiling_from_wire\\
             nslopdesk_video_effective_fps\nkept so the ban has a haystack\n",
        );
    }

    #[test]
    fn host_session_machine_crosses_by_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("host-session-machine-crosses-by");
        write_host_session_machine_crosses_by(&fixture);
        assert!(super::host_session_machine_crosses_by(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoHost/VideoSessionLogic.swift", "");
        assert!(!super::host_session_machine_crosses_by(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_host_session_machine_crosses_by(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            "epoch <= lastApplied\n",
        );
        assert!(!super::host_session_machine_crosses_by(&fixture.tree()).is_clean());
    }
}
