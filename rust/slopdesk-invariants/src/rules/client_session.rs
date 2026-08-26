//! What a CLIENT decides about the stream the host is sending it, and it is
//! `rust/slopdesk-clientsession`'s.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const RUST_SEQ: &str = "rust/slopdesk-clientsession/src/seq.rs";
const RUST_BACKOFF: &str = "rust/slopdesk-clientsession/src/backoff.rs";
const SWIFT_CLIENT: &str = "Sources/SlopDeskClient/SlopDeskClient.swift";
const SWIFT_RECONNECT: &str = "Sources/SlopDeskClient/ReconnectManager.swift";

/// ONE PANE'S CLIENT SESSION, and it is `slopdesk_clientsession`.
///
/// The same carve as `muxsession` on hostd, from the other end of the wire. `SlopDeskClient` keeps
/// what only an actor can keep — a transport, four background pumps, an inbox, a wake stream. What
/// came out from underneath them is a table of cases: which output seq is NEW, what the resume
/// presented, whether an ack is owed, whether a transport may be adopted after the handshake,
/// whether a reconnect campaign may run at all, and how long the next retry waits.
///
/// Every one of those failed SILENTLY. A dedup mark that advances on a duplicate swallows a real
/// frame and prints nothing; a resume verdict resolved one seq too late reads a warm reattach as a
/// fresh shell; an ack flag cleared on a throw strands the host's window credit; a campaign that
/// runs after `close()` burns twenty doomed connects and fires a spurious "unreachable". None of
/// them is visible in a diff, and none of them is reachable from a test without a `HostServer` —
/// the exact shape that goes to Rust.
///
/// The BYTES do not cross. `deliver` takes a SEQ and answers accept-or-duplicate; the inbox, the
/// surfaced stream and the wire credit stay Swift-side, so the hot path allocates nothing in either
/// direction. The session is four integers and a flag, so it crosses BY VALUE, IN PLACE.
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
        Claim::Doors {
            path: SWIFT_CLIENT,
            entries: &[
                "slopdesk_pane_session_seeded",
                "slopdesk_pane_session_adopt",
                "slopdesk_pane_session_deliver",
                "slopdesk_pane_session_ack",
                "slopdesk_pane_session_ack_failed",
                "slopdesk_pane_session_stream_ended",
                "slopdesk_pane_session_rtt",
                "slopdesk_pane_session_connect_refusal",
                "slopdesk_pane_session_refusal_reason",
                "slopdesk_pane_session_adopts",
                "slopdesk_pane_session_announces_drop",
            ],
            message: "SlopDeskClient.swift no longer calls {entry} — what the client decides about the \
                      stream is slopdesk_clientsession's, and the actor around it is the IO shell",
        },
        Claim::Doors {
            path: SWIFT_RECONNECT,
            entries: &[
                "slopdesk_pane_session_campaign_runs",
                "slopdesk_pane_backoff_default",
                "slopdesk_pane_backoff_next_after",
                "slopdesk_pane_backoff_delay",
                "slopdesk_pane_backoff_max_attempts",
                "slopdesk_pane_backoff_direct_attempts",
                "slopdesk_pane_backoff_exhausted",
            ],
            message: "ReconnectManager.swift no longer calls {entry} — the retry ladder and the four \
                      windows that end a campaign are slopdesk_clientsession's",
        },
        // The marks, back as Swift STATE. `highestContiguousSeq` and `sessionResumeOutcome` survive
        // as read-only projections of the crossing struct and are deliberately not named here; what
        // is banned is a second `var` that a second rule would then have to advance.
        Claim::NoneUnder {
            roots: &["Sources", "Apps"],
            extensions: SWIFT,
            pattern: r"var highestSeqFed\b|var presentedResumeSeq\b|var ackPending\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a client session mark is Swift state again in {files} — the dedup high-water mark, \
                      the resume probe and the ack gate advance together inside one door, and a Swift copy \
                      is how they stop agreeing",
        },
        // The schedule, respelled. A literal ceiling beside the door that vends one is the drift
        // this whole rule exists to stop: the give-up count is ALSO the UI's "attempt N of M", so a
        // second 20 renders an impossible "attempt 25 of 20".
        Claim::Lacks {
            path: SWIFT_RECONNECT,
            pattern: r"= 20\b|milliseconds\(250\)|1\.\.\.64\b|multiplier: Double = 2\.0",
            view: View::Code,
            message: "ReconnectManager.swift spells the retry schedule again — the ladder, the give-up \
                      ceiling and the direct-reconnect bound are slopdesk_clientsession::backoff's",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The actor as it stands: an IO shell whose every decision is a call across.
    const CLIENT: &str = "\
actor SlopDeskClient {
    private var session = SlopDeskPaneSession()
    init(resumeSeed: Int64) { session = slopdesk_pane_session_seeded(resumeSeed) }
    func connect() throws {
        let refusal = slopdesk_pane_session_connect_refusal(closed, childExited, hostClosed)
        if refusal != 0 { throw ClientError.invalidState(Self.refusalReason(refusal)) }
        guard slopdesk_pane_session_adopts(closed, paused, cancelled, superseded) else { return }
        if slopdesk_pane_session_adopt(&session, lastSeq, resumeFromSeq) == 1 { reset() }
    }
    func deliverOutput(seq: Int64) {
        guard slopdesk_pane_session_deliver(&session, seq) == 1 else { return }
    }
    func flushAck() {
        guard slopdesk_pane_session_ack(&session, &seq) else { return }
        do { try send() } catch { slopdesk_pane_session_ack_failed(&session) }
    }
    func recordPong() { _ = slopdesk_pane_session_rtt(now, sent, has, prev, &reading) }
    func handleStreamEnded() {
        slopdesk_pane_session_stream_ended(&session)
        guard slopdesk_pane_session_announces_drop(closed, tearingDown, childExited) else { return }
    }
    static func refusalReason(_ code: UInt8) -> String {
        read { out, cap in slopdesk_pane_session_refusal_reason(code, out, cap) }
    }
}
";

    /// The campaign as it stands: a supervising task whose ladder and whose four windows are read.
    const RECONNECT: &str = "\
final class ReconnectManager {
    struct Backoff {
        private static let shipped = slopdesk_pane_backoff_default()
        func next(after current: Duration) -> Duration {
            .nanoseconds(slopdesk_pane_backoff_next_after(crossing, ns(current)))
        }
        func delay(forAttempt attempt: Int) -> Duration {
            .nanoseconds(slopdesk_pane_backoff_delay(crossing, UInt32(clamping: attempt)))
        }
    }
    static let cap = Int(slopdesk_pane_backoff_max_attempts())
    static func loop() async {
        guard slopdesk_pane_session_campaign_runs(paused, closed, exited, hostClosed) else { return }
        if slopdesk_pane_backoff_exhausted(UInt32(clamping: attempt)) { return }
        for attempt in 1...Int(slopdesk_pane_backoff_direct_attempts()) { try await connect() }
    }
}
";

    fn seeded(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(super::RUST_SEQ, "pub fn deliver() {}\n")
            .write(super::RUST_BACKOFF, "pub fn delay_for_attempt() {}\n")
            .write(super::SWIFT_CLIENT, CLIENT)
            .write(super::SWIFT_RECONNECT, RECONNECT);
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

    /// The decision, decided in Swift again: the marks back as `var`s that a second rule would then
    /// have to advance, and the ladder respelled as the literals it used to be.
    #[test]
    fn a_client_session_decided_in_swift_again_is_caught() {
        let fixture = seeded("pane-client-session-swift");

        // The marks, back as Swift state beside the struct that already holds them.
        fixture.write(
            "Sources/SlopDeskClient/PaneMarks.swift",
            "final class PaneMarks {\n    var highestSeqFed: Int64 = 0\n    var ackPending = false\n}\n",
        );
        says(&fixture, "client session mark is Swift state again");

        // The ladder, respelled — the give-up ceiling is ALSO the UI's "attempt N of M".
        fixture.remove("Sources/SlopDeskClient/PaneMarks.swift").write(
            super::SWIFT_RECONNECT,
            &RECONNECT.replace(
                "static let cap = Int(slopdesk_pane_backoff_max_attempts())",
                "static let cap = 20\n    static let initial = Duration.milliseconds(250)",
            ),
        );
        says(&fixture, "spells the retry schedule again");
    }

    /// The same drift one step earlier: a door dropped on either file, and the crate the whole rule
    /// folds through gone.
    #[test]
    fn a_dropped_door_or_a_deleted_crate_is_caught() {
        let fixture = seeded("pane-client-session-doors");
        fixture
            .write(
                super::SWIFT_RECONNECT,
                &RECONNECT.replace("slopdesk_pane_session_campaign_runs(", "shouldRetry("),
            )
            .write(
                super::SWIFT_CLIENT,
                &CLIENT.replace("slopdesk_pane_session_deliver(", "isNew("),
            );
        says(&fixture, "slopdesk_pane_session_campaign_runs");
        says(&fixture, "slopdesk_pane_session_deliver");

        fixture.remove(super::RUST_SEQ);
        says(&fixture, "one pane's client session, decided once");
    }
}
