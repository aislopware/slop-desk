//! The host's admission laws, the rate law, the frame-rate axis and the presentation depth.
//!
//! Ported from the deleted `check-supervisor.sh`. Every one of these is a CONTROL LAW: a handful of
//! branches that decide how much to send, how often, and when to give up and re-key. A second
//! speller of any of them is a second control law that agrees on the easy cases and diverges on the
//! link that was already in trouble — which is where nobody is watching, and where every test
//! suite's numbers are too small to tell.
//!
//! Three of the four used to be asked of a Swift face under `Sources/SlopDeskVideoHost`. `docs/61`
//! deleted every one of those faces, so the same three questions are now asked of
//! `rust/slopdesk-videohostd`, which is the only asker left. Nothing about the argument changed —
//! only which language could hold the second copy. `presentation_depth` is the client's and is
//! untouched.
//!
//! Each host rule is a PAIR: the daemon must still ASK `rust/slopdesk-video` for the law, and it
//! must not RE-SPELL the law's interior. The ask alone would pass a daemon that calls the crate for
//! the easy path and hand-rolls the hard one beside it; the ban alone would pass a daemon that
//! dropped the law entirely. `MentionsUnder` fails on a drained root for the same reason.
//!
//! The bans are scoped to the daemon and never to `rust/slopdesk-video` itself, which legitimately
//! spells every one of these interiors — it is the crate that owns them.
//!
//! The "no Swift brings any of this back" half is stated tree-wide, at full strength, in
//! [`crate::rules::deleted_video_swift`].

use crate::claim::{Claim, RUST, SWIFT, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The Rust host — the only thing that asks these laws now.
const DAEMON: &str = "rust/slopdesk-videohostd";

const SWIFT_DEPTH: &str = "Sources/SlopDeskVideoClient/PacerDepthPolicy.swift";
const SWIFT_OWD: &str = "Sources/SlopDeskVideoClient/OwdLateDetector.swift";

/// The host's two ADMISSION LAWS — `rust/slopdesk-video`'s `qp_control` and `recovery_idr` — and
/// the ROUTING law that feeds them.
///
/// The handle bookkeeping this rule used to pin DISSOLVED with the port. `RecoveryIDRPolicy` was a
/// `final class` around a C handle, so "one new, one free" had to be asserted by naming the
/// `deinit`; the policy is now an ordinary Rust value the daemon owns by move, and the compiler
/// answers the lifetime question that claim was standing in for. What survives the dissolution is
/// the question of WHO the daemon asks, so that is what is asked here.
///
/// `session_state` is in the ask beside the two admissions because it is where both verdicts land:
/// the daemon holds the machine, and the crate holds every transition in it. A daemon that asked
/// for `qp_control` but kept its own idea of the session's phase would re-key on a state the crate
/// never entered.
///
/// The state a re-implementation would grow back: `clean_streak` is the whole difference between
/// one sharpen per interval and one per report; the keyframe ring and the token bucket are the
/// recovery law, and `bucket_capacity`/`refill_tokens_per_second` are its two knobs. The daemon
/// resolves those through `recovery_idr`'s own key table, never by naming a field — so a field name
/// appearing in the daemon at all is a second bucket, not a lookup.
///
/// The routing half is `recovery_routing`'s, which decides what an arriving recovery datagram MEANS
/// before either admission ever sees it. Its arm table is the boring half; the two halves that
/// drift silently are the guard ORDER — not-streaming refuses before any decode — and the wire's
/// no-frame-decoded SENTINEL, which must become an absent frontier inside the crate and never reach
/// the daemon as its number. So the ask is pinned, and so is the absence of the sentinel's name and
/// of its literal: a `last_decoded == NO_FRAME_DECODED_SENTINEL` in the daemon is the second
/// speller of that mapping, and it would agree with the crate on every frontier except the one that
/// says the client has decoded nothing at all — a client at its most frozen.
#[must_use]
pub fn admission(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["qp_control", "recovery_idr", "recovery_routing", "session_state"],
            message: "rust/slopdesk-videohostd stopped naming {entry} — the quantiser admission, the \
                      recovery-IDR admission, the routing that feeds them and the session machine they land \
                      in are all rust/slopdesk-video's, and a daemon that no longer asks for one is \
                      deciding it somewhere the crate's suite does not reach (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bclean_streak\b|\brecent_keyframes\b|fn refill *\(|\brefill_tokens_per_second\b|\bbucket_capacity\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd spells an admission's own state in {files} — the clean \
                      streak, the keyframe ring and the token bucket are slopdesk_video's qp_control and \
                      recovery_idr, and a daemon-local copy re-keys on evidence the crate never saw \
                      (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"NO_FRAME_DECODED_SENTINEL|0xFFFF_FFFF",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd names the no-frame-decoded sentinel in {files} — \
                      recovery_routing turns it into an absent frontier so it never leaves the crate, and a \
                      daemon that compares against it agrees on every frontier but the frozen one (docs/61 \
                      §3)",
        },
    ];
    check_all(tree, &claims)
}

/// The RATE LAW — `rust/slopdesk-video`'s `congestion` and `network_estimate`.
///
/// The AIMD is one crate's, asked by one daemon. The only thing left on the asking side is
/// resolving the `SLOPDESK_ABR_*` family through the overlay, and even that is not a lookup the
/// daemon composes: `ABR_KEYS` is the crate's own table and `CongestionConfig::from_env` is the
/// crate's own resolver, so the daemon hands over resolved slots rather than choosing which knobs
/// exist. That is why both names are in the ask and why a quoted `SLOPDESK_ABR_` anywhere in the
/// daemon is a violation rather than an exception — a key spelled beside the table is a knob the
/// table does not know it has, and the two would agree until someone adds the twenty-ninth.
///
/// This replaces a COUNT. The old rule counted the Swift face's `defaults.…` reads and demanded at
/// least twenty-four, because a knob added later with a hand-written default beside it left both
/// languages internally consistent. Asking for the table and banning the literal is strictly
/// stronger: a new knob now arrives with its default inside the crate or not at all, and there is
/// no number to keep in step with the code.
///
/// The EWMA weights are the fold, not a tunable: no env reads them and nothing hands them across,
/// so a second copy could drift for a whole release without a test noticing. The named branches are
/// the decisions themselves — `decide_inner`, the app-limited decay, the utilisation gate, the
/// clean-link step and the cut target — and a second speller of any one of them is a second control
/// law that agrees on the easy cases and diverges on the link that was already in trouble.
#[must_use]
pub fn rate_law(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["congestion", "network_estimate", "ABR_KEYS", "CongestionConfig"],
            message: "rust/slopdesk-videohostd stopped naming {entry} — the AIMD, the report fold, the knob \
                      table and the config it resolves into are rust/slopdesk-video's, and a daemon that \
                      stopped asking for one of them is deciding the send rate itself (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"fn decide_inner *\(|fn app_limited_decay *\(|fn utilization_permits_ramp *\(|fn clean_link_step *\(|fn cut_target *\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd re-spells an AIMD branch in {files} — the rate law is \
                      decided once, inside slopdesk_video::congestion, and a daemon-local branch diverges \
                      exactly on the congested link nobody is watching (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r#""SLOPDESK_ABR_"#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd spells an ABR knob name in {files} — the whole family \
                      resolves from slopdesk_video::congestion::ABR_KEYS, so a literal beside the table is \
                      a knob the table does not know it has (docs/61 §3)",
        },
        // Each names a decision the law makes, and a second speller of any one of them is a second
        // control law that agrees on the easy cases.
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
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
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"static let (rttAlpha|lossAlpha|minRTTDecay)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the estimate's EWMA weights are spelled in Swift again ({files}) — they live in \
                      network_estimate.rs",
        },
        // The same weights, in the language the host is written in now. The Rust respelling of
        // `static let rttAlpha` is a `const` on the crate's own estimate, so it is the DECLARATION
        // that is banned: a daemon that declares one is folding a report itself.
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\b(const|let) (RTT_ALPHA|LOSS_ALPHA|MIN_RTT_DECAY)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd spells an EWMA weight in {files} — the fold lives in \
                      slopdesk_video::network_estimate and no env reads these, so a daemon-local copy \
                      drifts for a whole release with every suite green (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

/// The FRAME-RATE axis — `rust/slopdesk-video`'s `fps_governor`.
///
/// Two governors, the gate they actuate through and the self-heal cadence, all in one crate module.
/// `EncodeCadenceGate` is the DELIVERY axis's gate and `EncodeLoadPacer` is the COMPUTE axis's, so
/// both are named: a daemon that asked for the governor but not the gate would be picking a rate
/// and then admitting frames on a schedule of its own.
///
/// The LADDER is the shape both axes step, and a second speller of it would let the two disagree
/// about which rungs exist — which is why the divisor loop and the rung push are banned by their
/// Rust spelling rather than their Swift one. The gate's schedule arithmetic is the other one: a
/// drift-free advance re-derived by hand is how a metronome becomes a beat pattern, so
/// `next_due_seconds +=` is banned even though reading the field back out of a restore is fine.
/// The per-frame budget is the third — `1000.0 / f64::from(fps)` is four characters of arithmetic
/// and a whole second answer to how long a frame may take.
///
/// The bans are scoped to the daemon, because a frame interval is a shape rather than a law — the
/// loopback harness computes its own slot times and is not what this rule pins.
///
/// The congestion predicate must keep reading the RATE law's tunables, and the crate now enforces
/// that in its signature: `congestion_evidence` TAKES a `&CongestionConfig`. So what is left to
/// pin is the other direction — a daemon that grows its own predicate, or its own copy of the
/// inflate factor and the loss threshold, is the drift that makes the frame rate step down on
/// evidence the rate law ignored. It is banned rather than asked because the daemon's inbound half
/// is still landing; the ban holds from the first line of it, and the ask would have to wait.
#[must_use]
pub fn frame_rate(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &[
                "fps_governor",
                "FpsGovernorConfig",
                "EncodeCadenceGate",
                "EncodeLoadPacer",
            ],
            message: "rust/slopdesk-videohostd stopped naming {entry} — the rate ladder, its config, the \
                      delivery gate and the compute pacer are rust/slopdesk-video's fps_governor, and a \
                      daemon missing one of them is choosing a cadence the crate never governed (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"rungs\.(push|insert)\(|for divisor in |next_due_seconds *\+=",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd builds a ladder or advances a cadence in {files} — both live \
                      in slopdesk_video::fps_governor, and a second speller of either turns a metronome \
                      into a beat pattern (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"1000\.0 */ *\(?(f64::from|[a-z_]+ as f64)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd derives a per-frame budget in {files} — four characters of \
                      arithmetic are still a whole second answer to how long a frame may take, and the \
                      answer is slopdesk_video::fps_governor's (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"fn congestion_evidence *\(|\brtt_inflate_factor\b|config\.loss_threshold",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd decides congestion evidence itself in {files} — \
                      slopdesk_video::fps_governor::congestion_evidence takes the ABR's own \
                      &CongestionConfig for exactly this reason, so a local predicate steps the frame rate \
                      down on evidence the rate law ignored (docs/61 §3)",
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
        // Both of these stay at `Sources` for [`crate::claim::SWIFT_ROOTS`]'s third reason, and each
        // shows a different face of it. The knob names are the door's own contract: `OwdLateDetector`
        // and `PacerDepthPolicy` are configured through the environment, so the suite that proves the
        // clamps SETS `SLOPDESK_OWD_LATE_FRAC_PCT` to 9999 — spelling the name is how it asks. The
        // identifier ban is the subtler one: its only hit in `Tests` is `lateTimes` in a TRAILING
        // comment explaining a ring size, and `View::Code` strips whole-line comments, not trailing
        // ones — so widening this would report a test's prose as a relapse. The ban itself is right
        // about tests; the VIEW cannot tell them apart, and a rule that fires on a comment teaches
        // people to stop reading it.
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

    /// A daemon that asks `rust/slopdesk-video` for every control law these three rules are about.
    ///
    /// ONE file rather than one per rule, because that is how the daemon reads: `session_capture`
    /// resolves each key table through the crate's own resolver and hands the config straight back.
    /// Every break-test below starts from this and seeds ONE drift into it, so what each test
    /// demonstrates is the drift and not the scaffolding.
    const DAEMON_ASKS: &str = "\
use slopdesk_video::congestion::{self, ABR_KEYS, CongestionConfig};
use slopdesk_video::fps_governor::{self, EncodeCadenceGate, EncodeLoadPacer, FpsGovernorConfig};
use slopdesk_video::network_estimate::NetworkEstimate;
use slopdesk_video::qp_control::{self, QpConfig};
use slopdesk_video::recovery_idr::RecoveryIdrPolicy;
use slopdesk_video::recovery_routing::route_recovery;
use slopdesk_video::session_state::SessionState;
";

    /// The daemon file every break-test drifts, and the live Swift target that must stay quiet.
    const DAEMON_FILE: &str = "rust/slopdesk-videohostd/src/session_capture.rs";

    fn seeded(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(DAEMON_FILE, DAEMON_ASKS)
            .write("Sources/SlopDeskVideoClient/A.swift", "let ordinary = 1\n");
        fixture
    }

    /// The state a re-implementation grows back, now that the re-implementation would be Rust.
    ///
    /// Each of these is one line the compiler is perfectly happy with and no suite can see: the
    /// daemon still calls `qp_control`, still calls `recovery_idr`, and now also carries its own
    /// streak or its own bucket beside them. The two agree until the link is in trouble.
    #[test]
    fn a_daemon_that_respells_an_admission_is_caught() {
        for line in [
            "let clean_streak = 0;\n",
            "let recent_keyframes: Vec<u32> = Vec::new();\n",
            "fn refill(now: f64) {}\n",
            "let refill_tokens_per_second = 2.0;\n",
            "let bucket_capacity = 2.0;\n",
        ] {
            let fixture = seeded("admission-respell");
            assert!(super::admission(&fixture.tree()).is_clean(), "{line}");

            fixture.append(DAEMON_FILE, line);
            let report = super::admission(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("admission's own state")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// The sentinel is HALF the routing rule, and the half a daemon is most likely to grow back:
    /// the crate already answers the frontier, so a `== NO_FRAME_DECODED_SENTINEL` beside it looks
    /// like a harmless normalisation. It is a second speller that agrees on every frontier except
    /// "nothing decoded yet" — a client at its most frozen. The bare literal is the same drift
    /// spelled without the name, which is why both are banned.
    #[test]
    fn a_daemon_that_names_the_sentinel_is_caught() {
        for line in [
            "let frontier = if raw == NO_FRAME_DECODED_SENTINEL { None } else { Some(raw) };\n",
            "let frontier = if raw == 0xFFFF_FFFF { None } else { Some(raw) };\n",
        ] {
            let fixture = seeded("admission-sentinel");
            assert!(super::admission(&fixture.tree()).is_clean(), "{line}");

            fixture.append(DAEMON_FILE, line);
            let report = super::admission(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("no-frame-decoded sentinel")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// A token bucket is a SHAPE rather than a law, and the scope is what keeps the ban honest at
    /// both ends: `rust/slopdesk-video` IS the bucket, so the crate that owns the law must not fire
    /// on it, and the notification rate limiter in `SlopDeskWorkspaceCore` is its own.
    #[test]
    fn a_token_bucket_outside_the_daemon_is_not_this_law() {
        let fixture = seeded("admission-scope");
        fixture
            .write(
                "rust/slopdesk-video/src/recovery_idr.rs",
                "struct Policy { tokens: f64, recent_keyframes: Vec<u32> }\nfn refill(now: f64) {}\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/RateLimiter.swift",
                "var tokens: Double = 3\n",
            );
        assert!(super::admission(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-videohostd/src/sneak.rs",
            "fn refill(now: f64) {}\n",
        );
        let report = super::admission(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("admission's own state")),
            "{report:?}"
        );
    }

    /// A rule whose subject stopped answering is worse than a deleted one, so `MentionsUnder` fails
    /// on a drained root. A daemon that no longer names `recovery_idr` is not one that stopped
    /// re-keying — it is one deciding when to re-key somewhere the crate's suite does not run.
    #[test]
    fn a_daemon_that_stopped_asking_an_admission_is_caught() {
        let fixture = seeded("admission-drained");
        assert!(super::admission(&fixture.tree()).is_clean());

        fixture.write(
            DAEMON_FILE,
            "\
use slopdesk_video::qp_control::QpConfig;
use slopdesk_video::recovery_routing::route_recovery;
use slopdesk_video::session_state::SessionState;
",
        );
        let report = super::admission(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped naming recovery_idr")),
            "{report:?}"
        );
    }

    /// A second AIMD branch in the daemon agrees with the crate on every clean link and diverges on
    /// the congested one — the case the suite's numbers are too small to tell apart.
    #[test]
    fn a_daemon_that_respells_an_aimd_branch_is_caught() {
        for line in [
            "fn decide_inner(&mut self) -> i64 { 0 }\n",
            "fn app_limited_decay(&self) -> Option<i64> { None }\n",
            "fn utilization_permits_ramp(&self) -> bool { true }\n",
            "fn clean_link_step(&mut self) -> Option<i64> { None }\n",
            "fn cut_target(&self) -> i64 { 0 }\n",
        ] {
            let fixture = seeded("rate-law-branch");
            assert!(super::rate_law(&fixture.tree()).is_clean(), "{line}");

            fixture.append(DAEMON_FILE, line);
            let report = super::rate_law(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("AIMD branch")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// The drift the old COUNT was reaching for, seeded directly: a knob resolved beside the table
    /// rather than out of it. `SLOPDESK_ABR_GRAD` is the honest-looking version — it IS a real key,
    /// it IS the last slot of `ABR_KEYS`, and looking it up by hand is exactly how the daemon and
    /// the crate stop agreeing about which knobs exist.
    #[test]
    fn a_daemon_that_spells_an_abr_knob_is_caught() {
        let fixture = seeded("rate-law-knob");
        assert!(super::rate_law(&fixture.tree()).is_clean());

        fixture.append(
            DAEMON_FILE,
            "let raw = overlay.get(\"SLOPDESK_ABR_GRAD\").as_deref();\n",
        );
        let report = super::rate_law(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("ABR knob name")),
            "{report:?}"
        );
    }

    /// No env reads the EWMA weights and nothing hands them across, so a daemon-local declaration
    /// of one could drift for a whole release with every suite green. Only the shape catches it.
    #[test]
    fn an_ewma_weight_declared_in_the_daemon_is_caught() {
        for line in [
            "const RTT_ALPHA: f64 = 0.125;\n",
            "const LOSS_ALPHA: f64 = 0.125;\n",
            "let MIN_RTT_DECAY = 0.01;\n",
        ] {
            let fixture = seeded("rate-law-ewma");
            assert!(super::rate_law(&fixture.tree()).is_clean(), "{line}");

            fixture.append(DAEMON_FILE, line);
            let report = super::rate_law(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("EWMA weight")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// The rate law's ask going quiet: a daemon that stopped naming `ABR_KEYS` is one that decided
    /// for itself which knobs the operating point has.
    #[test]
    fn a_daemon_that_stopped_asking_the_rate_law_is_caught() {
        let fixture = seeded("rate-law-drained");
        assert!(super::rate_law(&fixture.tree()).is_clean());

        fixture.write(
            DAEMON_FILE,
            "\
use slopdesk_video::congestion::CongestionConfig;
use slopdesk_video::network_estimate::NetworkEstimate;
",
        );
        let report = super::rate_law(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped naming ABR_KEYS")),
            "{report:?}"
        );
    }

    /// A ladder built twice lets the two axes disagree about which rungs exist, and an advance
    /// re-derived by hand is how a metronome becomes a beat pattern. Both are one line.
    #[test]
    fn a_daemon_that_rebuilds_the_ladder_is_caught() {
        for line in [
            "for divisor in 2..=4 {\n",
            "rungs.push(rung);\n",
            "self.next_due_seconds += interval;\n",
        ] {
            let fixture = seeded("frame-rate-ladder");
            assert!(super::frame_rate(&fixture.tree()).is_clean(), "{line}");

            fixture.append(DAEMON_FILE, line);
            let report = super::frame_rate(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("beat pattern")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// The budget is one division, and it is written both ways in real Rust — through `f64::from`
    /// and through an `as` cast that the parenthesis hides. The ban has to see both spellings, so
    /// the break-test seeds both.
    #[test]
    fn a_daemon_that_derives_the_frame_budget_is_caught() {
        for line in [
            "let budget = 1000.0 / f64::from(fps);\n",
            "let budget = 1000.0 / (fps as f64);\n",
            "let budget = 1000.0 / fps as f64;\n",
        ] {
            let fixture = seeded("frame-rate-budget");
            assert!(super::frame_rate(&fixture.tree()).is_clean(), "{line}");

            fixture.append(DAEMON_FILE, line);
            let report = super::frame_rate(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("how long a frame may take")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// The successor of the old "keep passing the ABR's own config" claim. The crate now demands
    /// that config in `congestion_evidence`'s signature, so the drift left to catch is the daemon
    /// answering the question itself — which steps the frame rate down on evidence the rate law
    /// ignored, with both controllers internally consistent.
    #[test]
    fn a_daemon_that_decides_congestion_evidence_itself_is_caught() {
        for line in [
            "fn congestion_evidence(&self) -> bool { false }\n",
            "let inflate = self.rtt_inflate_factor;\n",
            "if loss > config.loss_threshold { return true; }\n",
        ] {
            let fixture = seeded("frame-rate-evidence");
            assert!(super::frame_rate(&fixture.tree()).is_clean(), "{line}");

            fixture.append(DAEMON_FILE, line);
            let report = super::frame_rate(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("congestion evidence")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// The frame-rate ask going quiet: a governor without its gate is a rate chosen by the crate
    /// and admitted on a schedule of the daemon's own.
    #[test]
    fn a_daemon_that_stopped_asking_the_frame_rate_axis_is_caught() {
        let fixture = seeded("frame-rate-drained");
        assert!(super::frame_rate(&fixture.tree()).is_clean());

        fixture.write(
            DAEMON_FILE,
            "use slopdesk_video::fps_governor::{EncodeLoadPacer, FpsGovernorConfig};\n",
        );
        let report = super::frame_rate(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped naming EncodeCadenceGate")),
            "{report:?}"
        );
    }
}
