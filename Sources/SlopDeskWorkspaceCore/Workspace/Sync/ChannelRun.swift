import CSlopDeskFFI
import Foundation

/// Which rung of the channel's own lifecycle a client is on.
///
/// The `stateNum` beside ``live(_:)`` is part of the VALUE: a client that acks 5 and then acks 6 has
/// changed state, and a publish that de-duplicated on the case alone would swallow every document
/// frame after the first.
public enum ChannelRunState: Equatable, Sendable {
    case idle
    case opening
    case live(Int64)
    case refused
    case closed

    /// The tag and number the door carries this as.
    var parts: (tag: UInt8, stateNum: Int64) {
        switch self {
        case .idle: (UInt8(SLOPDESK_CHANNEL_RUN_IDLE), 0)
        case .opening: (UInt8(SLOPDESK_CHANNEL_RUN_OPENING), 0)
        case let .live(stateNum): (UInt8(SLOPDESK_CHANNEL_RUN_LIVE), stateNum)
        case .refused: (UInt8(SLOPDESK_CHANNEL_RUN_REFUSED), 0)
        case .closed: (UInt8(SLOPDESK_CHANNEL_RUN_CLOSED), 0)
        }
    }

    /// The inverse. A tag outside the ladder reads as ``idle``, which is the state that admits a
    /// fresh start.
    static func from(tag: UInt8, stateNum: Int64) -> Self {
        switch Int32(tag) {
        case SLOPDESK_CHANNEL_RUN_OPENING: .opening
        case SLOPDESK_CHANNEL_RUN_LIVE: .live(stateNum)
        case SLOPDESK_CHANNEL_RUN_REFUSED: .refused
        case SLOPDESK_CHANNEL_RUN_CLOSED: .closed
        default: .idle
        }
    }
}

/// The Swift face of `rust/slopdesk-workspace`'s `channel_run`, reached through the `channel_run`
/// door.
///
/// ``WorkspaceChannelClient``'s loop is I/O — open a channel, race the ack, subscribe, apply frames,
/// drain two ordered queues. What is NOT I/O is which run is still allowed to speak, who releases
/// the channel and which presence clock is next; that is over there, and this side performs what it
/// answers.
///
/// Held by ONE `@MainActor` object, so the far handle is exclusive: the actor IS the lock.
@MainActor
final class ChannelRun {
    /// What a ``finish(_:generation:)`` left for the caller to do.
    ///
    /// ``stale`` and ``quiet`` both publish nothing, and they are NOT the same ending: a superseded
    /// run must leave the live run's task slot alone, while a current run that ended where it began
    /// has still ended and must retire its own — otherwise the next ``start(runInFlight:)`` sees a
    /// run in flight forever and the client never reopens.
    enum FinishVerdict {
        case stale
        case quiet
        case news

        init(tag: UInt8) {
            switch Int32(tag) {
            case SLOPDESK_CHANNEL_RUN_FINISH_QUIET: self = .quiet
            case SLOPDESK_CHANNEL_RUN_FINISH_NEWS: self = .news
            default: self = .stale
            }
        }
    }

    /// What a ``stop()`` left for the caller to do.
    struct StopVerdict {
        /// The channel id this stop CLAIMED, if it still held one. The run task's own exit path
        /// finds the slot empty and releases nothing, which is what keeps the release single.
        let release: UInt32?
        /// Whether `.closed` is news — `false` when the client was already closed, in which case
        /// nothing fires the state-change callback.
        let publish: Bool
    }

    /// The far side, which owns the state, the generation, the channel claim and the clock.
    ///
    /// `nonisolated(unsafe)` for `deinit` alone: every OTHER touch is on the main actor with the
    /// class, and by the time `deinit` runs the last reference is already gone, so the free races
    /// with nothing.
    private nonisolated(unsafe) let handle: OpaquePointer

    /// A client that has never opened anything.
    init() {
        guard let opened = slopdesk_channel_run_new() else {
            preconditionFailure("the channel run door would not open")
        }
        handle = opened
    }

    deinit { slopdesk_channel_run_free(handle) }

    /// The state the interface binds to.
    var state: ChannelRunState {
        var stateNum: Int64 = 0
        let tag = slopdesk_channel_run_state(handle, &stateNum)
        return ChannelRunState.from(tag: tag, stateNum: stateNum)
    }

    /// Whether this client can carry an intent right now — `.live` and nothing else.
    var maySendIntent: Bool { slopdesk_channel_run_may_send_intent(handle) }

    /// Admits a run and answers the generation it must quote in every later publish, or `nil` for a
    /// client that already has one in flight or that the host has refused.
    func start(runInFlight: Bool) -> UInt64? {
        let generation = slopdesk_channel_run_start(handle, runInFlight)
        return generation == UInt64(SLOPDESK_CHANNEL_RUN_START_REFUSED) ? nil : generation
    }

    /// Retires every run in flight and claims the channel for release.
    func stop() -> StopVerdict {
        var release: UInt32 = 0
        var hasRelease = false
        let publish = slopdesk_channel_run_stop(handle, &release, &hasRelease)
        return StopVerdict(release: hasRelease ? release : nil, publish: publish)
    }

    /// Records the channel a run just opened, so a stop mid-handshake knows what to release.
    func claim(_ channel: UInt32) { slopdesk_channel_run_claim(handle, channel) }

    /// Claims `channel` for release, but only while this client still owns it.
    func releaseIfOwned(_ channel: UInt32) -> Bool {
        slopdesk_channel_run_release_if_owned(handle, channel)
    }

    /// Publishes `next` on behalf of the run born under `generation`, and answers what the caller
    /// still owes.
    func finish(_ next: ChannelRunState, generation: UInt64) -> FinishVerdict {
        let parts = next.parts
        let tag = slopdesk_channel_run_finish(handle, parts.tag, parts.stateNum, generation)
        return FinishVerdict(tag: tag)
    }

    /// Moves to `next` whatever run is current, and answers whether that is news.
    func publish(_ next: ChannelRunState) -> Bool {
        let parts = next.parts
        return slopdesk_channel_run_publish(handle, parts.tag, parts.stateNum)
    }

    /// Mints the next presence clock. Monotone across a reconnect, because the host keeps the newest
    /// and ignores anything older.
    func mintPresenceClock() -> Int64 { slopdesk_channel_run_mint_presence_clock(handle) }
}
