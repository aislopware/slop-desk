//! Where a window goes, and who decides — the parked placement, the off-screen rescue, the
//! discovery cadence, the raise rule and the two accumulators that cross by value.
//!
//! Ported from the deleted `check-supervisor.sh`. Every one of these is arithmetic over a screen
//! the test machine does not have, which is exactly why a second copy survives a green suite.

use crate::claim::{Claim, Extract, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The Swift poller, and the Rust one that will replace it once `docs/61`'s cascade lands.
const GEOMETRY_SWIFT: &str = "Sources/SlopDeskVideoHost/WindowGeometryWatcher.swift";
/// The Rust poller. Registered as stranded in `repo_invariants` for the same reason as this rule.
const GEOMETRY_RUST: &str = "rust/slopdesk-videohostd/src/windowgeometry.rs";

/// The drag cadence and the union divider agree, until one of the two pollers is deleted
///
/// Both numbers are spelled twice, once per language, which `shared-number-asked-or-ratcheted`
/// finds and is right to find. Neither of its two ordinary answers fits while the port is in
/// flight. A `CSlopDeskFFI` door would be built into a file `docs/61` §1 schedules for deletion —
/// paying an ABI to serve a caller with weeks to live. And the DELETION cannot come first:
/// `docs/61` §3 says the capture half is unported, so `Sources/SlopDeskVideoHost` is what actually
/// runs and removing it would leave zero implementations rather than one.
///
/// So the pair is ratcheted by VALUE, which is the third answer that rule's own message names. This
/// gate is what keeps the interval honest in the window where two copies exist: change 30 Hz on one
/// side and the sets stop being equal. It also registers both names in the sweep's corpus, which is
/// how the finding above is suppressed — by a gate that compares them, not by a list that excuses
/// them.
///
/// The numbers cross as their INTEGER text on both sides, which is why the Rust pattern eats the
/// `.0`: `30` and `30.0` are the same cadence and a set comparison over raw literals would call
/// them a drift. Deleting this rule is a step in the same commit that deletes the Swift.
#[must_use]
pub fn the_drag_cadence_is_ratcheted_across_the_port(tree: &Tree) -> Report {
    check_all(tree, &[Claim::SameSet {
        label: "the drag poll cadence and the union divider",
        swift: Extract::code(GEOMETRY_SWIFT, r"dragPollHz: Double = ([0-9]+)")
            .also(&[r"unionPollDivider = ([0-9]+)"]),
        rust: Extract::code(GEOMETRY_RUST, r"DRAG_POLL_HZ: f64 = ([0-9]+)\.0")
            .also(&[r"UNION_POLL_DIVIDER: u32 = ([0-9]+)"]),
    }])
}

/// The park math is Rust, and Swift keeps only what CoreGraphics defines
///
/// `WindowPlacementMath` was reabsorbed into Swift back when a Rust twin was a mirror rather than
/// the implementation, and its 19 frozen vectors were pinned by a comment for a long time. The
/// arithmetic is now `window_placement`, replayed on both sides of the door. Two things must not
/// come back: the ordered ternary (a `Swift.min` here would swallow a NaN the corpus pins) and the
/// half-point tolerance, which decides whether an app is asked to resize at all.
#[must_use]
pub fn parked_window_placed_by_one(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoHost/WindowPlacement.swift",
            names: &["slopdesk_window_placement", "slopdesk_window_fits"],
            message: "Sources/SlopDeskVideoHost/WindowPlacement.swift no longer parks through {entry} — \
                      that math is rust/slopdesk-video's window_placement",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/WindowPlacement.swift"],
            pattern: r"\+ 0\.5|< windowSize\.|needsResize = ",
            view: View::Code,
            message: "{files} re-derives the clamp or the half-point tolerance — window_placement.rs owns \
                      both",
        },
    ];
    check_all(tree, &claims)
}

/// The off-screen rescue decides once, and it decides in Rust
///
/// The settle gate is the whole rescue: capture size is locked from the minted handle's frame, the
/// Dock restore reports intermediate frames that already claim to be on screen, and a mid-animation
/// mint crops the stream permanently because nothing re-targets afterwards. That tree existed
/// twice, once per language, and a second copy of it does not fail a test — it crops a pane. It
/// lives in `slopdesk-video`'s `mint_rescue` now, driven a step at a time because every effect it
/// needs suspends on the Swift side and no C ABI can call back into that and wait.
#[must_use]
pub fn off_screen_rescue_decides_once(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoHost/OffScreenWindowMintRescue.swift",
            names: &["slopdesk_mint_rescue_begin", "slopdesk_mint_rescue_advance"],
            message: "Sources/SlopDeskVideoHost/OffScreenWindowMintRescue.swift no longer drives {entry} — \
                      the decision tree is mint_rescue.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/OffScreenWindowMintRescue.swift"],
            pattern: r"func settledHandle|lastSighting|pollAttempts >|prior\.frame ==",
            view: View::Code,
            message: "{files} re-derives the settle gate in Swift — two consecutive agreeing frames is \
                      mint_rescue.rs's rule",
        },
        Claim::Names {
            path: "rust/slopdesk-video/src/mint_rescue.rs",
            needle: "fn advance",
            message: "rust/slopdesk-video/src/mint_rescue.rs lost advance — the rescue asks for one step \
                      and takes one observation",
        },
    ];
    check_all(tree, &claims)
}

/// One discovery, one resend schedule
///
/// The window picker and the display switcher run the SAME one-shot discovery over a transient
/// lane, and it was written twice here and a third time in Rust that nothing reached. The schedule
/// is the part with arithmetic in it — and an interval of zero or less is not a schedule but a
/// spin, which the Swift loop had no answer for. It comes from `slopdesk-video` now, and the two
/// discoveries are one function that differs only in which message it sends.
#[must_use]
pub fn one_discovery_one_resend_schedule(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskVideoClient/VideoWindowDiscovery.swift",
            needle: "slopdesk_video_request_send_offsets",
            message: "Sources/SlopDeskVideoClient/VideoWindowDiscovery.swift no longer takes its resend \
                      schedule from slopdesk_video_request_send_offsets",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoClient/VideoWindowDiscovery.swift"],
            pattern: r"ContinuousClock\.now < deadline|advanced\(by: timeout\)",
            view: View::Code,
            message: "{files} walks its own deadline again — the schedule is mux_client_pool.rs's \
                      request_send_offsets",
        },
        Claim::NoneOf {
            paths: &["rust/slopdesk-video/src/mux_client_pool.rs"],
            pattern: r"OneShotDiscovery|DiscoveryKind",
            view: View::Code,
            message: "{files} is a discovery gate no caller reaches — the reply is extracted where it is \
                      decoded, in Swift",
        },
    ];
    check_all(tree, &claims)
}

/// The raise rule is read once, off one event
///
/// Raising is the expensive half of injecting — six to ten synchronous accessibility calls the
/// input consumer awaits before the click is posted — and the four predicates that decide it
/// (always, re-arm, latch-exempt, and the raise itself) were four Swift functions mirroring four
/// Rust ones nothing reached. They are one reading of one event now: `slopdesk_input_raise_flags`
/// answers all four as bits, so they cannot disagree about which arm they were shown.
///
/// The FRONTMOST-app half of the decision is no longer read here at all. It went inside the
/// injector handle with the rest of the injector (`docs/60`), onto the raise thread that acts on
/// it, where it is taken against the frontmost pid the same thread just sampled — so there is no
/// window between asking and acting for the answer to go stale in, and
/// `slopdesk_input_should_raise` has no caller left to be a door for. What Swift still reads is
/// which EVENT wants a raise, and that stays one call.
#[must_use]
pub fn raise_rule_read_once_off(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            names: &["slopdesk_input_raise_flags"],
            message: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift no longer takes its raise decision \
                      from {entry}",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/VideoSessionLogic.swift"],
            pattern: r"case \.mouseDown = event|case \.scroll = event|case \.mouseUp = event",
            view: View::Code,
            message: "{files} reads an arm to decide a raise again — the rule is input_routing.rs, through \
                      one door",
        },
        Claim::NoneOf {
            paths: &["rust/slopdesk-video/src/input_routing.rs"],
            pattern: r"fn route_input|enum InputDecision",
            view: View::Code,
            message: "{files} folds the streaming gate, the decode and the raise back together — each has \
                      one home",
        },
    ];
    check_all(tree, &claims)
}

/// The ledger and the accumulator cross by VALUE, and hold no rule
///
/// Both are stateful folds whose owners COPY them — the injector holds one under a lock, the
/// session CARRIES one across a reconnect, a test folds one of its own — so neither can be a
/// handle: a handle they copied would be two ledgers by the second copy (docs/55 §4b). The state
/// crosses instead. The ledger is twelve bits, three buttons and nine modifier keycodes, and the
/// modifier BIT is a key's position in the far side's own table, which is why that table is not
/// spelled here either.
#[must_use]
pub fn ledger_accumulator_cross_by_value(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            names: &[
                "slopdesk_input_balance_plan",
                "slopdesk_scroll_planner_plan",
                "slopdesk_scroll_planner_clear",
            ],
            message: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift no longer folds through {entry}",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/VideoSessionLogic.swift"],
            pattern: r"held\.insert|held\.remove|heldModifierKeys\.insert|heldModifierKeys\.remove",
            view: View::Code,
            message: "{files} keeps a held set of its own again — the ledger is input_routing.rs's, twelve \
                      bits wide",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/VideoSessionLogic.swift"],
            pattern: r"accumDx|accumTemplate|appendPendingFlush",
            view: View::Code,
            message: "{files} accumulates scroll in Swift again — the metering is ScrollCoalescePlanner, in \
                      Rust",
        },
        Claim::Names {
            path: "Sources/SlopDeskVideoProtocol/InputModifierKeys.swift",
            needle: "slopdesk_input_modifier_key_codes",
            message: "Sources/SlopDeskVideoProtocol/InputModifierKeys.swift spells the held-modifier table \
                      again — the ledger's bits are its order",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_parked_window_placed_by_one(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskVideoHost/WindowPlacement.swift",
            "slopdesk_window_placement\nslopdesk_window_fits\nkept so the ban has a haystack\n",
        );
    }

    #[test]
    fn parked_window_placed_by_one_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("parked-window-placed-by-one");
        write_parked_window_placed_by_one(&fixture);
        assert!(super::parked_window_placed_by_one(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoHost/WindowPlacement.swift", "");
        assert!(!super::parked_window_placed_by_one(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_parked_window_placed_by_one(&fixture);
        fixture.append("Sources/SlopDeskVideoHost/WindowPlacement.swift", "+ 0.5\n");
        assert!(!super::parked_window_placed_by_one(&fixture.tree()).is_clean());
    }

    fn write_off_screen_rescue_decides_once(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoHost/OffScreenWindowMintRescue.swift",
                "slopdesk_mint_rescue_begin\nslopdesk_mint_rescue_advance\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-video/src/mint_rescue.rs",
                "fn advance\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn off_screen_rescue_decides_once_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("off-screen-rescue-decides-once");
        write_off_screen_rescue_decides_once(&fixture);
        assert!(super::off_screen_rescue_decides_once(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoHost/OffScreenWindowMintRescue.swift", "");
        assert!(!super::off_screen_rescue_decides_once(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_off_screen_rescue_decides_once(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoHost/OffScreenWindowMintRescue.swift",
            "func settledHandle\n",
        );
        assert!(!super::off_screen_rescue_decides_once(&fixture.tree()).is_clean());
    }

    fn write_one_discovery_one_resend_schedule(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoClient/VideoWindowDiscovery.swift",
                "slopdesk_video_request_send_offsets\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-video/src/mux_client_pool.rs",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_discovery_one_resend_schedule_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-discovery-one-resend-schedule");
        write_one_discovery_one_resend_schedule(&fixture);
        assert!(super::one_discovery_one_resend_schedule(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoClient/VideoWindowDiscovery.swift", "");
        assert!(!super::one_discovery_one_resend_schedule(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_discovery_one_resend_schedule(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoClient/VideoWindowDiscovery.swift",
            "ContinuousClock.now < deadline\n",
        );
        assert!(!super::one_discovery_one_resend_schedule(&fixture.tree()).is_clean());
    }

    fn write_raise_rule_read_once_off(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
                "slopdesk_input_raise_flags\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-video/src/input_routing.rs",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn raise_rule_read_once_off_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("raise-rule-read-once-off");
        write_raise_rule_read_once_off(&fixture);
        assert!(super::raise_rule_read_once_off(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoHost/VideoSessionLogic.swift", "");
        assert!(!super::raise_rule_read_once_off(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_raise_rule_read_once_off(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            "case .mouseDown = event\n",
        );
        assert!(!super::raise_rule_read_once_off(&fixture.tree()).is_clean());
    }

    fn write_ledger_accumulator_cross_by_value(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
                "slopdesk_input_balance_plan\nslopdesk_scroll_planner_plan\nslopdesk_scroll_planner_clear\\
                 nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/InputModifierKeys.swift",
                "slopdesk_input_modifier_key_codes\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn ledger_accumulator_cross_by_value_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("ledger-accumulator-cross-by-value");
        write_ledger_accumulator_cross_by_value(&fixture);
        assert!(super::ledger_accumulator_cross_by_value(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoHost/VideoSessionLogic.swift", "");
        assert!(!super::ledger_accumulator_cross_by_value(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_ledger_accumulator_cross_by_value(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            "held.insert\n",
        );
        assert!(!super::ledger_accumulator_cross_by_value(&fixture.tree()).is_clean());
    }

    fn write_drag_cadence(fixture: &Fixture, swift_hz: &str, rust_hz: &str) {
        fixture
            .write(
                super::GEOMETRY_SWIFT,
                &format!(
                    "public static let dragPollHz: Double = {swift_hz}\nprivate static let unionPollDivider \
                     = 5\n"
                ),
            )
            .write(
                super::GEOMETRY_RUST,
                &format!(
                    "pub const DRAG_POLL_HZ: f64 = {rust_hz}.0;\npub const UNION_POLL_DIVIDER: u32 = 5;\n"
                ),
            );
    }

    /// `30` and `30.0` are the same cadence; `30` and `60` are the drift this exists to catch.
    #[test]
    fn the_drag_cadence_agrees_across_the_port_or_it_is_red() {
        let fixture = Fixture::new("drag-cadence-ratchet");
        write_drag_cadence(&fixture, "30", "30");
        assert!(super::the_drag_cadence_is_ratcheted_across_the_port(&fixture.tree()).is_clean());

        // One side is retuned and the other is not — the window this rule exists for.
        write_drag_cadence(&fixture, "60", "30");
        assert!(!super::the_drag_cadence_is_ratcheted_across_the_port(&fixture.tree()).is_clean());

        // And the divider, which the same claim carries through `also`.
        write_drag_cadence(&fixture, "30", "30");
        fixture.write(
            super::GEOMETRY_RUST,
            "pub const DRAG_POLL_HZ: f64 = 30.0;\npub const UNION_POLL_DIVIDER: u32 = 7;\n",
        );
        assert!(!super::the_drag_cadence_is_ratcheted_across_the_port(&fixture.tree()).is_clean());
    }
}
