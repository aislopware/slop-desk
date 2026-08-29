/// What ``SlopDeskClient`` throws.
///
/// Two cases, because the driver's eight connect verdicts and four send verdicts collapse to two
/// questions the callers actually ask: is this pane's session finished (do not retry, do not report
/// a network problem), or did the network fail (retry, and say so in the chrome). The associated
/// string is the driver's OWN sentence, spilled through the door beside the code — so a refusal and
/// the words for it cannot drift apart, and `ConnectGate.failureReason` (which reads
/// `String(describing:)`) surfaces it verbatim.
public enum ClientError: Error, Equatable, Sendable {
    /// The session cannot do this from the state it is in — a send before the first connect, a
    /// resume with no endpoint, a dial after close or after the child exited, or a call made from
    /// inside an event callback. Terminal for this client instance; recovery builds a new one.
    case invalidState(String)
    /// The dial or the handshake failed. Worth retrying, and what the reconnect campaign retries.
    case notConnected(String)
}
