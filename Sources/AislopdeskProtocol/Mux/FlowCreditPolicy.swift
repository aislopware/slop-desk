import Foundation

/// Pure SSH-window-style flow-control credit math for one direction of one channel.
///
/// Mirrors the SSH per-channel window: the sender may transmit at most ``remaining``
/// bytes before it must wait for the peer to grant more credit via a
/// `CHANNEL_WINDOW_ADJUST`. ``consume(_:)`` debits the window as bytes go out;
/// ``adjust(bytesToAdd:)`` re-credits it. When the window is exhausted the channel
/// ``isBlocked`` and further sends must wait.
///
/// No IO, no clock, no sockets — just the credit arithmetic — so it is trivially
/// unit-testable in isolation (same discipline as ``ChannelTable``).
public struct FlowCreditPolicy: Sendable, Equatable {
    /// The window size the channel started with (and the natural cap reference for
    /// callers that want to know how much has been consumed).
    public let initialWindow: Int
    /// Bytes of credit still available to send. Never negative.
    public private(set) var remaining: Int

    /// Creates a window with `initialWindow` bytes of credit.
    /// `initialWindow` is clamped to be non-negative.
    public init(initialWindow: Int) {
        let start = max(0, initialWindow)
        self.initialWindow = start
        self.remaining = start
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
        let want = max(0, bytes)
        guard want <= remaining else {
            return .insufficient(available: remaining)
        }
        remaining -= want
        return .allowed(remaining: remaining)
    }

    /// Re-credits the window by `bytesToAdd` (an SSH `CHANNEL_WINDOW_ADJUST`).
    /// Negative grants are ignored. Replenishing a blocked window unblocks it.
    ///
    /// OVERFLOW-SAFE (R6 #7): a huge peer-chosen `UInt32` grant (or a long run of grants) must not
    /// Int-overflow-trap the `remaining += bytesToAdd`. Saturate at `Int.max` instead. NOTE: SSH-style
    /// windows may legitimately grow PAST ``initialWindow`` (it is the starting reference, not a hard
    /// cap on `remaining` — see `testAdjustCanGrowBeyondInitialWindow`), so we deliberately do NOT clamp
    /// to the window; we only defuse the overflow trap. (For this remote-terminal the SENDER is the host
    /// PTY, whose output is bounded by what the shell produces, so an inflated window is not itself a
    /// socket-monopolisation lever — the bounded-queue + ReplayBuffer gates bound host memory regardless.)
    public mutating func adjust(bytesToAdd: Int) {
        guard bytesToAdd > 0 else { return }
        let (sum, overflowed) = remaining.addingReportingOverflow(bytesToAdd)
        remaining = overflowed ? Int.max : sum
    }

    /// Whether the window is exhausted (no credit to send even a single byte).
    public var isBlocked: Bool {
        remaining <= 0
    }
}
