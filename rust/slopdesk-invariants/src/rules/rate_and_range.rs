//! Where a bucket comes from, and a vocabulary that needs a count as well as a map.
//!
//! Ported from the deleted `check-supervisor.sh`. Two rules that look unrelated and are the same
//! shape twice: a value the crate decides, decided a second time on the near side. In one case that
//! is four doubles and the failure is a banner nobody sees; in the other it is a table length and
//! the failure is a settings field rendered with no range at all.

use crate::claim::{Claim, Extract, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The bucket's Swift face.
const NOTIFIER: &str = "Sources/SlopDeskWorkspaceCore/Connection/CommandCompletionNotifier.swift";
/// The catalog whose `Stepper` vocabulary is walked by a round-trip test.
const SETTINGS_CATALOG_RS: &str = "rust/slopdesk-settings/src/settings_catalog.rs";

/// An anti-flood bucket comes from the crate, burst and all
///
/// The spend door hands the bucket back BY VALUE, so the near side owns the four doubles between
/// calls — and for a year it also decided what a NEW one holds. That is not an assignment: a bucket
/// that rests empty rather than full swallows the first explicit notification of every attach, and
/// a rate limiter is the last place anyone looks for a missing banner.
///
/// Three arms. The face is floored by name first, because its two bans read nothing at all if the
/// file moved. Either constructor door being dropped can only mean the four fields are being filled
/// on this side again. And the ban catches two drifts in one pattern:
/// `SlopDeskWsNotifyRateLimiter(` is the memberwise construction that decided `tokens: capacity`
/// here, while a `= 5` / `= 0.5` default argument on the initialiser is the anti-flood POLICY
/// spelled in Swift — and of two spellings, the looser is always the one that runs. Neither would
/// fail a test if it came back.
#[must_use]
pub fn an_anti_flood_bucket_comes_from_the_crate(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Exists {
            path: NOTIFIER,
            message: "the bucket's Swift face moved, so the bans below stopped checking anything (docs/55 \
                      §6)",
        },
        Claim::Mentions {
            path: NOTIFIER,
            names: &[
                "slopdesk_ws_notify_rate_limiter",
                "slopdesk_ws_notify_explicit_rate_limiter",
            ],
            message: "the notifier stopped calling {entry} — a resting bucket is RateLimiter::new / \
                      ::explicit in rust/slopdesk-workspace's notify (docs/55 §6)",
        },
        Claim::Lacks {
            path: NOTIFIER,
            pattern: r"SlopDeskWsNotifyRateLimiter\(|refillPerSecond: Double = |capacity: Double = ",
            view: View::Code,
            message: "the notifier builds or defaults a bucket again — the burst, the refill rate and 'a \
                      new bucket rests full' are notify.rs's EXPLICIT_BURST / EXPLICIT_REFILL_PER_SECOND / \
                      RateLimiter::new (docs/55 §4, §8)",
        },
    ])
}

/// A vocabulary pin needs a COUNT as well as a map
///
/// `Stepper::ALL` is what the round-trip test walks, and it is hand-maintained. The test already
/// catches a seventh case added to `from_index` but not to `ALL` — `from_index(ALL.len())` would
/// answer `Some` where it asserts `None`. What NOTHING catches is the other order: a case added to
/// the enum and to `index` (which is an exhaustive match, so the compiler forces it) but left out
/// of both `from_index` and `ALL`. Then the suite walks six of seven and passes, and the seventh
/// stepper's door answers `found: false` — a settings field rendered with no range at all.
///
/// So the pin is the enum's variant count against the length `ALL` declares. Both sides are
/// EXTRACTIONS, which is why [`Claim::Census`] refuses two empties rather than calling them equal:
/// a rename that broke either reading would otherwise leave `"" == ""` looking like the healthiest
/// result this can print.
#[must_use]
pub fn the_stepper_vocabulary_is_counted(tree: &Tree) -> Report {
    check_all(tree, &[Claim::Census {
        label: "Stepper cases vs ALL",
        cases: Extract::code(SETTINGS_CATALOG_RS, r"^    ([A-Z][A-Za-z]*),$")
            .within(r"^pub enum Stepper \{", r"^\}"),
        declared: Extract::code(SETTINGS_CATALOG_RS, r"const ALL: \[Self; ([0-9]+)\]")
            .within(r"^impl Stepper \{", r"^\}"),
    }])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    #[test]
    fn a_bucket_built_on_the_near_side_is_red() {
        let fixture = Fixture::new("bucket-notifier");
        fixture.write(
            super::NOTIFIER,
            "// Not SlopDeskWsNotifyRateLimiter(capacity:refill:) — the burst is notify.rs's.\nlet bucket = \
             slopdesk_ws_notify_rate_limiter()\nlet explicit = slopdesk_ws_notify_explicit_rate_limiter()\n",
        );
        // The prose names the construction it replaced, so the ban reads code.
        assert!(super::an_anti_flood_bucket_comes_from_the_crate(&fixture.tree()).is_clean());

        // A bucket that rests empty swallows the first explicit notification of every attach.
        fixture.write(
            super::NOTIFIER,
            "let bucket = SlopDeskWsNotifyRateLimiter(capacity: 5, tokens: 0)\nlet explicit = \
             slopdesk_ws_notify_explicit_rate_limiter()\n",
        );
        assert!(!super::an_anti_flood_bucket_comes_from_the_crate(&fixture.tree()).is_clean());

        // The policy as a default argument — of two spellings, the looser is the one that runs.
        fixture.write(
            super::NOTIFIER,
            "let bucket = slopdesk_ws_notify_rate_limiter()\nlet explicit = \
             slopdesk_ws_notify_explicit_rate_limiter()\ninit(capacity: Double = 5, refillPerSecond: Double \
             = 0.5) {}\n",
        );
        assert!(!super::an_anti_flood_bucket_comes_from_the_crate(&fixture.tree()).is_clean());

        // And a door dropped, which can only mean the four fields are filled here again.
        fixture.write(
            super::NOTIFIER,
            "let bucket = slopdesk_ws_notify_rate_limiter()\n",
        );
        assert!(!super::an_anti_flood_bucket_comes_from_the_crate(&fixture.tree()).is_clean());
    }

    /// Three cases, and an `ALL` that declares three.
    fn stepper(fixture: &Fixture, cases: &str, declared: usize) {
        fixture.write(
            super::SETTINGS_CATALOG_RS,
            &format!(
                "pub enum Stepper {{\n{cases}}}\n\nimpl Stepper {{\n    pub(crate) const ALL: [Self; \
                 {declared}] = [\n\x20       Self::WindowCells,\n    ];\n}}\n"
            ),
        );
    }

    #[test]
    fn a_case_missing_from_all_is_red() {
        let fixture = Fixture::new("stepper-census");
        stepper(
            &fixture,
            "    WindowCells,\n    WindowPixels,\n    FontPoints,\n",
            3,
        );
        assert!(super::the_stepper_vocabulary_is_counted(&fixture.tree()).is_clean());

        // The order no test catches: the case is in the enum and in `index`, and the suite walks
        // three of four and passes while the fourth stepper renders with no range at all.
        stepper(
            &fixture,
            "    WindowCells,\n    WindowPixels,\n    FontPoints,\n    VideoQp,\n",
            3,
        );
        assert!(!super::the_stepper_vocabulary_is_counted(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_census_that_reads_empty_is_red() {
        // A rename that breaks either extraction leaves "" == "", which agrees; its own fixture,
        // because writes accumulate.
        let fixture = Fixture::new("stepper-census-stale");
        fixture.write(
            super::SETTINGS_CATALOG_RS,
            "pub enum Rung {\n    WindowCells,\n}\n\nimpl Rung {\n\x20   pub(crate) const ALL: [Self; 1] = \
             [Self::WindowCells];\n}\n",
        );
        assert!(!super::the_stepper_vocabulary_is_counted(&fixture.tree()).is_clean());
    }
}
