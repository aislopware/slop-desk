import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-muxsession`'s `open_route`, reached through the `open_route`
/// doors — docs/59 step 6.
///
/// Where an inbound `channelOpen` goes, and the three numbers a reattach turns on. Every member is
/// `static`: the router holds no state, because it IS a function of the facts ``HostServer`` reads
/// under its one critical section. Nothing is allocated, nothing is freed, and there is no handle
/// whose lifetime could be got wrong.
///
/// **What crosses is the SHAPE, never the identity.** A `MuxChannelSession` is an actor around a
/// PTY and a `DetachedSessionStore` owns a TTL task; neither can be a scalar. What the host hands
/// over is "somebody live holds this id, under another key", and it resolves the verdict against
/// the objects it already has.
///
/// **The order is the invariant.** Routing a live id past the JOIN and into the spawn path rotates
/// the incumbent's journal writer out from under it and its transcript stops mid-session; routing
/// an unserved class into the PTY path forks a login shell nobody asked for. That precedence used
/// to be a comment over five booleans. It is a Rust test now.
enum MuxOpenRouter {
    /// Who, if anyone, is already holding the session id an open presents.
    ///
    /// Three states rather than the two booleans they were, because the pair had a fourth
    /// combination that meant nothing and a route that would have been undefined for it.
    enum Incumbent: UInt8 {
        /// Nothing live answers to this id.
        case none = 0
        /// A session is already registered under THIS composite key — a duplicate or retransmitted
        /// `channelOpen`.
        case thisKey = 1
        /// The same id is live under a DIFFERENT composite key: a second window or device.
        case otherKey = 2
    }

    /// What the host does with one `channelOpen`.
    enum Route: UInt8 {
        /// Not a pane — the workspace document rides an ordinary open with its own class byte.
        case workspace = 1
        /// A class this build serves nobody under.
        case decline = 2
        /// The host is stopping; no PTY may be forked that would outlive the daemon.
        case refuseStopping = 3
        /// A session already answers to this key — re-ack idempotently.
        case reAck = 4
        /// The id is live elsewhere: add this client to that session's roster.
        case join = 5
        /// The id may be parked in the detached store — attempt the exclusive claim.
        case claim = 6
        /// Fork a shell.
        case spawnFresh = 7
    }

    /// What the detached store said when the claim was attempted.
    enum Claim: UInt8 {
        case claimed = 1
        case reapedDeadChild = 2
        case notFound = 3
    }

    /// What the host does once the claim has answered.
    enum Settled: UInt8 {
        /// Rebind the claimed session to the new sub-channels.
        case reattach = 1
        /// Fan the dead session's final agent teardown and drop its hook sink, then fork under the
        /// same id. The journal writer is deliberately not released.
        case reapThenSpawn = 2
        /// Fork a shell.
        case spawnFresh = 3
    }

    /// How to make a reattached shell repaint.
    enum Redraw: UInt8 {
        /// A plain `SIGWINCH` at the same size.
        case nudge = 1
        /// Shrink one row, hold, restore — the only thing that forces a differential renderer to
        /// re-lay-out rows it believes are already painted.
        case jiggle = 2
    }

    /// Routes one `channelOpen`.
    ///
    /// A verdict byte outside the enum would be a door and a face that disagree, which the
    /// `ffi-doors-are-opened` ratchet exists to prevent — so the fallback declines rather than
    /// guessing: a declined open costs a client one reconnect, and every other wrong answer costs
    /// a PTY.
    static func route(
        channelClass: UInt8,
        incumbent: Incumbent,
        stopping: Bool,
        realSessionID: Bool,
        detachedStore: Bool,
    ) -> Route {
        let raw = slopdesk_mux_open_route(
            channelClass, incumbent.rawValue, stopping, realSessionID, detachedStore,
        )
        return Route(rawValue: raw) ?? .decline
    }

    /// Turns the detached store's answer into the next action.
    static func settle(_ outcome: Claim) -> Settled {
        Settled(rawValue: slopdesk_mux_open_settle(outcome.rawValue)) ?? .spawnFresh
    }

    /// The host-authoritative resume verdict — the client's memory, clamped to what this session
    /// can actually number.
    ///
    /// The clamp is what keeps the answer honest for an ADOPTED pane: a new session object around
    /// an old shell, whose replay buffer starts at zero. Echoing the client's own 4000 back told it
    /// to keep dedup marks above every seq the session would ever assign, and the restored
    /// transcript plus all live output arrived below the mark and was dropped — a terminal that
    /// rendered nothing while keystrokes still reached the shell.
    static func resumeFrom(lastReceivedSeq: Int64, highestAssignedSeq: Int64) -> Int64 {
        slopdesk_mux_open_resume_from(lastReceivedSeq, highestAssignedSeq)
    }

    /// Which repaint a reattach earns.
    static func redraw(coldClient: Bool, snapshotComposed: Bool) -> Redraw {
        Redraw(rawValue: slopdesk_mux_open_redraw(coldClient, snapshotComposed)) ?? .nudge
    }

    /// Whether a FRESH spawn for a returning id replays the on-disk transcript first.
    static func restoresTranscript(realSessionID: Bool, lastReceivedSeq: Int64) -> Bool {
        slopdesk_mux_open_restores_transcript(realSessionID, lastReceivedSeq)
    }

    /// Where an adopted pane's supervised stream resumes, and whether the answer had to be guessed.
    ///
    /// `unpositioned` is the one case worth a log line: the transcript on disk has bytes but superd
    /// holds no position in the stream, so the user is handed the stored transcript and then
    /// everything from now, with an unknown gap between.
    static func survivorResume(
        storedBytes: UInt64,
        head: UInt64?,
    ) -> (offset: UInt64, unpositioned: Bool) {
        var unpositioned = false
        let offset = slopdesk_mux_open_survivor_resume(
            storedBytes, head != nil, head ?? 0, &unpositioned,
        )
        return (offset, unpositioned)
    }

    /// Whether a surviving pane's recorded owner permits THIS hostd to adopt it.
    static func ownershipAllowsAdoption(owner: String?, ours: String) -> Bool {
        var owner = owner ?? ""
        var ours = ours
        return owner.withUTF8 { ownerBytes in
            ours.withUTF8 { oursBytes in
                slopdesk_mux_open_ownership_allows_adoption(
                    ownerBytes.baseAddress, ownerBytes.count,
                    oursBytes.baseAddress, oursBytes.count,
                )
            }
        }
    }
}
