import Foundation

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
/// steady stream — the standard amortised-credit trade-off (yamux replenishes when the
/// receive window has been consumed past half; RFC 9113 §5.2 / RFC 4254 are equivalent).
///
/// No IO, no clock, no sockets — just the threshold arithmetic — so it is trivially
/// unit-testable in isolation (same discipline as ``FlowCreditPolicy`` / ``ChannelTable``).
public struct ReceiveWindowAccountant: Sendable, Equatable {
    /// The receive window size — the same value the sender was told to use as its initial
    /// send window. The half of this is the replenish threshold.
    public let initialWindow: Int
    /// Bytes consumed (delivered upward) but NOT yet granted back to the sender via a
    /// window-adjust. Reset to 0 each time a grant is emitted. Never negative.
    public private(set) var pendingCredit: Int

    /// Creates an accountant for a window of `initialWindow` bytes (clamped non-negative).
    public init(initialWindow: Int) {
        self.initialWindow = max(0, initialWindow)
        pendingCredit = 0
    }

    /// The half-window replenish threshold: once `pendingCredit` reaches this, emit a grant.
    /// At least 1 for any positive window so a tiny window still makes progress.
    public var threshold: Int {
        initialWindow <= 0 ? Int.max : max(1, initialWindow / 2)
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
        guard initialWindow > 0 else { return nil }
        let took = max(0, bytes)
        pendingCredit += took
        guard pendingCredit >= threshold else { return nil }
        let grant = pendingCredit
        pendingCredit = 0
        return grant
    }
}
