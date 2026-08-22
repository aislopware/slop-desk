//! The host's mux, its window feed, the four smallest send-path decisions, the four bounded
//! accumulators and the aspect geometry.
//!
//! Ported from `scripts/check-supervisor.sh`. What every rule here guards is a verdict that must be
//! SINGLE because two surfaces ask it: the router's lane sets and the client's, the picker's
//! inclusion test and the feed's, the encoder's budget and the pacer's. A second copy agrees on the
//! easy cases and diverges exactly where nobody is watching.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const SWIFT_MUX_ROUTER: &str = "Sources/SlopDeskVideoHost/Mux/VideoMuxRouter.swift";
const SWIFT_MUX_FLOWS: &str = "Sources/SlopDeskVideoHost/Mux/MuxFlowTable.swift";
const SWIFT_MUX_BYE: &str = "Sources/SlopDeskVideoHost/Mux/UnboundLaneByePolicy.swift";

/// The HOST MUX's three deciders — `mux_routing` and `mux_flow`.
///
/// Two handles and a question: the router's lane sets and the flow table's stamps are large and
/// read one verdict at a time, and the bye policy asks about one payload. What makes the port
/// matter is that all three guard the same failure — a datagram from a session that no longer
/// exists reaching one that does.
///
/// The router's prune is named because it is the subtle half: ids are monotonic, so the cap must
/// drop the ids far BELOW the wrap-aware high-water mark — a second copy that pruned by insertion
/// order would evict a lane whose in-flight datagrams are still arriving, and route a dead
/// generation's bytes into a live session.
///
/// The flow table's reference snapshot is named because rule 2 must run AFTER rule 1: a stale stamp
/// that swept first stops protecting the flow it pointed at, and a copy that took the snapshot
/// early would keep an orphan alive forever.
///
/// The bye policy's control decode is named because a second reader of that grammar is how a
/// session-LESS discovery request starts earning a bye — which would tell a client with no session
/// that its session ended.
#[must_use]
pub fn host_mux(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_MUX_ROUTER,
            entries: &[
                "slopdesk_mux_router_new",
                "slopdesk_mux_router_free",
                "slopdesk_mux_router_admit",
                "slopdesk_mux_router_retire",
                "slopdesk_mux_router_begin_drain",
                "slopdesk_mux_router_end_drain",
                "slopdesk_mux_router_is_admitted",
                "slopdesk_mux_router_is_draining",
                "slopdesk_mux_router_route",
                "slopdesk_mux_bootstrap_action",
            ],
            message: "Sources/SlopDeskVideoHost/Mux/VideoMuxRouter.swift no longer calls {entry} — the mux \
                      routing law is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_MUX_ROUTER,
            pattern: r"retiredCap|retiredPruneWindow|distanceWrapped|admitted\.insert|retired\.insert|draining\.insert",
            view: View::Code,
            message: "Sources/SlopDeskVideoHost/Mux/VideoMuxRouter.swift spells the lane sets or the \
                      retired bound again — those live in mux_routing.rs",
        },
        Claim::Doors {
            path: SWIFT_MUX_FLOWS,
            entries: &[
                "slopdesk_mux_flows_new",
                "slopdesk_mux_flows_free",
                "slopdesk_mux_flows_accept",
                "slopdesk_mux_flows_note_inbound",
                "slopdesk_mux_flows_stamp_media_reply",
                "slopdesk_mux_flows_stamp_media_bootstrap",
                "slopdesk_mux_flows_stamp_cursor_reply",
                "slopdesk_mux_flows_retire_lane",
                "slopdesk_mux_flows_did_reset",
                "slopdesk_mux_flows_tracks",
                "slopdesk_mux_flows_reap",
                "slopdesk_mux_flows_remove_all",
                "slopdesk_mux_flows_media_reply",
                "slopdesk_mux_flows_cursor_reply",
                "slopdesk_mux_flows_count",
            ],
            message: "Sources/SlopDeskVideoHost/Mux/MuxFlowTable.swift no longer calls {entry} — the flow \
                      bookkeeping is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_MUX_FLOWS,
            pattern: r"mediaReply\[|cursorReply\[|unadmittedStampAt|flowLastInbound|referenced\.insert|now - lastInbound",
            view: View::Code,
            message: "Sources/SlopDeskVideoHost/Mux/MuxFlowTable.swift spells the stamp maps or the reap \
                      rules again — those live in mux_flow.rs",
        },
        Claim::Doors {
            path: SWIFT_MUX_BYE,
            entries: &[
                "slopdesk_mux_warrants_bye",
                "slopdesk_mux_bye_limiter_new",
                "slopdesk_mux_bye_limiter_free",
                "slopdesk_mux_bye_limiter_admit",
            ],
            message: "Sources/SlopDeskVideoHost/Mux/UnboundLaneByePolicy.swift no longer calls {entry} — \
                      the unbound-lane bye policy is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: SWIFT_MUX_BYE,
            pattern: r"VideoControlMessage\.decode|case \.keepalive|lastSent\[|listSystemDialogs",
            view: View::Code,
            message: "Sources/SlopDeskVideoHost/Mux/UnboundLaneByePolicy.swift decodes control or spells \
                      the limiter map again — those live in mux_flow.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The HOST WINDOW FEED — `window_feed_host`.
///
/// Four Swift files against one crate module: what to list, how to pack it, who to push it to, and
/// when. The inclusion verdict is the one that has to be single, because the PICKER and the FEED
/// both ask it — two copies would show a window in one surface and not the other.
///
/// The AX evidence gate is named because it is the whole reason the rail is not full of phantoms:
/// an off-screen window is listable only on evidence, and a copy that forgot would drown the feed
/// in tab caches and panel services. The zero-record chunk is named because an empty desktop is a
/// real snapshot: a copy that emitted nothing would leave the client waiting for a generation that
/// never assembles. The structural skeleton is named because WHICH bits count as structural is the
/// whole coalescing contract: a copy that called a title structural would put a typing window into
/// permanent 4 Hz burst.
///
/// The record marshalling is spelled ONCE, on the protocol side, and both the client assembler and
/// the host cache use it. A fourth hand-rolled row layout is how the arena offsets drift.
#[must_use]
pub fn window_feed(tree: &Tree) -> Report {
    const BUILD: &str = "Sources/SlopDeskVideoHost/WindowFeed/WindowFeedSnapshotBuilder.swift";
    const CACHE: &str = "Sources/SlopDeskVideoHost/WindowFeed/WindowFeedCache.swift";
    const PUSH: &str = "Sources/SlopDeskVideoHost/WindowFeed/WindowFeedSubscribers.swift";
    const ROWS: &str = "Sources/SlopDeskVideoProtocol/HostWindowRecordRows.swift";

    let claims = [
        Claim::Doors {
            path: BUILD,
            entries: &[
                "slopdesk_feed_constants",
                "slopdesk_feed_includes",
                "slopdesk_feed_snapshot",
            ],
            message: "Sources/SlopDeskVideoHost/WindowFeed/WindowFeedSnapshotBuilder.swift no longer calls \
                      {entry} — the listing law is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: BUILD,
            pattern: r"excludedSystemApps|junkTitlesByOwner|Window Server|focusedAssigned|isAXListed \|\||= 80$|truncatedUTF8",
            view: View::Code,
            message: "WindowFeedSnapshotBuilder.swift spells the exclusions, the evidence gate or a cap \
                      again — those live in window_feed_host.rs",
        },
        Claim::Doors {
            path: CACHE,
            entries: &[
                "slopdesk_feed_chunks",
                "slopdesk_feed_cache_new",
                "slopdesk_feed_cache_free",
                "slopdesk_feed_cache_generation",
                "slopdesk_feed_cache_records",
                "slopdesk_feed_cache_needs_rebuild",
                "slopdesk_feed_cache_fold",
                "slopdesk_feed_cache_reply",
            ],
            message: "Sources/SlopDeskVideoHost/WindowFeed/WindowFeedCache.swift no longer calls {entry} — \
                      the cache and the packer are rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: CACHE,
            pattern: r"generation &\+= 1|currentBytes|feedRecordBytesPerChunk|groups\.append|builtAt",
            view: View::Code,
            message: "WindowFeedCache.swift spells the generation bump or the packer again — those live in \
                      window_feed_host.rs",
        },
        Claim::Doors {
            path: PUSH,
            entries: &[
                "slopdesk_feed_subscribers_new",
                "slopdesk_feed_subscribers_free",
                "slopdesk_feed_subscribers_count",
                "slopdesk_feed_subscribers_renew",
                "slopdesk_feed_subscribers_reap",
                "slopdesk_feed_subscribers_live",
                "slopdesk_feed_classify",
                "slopdesk_feed_policy_new",
                "slopdesk_feed_should_fold",
                "slopdesk_feed_tick_interval",
            ],
            message: "Sources/SlopDeskVideoHost/WindowFeed/WindowFeedSubscribers.swift no longer calls \
                      {entry} — the push policy is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: PUSH,
            pattern: r"structuralBits|func skeleton|burstUntil|lastVolatileFold|lastRenewal|= 0\.25|= 3\.0",
            view: View::Code,
            message: "WindowFeedSubscribers.swift spells the differ, a cadence or the subscriber map again \
                      — those live in window_feed_host.rs",
        },
        Claim::Names {
            path: ROWS,
            needle: "func row(into arena",
            message: "HostWindowRecordRows.swift no longer vends `func row(into arena` — the one record \
                      marshalling lives there",
        },
        Claim::Names {
            path: ROWS,
            needle: "static func of(_ row",
            message: "HostWindowRecordRows.swift no longer vends `static func of(_ row` — the one record \
                      marshalling lives there",
        },
        Claim::Names {
            path: ROWS,
            needle: "static func rows(_ records",
            message: "HostWindowRecordRows.swift no longer vends `static func rows(_ records` — the one \
                      record marshalling lives there",
        },
        Claim::Lacks {
            path: "Sources/SlopDeskVideoProtocol/WindowFeedAssembler.swift",
            pattern: r"private static func row\(",
            view: View::Code,
            message: "WindowFeedAssembler.swift grew its own row layout back — it belongs to \
                      HostWindowRecordRows.swift",
        },
    ];
    check_all(tree, &claims)
}

/// The four smallest SEND-PATH decisions — `frame_gate`, `live_bitrate` and `capture_recovery`.
///
/// They are pinned precisely BECAUSE they are small: a rule that is one `guard` and a rung ladder
/// that is one ternary are what get re-typed at the call site instead of called, and a suppression
/// rule that forgot one obligation freezes a client on a frame it is waiting for.
///
/// The density and the floor are named because the encoder's QP ceiling is sized against the budget
/// they produce: a second copy that rounds differently drops frames on one machine and not the
/// other.
#[must_use]
pub fn send_path_decisions(tree: &Tree) -> Report {
    const SUPPRESS: &str = "Sources/SlopDeskVideoHost/StaticFrameSuppressionDecider.swift";
    const STILLNESS: &str = "Sources/SlopDeskVideoHost/StillnessCrispDecider.swift";
    const BITRATE: &str = "Sources/SlopDeskVideoHost/LiveBitratePolicy.swift";
    const RUNG: &str = "Sources/SlopDeskVideoHost/CaptureRegionRecovery.swift";

    let claims = [
        Claim::Doors {
            path: SUPPRESS,
            entries: &["slopdesk_should_suppress_static_frame"],
            message: "StaticFrameSuppressionDecider.swift no longer calls {entry} — that decision is \
                      rust/slopdesk-video's",
        },
        Claim::Doors {
            path: STILLNESS,
            entries: &[
                "slopdesk_stillness_crisp_new",
                "slopdesk_stillness_crisp_on_frame",
                "slopdesk_stillness_crisp_should_fire",
                "slopdesk_stillness_crisp_note_fired",
            ],
            message: "StillnessCrispDecider.swift no longer calls {entry} — that decision is \
                      rust/slopdesk-video's",
        },
        Claim::Doors {
            path: BITRATE,
            entries: &[
                "slopdesk_live_bitrate_defaults",
                "slopdesk_live_bitrate_bits_per_pixel",
                "slopdesk_live_bitrate_target",
            ],
            message: "LiveBitratePolicy.swift no longer calls {entry} — that decision is \
                      rust/slopdesk-video's",
        },
        Claim::Doors {
            path: RUNG,
            entries: &["slopdesk_capture_failure_action"],
            message: "CaptureRegionRecovery.swift no longer calls {entry} — that decision is \
                      rust/slopdesk-video's",
        },
        Claim::NoneOf {
            paths: &[SUPPRESS, STILLNESS, BITRATE, RUNG],
            pattern: r"guard hashEqualToLast|consecutiveEqual \+= 1|firedThisRest = true|= 0\.25|1_000_000|isFallbackRebuild \?",
            view: View::Code,
            message: "a send-path decision is spelled in Swift again ({files}) — those live in \
                      frame_gate.rs, live_bitrate.rs and capture_recovery.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The four bounded ACCUMULATORS — `ltr`, `recovery_dedupe`, `idle_reap` and `retransmit_ring`.
///
/// All handles, because each holds across calls what the near side barely reads. The LTR gate is
/// the load-bearing one: a second "has anything been acked" that drifts open issues a refresh
/// against a reference the client never held — corruption until the next IDR, with no error.
///
/// The ring's hand-parsed header offset is named because that is exactly how the Swift copy read a
/// fragment index — a byte offset that silently mis-selects the moment the wire header moves.
#[must_use]
pub fn accumulators(tree: &Tree) -> Report {
    const LTR: &str = "Sources/SlopDeskVideoHost/LTRController.swift";
    const DEDUPE: &str = "Sources/SlopDeskVideoHost/RecoveryRequestDeduper.swift";
    const REAPER: &str = "Sources/SlopDeskVideoHost/IdleReapDecider.swift";
    const RING: &str = "Sources/SlopDeskVideoHost/RetransmitRing.swift";

    let claims = [
        Claim::Doors {
            path: LTR,
            entries: &[
                "slopdesk_ltr_caps",
                "slopdesk_ltr_new",
                "slopdesk_ltr_free",
                "slopdesk_ltr_record",
                "slopdesk_ltr_ack",
                "slopdesk_ltr_reset",
                "slopdesk_ltr_decision",
                "slopdesk_ltr_frames",
                "slopdesk_ltr_acked_tokens",
            ],
            message: "LTRController.swift no longer calls {entry} — that accumulator is \
                      rust/slopdesk-video's",
        },
        Claim::Doors {
            path: DEDUPE,
            entries: &[
                "slopdesk_recovery_dedupe_defaults",
                "slopdesk_recovery_dedupe_new",
                "slopdesk_recovery_dedupe_free",
                "slopdesk_recovery_dedupe_admit",
            ],
            message: "RecoveryRequestDeduper.swift no longer calls {entry} — that accumulator is \
                      rust/slopdesk-video's",
        },
        Claim::Doors {
            path: REAPER,
            entries: &[
                "slopdesk_idle_reaper_new",
                "slopdesk_idle_reaper_free",
                "slopdesk_idle_reaper_note_inbound",
                "slopdesk_idle_reaper_reap",
                "slopdesk_idle_reaper_forget",
                "slopdesk_idle_reaper_record",
            ],
            message: "IdleReapDecider.swift no longer calls {entry} — that accumulator is \
                      rust/slopdesk-video's",
        },
        Claim::Doors {
            path: RING,
            entries: &[
                "slopdesk_retransmit_ring_new",
                "slopdesk_retransmit_ring_free",
                "slopdesk_retransmit_ring_record",
                "slopdesk_retransmit_ring_select",
                "slopdesk_retransmit_ring_take",
            ],
            message: "RetransmitRing.swift no longer calls {entry} — that accumulator is \
                      rust/slopdesk-video's",
        },
        Claim::NoneOf {
            paths: &[LTR, DEDUPE, REAPER, RING],
            pattern: r"frameOrder\.append|acknowledgedTokens\.append|frameTokenCap = |entries\.removeAll|windowSeconds > 0|flows\[|byFrame\[|startIndex \+ 8",
            view: View::Code,
            message: "a host accumulator's interior is spelled in Swift again ({files}) — those live in \
                      ltr.rs, recovery_dedupe.rs, idle_reap.rs and retransmit_ring.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The ASPECT GEOMETRY and the virtual-display throttle — `geometry` and `capture_recovery`.
///
/// `view_point` is the exact inverse of the input encoder's normalise, so a second copy that
/// contracts one multiply-add lands the cursor overlay a pixel off the click it is drawn for — on
/// one machine and not the other. It is golden-pinned for exactly that reason.
///
/// `Double.maximum` is named in the ban because it is the NaN-ignoring form the crate's `f64::max`
/// requires — a plain `max` here would silently poison the multi-monitor pick instead of clamping
/// it.
#[must_use]
pub fn geometry(tree: &Tree) -> Report {
    const GEOM: &str = "Sources/SlopDeskVideoProtocol/Geometry.swift";
    const VD: &str = "Sources/SlopDeskVideoHost/VirtualDisplayRecoveryPolicy.swift";

    let claims = [
        Claim::Doors {
            path: GEOM,
            entries: &[
                "slopdesk_geometry_intersection_area",
                "slopdesk_geometry_displayed_video_rect",
                "slopdesk_geometry_view_point",
            ],
            message: "Sources/SlopDeskVideoProtocol/Geometry.swift no longer calls {entry} — that geometry \
                      is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: VD,
            entries: &[
                "slopdesk_vd_recreate_cooldown",
                "slopdesk_vd_recreate_should_attempt",
                "slopdesk_vd_channels_to_disconnect",
            ],
            message: "VirtualDisplayRecoveryPolicy.swift no longer calls {entry} — that geometry is \
                      rust/slopdesk-video's",
        },
        Claim::NoneOf {
            paths: &[GEOM, VD],
            pattern: r"Double\.maximum|Double\.minimum|panLimit|invZoom|intersection\(|TimeInterval = 30",
            view: View::Code,
            message: "the aspect geometry or the VD throttle is spelled in Swift again ({files}) — those \
                      live in geometry.rs and capture_recovery.rs",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The failure all three mux deciders guard: a datagram from a session that no longer exists
    /// reaching one that does. A Swift lane set is the second answer that lets it happen.
    #[test]
    fn a_swift_lane_set_growing_back_is_caught() {
        let fixture = Fixture::new("mux-lane-set");
        fixture
            .write(super::SWIFT_MUX_ROUTER, ROUTER_DOORS)
            .write(super::SWIFT_MUX_FLOWS, FLOWS_DOORS)
            .write(super::SWIFT_MUX_BYE, BYE_DOORS);
        assert!(super::host_mux(&fixture.tree()).is_clean());

        fixture.write(
            super::SWIFT_MUX_ROUTER,
            &format!("{ROUTER_DOORS}admitted.insert(lane)\n"),
        );
        let report = super::host_mux(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("lane sets")),
            "{report:?}"
        );
    }

    /// A multi-file ban must not be satisfied by a file that stripped to nothing — that is the
    /// healthiest-looking result this gate can print, and it means nothing.
    #[test]
    fn an_all_comment_file_under_a_multi_file_ban_says_so() {
        let fixture = Fixture::new("geometry-comment");
        fixture
            .write(
                "Sources/SlopDeskVideoProtocol/Geometry.swift",
                "// prose naming Double.maximum, which is the banned thing\n",
            )
            .write(
                "Sources/SlopDeskVideoHost/VirtualDisplayRecoveryPolicy.swift",
                "slopdesk_vd_recreate_cooldown(x)\nslopdesk_vd_recreate_should_attempt(x)\\
                 nslopdesk_vd_channels_to_disconnect(x)\n",
            );
        let report = super::geometry(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stripped to nothing")),
            "{report:?}"
        );
    }

    const ROUTER_DOORS: &str = "\
slopdesk_mux_router_new(x)
slopdesk_mux_router_free(x)
slopdesk_mux_router_admit(x)
slopdesk_mux_router_retire(x)
slopdesk_mux_router_begin_drain(x)
slopdesk_mux_router_end_drain(x)
slopdesk_mux_router_is_admitted(x)
slopdesk_mux_router_is_draining(x)
slopdesk_mux_router_route(x)
slopdesk_mux_bootstrap_action(x)
";
    const FLOWS_DOORS: &str = "\
slopdesk_mux_flows_new(x)
slopdesk_mux_flows_free(x)
slopdesk_mux_flows_accept(x)
slopdesk_mux_flows_note_inbound(x)
slopdesk_mux_flows_stamp_media_reply(x)
slopdesk_mux_flows_stamp_media_bootstrap(x)
slopdesk_mux_flows_stamp_cursor_reply(x)
slopdesk_mux_flows_retire_lane(x)
slopdesk_mux_flows_did_reset(x)
slopdesk_mux_flows_tracks(x)
slopdesk_mux_flows_reap(x)
slopdesk_mux_flows_remove_all(x)
slopdesk_mux_flows_media_reply(x)
slopdesk_mux_flows_cursor_reply(x)
slopdesk_mux_flows_count(x)
";
    const BYE_DOORS: &str = "\
slopdesk_mux_warrants_bye(x)
slopdesk_mux_bye_limiter_new(x)
slopdesk_mux_bye_limiter_free(x)
slopdesk_mux_bye_limiter_admit(x)
";
}
