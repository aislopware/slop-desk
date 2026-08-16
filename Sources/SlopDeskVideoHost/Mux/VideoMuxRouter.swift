import CSlopDeskFFI
import SlopDeskVideoProtocol

/// The Swift face of `rust/slopdesk-video`'s `mux_routing` router, reached through the `mux_host`
/// door.
///
/// PER-datagram mux router for the HOST side of the GUI video path (PATH 2).
///
/// When several remote-window sessions share one host UDP socket, each datagram is fronted by a
/// `UInt32` channelID (see ``VideoMuxHeaderCodec``). This router decides which session a
/// freshly-arrived datagram belongs to — purely from the channelID it is told plus the
/// admitted/retired bookkeeping the door holds. It owns NO sockets and NO session objects: it
/// returns a ``Decision`` and lets the IO layer act.
///
/// **Reconnect-generation safety.** A reconnecting client is admitted under a NEW channelID (the
/// prior one is `retire`d). In-flight datagrams that were already on the wire for the OLD channelID
/// must be DROPPED, not misrouted to the new session — otherwise a stale frame/input from the
/// previous generation would leak into the fresh one. The far side therefore keeps a retired set
/// distinct from a "never seen" channelID: a retired id is dropped with ``Decision/dropRetired`` (a
/// known, benign drop), while a genuinely unknown id is ``Decision/rejectUnadmitted``.
///
/// **A handle, not a fold.** Three lane sets and a wrap-aware high-water mark, bounded at five
/// hundred retired ids — and the near side reads exactly one verdict per datagram out of them.
/// That is doc 55 §4b's test for a handle, and it keeps the retired-set prune (the part a second
/// implementation would get wrong) on the side that states the rule.
///
/// A `final class`, so the single owner (``NWVideoMuxDatagramTransport``) holds it by reference
/// without a `let`→`var` ripple. `@unchecked Sendable` is sound because that owner serializes every
/// call under its mux `lock` (and the tests run on one thread), so no two threads race the state.
public final class VideoMuxRouter: @unchecked Sendable {
    /// The far-side router, which owns every lane set.
    private let handle: OpaquePointer?

    public init() { handle = slopdesk_mux_router_new() }

    deinit { slopdesk_mux_router_free(handle) }

    /// The decision for one received muxed datagram. Mirrors `InputDatagramRouter.Decision`'s pure
    /// style (a closed enum the IO layer acts on, never a fatal condition for a single bad packet).
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

        /// The code this verdict crosses as.
        var code: UInt32 {
            switch self {
            case .route: SLOPDESK_MUX_ROUTE
            case .rejectUnadmitted: SLOPDESK_MUX_REJECT_UNADMITTED
            case .dropRetired: SLOPDESK_MUX_DROP_RETIRED
            case .dropDraining: SLOPDESK_MUX_DROP_DRAINING
            case .drop: SLOPDESK_MUX_DROP_EMPTY
            }
        }

        /// The verdict a code names, for the lane that was asked about.
        static func of(_ code: UInt32, channelID: UInt32) -> Self {
            switch code {
            case SLOPDESK_MUX_ROUTE: .route(channelID: channelID)
            case SLOPDESK_MUX_DROP_RETIRED: .dropRetired
            case SLOPDESK_MUX_DROP_DRAINING: .dropDraining
            case SLOPDESK_MUX_DROP_EMPTY: .drop(reason: "empty datagram")
            default: .rejectUnadmitted
            }
        }
    }

    /// Admits `channelID` as a live lane. Idempotent. Admitting a previously-retired
    /// id clears its retired mark (a fresh generation may legitimately reuse an id) and clears any
    /// draining mark.
    public func admit(_ channelID: UInt32) { slopdesk_mux_router_admit(handle, channelID) }

    /// Retires `channelID` (reconnect/teardown): it stops being admitted and any
    /// further in-flight datagram for it is dropped via ``Decision/dropRetired``.
    public func retire(_ channelID: UInt32) { slopdesk_mux_router_retire(handle, channelID) }

    /// Begin tearing a lane down on the reaper path: stop routing it and HOLD it (draining) so a
    /// reconnect racing the async `session.stop()` drops cleanly rather than hitting the dying
    /// session's still-registered sink or re-minting early. Pair with ``endDrain`` once stopped.
    public func beginDrain(_ channelID: UInt32) { slopdesk_mux_router_begin_drain(handle, channelID) }

    /// Finish a reaper teardown: the session is stopped, so move the lane draining → retired (where a
    /// fresh `hello` may now re-admit it). Idempotent if the lane was not draining.
    public func endDrain(_ channelID: UInt32) { slopdesk_mux_router_end_drain(handle, channelID) }

    /// Whether `channelID` is currently an admitted (routable) lane.
    public func isAdmitted(_ channelID: UInt32) -> Bool { slopdesk_mux_router_is_admitted(handle, channelID) }

    /// Whether `channelID` is currently draining (reaper teardown in flight).
    public func isDraining(_ channelID: UInt32) -> Bool { slopdesk_mux_router_is_draining(handle, channelID) }

    /// Decides what to do with one received datagram on `channel` carrying `channelID`.
    ///
    /// - Parameters:
    ///   - channelID: the lane the datagram is fronted with (from ``VideoMuxHeaderCodec``).
    ///   - channel: the logical sub-stream the datagram arrived on (control / video / geometry /
    ///     cursor / input / recovery). Carried through for the IO layer; the admit/retire decision
    ///     is per-channelID, not per-channel, so it does not cross.
    ///   - bytesCount: the datagram's byte length (an empty datagram is dropped, and this check
    ///     takes precedence over admitted/draining/retired state).
    public func route(channelID: UInt32, channel: VideoChannel, bytesCount: Int) -> Decision {
        _ = channel
        return Decision.of(slopdesk_mux_router_route(handle, channelID, bytesCount), channelID: channelID)
    }

    /// What the transport's bootstrap arm should do with a NOT-yet-admitted datagram (the lane is
    /// unadmitted OR retired), given the router's ``route`` decision, the channel it arrived on, and
    /// whether its payload decoded as a `hello`. PURE (the hello-peek itself is done once by the
    /// caller and passed in as `payloadIsHello`) so it is unit-testable without a socket — the
    /// "decider beside the actor" pattern. The rule is `mux_routing.rs`'s; see it for which lane
    /// state re-admits on what.
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
        let action = slopdesk_mux_bootstrap_action(
            decision.code, channel.rawValue, payloadIsHello, payloadIsListRequest,
        )
        return action == SLOPDESK_MUX_BOOTSTRAP_DELIVER ? .bootstrapDeliver : .dropNoStamp
    }
}
