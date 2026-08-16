import CSlopDeskFFI

/// Pure receiver-side accounting for ONE direction of ONE channel: how many bytes the
/// receiver has consumed (delivered upward) since it last granted credit, and the
/// decision of WHEN to emit a `CHANNEL_WINDOW_ADJUST` back to the sender.
///
/// This is the symmetric peer of ``FlowCreditPolicy`` (which lives on the SENDER): the
/// sender debits its window as bytes go out and blocks when it hits zero; the receiver
/// re-credits the sender by emitting a window-adjust once it has consumed "enough" of
/// the window — the classic SSH / HTTP-2 / yamux half-window replenish. Emitting on a
/// HALF-WINDOW threshold (rather than per byte) keeps a window-adjust frame off the wire
/// for every chunk while still keeping the sender's window from draining to zero under a
/// steady stream.
///
/// The threshold arithmetic lives in `rust/slopdesk-wire`'s `mux::flow`; this crosses by value for
/// the reason ``FlowCreditPolicy`` does.
public struct ReceiveWindowAccountant: Sendable, Equatable {
    /// The two numbers, in the layout the codec reads them in.
    private var state: SlopDeskReceiveWindow

    /// The receive window size — the same value the sender was told to use as its initial
    /// send window. The half of this is the replenish threshold.
    public var initialWindow: Int { Int(state.initial_window) }

    /// Bytes consumed (delivered upward) but NOT yet granted back to the sender via a
    /// window-adjust. Reset to 0 each time a grant is emitted. Never negative.
    public var pendingCredit: Int { Int(state.pending_credit) }

    /// Creates an accountant for a window of `initialWindow` bytes (clamped non-negative).
    public init(initialWindow: Int) {
        state = slopdesk_receive_window_new(Int64(initialWindow))
    }

    /// The half-window replenish threshold: once `pendingCredit` reaches this, emit a grant.
    /// At least 1 for any positive window so a tiny window still makes progress.
    public var threshold: Int {
        let answer = slopdesk_receive_window_threshold(state.initial_window)
        // A window of zero disables this accountant, which the arithmetic says by never reaching
        // its threshold — the value Swift callers have always compared against is `Int.max`.
        return answer == Int64.max ? Int.max : Int(answer)
    }

    /// Records that `bytes` were consumed (delivered upward) and returns the amount of
    /// credit to GRANT back to the sender right now, or `nil` if the half-window threshold
    /// has not yet been crossed (accumulate and wait).
    ///
    /// All-or-nothing per crossing: when the threshold is crossed the WHOLE accumulated
    /// `pendingCredit` is granted (and reset to 0), so the sender's window is topped back
    /// up to its full size. A zero/negative consume grants nothing. A zero/negative window
    /// (flow control effectively disabled for this accountant) never grants.
    public mutating func consume(_ bytes: Int) -> Int? {
        let grant = slopdesk_receive_window_consume(&state, Int64(bytes))
        return grant < 0 ? nil : Int(grant)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.initial_window == rhs.state.initial_window
            && lhs.state.pending_credit == rhs.state.pending_credit
    }
}
