import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-muxsession`'s `lifecycle`, reached through the
/// `pane_lifecycle` door.
///
/// The detach/rebind ladder is I/O — retire the member, cancel the drain, stop the stream, open a
/// new one, rebuild the sender. What is NOT I/O is which of those this call is allowed to do, and
/// where the new subscription starts; that is over there, and this side performs what it answers.
///
/// **Unlike every other pane handle, this one is not held under a caller lock.** The EOF latch is
/// set from the supervised ingest path, the exit-sent latch from the output drain, and both are
/// polled by the exit task — three callers that must never queue behind the teardown ladder. The
/// far side serializes itself, so ``MuxChannelSession`` keeps only `taskLock`, which guards the
/// `Task`s, the sub-channels and the stream: Swift objects that cannot cross at all.
final class PaneLifecycle: @unchecked Sendable {
    /// What a ``detach()`` call must do.
    struct DetachVerdict {
        /// `false` for a second detach on an already-detached session. The caller still refreshes
        /// the exit handler and then stands down.
        let first: Bool
        /// Whether a supervised stream was open and must be stopped.
        let stopStream: Bool
    }

    /// What a ``rebind(dataFinished:controlFinished:)`` call may do.
    enum RebindVerdict: Equatable {
        /// Not detached, or the returning client's sub-channels are already finished. NOTHING was
        /// changed — refuse the channel rather than ack a pane whose relay is wired elsewhere.
        case refuse
        /// Proceed. `resumeFrom` is the offset to re-open the subscription at, or `nil` for a
        /// session that never started a relay and has none to re-open.
        case proceed(resumeFrom: UInt64?)
    }

    /// The far side, which owns the flags, the cursor and the two latches.
    private let handle: OpaquePointer?

    /// A fresh lifecycle: not started, attached, resuming from nowhere.
    init() { handle = slopdesk_pane_lifecycle_new() }

    deinit { slopdesk_pane_lifecycle_free(handle) }

    /// The `PaneOutputStream.fromNowOn` seed, for the one caller that has to NAME it.
    static var fromNowOn: UInt64 { slopdesk_pane_lifecycle_from_now_on() }

    /// Claims the one-time relay start. `true` for the caller that wins.
    func start() -> Bool { slopdesk_pane_lifecycle_start(handle) }

    /// Whether the relay has been started.
    var isStarted: Bool { slopdesk_pane_lifecycle_is_started(handle) }

    /// Records that a supervised subscription is open, so a later rebind knows to re-open one.
    func streamOpened() { slopdesk_pane_lifecycle_stream_opened(handle) }

    /// Flips the detached flag and answers what this call must tear down.
    func detach() -> DetachVerdict {
        let bits = slopdesk_pane_lifecycle_detach(handle)
        return DetachVerdict(
            first: bits & UInt8(SLOPDESK_PANE_DETACH_FIRST) != 0,
            stopStream: bits & UInt8(SLOPDESK_PANE_DETACH_STOP_STREAM) != 0,
        )
    }

    /// Whether the session is parked in the detached store.
    var isDetached: Bool { slopdesk_pane_lifecycle_is_detached(handle) }

    /// Decides a rebind against the returning client's sub-channels, and un-detaches when it
    /// proceeds.
    func rebind(dataFinished: Bool, controlFinished: Bool) -> RebindVerdict {
        var resume: UInt64 = 0
        let verdict = slopdesk_pane_lifecycle_rebind(handle, dataFinished, controlFinished, &resume)
        switch verdict {
        case UInt8(SLOPDESK_PANE_REBIND_PROCEED): return .proceed(resumeFrom: nil)
        case UInt8(SLOPDESK_PANE_REBIND_PROCEED_RESUME): return .proceed(resumeFrom: resume)
        default: return .refuse
        }
    }

    /// Advances the resume cursor to where the just-ingested chunk ends.
    func recordOffset(_ end: UInt64) { slopdesk_pane_lifecycle_record_offset(handle, end) }

    /// Where a rebind re-opens the subscription.
    var offset: UInt64 { slopdesk_pane_lifecycle_offset(handle) }

    /// Latches "superd drained this master to EOF".
    func signalEOF() { slopdesk_pane_lifecycle_signal_eof(handle) }

    /// Whether the EOF latch is set.
    var isEOF: Bool { slopdesk_pane_lifecycle_is_eof(handle) }

    /// Latches "the drain put `.exit` on the wire".
    func signalExitSent() { slopdesk_pane_lifecycle_signal_exit_sent(handle) }

    /// Whether the exit-sent latch is set.
    var isExitSent: Bool { slopdesk_pane_lifecycle_is_exit_sent(handle) }
}
