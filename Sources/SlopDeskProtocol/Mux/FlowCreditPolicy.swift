import CSlopDeskFFI

/// Pure SSH-window-style flow-control credit math for one direction of one channel.
///
/// Mirrors the SSH per-channel window: the sender may transmit at most ``remaining``
/// bytes before it must wait for the peer to grant more credit via a
/// `CHANNEL_WINDOW_ADJUST`. ``consume(_:)`` debits the window as bytes go out;
/// ``adjust(bytesToAdd:)`` re-credits it. When the window is exhausted the channel
/// ``isBlocked`` and further sends must wait.
///
/// The arithmetic — the all-or-nothing debit, the non-negative clamps, the saturation of a
/// peer-chosen grant — lives in `rust/slopdesk-wire`'s `mux::flow`. This is the seam, and it stays
/// a VALUE type: the whole state is two integers, so it crosses in the call rather than behind a
/// handle nobody would gain anything from.
public struct FlowCreditPolicy: Sendable, Equatable {
    /// The two numbers, in the layout the codec reads them in.
    private var state: SlopDeskFlowCredit

    /// The window size the channel started with (and the natural cap reference for
    /// callers that want to know how much has been consumed).
    public var initialWindow: Int { Int(state.initial_window) }

    /// Bytes of credit still available to send. Never negative.
    public var remaining: Int { Int(state.remaining) }

    /// Creates a window with `initialWindow` bytes of credit.
    /// `initialWindow` is clamped to be non-negative.
    public init(initialWindow: Int) {
        state = slopdesk_flow_credit_new(Int64(initialWindow))
    }

    /// The outcome of attempting to send `bytes`.
    public enum ConsumeResult: Sendable, Equatable {
        /// The full request fit; `remaining` is the credit left afterwards.
        case allowed(remaining: Int)
        /// The window had fewer than `bytes` credit; NOTHING was consumed.
        /// `available` is how much could be sent right now (0 when blocked).
        case insufficient(available: Int)
    }

    /// Attempts to debit `bytes` from the window.
    ///
    /// All-or-nothing: if fewer than `bytes` credit remains, the window is left
    /// untouched and `.insufficient(available:)` reports how much is currently
    /// sendable. A zero- or negative-byte request is always `.allowed` and consumes
    /// nothing (callers never send negative bytes; we guard defensively).
    @discardableResult
    public mutating func consume(_ bytes: Int) -> ConsumeResult {
        let verdict = slopdesk_flow_credit_consume(&state, Int64(bytes))
        return verdict.allowed
            ? .allowed(remaining: Int(verdict.value))
            : .insufficient(available: Int(verdict.value))
    }

    /// Re-credits the window by `bytesToAdd` (an SSH `CHANNEL_WINDOW_ADJUST`).
    /// Negative grants are ignored. Replenishing a blocked window unblocks it.
    ///
    /// OVERFLOW-SAFE: a huge peer-chosen grant (or a long run of grants) saturates rather than
    /// trapping. SSH-style windows may legitimately grow PAST ``initialWindow`` — it is the
    /// starting reference, not a hard cap — so the saturation is the only bound applied.
    public mutating func adjust(bytesToAdd: Int) {
        slopdesk_flow_credit_adjust(&state, Int64(bytesToAdd))
    }

    /// Whether the window is exhausted (no credit to send even a single byte).
    public var isBlocked: Bool {
        slopdesk_flow_credit_blocked(state)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.initial_window == rhs.state.initial_window && lhs.state.remaining == rhs.state.remaining
    }
}
