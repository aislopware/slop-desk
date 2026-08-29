//! What a CLIENT decides about the stream the host is sending it, and it is
//! `rust/slopdesk-clientsession`'s.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const RUST_SEQ: &str = "rust/slopdesk-clientsession/src/seq.rs";
const RUST_BACKOFF: &str = "rust/slopdesk-clientsession/src/backoff.rs";

/// The one CALLER of the decisions, since `docs/63` §G.5 — the driver half of a pane session.
const DRIVER: &str = "rust/slopdesk-clientdriver/src";

/// The retry campaign's own file inside it, which is where the ladder is walked.
const DRIVER_SUPERVISOR: &str = "rust/slopdesk-clientdriver/src/driver.rs";

/// ONE PANE'S CLIENT SESSION, and it is `slopdesk_clientsession`.
///
/// The same carve as `muxsession` on hostd, from the other end of the wire. What the crate holds is
/// a table of cases: which output seq is NEW, what the resume presented, whether an ack is owed,
/// whether a transport may be adopted after the handshake, whether a reconnect campaign may run at
/// all, and how long the next retry waits.
///
/// Every one of those failed SILENTLY. A dedup mark that advances on a duplicate swallows a real
/// frame and prints nothing; a resume verdict resolved one seq too late reads a warm reattach as a
/// fresh shell; an ack flag cleared on a throw strands the host's window credit; a campaign that
/// runs after `close()` burns twenty doomed connects and fires a spurious "unreachable". None of
/// them is visible in a diff.
///
/// ## The CALLER changed, and this rule moved with it
///
/// Until `docs/63` §G.5 the caller was Swift — `SlopDeskClient.swift` and `ReconnectManager.swift`
/// reaching the crate through `slopdesk_pane_session_*` and `slopdesk_pane_backoff_*` — so this
/// rule read those two files for those door names. The shell around the decisions is
/// `rust/slopdesk-clientdriver` now, so it calls the crate as a CRATE and the eighteen doors lost
/// their only caller and retired with the Swift.
///
/// What the rule is about did not change at all: there is one place each of these is decided, and
/// the shell around them may not decide any of it a second time. Only the language the caller is
/// written in did — which is why the claims below name Rust call sites rather than C entry points,
/// and why the two Swift bans at the end SURVIVE. A mark that came back as a Swift `var` would be
/// exactly as wrong now as it was then, and more likely, because there is no longer a door beside
/// it to make the duplication obvious.
#[must_use]
pub fn client_session(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: RUST_SEQ,
            message: "the dedup high-water mark, the resume verdict and the ack gate — one pane's client \
                      session, decided once",
        },
        Claim::Exists {
            path: RUST_BACKOFF,
            message: "the retry ladder the reconnect campaign walks, in nanoseconds because a Duration \
                      carries attoseconds",
        },
        // The SEQ half. Named as the call sites they are, because a `use` line proves only that the
        // crate is linked — a driver that imported `Session` and then advanced its own integer
        // beside it would satisfy an import check and nothing else.
        Claim::MentionsUnder {
            root: DRIVER,
            names: &[
                "Session::seeded(",
                "state.session.deliver(",
                "state.session.ack(",
                "state.session.ack_failed(",
                ".adopt(opening.last_received_seq",
                "state.session.stream_ended(",
                "rtt::fold(",
            ],
            message: "the driver no longer calls {entry} — what a client decides about the stream is \
                      slopdesk_clientsession's, and this crate is the threads, the inbox and the ladder \
                      around it (docs/63 §G.5)",
        },
        // The GATE half: four questions whose answers are opposite pairs, and each of which the
        // driver used to be able to get wrong on its own.
        Claim::MentionsUnder {
            root: DRIVER,
            names: &[
                "gates::connect_refusal(",
                "gates::adopts(",
                "gates::announces_drop(",
                "gates::campaign_runs(",
            ],
            message: "the driver no longer calls {entry} — whether a connect is refused, whether a \
                      handshaken transport may still be adopted, whether a stream end is a real drop and \
                      whether a campaign may run at all are four gates in slopdesk_clientsession, not four \
                      `if`s here (docs/63 §G.5)",
        },
        // The LADDER half, in the one file that walks it.
        Claim::Doors {
            path: DRIVER_SUPERVISOR,
            entries: &["Backoff::default", "schedule.next_after", "backoff::exhausted"],
            message: "the supervisor no longer calls {entry} — the ladder, its ceiling and the give-up \
                      count are slopdesk_clientsession::backoff's, and a schedule spelled here is a second \
                      schedule (docs/63 §G.5)",
        },
        // The marks, back as Swift STATE. `highestContiguousSeq` and `sessionResumeOutcome` survive
        // as read-only projections and are deliberately not named here; what is banned is a second
        // `var` that a second rule would then have to advance.
        //
        // This ban OUTLIVED the doors it was written beside, and is worth more now than it was: the
        // marks are two boundaries away rather than one, so a Swift copy would no longer sit in the
        // same file as the call it disagrees with.
        Claim::NoneUnder {
            roots: &["Sources", "Apps"],
            extensions: SWIFT,
            pattern: r"var highestSeqFed\b|var presentedResumeSeq\b|var ackPending\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a client session mark is Swift state again in {files} — the dedup high-water mark, \
                      the resume probe and the ack gate advance together inside one call, and a Swift copy \
                      is how they stop agreeing",
        },
        // The schedule, respelled — tree-wide now rather than in `ReconnectManager.swift`, which is
        // deleted. The give-up count is ALSO the UI's "attempt N of M", so a second 20 renders an
        // impossible "attempt 25 of 20"; the driver reports `attempt` and `delay_ms` on its
        // `Retry` event for exactly that reason, and a Swift side that recomputed either would be
        // rendering a countdown against a ladder it does not walk.
        Claim::NoneUnder {
            roots: &["Sources", "Apps"],
            extensions: SWIFT,
            // Narrower than the `ReconnectManager.swift`-scoped pattern it replaces, and in a
            // different DIRECTION: this is tree-wide now, so it cannot ban a NAME. Two live files
            // name a retry legitimately — `SlopDeskClient.maxReconnectAttempts`, which reads
            // `slopdesk_pane_backoff_max_attempts()`, and `VideoWindowDiscovery.retryInterval`,
            // which is PATH-2's own transient-lane cadence and has nothing to do with this ladder.
            //
            // What is banned is a retry-ish name bound to a LITERAL, which is the only spelling
            // that can drift: a name bound to the door cannot. The three numbers are the shipped
            // ladder's — 250 ms, the 2.0 doubling and the ceiling of 20 — because those are what a
            // second copy would be a copy OF.
            pattern: r"(?i)(retry|reconnect|backoff)[A-Za-z]*\s*[:=]\s*(20\b|2\.0\b|\.milliseconds\(250\)|\
                       \.seconds\(2\)|Duration\.milliseconds\(250\))",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} spells the retry schedule again — the ladder, the give-up ceiling and the \
                      direct-reconnect bound are slopdesk_clientsession::backoff's, and the driver REPORTS \
                      the attempt and the delay it is actually waiting (docs/63 §G.5)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The supervisor as it stands: every decision a call into the crate, and the ladder walked
    /// rather than spelled.
    const SUPERVISOR: &str = "\
fn supervise(shared: &Shared, inbox: &Receiver<Command>) {
    let refusal = gates::connect_refusal(state.closed, state.child_exited, state.host_closed);
    if !gates::adopts(state.closed, state.paused, cancelled, superseded) { return; }
    let reset = state.session.adopt(opening.last_received_seq, ack.resume_from_seq);
    if let Some(seq) = state.session.ack(&mut owed) { send(seq); } else { state.session.ack_failed(); }
    state.session.stream_ended();
    if !gates::announces_drop(state.closed, tearing_down, state.child_exited) { return; }
    if !gates::campaign_runs(state.paused, state.closed, exited, host_closed) { return; }
    let schedule = Backoff::default();
    let next = schedule.next_after(run.delay.as_nanos());
    if backoff::exhausted(run.attempt) { return; }
}
";

    /// The state as it stands: the marks are the crate's struct, stepped where they live.
    const STATE: &str = "\
impl Shared {
    fn new(seed: Option<ResumeSeed>) -> Self {
        let session = seed.map_or_else(Session::default, |seed| Session::seeded(seed.last_seq));
        Self { session }
    }
    fn fold(&self, seq: i64) {
        match state.session.deliver(seq) { Delivery::Duplicate => return, Delivery::New => {} }
    }
    fn pong(&self, sent: Instant) { state.smoothed_rtt_ms = rtt::fold(now, sent, previous); }
}
";

    fn seeded(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(super::RUST_SEQ, "pub fn deliver() {}\n")
            .write(super::RUST_BACKOFF, "pub fn delay_for_attempt() {}\n")
            .write(super::DRIVER_SUPERVISOR, SUPERVISOR)
            .write("rust/slopdesk-clientdriver/src/state.rs", STATE);
        assert!(super::client_session(&fixture.tree()).is_clean());
        fixture
    }

    fn says(fixture: &Fixture, fragment: &str) {
        let report = super::client_session(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains(fragment)),
            "{report:?}"
        );
    }

    /// The decision, decided in Swift again — which is still possible, and still silent, on the far
    /// side of a port that put the decisions two boundaries away instead of one.
    #[test]
    fn a_client_session_mark_kept_in_swift_is_caught() {
        let fixture = seeded("pane-client-session-swift");

        fixture.write(
            "Sources/SlopDeskClient/PaneMarks.swift",
            "final class PaneMarks {\n    var highestSeqFed: Int64 = 0\n    var ackPending = false\n}\n",
        );
        says(&fixture, "client session mark is Swift state again");

        // And the ladder, respelled beside a countdown the driver already reports.
        fixture.remove("Sources/SlopDeskClient/PaneMarks.swift").write(
            "Sources/SlopDeskWorkspaceCore/RetryBadge.swift",
            "enum RetryBadge {\n    static let maxAttempts = 20\n    static let retryDelay = \
             Duration.milliseconds(250)\n}\n",
        );
        says(&fixture, "spells the retry schedule again");
    }

    /// The same drift one step earlier: the driver deciding for itself what it used to ask.
    ///
    /// Each replacement is what the mistake actually looks like — not a deletion, but a plausible
    /// local answer. `isNew(seq)` is a two-line comparison anyone would write; it is also the one
    /// that swallows a real frame the first time a retransmission arrives out of order.
    #[test]
    fn a_driver_that_decides_for_itself_is_caught() {
        let fixture = seeded("pane-client-session-doors");

        fixture.write(
            "rust/slopdesk-clientdriver/src/state.rs",
            &STATE.replace("state.session.deliver(", "isNew("),
        );
        says(&fixture, "state.session.deliver(");

        fixture.write(
            super::DRIVER_SUPERVISOR,
            &SUPERVISOR
                .replace("gates::campaign_runs(", "should_retry(")
                .replace("backoff::exhausted(", "(run.attempt > 20) && ignore("),
        );
        says(&fixture, "gates::campaign_runs(");
        says(&fixture, "backoff::exhausted");

        // And the crate the whole rule folds through, gone.
        fixture.remove(super::RUST_SEQ);
        says(&fixture, "one pane's client session, decided once");
    }

    /// A drained driver directory answers nothing, so the two `MentionsUnder` claims must fire on
    /// it rather than pass — this is the "an empty tree satisfies every ban" hole, closed.
    #[test]
    fn a_driver_with_no_files_is_red() {
        let fixture = Fixture::new("pane-client-session-bare");
        fixture
            .write(super::RUST_SEQ, "pub fn deliver() {}\n")
            .write(super::RUST_BACKOFF, "pub fn delay_for_attempt() {}\n");
        assert!(!super::client_session(&fixture.tree()).is_clean());
    }
}
