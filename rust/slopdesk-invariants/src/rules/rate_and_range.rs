//! Where a bucket comes from, and a vocabulary that needs a count as well as a map.
//!
//! Ported from the deleted `check-supervisor.sh`. Two rules that look unrelated and are the same
//! shape twice: a value the crate decides, decided a second time on the near side. In one case that
//! is four doubles and the failure is a banner nobody sees; in the other it is a table length and
//! the failure is a settings field rendered with no range at all.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The bucket's Swift face.
const NOTIFIER: &str = "Sources/SlopDeskWorkspaceCore/Connection/CommandCompletionNotifier.swift";

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
}
