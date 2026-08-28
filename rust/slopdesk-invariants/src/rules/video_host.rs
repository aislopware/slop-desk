//! The host's mux, its window feed, the four smallest send-path decisions, the four bounded
//! accumulators and the aspect geometry.
//!
//! Ported from the deleted `check-supervisor.sh`. What every rule here guards is a verdict that
//! must be SINGLE because two surfaces ask it: the router's lane sets and the client's, the
//! picker's inclusion test and the feed's, the encoder's budget and the pacer's. A second copy
//! agrees on the easy cases and diverges exactly where nobody is watching.
//!
//! ## What `docs/61` changed, and what it did not
//!
//! Every rule here used to name a file under `Sources/SlopDeskVideoHost` and ask two things of it:
//! that it CALLED the crate's door, and that it did not respell the interior behind that door. The
//! Swift host is deleted and its doors went with it — `rust/slopdesk-videohostd` links
//! `slopdesk-video` as a Rust dependency, so there is no `(ptr, len)` to prove a call across.
//!
//! So the door half is re-aimed rather than dropped: the claim "the law is asked, not re-derived"
//! is now a [`Claim::MentionsUnder`] over the DAEMON's directory, naming the crate module each rule
//! is about. It reads the directory rather than a file because the daemon's modules are still being
//! split — a claim pinned to a filename would go wrong the moment a session module divides, which
//! is drift the rule was never about.
//!
//! The Swift half is re-aimed to [`crate::rules::deleted_video_swift`], where it is stated ONCE at
//! full strength: no Swift target may declare a video-host type, not just the file that used to.
//! What is left in each rule below is the ban that only makes sense HERE — the interior, spelled in
//! the daemon's own language, which is the one language it could now come back in.

use crate::claim::{Claim, RUST, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The daemon that IS the GUI host — `docs/61`.
///
/// A directory rather than a file for the reason the module doc gives: the faces this file used to
/// name one-for-one are modules of this crate, and which module holds which face is still moving.
const DAEMON: &str = "rust/slopdesk-videohostd";

/// The HOST MUX's five deciders — `mux_routing` and `mux_flow`.
///
/// Two handles and three questions: the router's lane sets and the flow table's stamps are large
/// and read one verdict at a time, and the bye policy, the registry's dispatch and the reaper's
/// keepalive proof each ask about one payload. What makes the port matter is that all five guard
/// the same failure — a datagram from a session that no longer exists reaching one that does, or a
/// session that still exists being torn down under a client that is watching it.
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
///
/// The registry's hello switch is named because that switch IS the mint rule: a copy of it that
/// missed one bootstrapping message would leave a whole pane kind unable to open a session, with
/// both suites green — `helloDisplay` is the message it would miss, and it has been missed from a
/// hand-mirrored copy of this exact switch before. `dispatch_decision` is the one answer, and the
/// daemon's registry asks it rather than switching itself.
///
/// The transport's keepalive test is named because the type byte it used to compare against, `6`,
/// is also `VideoChannel::Audio`'s raw value, one table away from the `channel == .control` test it
/// sat beside. It feeds the reaper's STICKY liveness proof, so getting it wrong decides whether a
/// lane can ever be reaped at all — silently, in either direction.
#[must_use]
pub fn host_mux(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["mux_routing", "dispatch_decision", "mux_flow", "mux_header"],
            message: "the daemon stopped asking {entry} — the mux routing law, the flow bookkeeping and the \
                      header grammar are rust/slopdesk-video's, and a host that stopped asking has started \
                      deciding (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\b(admitted|retired|draining|media_reply|cursor_reply|last_sent)\.insert\(|\b(retired_cap|retired_prune_window|distance_wrapped|unadmitted_stamp_at|flow_last_inbound)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon spells a lane set, a reply stamp or the retired bound itself in {files} — \
                      those live in mux_routing.rs and mux_flow.rs, and a copy here is a datagram from a \
                      dead generation reaching a live session (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"payload\[1\] == 6|\[1\] == 6u8",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon reads the control type byte by offset again in {files} — that byte is \
                      mux_flow.rs's, and 6 is also VideoChannel::Audio's raw value; the reaper's liveness \
                      proof is sticky, so a wrong read decides whether a lane can ever be reaped at all \
                      (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

/// The HOST WINDOW FEED — `window_feed_host`.
///
/// Four decisions against one crate module: what to list, how to pack it, who to push it to, and
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
/// The record marshalling is the half that did NOT move. It is spelled ONCE, on the protocol side,
/// and both the client assembler and the host's own packer use it — so those three claims still
/// name `HostWindowRecordRows.swift`, which is live client Swift and not a host face. A fourth
/// hand-rolled row layout is how the arena offsets drift.
#[must_use]
pub fn window_feed(tree: &Tree) -> Report {
    const ROWS: &str = "Sources/SlopDeskVideoProtocol/HostWindowRecordRows.swift";

    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["window_feed_host"],
            message: "the daemon stopped asking {entry} — the listing law, the cache, the packer and the \
                      push policy are rust/slopdesk-video's, and the inclusion verdict has to be the same \
                      one the picker asks (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\b(excluded_system_apps|junk_titles_by_owner|focused_assigned|structural_bits|burst_until|last_volatile_fold)\b|generation \+= 1|\bfn skeleton\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon spells an exclusion, the evidence gate, the generation bump or the \
                      structural differ itself in {files} — those live in window_feed_host.rs, and a copy \
                      that calls a title structural puts a typing window into permanent burst (docs/61 §3)",
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
/// rule that forgot one obligation freezes a client on a frame it is waiting for. Nothing about
/// that argument was Swift's — a `if hash == last { return }` typed into the daemon's capture loop
/// is the same second answer in a different language, and cheaper to type.
///
/// The density and the floor are named because the encoder's QP ceiling is sized against the budget
/// they produce: a second copy that rounds differently drops frames on one machine and not the
/// other.
#[must_use]
pub fn send_path_decisions(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["frame_gate", "live_bitrate", "capture_recovery"],
            message: "the daemon stopped asking {entry} — the static-frame suppression, the stillness \
                      crisp, the live bitrate target and the capture-failure rung are rust/slopdesk-video's \
                      (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\b(consecutive_equal|fired_this_rest|is_fallback_rebuild)\b|hash_equal_to_last",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a send-path decision is spelled in the daemon again ({files}) — those live in \
                      frame_gate.rs, live_bitrate.rs and capture_recovery.rs, and a suppression rule that \
                      forgot one obligation freezes a client on the frame it is waiting for (docs/61 §3)",
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
/// The ring's hand-parsed header offset is named because that is exactly how the deleted Swift copy
/// read a fragment index — a byte offset that silently mis-selects the moment the wire header
/// moves. `fragment::FrameFragmentHeader` is the only reader, in either language.
///
/// `recovery_dedupe` is deliberately absent from the ask below and present in the ban. The daemon's
/// inbound half is still landing, so a claim that it already imports that module would be a claim
/// about a schedule rather than about a law; the ban is the half that holds either way — whenever
/// the dedupe arrives, it arrives as the crate's and not as a second admission window.
#[must_use]
pub fn accumulators(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["ltr::", "idle_reap", "retransmit_ring"],
            message: "the daemon stopped asking {entry} — the reference gate, the idle reaper and the \
                      retransmit ring are rust/slopdesk-video's; an LTR gate that drifts open issues a \
                      refresh against a reference the client never held (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\b(frame_order|acknowledged_tokens)\.push\(|\b(frame_token_cap|window_seconds|by_frame)\b|\[\.\.8\]\.try_into",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a host accumulator's interior is spelled in the daemon again ({files}) — those live \
                      in ltr.rs, recovery_dedupe.rs, idle_reap.rs and retransmit_ring.rs, and a fragment \
                      index read by byte offset mis-selects the moment the wire header moves (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

/// The ASPECT GEOMETRY and the virtual-display throttle — `geometry` and `capture_recovery`.
///
/// `view_point` is the exact inverse of the input encoder's normalise, so a second copy that
/// contracts one multiply-add lands the cursor overlay a pixel off the click it is drawn for — on
/// one machine and not the other. It is golden-pinned for exactly that reason. That half is
/// unchanged: `Geometry.swift` is CLIENT Swift, still a face over three doors, and still the file
/// the claim names.
///
/// `Double.maximum` is named in the ban for the same file because it is the NaN-ignoring form the
/// crate's `f64::max` requires — a plain `max` here would silently poison the multi-monitor pick
/// instead of clamping it.
///
/// The virtual-display throttle is the half that moved. The cooldown, the single-flight rule and
/// the set of channels a recreate must disconnect are `capture_recovery`'s and `virtual_display`'s,
/// and the daemon's `vdisplay` asks them.
#[must_use]
pub fn geometry(tree: &Tree) -> Report {
    const GEOM: &str = "Sources/SlopDeskVideoProtocol/Geometry.swift";

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
        Claim::Lacks {
            path: GEOM,
            pattern: r"Double\.maximum|Double\.minimum|panLimit|invZoom|intersection\(",
            view: View::Code,
            message: "the aspect geometry is spelled in Swift again in \
                      Sources/SlopDeskVideoProtocol/Geometry.swift — view_point is the exact inverse of the \
                      input encoder's normalise and is golden-pinned, so a second copy lands the cursor \
                      overlay a pixel off the click it is drawn for",
        },
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["capture_recovery", "virtual_display"],
            message: "the daemon stopped asking {entry} — the recreate cooldown, the single-flight rule and \
                      the channels a recreate disconnects are rust/slopdesk-video's (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"= *30\.0 *; *// *cooldown|\brecreate_cooldown_seconds *: *f64 *=",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon types the virtual-display recreate throttle itself in {files} — the \
                      cooldown is capture_recovery.rs's RECREATE_COOLDOWN_SECONDS (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A daemon that stopped importing the routing law has started deciding it — which is the
    /// failure, whichever way it happened.
    #[test]
    fn a_daemon_that_stops_asking_the_mux_law_is_caught() {
        let fixture = seeded("mux-law-unasked");
        assert!(super::host_mux(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-videohostd/src/mux_registry.rs",
            "use slopdesk_video::mux_flow::FlowId;\n",
        );
        let report = super::host_mux(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("dispatch_decision")),
            "{report:?}"
        );
    }

    /// The failure all three mux deciders guard: a datagram from a session that no longer exists
    /// reaching one that does. A lane set kept in the daemon is the second answer that lets it
    /// happen — and it is cheaper to type in Rust than it ever was in Swift.
    #[test]
    fn a_lane_set_growing_back_in_the_daemon_is_caught() {
        let fixture = seeded("mux-lane-set");
        fixture.append(
            "rust/slopdesk-videohostd/src/mux_registry.rs",
            "fn admit(&mut self, lane: u32) {\n    self.admitted.insert(lane);\n}\n",
        );
        let report = super::host_mux(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("lane set")),
            "{report:?}"
        );
    }

    /// The type byte the reaper's sticky liveness proof turns on, read by offset again. `6` is also
    /// `VideoChannel::Audio`'s raw value.
    #[test]
    fn a_keepalive_byte_peek_growing_back_is_caught() {
        let fixture = seeded("mux-keepalive-peek");
        fixture.append(
            "rust/slopdesk-videohostd/src/mux_transport.rs",
            "let is_ka = payload[1] == 6;\n",
        );
        let report = super::host_mux(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("type byte by offset")),
            "{report:?}"
        );
    }

    /// The feed's structural differ, re-derived in the daemon: a copy that calls a title structural
    /// puts a typing window into permanent burst, and nothing turns red for it.
    #[test]
    fn a_structural_differ_growing_back_in_the_daemon_is_caught() {
        let fixture = seeded("feed-differ");
        assert!(super::window_feed(&fixture.tree()).is_clean());

        fixture.append(
            "rust/slopdesk-videohostd/src/feed.rs",
            "fn skeleton(record: &Record) -> u64 {\n    record.structural_bits\n}\n",
        );
        let report = super::window_feed(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("structural differ")),
            "{report:?}"
        );
    }

    /// The suppression rule re-typed at the call site — the shape the rule was always about, now in
    /// the only language left to type it in.
    #[test]
    fn a_send_path_decision_growing_back_in_the_daemon_is_caught() {
        let fixture = seeded("send-path-decision");
        assert!(super::send_path_decisions(&fixture.tree()).is_clean());

        fixture.append(
            "rust/slopdesk-videohostd/src/capture.rs",
            "if hash_equal_to_last { return; }\n",
        );
        assert!(!super::send_path_decisions(&fixture.tree()).is_clean());
    }

    /// The ring's fragment index, read by byte offset. It is the exact shape the deleted Swift copy
    /// had, and it mis-selects silently the moment the wire header moves.
    #[test]
    fn a_hand_read_fragment_index_is_caught() {
        let fixture = seeded("ring-offset");
        assert!(super::accumulators(&fixture.tree()).is_clean());

        fixture.append(
            "rust/slopdesk-videohostd/src/sendlane.rs",
            "let index = u64::from_be_bytes(header[..8].try_into().unwrap());\n",
        );
        let report = super::accumulators(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("accumulator's interior")),
            "{report:?}"
        );
    }

    /// The client half of `geometry` did not move, and its ban is still a ban about one Swift file.
    #[test]
    fn a_swift_aspect_geometry_growing_back_is_caught() {
        let fixture = seeded("geometry-swift");
        assert!(super::geometry(&fixture.tree()).is_clean());

        fixture.append(
            "Sources/SlopDeskVideoProtocol/Geometry.swift",
            "let side = Double.maximum(a, b)\n",
        );
        let report = super::geometry(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("aspect geometry")),
            "{report:?}"
        );
    }

    /// A `MentionsUnder` over a directory that stripped to nothing must FAIL rather than pass —
    /// a drained daemon is the healthiest-looking answer this gate can print, and it means nothing.
    #[test]
    fn a_drained_daemon_cannot_satisfy_the_ask() {
        // Fixture names are a GLOBAL key: `Fixture::new` does a name-keyed `remove_dir_all` and the
        // tests run concurrently, so two files sharing a name delete each other's scratch tree
        // mid-run. Prefixed with this module's subject to keep it unique across the crate.
        let fixture = Fixture::new("videohost-daemon-drained");
        fixture.write(
            "rust/slopdesk-videohostd/src/mux_registry.rs",
            "// every call is a comment now\n",
        );
        assert!(!super::host_mux(&fixture.tree()).is_clean());
    }

    /// The daemon and the two live Swift files, spelled the way a clean tree spells them.
    fn seeded(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(
                "rust/slopdesk-videohostd/src/mux_registry.rs",
                "use slopdesk_video::mux_routing::{DispatchDecision, dispatch_decision};\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/mux_transport.rs",
                "use slopdesk_video::mux_flow::FlowId;\nuse slopdesk_video::mux_header;\nuse \
                 slopdesk_video::idle_reap::IdleReapDecider;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/feed.rs",
                "use slopdesk_video::window_feed_host::includes_window;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/capture.rs",
                "use slopdesk_video::frame_gate::FrameGate;\nuse slopdesk_video::capture_recovery;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/session_capture.rs",
                "use slopdesk_video::live_bitrate::{self, BITS_PER_PIXEL_KEY};\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/session_wiring.rs",
                "use slopdesk_video::ltr::LtrController;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/sendlane.rs",
                "use slopdesk_video::retransmit_ring::RetransmitRing;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/vdisplay.rs",
                "use slopdesk_video::virtual_display::{Geometry, chip_pixel_limit};\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/Geometry.swift",
                "slopdesk_geometry_intersection_area(x)\nslopdesk_geometry_displayed_video_rect(x)\\
                 nslopdesk_geometry_view_point(x)\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/HostWindowRecordRows.swift",
                "func row(into arena: Arena) {}\nstatic func of(_ row: Row) {}\nstatic func rows(_ records: \
                 [Record]) {}\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/WindowFeedAssembler.swift",
                "let assembled = 1\n",
            );
        fixture
    }
}
