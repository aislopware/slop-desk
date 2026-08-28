//! Where a window goes, and who decides — the parked placement, the off-screen rescue, the
//! discovery cadence, the raise rule and the two accumulators that cross by value.
//!
//! Ported from the deleted `check-supervisor.sh`. Every one of these is arithmetic over a screen
//! the test machine does not have, which is exactly why a second copy survives a green suite.
//!
//! ## What `docs/61` changed here
//!
//! Four of these rules named a file under `Sources/SlopDeskVideoHost` and asked two things of it:
//! that it CALLED the crate's door, and that it did not respell the interior behind that door.
//! That target is deleted and its doors went with it — `rust/slopdesk-videohostd` links
//! `slopdesk-video` as an ordinary Rust dependency, so there is no `(ptr, len)` left to prove a
//! call across and no `slopdesk_window_placement` for a message to name.
//!
//! So the door half is re-aimed rather than dropped: "the law is asked, not re-derived" is a
//! [`Claim::MentionsUnder`] over the DAEMON's directory, naming the crate module each rule is
//! about. It reads the directory rather than a file because the daemon's modules are still being
//! split, and a claim pinned to a filename would go wrong the moment a session module divides —
//! drift these rules were never about.
//!
//! The "no Swift brings this back" half is stated ONCE, tree-wide and at full strength, in
//! [`crate::rules::deleted_video_swift`]: no Swift target may declare a video-host type, not just
//! the file that used to hold one. What is left below is the ban that only makes sense HERE — the
//! interior, spelled in the daemon's own language, which is the one language it could come back in.
//!
//! [`one_discovery_one_resend_schedule`] is untouched by any of that: its face is
//! `Sources/SlopDeskVideoClient`, which is live client Swift.

use crate::claim::{Claim, RUST, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The daemon that IS the GUI host — `docs/61`.
///
/// A directory rather than a file, for the reason the module doc gives: the faces these rules used
/// to name one-for-one are modules of this crate, and which module holds which face is still
/// moving. The bans below are scoped to it and NOT to `rust/slopdesk-video`, which legitimately
/// spells every interior they forbid — that crate is where the interiors are supposed to be.
const DAEMON: &str = "rust/slopdesk-videohostd";

/// The Rust poller, and the only place the drag cadence is spelled at all.
const GEOMETRY_RUST: &str = "rust/slopdesk-videohostd/src/windowgeometry.rs";

/// The drag cadence and the union divider are named constants, spelled once
///
/// NOTE — what this rule used to be. It was a `SameSet` ratchet across the port: `dragPollHz` and
/// `unionPollDivider` in the deleted Swift `WindowGeometryWatcher` had to equal
/// `DRAG_POLL_HZ` and `UNION_POLL_DIVIDER` here, because two pollers existed at once and retuning
/// one of them was a drift no suite could see. `docs/61` §1 row 13 deleted the Swift watcher, so
/// that cross-language subject dissolved: there is nothing left to compare a value against, and a
/// `SameSet` whose Swift side does not exist is the vacuous pass this crate exists to refuse.
///
/// Row 13 sanctions dropping the rule outright. It is re-aimed instead, the way row 8 treats
/// `apple_floors`, because the thing the ratchet actually protected outlived its Swift half: the
/// cadence must be a NAMED constant that every reader reaches, rather than an interval typed at the
/// call site. That is the failure the old rule caught in the only shape it can still take. A
/// `Duration::from_millis(33)` in a second poller is 30.3 Hz — close enough that nothing looks
/// wrong, far enough that the DIALOG-EXPAND region is sampled against a divider that no longer
/// divides the poll it was written for, and the union sample drifts off the drag it belongs to.
///
/// The ban is scoped to the daemon because the daemon is the only place a second poller could be
/// written now, and it names the LITERALS rather than the constants: `DRAG_POLL_HZ: f64 = 30.0` is
/// the declaration this rule protects, not a violation of it.
#[must_use]
pub fn the_drag_cadence_is_ratcheted_across_the_port(tree: &Tree) -> Report {
    let claims = [
        Claim::Matches {
            path: GEOMETRY_RUST,
            pattern: r"const DRAG_POLL_HZ: f64 = [0-9]",
            view: View::Code,
            message: "rust/slopdesk-videohostd/src/windowgeometry.rs no longer declares DRAG_POLL_HZ — the \
                      drag poll cadence is a named constant so that every reader reaches the same one \
                      (docs/61 §1 row 13)",
        },
        Claim::Matches {
            path: GEOMETRY_RUST,
            pattern: r"const UNION_POLL_DIVIDER: u32 = [0-9]",
            view: View::Code,
            message: "rust/slopdesk-videohostd/src/windowgeometry.rs no longer declares UNION_POLL_DIVIDER \
                      — the DIALOG-EXPAND region is sampled every Nth poll, and N is only meaningful beside \
                      the cadence it divides (docs/61 §1 row 13)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"from_secs_f64\(1\.0 */ *30|from_millis\(33\)|is_multiple_of\(5\)|% *5 *== *0",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the drag cadence or the union divider is typed as a literal in {files} — both are \
                      windowgeometry.rs's DRAG_POLL_HZ and UNION_POLL_DIVIDER, and a hand-typed 33 ms is \
                      30.3 Hz: near enough that nothing looks wrong, far enough that the region sample \
                      drifts off the drag it belongs to (docs/61 §1 row 13)",
        },
    ];
    check_all(tree, &claims)
}

/// The park math is `window_placement`'s, and the daemon keeps only the effects
///
/// `WindowPlacementMath` was reabsorbed into Swift back when a Rust twin was a mirror rather than
/// the implementation, and its 19 frozen vectors were pinned by a comment for a long time. The
/// arithmetic is `slopdesk-video`'s `window_placement`, golden-pinned by `place` and `fits`.
///
/// The face that used to ask it through a door is gone; `windowplace.rs` asks it as an ordinary
/// call, which is why the ask below reads the daemon's directory. Two things must not come back on
/// the daemon's side: the clamp, whose ordered comparison is what keeps a NaN the corpus pins from
/// being swallowed, and the half-point tolerance, which decides whether an app is asked to resize
/// at all. A daemon that re-derives either has two answers to "does this window already fit", and
/// the one that loses is the one holding the window the user is watching.
///
/// The ban names `place`, `fits`, the tolerance and an ASSIGNMENT to `needs_resize` — a READ of
/// `plan.needs_resize` is the daemon using the crate's answer, which is the whole point.
#[must_use]
pub fn parked_window_placed_by_one(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["window_placement"],
            message: "the daemon stopped asking {entry} — the park clamp, the half-point tolerance and the \
                      fits test are rust/slopdesk-video's, golden-pinned, and a host that stopped asking \
                      has started deciding (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bfn (place|fits)\b|\bneeds_resize *[:=][^=]|\bPLACEMENT_TOLERANCE\b|\bTOLERANCE *: *f64",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon re-derives the park clamp or the half-point tolerance in {files} — both \
                      live in window_placement.rs and are golden-pinned, and a second tolerance decides \
                      whether an app is asked to resize at all (docs/61 §3)",
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
/// lives in `slopdesk-video`'s `mint_rescue`, driven a step at a time because every effect it needs
/// blocks in the caller and no decision may block with it.
///
/// The step loop is `rust/slopdesk-videohostd`'s `rescue.rs` now — it asks `begin`, `next_step` and
/// `advance` and does nothing between them but perform the effect each step names. The ban keeps
/// the STATE out of it: `polls_left`, the stage ladder and the `prior == Some(frame)` settle test
/// are the tree itself, and a daemon that kept its own copy of any of them is the second decision
/// this rule was always about — in the one language left to type it in.
#[must_use]
pub fn off_screen_rescue_decides_once(tree: &Tree) -> Report {
    let claims = [
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["mint_rescue"],
            message: "the daemon stopped asking {entry} — the settle gate, the poll budget and the stage \
                      ladder are rust/slopdesk-video's, and a second copy does not fail a test, it crops a \
                      pane (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"prior *== *Some|\bpolls_left\b|\bfn (next_step|is_finished|stage_of)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon re-derives the rescue's settle gate or its poll budget in {files} — two \
                      consecutive agreeing frames is mint_rescue.rs's rule, and a mid-animation mint crops \
                      the stream permanently because nothing re-targets afterwards (docs/61 §3)",
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
/// input consumer waits on before the click is posted — and the four predicates that decide it
/// (always, re-arm, latch-exempt, and the raise itself) were once four Swift functions mirroring
/// four Rust ones nothing reached. They are one reading of one event now: `input_routing` answers
/// all four, so they cannot disagree about which arm they were shown.
///
/// The FRONTMOST-app half of the decision is not read at the call site at all. It went inside the
/// injector with the rest of the injector (`docs/60`), onto the raise thread that acts on it, where
/// it is taken against the frontmost pid the same thread just sampled — so there is no window
/// between asking and acting for the answer to go stale in.
///
/// There is no positive ask over the daemon here on purpose, for the reason `video_host`'s
/// `accumulators` gives about `recovery_dedupe`: the injector is still a SEAM with a `None` slot,
/// and a claim that the daemon already reaches the raise predicates would be a claim about a
/// schedule rather than about a law. The two claims below are the halves that hold either way — the
/// crate keeps its four predicates unfolded, and whenever the injection half lands in the daemon it
/// lands asking them rather than carrying a latch of its own.
#[must_use]
pub fn raise_rule_read_once_off(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "rust/slopdesk-video/src/input_routing.rs",
            names: &["fn always_raises", "fn rearm_raise_after", "fn raise_first"],
            message: "rust/slopdesk-video/src/input_routing.rs lost {entry} — the four raise predicates are \
                      one reading of one event, so they cannot disagree about which arm they were shown \
                      (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bfn (always_raises|rearm_raise_after|latch_exempt_from_raise|raise_first|should_raise)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon decides a raise for itself in {files} — the four predicates are \
                      input_routing.rs's, and a copy that disagrees about one arm spends six to ten \
                      synchronous accessibility calls on a click that never needed them, or skips them on \
                      the one that did (docs/61 §3)",
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

/// The ledger and the accumulator hold state, and hold no rule
///
/// Both are stateful folds whose owners COPY them — the injector holds one under a lock, the
/// session CARRIES one across a reconnect, a test folds one of its own — so neither could ever be a
/// handle: a handle they copied would be two ledgers by the second copy (docs/55 §4b). Across the
/// deleted FFI door the state crossed by value; inside one process it is an ordinary `Copy` value
/// the daemon keeps and hands back, which changes the marshalling and not the rule. The ledger is
/// twelve bits, three buttons and nine modifier keycodes, and the modifier BIT is a key's position
/// in the far side's own table — which is why that table is not spelled twice either.
///
/// The daemon may OWN either fold: `session_inbound` holds a `ScrollCoalescePlanner` across drains
/// and a raise latch beside it, because that is the state, and state is what the daemon is for. It
/// may not spell the fold. The ban is the interiors — the held sets, the accumulated deltas, the
/// mask packing — because those are the parts that look small enough to re-type: a held set that
/// misses one release leaves a modifier stuck DOWN on the user's real machine, and nothing on
/// either side reports it.
///
/// There is no positive ask over the daemon for the same reason [`raise_rule_read_once_off`] has
/// none: the injector is still a seam with a `None` slot, so a claim that the daemon already folds
/// through the crate would be a claim about a schedule. The crate-side claim is the half that is
/// non-vacuous today, and the ban is the half that holds whenever the injection lands.
#[must_use]
pub fn ledger_accumulator_cross_by_value(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "rust/slopdesk-video/src/input_routing.rs",
            names: &[
                "struct InputButtonBalance",
                "struct ScrollAccumulator",
                "struct ScrollCoalescePlanner",
            ],
            message: "rust/slopdesk-video/src/input_routing.rs lost {entry} — the button ledger and the \
                      scroll accumulator are one fold each, written where they can be tested without a \
                      window server (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bheld_buttons\b|\bheld_modifiers\b|\bfn (masks|from_masks)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon keeps a held set or packs the ledger's masks itself in {files} — the \
                      ledger is input_routing.rs's, twelve bits wide, and a copy that misses one release \
                      leaves a modifier stuck down on the user's real machine (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\baccum_(dx|dy)\b|\bfn plan_slots\b|\bstruct ScrollAccumulator\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon accumulates scroll for itself in {files} — the metering is \
                      input_routing.rs's ScrollCoalescePlanner, which the daemon HOLDS and does not respell \
                      (docs/61 §3)",
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

    /// The daemon, the crate and the one live Swift file, spelled the way a clean tree spells them.
    ///
    /// Every seed here is an ASK — the import and the call that prove the daemon reaches the crate
    /// — because that is what these rules are about after `docs/61`. Nothing under
    /// `rust/slopdesk-videohostd` spells an interior, which is what makes each ban's seed below a
    /// real drift rather than a fixture detail.
    fn seeded(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(
                "rust/slopdesk-videohostd/src/windowplace.rs",
                "use slopdesk_video::window_placement;\nlet plan = window_placement::place(frame, \
                 display);\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/rescue.rs",
                "use slopdesk_video::mint_rescue::{self, Observation, Step};\nlet mut rescue = \
                 mint_rescue::begin(polls);\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/session_inbound.rs",
                "use slopdesk_video::input_routing::{self, ScrollCoalescePlanner};\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/windowgeometry.rs",
                "pub const DRAG_POLL_HZ: f64 = 30.0;\npub const UNION_POLL_DIVIDER: u32 = 5;\n",
            )
            .write(
                "rust/slopdesk-video/src/input_routing.rs",
                "pub const fn always_raises(event: &InputEvent) -> bool {}\npub const fn \
                 rearm_raise_after(event: &InputEvent) -> bool {}\npub const fn raise_first(event: \
                 &InputEvent) -> bool {}\npub struct InputButtonBalance {}\npub struct ScrollAccumulator \
                 {}\npub struct ScrollCoalescePlanner {}\n",
            )
            .write(
                "rust/slopdesk-video/src/mint_rescue.rs",
                "pub fn advance(rescue: &mut Rescue) -> Step {}\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/InputModifierKeys.swift",
                "slopdesk_input_modifier_key_codes\n",
            );
        fixture
    }

    /// A daemon that stopped asking the park math has started deciding it, and a daemon that spells
    /// the tolerance again has two answers to "does this window already fit".
    #[test]
    fn parked_window_placed_by_one_holds_the_daemon_to_the_crate() {
        let fixture = seeded("parked-window-placed-by-one");
        assert!(super::parked_window_placed_by_one(&fixture.tree()).is_clean());

        // The daemon stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "rust/slopdesk-videohostd/src/windowplace.rs",
            "let plan = self.own_placement(frame, display);\n",
        );
        assert!(!super::parked_window_placed_by_one(&fixture.tree()).is_clean());

        // And the law it is banned from respelling, respelled — the fits test, then the resize
        // verdict, which is the half that decides whether an app is asked to resize at all.
        let fixture = seeded("parked-window-respelled");
        fixture.append(
            "rust/slopdesk-videohostd/src/windowplace.rs",
            "fn fits(width: f64, bounds: f64) -> bool { width <= bounds + 0.5 }\n",
        );
        assert!(!super::parked_window_placed_by_one(&fixture.tree()).is_clean());

        let fixture = seeded("parked-window-resize-verdict");
        fixture.append(
            "rust/slopdesk-videohostd/src/windowplace.rs",
            "let needs_resize = achieved.0 < wanted.0;\n",
        );
        assert!(!super::parked_window_placed_by_one(&fixture.tree()).is_clean());
    }

    /// The settle gate, kept in the daemon: two consecutive agreeing frames is the whole rescue,
    /// and a second copy of it does not fail a test — it crops a pane.
    #[test]
    fn off_screen_rescue_decides_once_holds_the_daemon_to_the_crate() {
        let fixture = seeded("off-screen-rescue-decides-once");
        assert!(super::off_screen_rescue_decides_once(&fixture.tree()).is_clean());

        // The daemon stopped asking — the step loop is deciding its own steps.
        fixture.write(
            "rust/slopdesk-videohostd/src/rescue.rs",
            "let mut stage = Stage::Opening;\n",
        );
        assert!(!super::off_screen_rescue_decides_once(&fixture.tree()).is_clean());

        // And the settle test itself, respelled where the effect is performed.
        let fixture = seeded("off-screen-rescue-respelled");
        fixture.append(
            "rust/slopdesk-videohostd/src/rescue.rs",
            "if rescue.prior == Some(frame) { return Step::MintSighted; }\n",
        );
        assert!(!super::off_screen_rescue_decides_once(&fixture.tree()).is_clean());

        // And the poll budget, which is the other half of the same state.
        let fixture = seeded("off-screen-rescue-budget");
        fixture.append(
            "rust/slopdesk-videohostd/src/rescue.rs",
            "self.polls_left -= 1;\n",
        );
        assert!(!super::off_screen_rescue_decides_once(&fixture.tree()).is_clean());
    }

    /// The crate lost a predicate, or the daemon grew one — the two ways the four-way raise reading
    /// stops being one reading.
    #[test]
    fn raise_rule_read_once_off_holds_the_daemon_to_the_crate() {
        let fixture = seeded("raise-rule-read-once-off");
        assert!(super::raise_rule_read_once_off(&fixture.tree()).is_clean());

        // The crate stopped vending one of the four, so nothing single answers it any more.
        fixture.write(
            "rust/slopdesk-video/src/input_routing.rs",
            "pub const fn always_raises(event: &InputEvent) -> bool {}\npub const fn \
             rearm_raise_after(event: &InputEvent) -> bool {}\npub struct InputButtonBalance {}\npub struct \
             ScrollAccumulator {}\npub struct ScrollCoalescePlanner {}\n",
        );
        assert!(!super::raise_rule_read_once_off(&fixture.tree()).is_clean());

        // And the predicate re-typed beside the injection it gates, which is where it is cheapest
        // to type and where a disagreement about one arm costs a whole accessibility round trip.
        let fixture = seeded("raise-rule-respelled");
        fixture.append(
            "rust/slopdesk-videohostd/src/session_inbound.rs",
            "fn raise_first(event: &InputEvent, needs_raise: bool) -> bool { needs_raise }\n",
        );
        assert!(!super::raise_rule_read_once_off(&fixture.tree()).is_clean());
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

    /// The held set kept in the daemon, and the scroll fold re-typed beside the drain it feeds.
    ///
    /// A held set that misses one release leaves a modifier stuck DOWN on the user's real machine,
    /// which no test on either side reports — the exact failure the ledger being single prevents.
    #[test]
    fn ledger_accumulator_cross_by_value_holds_the_daemon_to_the_crate() {
        let fixture = seeded("ledger-accumulator-cross-by-value");
        assert!(super::ledger_accumulator_cross_by_value(&fixture.tree()).is_clean());

        // The crate stopped vending one of the two folds.
        fixture.write(
            "rust/slopdesk-video/src/input_routing.rs",
            "pub const fn always_raises(event: &InputEvent) -> bool {}\npub const fn \
             rearm_raise_after(event: &InputEvent) -> bool {}\npub const fn raise_first(event: &InputEvent) \
             -> bool {}\npub struct ScrollAccumulator {}\npub struct ScrollCoalescePlanner {}\n",
        );
        assert!(!super::ledger_accumulator_cross_by_value(&fixture.tree()).is_clean());

        // The ledger, kept in the daemon beside the injection it gates.
        let fixture = seeded("ledger-held-set");
        fixture.append(
            "rust/slopdesk-videohostd/src/session_inbound.rs",
            "self.held_buttons.insert(button);\n",
        );
        assert!(!super::ledger_accumulator_cross_by_value(&fixture.tree()).is_clean());

        // And the scroll fold, re-typed where the residual is drained.
        let fixture = seeded("ledger-scroll-fold");
        fixture.append(
            "rust/slopdesk-videohostd/src/session_inbound.rs",
            "self.accum_dx += event.dx;\n",
        );
        assert!(!super::ledger_accumulator_cross_by_value(&fixture.tree()).is_clean());

        // The Swift half that did NOT move: the table whose ORDER is the ledger's bit positions.
        let fixture = seeded("ledger-modifier-table");
        fixture.write(
            "Sources/SlopDeskVideoProtocol/InputModifierKeys.swift",
            "static let codes: [UInt16] = [0x38, 0x3B, 0x3A, 0x37]\n",
        );
        assert!(!super::ledger_accumulator_cross_by_value(&fixture.tree()).is_clean());
    }

    /// The cadence must be a NAMED constant, and no second poller may type an interval of its own.
    ///
    /// The old form of this test seeded a Swift `dragPollHz` and a Rust `DRAG_POLL_HZ` that
    /// disagreed. `docs/61` §1 row 13 deleted the Swift watcher, so the drift it seeded cannot be
    /// spelled any more; what it seeds now is the drift that outlived it — the constant dropped,
    /// and a literal interval typed in its place, which is 30.3 Hz against a divider that no longer
    /// divides the poll it was written for.
    #[test]
    fn a_hand_typed_drag_cadence_is_red() {
        let fixture = seeded("drag-cadence-ratchet");
        assert!(super::the_drag_cadence_is_ratcheted_across_the_port(&fixture.tree()).is_clean());

        // The cadence stopped being a named constant at all.
        fixture.write(super::GEOMETRY_RUST, "pub const UNION_POLL_DIVIDER: u32 = 5;\n");
        assert!(!super::the_drag_cadence_is_ratcheted_across_the_port(&fixture.tree()).is_clean());

        // And the divider with it — the region sample has nothing left to be a multiple of.
        let fixture = seeded("drag-cadence-divider");
        fixture.write(super::GEOMETRY_RUST, "pub const DRAG_POLL_HZ: f64 = 30.0;\n");
        assert!(!super::the_drag_cadence_is_ratcheted_across_the_port(&fixture.tree()).is_clean());

        // A second poller, typing the interval instead of reaching the constant.
        let fixture = seeded("drag-cadence-literal");
        fixture.append(
            "rust/slopdesk-videohostd/src/windowgeometry.rs",
            "thread::sleep(Duration::from_millis(33));\n",
        );
        assert!(!super::the_drag_cadence_is_ratcheted_across_the_port(&fixture.tree()).is_clean());

        // And the divider, typed as its literal in a second sampler.
        let fixture = seeded("drag-cadence-divider-literal");
        fixture.append(
            "rust/slopdesk-videohostd/src/windowplace.rs",
            "if ticks % 5 == 0 { self.sample_region(); }\n",
        );
        assert!(!super::the_drag_cadence_is_ratcheted_across_the_port(&fixture.tree()).is_clean());
    }

    /// A `MentionsUnder` over a directory that stripped to nothing must FAIL rather than pass — a
    /// drained daemon is the healthiest-looking answer these gates can print, and it means nothing.
    #[test]
    fn a_drained_daemon_cannot_satisfy_the_ask() {
        let fixture = seeded("window-placement-daemon-drained");
        fixture
            .remove("rust/slopdesk-videohostd/src/windowplace.rs")
            .remove("rust/slopdesk-videohostd/src/rescue.rs")
            .remove("rust/slopdesk-videohostd/src/session_inbound.rs")
            .remove("rust/slopdesk-videohostd/src/windowgeometry.rs");
        assert!(!super::parked_window_placed_by_one(&fixture.tree()).is_clean());
        assert!(!super::off_screen_rescue_decides_once(&fixture.tree()).is_clean());
    }
}
