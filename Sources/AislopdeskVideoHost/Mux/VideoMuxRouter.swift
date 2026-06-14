import AislopdeskVideoProtocol
import Foundation

// Pure, platform-free mux routing for the host video orchestrator. NO sockets, no
// SCStream, no clock — exactly the discipline of ``InputDatagramRouter`` /
// ``VideoSessionStateMachine`` in VideoSessionLogic.swift, so this is headlessly
// unit-testable in isolation. A later (gated) stage will wire the live UDP receive
// loop to feed decoded `(channelID, VideoChannel, bytesCount)` through this; for now
// nothing constructs it, so a single-pane run is byte-identical to today.

/// PURE per-datagram mux router for the HOST side of the GUI video path (PATH 2).
///
/// When several remote-window sessions share one host UDP socket, each datagram is
/// fronted by a `UInt32` channelID (see ``VideoMuxHeaderCodec``). This router decides
/// which session a freshly-arrived datagram belongs to — purely from the channelID it
/// is told plus the admitted/retired bookkeeping it holds. It owns NO sockets and NO
/// session objects: it returns a ``Decision`` and lets the (later-built) IO layer act.
///
/// **Reconnect-generation safety.** A reconnecting client is admitted under a NEW
/// channelID (the prior one is `retire`d). In-flight datagrams that were already on
/// the wire for the OLD channelID must be DROPPED, not misrouted to the new session —
/// otherwise a stale frame/input from the previous generation would leak into the
/// fresh one. The router therefore keeps a retired set distinct from an "never seen"
/// channelID: a retired id is dropped with ``Decision/dropRetired`` (a known, benign
/// drop), while a genuinely unknown id is ``Decision/rejectUnadmitted``.
public struct VideoMuxRouter: Sendable {
    /// Currently-admitted lanes (one per live session). Routable for data.
    private var admitted: Set<UInt32> = []
    /// Lanes retired by a reconnect/teardown. Their in-flight datagrams are dropped
    /// (reconnect-generation safety) rather than rejected or misrouted.
    private var retired: Set<UInt32> = []
    /// The highest channelID ever retired (wrap-aware high-water mark), so the retired
    /// set can be pruned of ids too far below it to ever still have an in-flight datagram.
    private var highestRetired: UInt32?
    /// Lanes mid-teardown by the reaper: `beginDrain`-ed, awaiting `session.stop()`, not yet
    /// `retired`. While draining, EVERY datagram (including a `hello`) drops — so a reconnect that
    /// races the async teardown is neither delivered to the dying session's still-registered sink (a
    /// false accept) nor prematurely re-minted (which the later `endDrain`/retire would then kill).
    /// `endDrain` transitions draining → retired, after which FIX #2's hello-re-admit applies. Mirrors
    /// the single-pin "hold the lane pinned through teardown, free it LAST" discipline (audit FIX #4b).
    private var draining: Set<UInt32> = []

    /// FIX #4: bound the `retired` set exactly like ``FrameReassembler`` bounds its retired
    /// frame ids (cap at 512, prune to within 256 of the high-water mark). The client allocator
    /// is monotonic so a retired id is otherwise never re-admitted ⇒ one entry per pane/reconnect
    /// leaks for the daemon lifetime. channelIDs are monotonic, so an id far BELOW the high-water
    /// mark can have no in-flight datagram left — dropping it from `retired` is safe: it falls back
    /// to ``Decision/rejectUnadmitted`` (a clean drop for an unknown lane), and with FIX #2 a fresh
    /// hello for such an id still re-admits cleanly.
    static let retiredCap = 512
    static let retiredPruneWindow: Int = 256

    public init() {}

    /// The decision for one received muxed datagram. Mirrors
    /// `InputDatagramRouter.Decision`'s pure style (a closed enum the IO layer acts on,
    /// never a fatal condition for a single bad packet).
    public enum Decision: Equatable, Sendable {
        /// Route the datagram to the session bound to `channelID`.
        case route(channelID: UInt32)
        /// The `channelID` was never admitted (an unknown / stray lane) — reject it.
        case rejectUnadmitted
        /// The `channelID` was retired by a reconnect/teardown — drop the in-flight
        /// datagram so a previous generation's bytes never reach the new session.
        case dropRetired
        /// The `channelID` is mid-teardown (the reaper is stopping its session) — drop EVERY
        /// datagram (incl. a hello) until ``endDrain`` transitions it to `retired`.
        case dropDraining
        /// Drop for another reason (e.g. an empty/zero-byte datagram). `reason` is a
        /// short human-readable explanation (never a fatal condition).
        case drop(reason: String)
    }

    /// Admits `channelID` as a live lane. Idempotent. Admitting a previously-retired
    /// id clears its retired mark (a fresh generation may legitimately reuse an id).
    public mutating func admit(_ channelID: UInt32) {
        admitted.insert(channelID)
        retired.remove(channelID)
        draining.remove(channelID)
    }

    /// Retires `channelID` (reconnect/teardown): it stops being admitted and any
    /// further in-flight datagram for it is dropped via ``Decision/dropRetired``.
    public mutating func retire(_ channelID: UInt32) {
        admitted.remove(channelID)
        retired.insert(channelID)
        // Track the wrap-aware high-water mark, then bound the set (FIX #4).
        if let high = highestRetired {
            if channelID.distanceWrapped(from: high) > 0 { highestRetired = channelID }
        } else {
            highestRetired = channelID
        }
        if retired.count > Self.retiredCap, let high = highestRetired {
            retired = retired.filter { high.distanceWrapped(from: $0) <= Self.retiredPruneWindow }
        }
    }

    /// Begin tearing a lane down on the reaper path: stop routing it and HOLD it (draining) so a
    /// reconnect racing the async `session.stop()` drops cleanly rather than hitting the dying
    /// session's still-registered sink or re-minting early. Pair with ``endDrain`` once stopped.
    public mutating func beginDrain(_ channelID: UInt32) {
        admitted.remove(channelID)
        draining.insert(channelID)
    }

    /// Finish a reaper teardown: the session is stopped, so move the lane draining → retired (where a
    /// fresh `hello` may now re-admit it, FIX #2). Idempotent if the lane was not draining.
    public mutating func endDrain(_ channelID: UInt32) {
        draining.remove(channelID)
        retire(channelID)
    }

    /// Whether `channelID` is currently an admitted (routable) lane.
    public func isAdmitted(_ channelID: UInt32) -> Bool { admitted.contains(channelID) }
    /// Whether `channelID` is currently draining (reaper teardown in flight).
    public func isDraining(_ channelID: UInt32) -> Bool { draining.contains(channelID) }

    /// Decides what to do with one received datagram on `channel` carrying `channelID`.
    ///
    /// - Parameters:
    ///   - channelID: the lane the datagram is fronted with (from ``VideoMuxHeaderCodec``).
    ///   - channel: the logical sub-stream the datagram arrived on (control / video /
    ///     geometry / cursor / input / recovery). Carried through for the IO layer;
    ///     the admit/retire decision is per-channelID, not per-channel.
    ///   - bytesCount: the datagram's byte length (an empty datagram is dropped).
    public func route(channelID: UInt32, channel: VideoChannel, bytesCount: Int) -> Decision {
        _ = channel
        guard bytesCount > 0 else { return .drop(reason: "empty datagram") }
        if admitted.contains(channelID) { return .route(channelID: channelID) }
        if draining.contains(channelID) { return .dropDraining }
        if retired.contains(channelID) { return .dropRetired }
        return .rejectUnadmitted
    }

    /// What the transport's bootstrap arm should do with a NOT-yet-admitted datagram (the lane is
    /// unadmitted OR retired), given the router's ``route`` decision, the channel it arrived on, and
    /// whether its payload decoded as a `hello`. PURE (the hello-peek itself is done once by the
    /// caller and passed in as `payloadIsHello`) so it is unit-testable without a socket — the
    /// "decider beside the actor" pattern.
    ///
    /// - FIX #2: a RETIRED channelID re-admits ONLY when its `.control` datagram is an actual hello
    ///   (cross-process channelID reuse after a client restart — the dead old process has no
    ///   in-flight old-gen datagrams left, so an explicit hello is a safe re-admission). A non-hello
    ///   for a retired id still drops (reconnect-generation safety: stale old-gen video/input must
    ///   never reach a survivor).
    /// - FIX #6: an UNADMITTED (`.rejectUnadmitted`) lane bootstraps (and the transport stamps its
    ///   reply flow) ONLY when its first `.control` datagram is a hello — a stray/adversarial
    ///   non-hello control datagram drops WITHOUT the transport remembering its flow (which would
    ///   otherwise leak `channelMediaConn` for never-helloed ids).
    public enum BootstrapAction: Equatable, Sendable {
        /// Remember the lane's reply flow and deliver the datagram to the registry (it mints/admits).
        case bootstrapDeliver
        /// Drop without touching any flow bookkeeping (stray/retired non-hello, or non-control).
        case dropNoStamp
    }

    public static func bootstrapAction(
        for decision: Decision,
        channel: VideoChannel,
        payloadIsHello: Bool,
        payloadIsListRequest: Bool = false,
    ) -> BootstrapAction {
        switch decision {
        case .rejectUnadmitted,
             .dropRetired:
            // Both the never-seen and the retired (cross-process reuse) cases bootstrap (deliver +
            // stamp the reply flow) ONLY for a hello OR a window-LIST request on the control channel;
            // everything else drops without a stamp. A listWindows is delivered+stamped exactly like a
            // hello so the daemon can answer it (the daemon intercepts it and replies WITHOUT minting a
            // session — it never reaches the registry's mint path, and a never-admitted list lane is
            // retired right after the reply).
            let isBootstrapControl = channel == .control && (payloadIsHello || payloadIsListRequest)
            return isBootstrapControl ? .bootstrapDeliver : .dropNoStamp
        case .dropDraining,
             .route,
             .drop:
            // A draining lane is mid-teardown — drop EVEN a hello (no false accept, no premature
            // re-mint). `.route` is the live path; `.drop` (empty datagram) never bootstraps.
            return .dropNoStamp
        }
    }
}
