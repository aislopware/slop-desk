import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

/// How the two things the driver hands across become one ``SlopDeskClient/Event``.
///
/// `docs/63` stage G.5. The door has two callbacks because it carries two unlike things — an
/// inbound `WireMessage`, and the session's own lifecycle, which is not on the wire — and this is
/// where they meet. Nothing here decides anything: every case is a rename, plus the two boundary
/// validations that must happen on the side that knows the Swift vocabulary.
extension SlopDeskClient.Event {
    /// One inbound wire message as an event, or `nil` for one that is not the app's business.
    ///
    /// `nil` covers `output` — which never arrives here at all, because the driver's inbox and the
    /// wake stream carry the bytes — and the client-to-host verbs, which cannot arrive on an
    /// inbound stream and are ignored defensively rather than trusted not to.
    init?(_ message: WireMessage) {
        switch message {
        case let .exit(code):
            self = .exit(code: code)
        case let .title(text):
            self = .title(text)
        case .bell:
            self = .bell
        case let .commandStatus(status):
            self = .commandStatus(status)
        case let .notification(title, body):
            self = .notification(title: title, body: body)
        case let .foregroundProcess(name):
            self = .foregroundProcess(name: name)
        case let .claudeStatus(state, kind, label):
            self = .claudeStatus(state: state, kind: kind, label: label)
        case let .commandBlock(index, exitCode, durationMS, complete, outputLen, commandText, promptOrdinal):
            self = .commandBlock(
                index: index, exitCode: exitCode, durationMS: durationMS,
                complete: complete, outputLen: outputLen, commandText: commandText,
                promptOrdinal: promptOrdinal,
            )
        case let .blockOutput(index, output):
            self = .blockOutput(index: index, output: output)
        case let .metadataResponse(requestID, status, payload):
            self = .metadataResponse(requestID: requestID, status: status, payload: payload)
        case let .inputEcho(enabled):
            self = .inputEcho(enabled: enabled)
        case let .progress(state, percent):
            // The decoder carries the RAW state byte verbatim, because a faithful byte round-trip
            // keeps the golden vector stable. VALIDATE it here at the boundary and DROP an unknown
            // discriminant rather than forwarding a byte the UI cannot map to a badge.
            guard let validated = ProgressState(wire: state) else { return nil }
            self = .progress(state: validated, percent: percent)
        case let .cwd(path):
            self = .cwd(path)
        case let .projectKey(path):
            self = .projectKey(path)
        case let .projectGitStatus(status):
            self = .projectGitStatus(status)
        case let .agentSessionIntent(intent):
            self = .agentSessionIntent(intent)
        default:
            return nil
        }
    }

    /// One session-lifecycle record as an event, or `nil` for a `kind` from a newer driver.
    ///
    /// Dropped rather than folded into a nearby case: a kind this build has no vocabulary for has no
    /// honest rendering, and inventing one would put a wrong reading in front of the user. The
    /// driver's own enum is `#[non_exhaustive]` for the same reason.
    init?(_ record: SlopDeskPaneEvent, text: String) {
        switch record.kind {
        case SLOPDESK_PANE_EVENT_ROUND_TRIP:
            self = .rtt(milliseconds: record.round_trip_ms)
        case SLOPDESK_PANE_EVENT_DISCONNECTED:
            self = .disconnected(reason: text)
        case SLOPDESK_PANE_EVENT_RECONNECTED:
            var identity = record.session_id
            let learned = withUnsafeBytes(of: &identity) { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            self = .reconnected(sessionID: learned, resumeFromSeq: record.resume_from_seq)
        case SLOPDESK_PANE_EVENT_RETRY:
            // The driver sends a DURATION and this is where it becomes an instant, because the two
            // sides do not share a clock epoch. Zero means "firing now", which has nothing to count
            // down to — the UI renders an attempt without a countdown rather than one already due.
            let nextRetryAt = record.delay_ms == 0
                ? nil
                : Date().addingTimeInterval(Double(record.delay_ms) / 1000)
            self = .retrying(attempt: Int(record.attempt), nextRetryAt: nextRetryAt)
        case SLOPDESK_PANE_EVENT_GAVE_UP:
            self = .gaveUp(attempts: Int(record.attempt))
        case SLOPDESK_PANE_EVENT_LOG:
            self = .log(text)
        default:
            return nil
        }
    }
}
