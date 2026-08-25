import CSlopDeskFFI
import Foundation

/// Why the host ended a channel, as ``SlopDeskClient/hostChannelCloseReason`` reports it.
///
/// The two host closes are NOT interchangeable — see ``ConnectRun`` for the asymmetry they cause.
enum ConnectCloseCause {
    /// The link died. Nothing was said about this pane, so the campaign is free to retry.
    case link
    /// The host reaped the PANE under this channel.
    case retired
    /// The host evicted this subscriber from a pane that is still running.
    case evicted

    var tag: UInt8 {
        switch self {
        case .link: UInt8(SLOPDESK_CONNECT_CLOSE_LINK)
        case .retired: UInt8(SLOPDESK_CONNECT_CLOSE_RETIRED)
        case .evicted: UInt8(SLOPDESK_CONNECT_CLOSE_EVICTED)
        }
    }
}

/// The Swift face of `rust/slopdesk-workspace`'s `connect_run`, reached through the `connect_run`
/// door.
///
/// ``ConnectionViewModel`` and ``AppConnection`` own the tasks, the teardown order and the OUT FIFO.
/// What is over there is the four scalars every dial path reads first: which attempt still owns the
/// connection, whether the user closed it, and which of the two host closes was said — a reap, which
/// gates the automatic dial paths, or an eviction, which deliberately does not.
///
/// Held by ONE `@MainActor` object, so the far handle is exclusive: the actor IS the lock.
@MainActor
final class ConnectRun {
    /// The far side, which owns the generation and the three latches.
    ///
    /// `nonisolated(unsafe)` for `deinit` alone: every OTHER touch is on the main actor with the
    /// class, and by the time `deinit` runs the last reference is already gone, so the free races
    /// with nothing.
    private nonisolated(unsafe) let handle: OpaquePointer

    /// A connection that has never dialled.
    init() {
        guard let opened = slopdesk_connect_run_new() else {
            preconditionFailure("the connect run door would not open")
        }
        handle = opened
    }

    deinit { slopdesk_connect_run_free(handle) }

    /// Opens an EXPLICIT attempt, clears all three latches, and answers the generation the caller
    /// must quote after its handshake `await`.
    func begin() -> UInt64 { slopdesk_connect_run_begin(handle) }

    /// Whether the attempt born under `generation` still owns this connection.
    ///
    /// Pair it with the caller's own client-identity check where there is one: the same attempt with
    /// a REPLACED client is superseded too, and object identity is not a number.
    func isCurrent(_ generation: UInt64) -> Bool {
        slopdesk_connect_run_is_current(handle, generation)
    }

    /// Latches a deliberate close. Does not supersede — call ``supersede()`` too where an in-flight
    /// attempt must also be disowned.
    func closeDeliberately() { slopdesk_connect_run_close_deliberately(handle) }

    /// Retires every attempt in flight WITHOUT claiming the user asked — the iOS background unpin.
    func supersede() { slopdesk_connect_run_supersede(handle) }

    /// Clears the deliberate-close latch without opening an attempt — the video automation seam,
    /// which declares the app connected against a host with no mux to pin.
    func admitWithoutDialling() { slopdesk_connect_run_admit_without_dialling(handle) }

    /// Latches what the host said on a `.disconnected` edge. ``ConnectCloseCause/link`` latches
    /// nothing.
    func noteHostClose(_ cause: ConnectCloseCause) {
        slopdesk_connect_run_note_host_close(handle, cause.tag)
    }

    /// Whether an AUTOMATIC dial path may proceed — the leaf's connect-on-remount and the
    /// app-connection fan-out. A reap gates them; an eviction does not.
    var mayAutoDial: Bool { slopdesk_connect_run_may_auto_dial(handle) }

    /// Whether a `.disconnected` edge reads as a definite disconnect rather than the start of a
    /// reconnect campaign.
    var disconnectIsQuiet: Bool { slopdesk_connect_run_disconnect_is_quiet(handle) }

    /// Whether a `.reconnected` event may still be acted on — `false` once the pane was deliberately
    /// closed, so a late buffered one cannot paint it green over a dead transport.
    var reconnectIsWelcome: Bool { slopdesk_connect_run_reconnect_is_welcome(handle) }

    /// Whether this connection was closed on purpose, for the reconnect fold that takes it as an
    /// input of its own.
    var wasClosedDeliberately: Bool { slopdesk_connect_run_was_closed_deliberately(handle) }
}
