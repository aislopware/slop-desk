//! The host's admission laws, the rate law, the frame-rate axis and the presentation depth.
//!
//! Ported from the deleted `check-supervisor.sh`. Every one of these is a CONTROL LAW: a handful of
//! branches that decide how much to send, how often, and when to give up and re-key. A second
//! speller of any of them is a second control law that agrees on the easy cases and diverges on the
//! link that was already in trouble — which is where nobody is watching, and where every test
//! suite's numbers are too small to tell.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const SWIFT_QP: &str = "Sources/SlopDeskVideoHost/QPController.swift";
const SWIFT_IDR: &str = "Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift";
const SWIFT_ABR: &str = "Sources/SlopDeskVideoHost/LiveCongestionController.swift";
const SWIFT_ESTIMATE: &str = "Sources/SlopDeskVideoHost/VideoSessionLogic.swift";
const SWIFT_FPS: &str = "Sources/SlopDeskVideoHost/FPSGovernor.swift";
const SWIFT_DEPTH: &str = "Sources/SlopDeskVideoClient/PacerDepthPolicy.swift";
const SWIFT_OWD: &str = "Sources/SlopDeskVideoClient/OwdLateDetector.swift";

/// The host's two ADMISSION LAWS — `rust/slopdesk-video`'s `qp_control` and `recovery_idr`.
///
/// They take opposite conventions on purpose and the far side is what picks: the quantiser
/// controller is a Swift struct copied by value, so it crosses as a pure fold with no handle to
/// alias; the recovery policy is a `final class` holding one token bucket, so it crosses as a
/// handle.
///
/// A handle that is allocated and never freed is the one failure a green test suite cannot see, so
/// the `deinit` is pinned too.
///
/// The state a re-implementation would grow back: `cleanStreak` is the whole difference between one
/// sharpen per interval and one per report; the keyframe ring and the bucket are the recovery law.
/// Scoped to the video host, because a token bucket is a SHAPE rather than a law — the notification
/// rate limiter in `SlopDeskWorkspaceCore` is its own, and is not what these entries pin.
#[must_use]
pub fn admission(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_QP,
            entries: &["slopdesk_qp_new", "slopdesk_qp_decide", "slopdesk_qp_clamped_int"],
            message: "Sources/SlopDeskVideoHost/QPController.swift no longer calls {entry} — the \
                      constant-QP AIMD is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: SWIFT_IDR,
            entries: &[
                "slopdesk_idr_policy_new",
                "slopdesk_idr_policy_free",
                "slopdesk_idr_policy_note_keyframe_sent",
                "slopdesk_idr_policy_note_keyframe_delivered",
                "slopdesk_idr_policy_decide",
                "slopdesk_idr_policy_grace",
                "slopdesk_idr_policy_available_tokens",
            ],
            message: "Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift no longer calls {entry} — the \
                      recovery-IDR admission is rust/slopdesk-video's",
        },
        Claim::Names {
            path: SWIFT_IDR,
            needle: "deinit { slopdesk_idr_policy_free",
            message: "Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift allocates a policy without freeing \
                      it in deinit — one new, one free",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskVideoHost", "Tests/SlopDeskVideoHostTests"],
            extensions: SWIFT,
            pattern: r"var cleanStreak\b|var recentKeyframes\b|var tokens: Double|func refill\(now:",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift clean streak / keyframe ring / token bucket is back in {files} — those laws \
                      are Rust's",
        },
    ];
    check_all(tree, &claims)
}

/// The RATE LAW — `rust/slopdesk-video`'s `congestion` and `network_estimate`, through the `abr`
/// door.
///
/// Two Swift structs their owners copy, so both cross by value, whole, every call. The only thing
/// left on this side is resolving `SLOPDESK_ABR_*` through the overlay-aware `EnvConfig`.
///
/// The EWMA weights are the fold, not a tunable: no env reads them and nothing hands them across,
/// so a Swift copy could drift for a whole release without a test noticing.
///
/// Every default is spelled once, on the far side: each env-resolved tunable falls back to a field
/// of `slopdesk_abr_config_default()`, never to a literal. Counting the fallbacks is what catches a
/// knob added later with a hand-written default beside it — the one drift no test can see, because
/// both languages would still be internally consistent.
#[must_use]
pub fn rate_law(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_ABR,
            entries: &[
                "slopdesk_abr_config_default",
                "slopdesk_abr_new",
                "slopdesk_abr_with_ceiling",
                "slopdesk_abr_effective_ceiling",
                "slopdesk_abr_set_user_ceiling",
                "slopdesk_abr_decide",
                "slopdesk_abr_effective_slack",
                "slopdesk_abr_is_material_change",
            ],
            message: "Sources/SlopDeskVideoHost/LiveCongestionController.swift no longer calls {entry} — \
                      the AIMD rate law is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: SWIFT_ESTIMATE,
            entries: &[
                "slopdesk_net_estimate_new",
                "slopdesk_net_estimate_rtt_millis",
                "slopdesk_net_estimate_fold",
            ],
            message: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift no longer calls {entry} — the \
                      report fold is rust/slopdesk-video's",
        },
        // Each names a decision the law makes, and a second speller of any one of them is a second
        // control law that agrees on the easy cases.
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: r"func decideInner\(|func applyDecrease\(|func appLimitedDecay\(|func increaseStep\(|func utilizationPermitsRamp\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift AIMD branch is back in {files} — the rate law is decided once, behind \
                      slopdesk_abr_decide",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: r"static let (rttAlpha|lossAlpha|minRTTDecay)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the estimate's EWMA weights are spelled in Swift again ({files}) — they live in \
                      network_estimate.rs",
        },
        Claim::AtLeast {
            path: SWIFT_ABR,
            pattern: r"\bdefaults\.[a-z_]+",
            minimum: 24,
            message: "Sources/SlopDeskVideoHost/LiveCongestionController.swift reads only {found} defaults \
                      from the door — a knob is spelled twice",
        },
    ];
    check_all(tree, &claims)
}

/// The FRAME-RATE axis — `rust/slopdesk-video`'s `fps_governor`, through `frame_rate`.
///
/// Two governors, the gate they actuate through and the self-heal cadence, all in one Swift file.
///
/// The LADDER is the shape both axes step, and a second speller of it would let the two disagree
/// about which rungs exist. The gate's schedule arithmetic is the other one — a drift-free advance
/// re-derived by hand is how a metronome becomes a beat pattern. Scoped to the video host, because
/// a frame interval is a shape rather than a law — the loopback harness computes its own slot
/// times, and is not what these entries pin.
///
/// The congestion predicate must keep reading the RATE law's tunables. A local copy of the inflate
/// factor here is the drift that makes the frame rate step down on evidence the rate law ignored.
#[must_use]
pub fn frame_rate(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_FPS,
            entries: &[
                "slopdesk_fps_config_default",
                "slopdesk_fps_ladder",
                "slopdesk_fps_governor_new",
                "slopdesk_fps_governor_note_frame",
                "slopdesk_fps_governor_tick",
                "slopdesk_fps_congestion_evidence",
                "slopdesk_fps_gate_admit",
                "slopdesk_fps_self_heal_every",
                "slopdesk_fps_pacer_config_default",
                "slopdesk_fps_budget_millis",
                "slopdesk_fps_pacer_new",
                "slopdesk_fps_pacer_note",
            ],
            message: "Sources/SlopDeskVideoHost/FPSGovernor.swift no longer calls {entry} — the frame-rate \
                      axis is rust/slopdesk-video's",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskVideoHost", "Tests/SlopDeskVideoHostTests"],
            extensions: SWIFT,
            pattern: r"rungs\.insert\(|for divisor in|nextDueSeconds \+=|1000\.0 / Double\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift ladder / cadence advance / per-frame budget is back in {files} — those live \
                      in fps_governor.rs",
        },
        Claim::Names {
            path: SWIFT_FPS,
            needle: "LiveCongestionController.config",
            message: "Sources/SlopDeskVideoHost/FPSGovernor.swift stopped passing the ABR's own config — \
                      the two controllers must agree",
        },
    ];
    check_all(tree, &claims)
}

/// The PRESENTATION DEPTH — `rust/slopdesk-video`'s `pacer_depth`, through the door of the same
/// name.
///
/// Two Swift structs the `FramePacer` copies under its lock, so both cross by value, whole, every
/// fold — the three rings included, because the windows are read over TIMES rather than counts.
///
/// The rings ARE the windows: a Swift ring here is a second promote window, a second dwell and a
/// second dense-flow gate that agree only while nothing ages out. The two-bucket minimum is the
/// same story for the baseline. Scoped to `Sources/`, because the tests are the parity evidence —
/// they name the state they drive.
#[must_use]
pub fn presentation_depth(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_DEPTH,
            entries: &[
                "slopdesk_pacer_depth_config_default",
                "slopdesk_pacer_depth_config_apply",
                "slopdesk_pacer_depth_new",
                "slopdesk_pacer_depth_expected_interval",
                "slopdesk_pacer_depth_late_threshold",
                "slopdesk_pacer_depth_note_arrival",
                "slopdesk_pacer_depth_note_present",
                "slopdesk_pacer_depth_note_network_late",
                "slopdesk_pacer_depth_note_reshow",
                "slopdesk_pacer_depth_drain",
                "slopdesk_pacer_depth_set_interval_hint",
                "slopdesk_pacer_depth_eq",
            ],
            message: "Sources/SlopDeskVideoClient/PacerDepthPolicy.swift no longer calls {entry} — the \
                      depth policy is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: SWIFT_OWD,
            entries: &[
                "slopdesk_owd_late_config_default",
                "slopdesk_owd_late_config_apply",
                "slopdesk_owd_late_new",
                "slopdesk_owd_late_note",
            ],
            message: "Sources/SlopDeskVideoClient/OwdLateDetector.swift no longer calls {entry} — the spike \
                      detector is rust/slopdesk-video's",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"lateTimes\b|arrivalRing\b|intervalRing\b|currentBucketMin\b|previousBucketMin\b|func evaluatePromote\(|func evaluateDemote\(|func wasDense\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift depth ring / promote-demote branch is back in {files} — those laws live in \
                      pacer_depth.rs",
        },
        // Every band AND every knob name is the door's: the config is walked one env pair at a time,
        // so a `SLOPDESK_DEPTH_*` literal in the SHIPPING code is a name the two languages could stop
        // agreeing on. The tests spell them on purpose — that a knob still answers to its name is
        // what they check.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r#""SLOPDESK_(DEPTH|OWD_LATE)_"#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a SLOPDESK_DEPTH_*/SLOPDESK_OWD_LATE_* name is spelled in Swift ({files}) — the door \
                      knows its knobs",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A handle allocated and never freed is the one failure a green test suite cannot see.
    #[test]
    fn a_policy_handle_with_no_deinit_free_is_caught() {
        let fixture = Fixture::new("idr-deinit");
        fixture
            .write("Sources/SlopDeskVideoHost/QPController.swift", QP_DOORS)
            .write(
                "Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift",
                &format!("{IDR_DOORS}deinit {{ slopdesk_idr_policy_free(handle) }}\n"),
            );
        assert!(super::admission(&fixture.tree()).is_clean());

        fixture.write("Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift", IDR_DOORS);
        let report = super::admission(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("one new, one free")),
            "{report:?}"
        );
    }

    /// A token bucket in `SlopDeskWorkspaceCore` is a SHAPE, not this law. The scope is what keeps
    /// the rule from firing on the notification rate limiter.
    #[test]
    fn a_token_bucket_outside_the_video_host_is_not_this_law() {
        let fixture = Fixture::new("token-bucket-scope");
        fixture
            .write("Sources/SlopDeskVideoHost/QPController.swift", QP_DOORS)
            .write(
                "Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift",
                &format!("{IDR_DOORS}deinit {{ slopdesk_idr_policy_free(handle) }}\n"),
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/RateLimiter.swift",
                "var tokens: Double = 3\n",
            );
        assert!(super::admission(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoHost/Sneak.swift",
            "var tokens: Double = 3\n",
        );
        let report = super::admission(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("token bucket is back")),
            "{report:?}"
        );
    }

    /// The drift no test can see: a knob added later with a hand-written default beside it. Both
    /// languages stay internally consistent, so only the COUNT catches it.
    #[test]
    fn a_knob_with_a_hand_written_default_is_caught_by_the_count() {
        let fixture = Fixture::new("abr-defaults");
        let doors = format!("{ABR_DOORS}{}", "let x = defaults.knob\n".repeat(24));
        fixture
            .write("Sources/SlopDeskVideoHost/LiveCongestionController.swift", &doors)
            .write(
                "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
                ESTIMATE_DOORS,
            );
        assert!(super::rate_law(&fixture.tree()).is_clean());

        let fewer = format!("{ABR_DOORS}{}", "let x = defaults.knob\n".repeat(23));
        fixture.write("Sources/SlopDeskVideoHost/LiveCongestionController.swift", &fewer);
        let report = super::rate_law(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("only 23 defaults")),
            "{report:?}"
        );
    }

    /// A local copy of the inflate factor makes the frame rate step down on evidence the rate law
    /// ignored — two controllers reading two configs.
    #[test]
    fn the_frame_rate_axis_must_keep_reading_the_rate_laws_config() {
        let fixture = Fixture::new("fps-config");
        fixture.write(
            "Sources/SlopDeskVideoHost/FPSGovernor.swift",
            &format!("{FPS_DOORS}let c = LiveCongestionController.config\n"),
        );
        assert!(super::frame_rate(&fixture.tree()).is_clean());

        fixture.write("Sources/SlopDeskVideoHost/FPSGovernor.swift", FPS_DOORS);
        let report = super::frame_rate(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("two controllers")),
            "{report:?}"
        );
    }

    const QP_DOORS: &str = "slopdesk_qp_new(x)\nslopdesk_qp_decide(x)\nslopdesk_qp_clamped_int(x)\n";
    const IDR_DOORS: &str = "\
slopdesk_idr_policy_new(x)
slopdesk_idr_policy_free(x)
slopdesk_idr_policy_note_keyframe_sent(x)
slopdesk_idr_policy_note_keyframe_delivered(x)
slopdesk_idr_policy_decide(x)
slopdesk_idr_policy_grace(x)
slopdesk_idr_policy_available_tokens(x)
";
    const ABR_DOORS: &str = "\
slopdesk_abr_config_default(x)
slopdesk_abr_new(x)
slopdesk_abr_with_ceiling(x)
slopdesk_abr_effective_ceiling(x)
slopdesk_abr_set_user_ceiling(x)
slopdesk_abr_decide(x)
slopdesk_abr_effective_slack(x)
slopdesk_abr_is_material_change(x)
";
    const ESTIMATE_DOORS: &str =
        "slopdesk_net_estimate_new(x)\nslopdesk_net_estimate_rtt_millis(x)\nslopdesk_net_estimate_fold(x)\n";
    const FPS_DOORS: &str = "\
slopdesk_fps_config_default(x)
slopdesk_fps_ladder(x)
slopdesk_fps_governor_new(x)
slopdesk_fps_governor_note_frame(x)
slopdesk_fps_governor_tick(x)
slopdesk_fps_congestion_evidence(x)
slopdesk_fps_gate_admit(x)
slopdesk_fps_self_heal_every(x)
slopdesk_fps_pacer_config_default(x)
slopdesk_fps_budget_millis(x)
slopdesk_fps_pacer_new(x)
slopdesk_fps_pacer_note(x)
";
}
