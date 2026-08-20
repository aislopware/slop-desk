#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// The shared-flow seam the ``VideoConnectionRegistry`` refcounts — the UDP-mux
/// counterpart of the TCP-mux `MuxNWConnection`. The production conformer is
/// ``NWVideoMuxClientFlow`` (real `NWConnection`s); a test injects an in-memory fake so
/// the registry's refcount / teardown logic is provable WITHOUT a socket.
public protocol VideoMuxClientFlowing: AnyObject, Sendable {
    /// Opens the shared media + cursor connections once (idempotent).
    func startIfNeeded()
    /// Registers a lane's inbound sinks (demuxed by channelID) + primes its cursor flow.
    func registerLane(
        channelID: UInt32,
        onMedia: @escaping @Sendable (VideoChannel, Data) -> Void,
        onCursor: @escaping @Sendable (Data) -> Void,
    )
    /// Removes a lane's sinks.
    func unregisterLane(channelID: UInt32)
    /// Sends one datagram for `channelID` on `channel` (channelID-stamped).
    func send(_ datagram: Data, on channel: VideoChannel, channelID: UInt32)
    /// Tears the shared connections down (only when the LAST lane releases).
    func close()
    /// Whether the media send path is currently viable (dead-path gate for the session's
    /// PERIODIC senders — see ``UDPSendPathPolicy``). Defaulted `true` for conformers
    /// without path tracking (in-memory fakes keep today's always-send behaviour).
    var isSendPathViable: Bool { get }
}

public extension VideoMuxClientFlowing {
    var isSendPathViable: Bool { true }
}

#if canImport(Network)
extension NWVideoMuxClientFlow: VideoMuxClientFlowing {}
#endif

/// Refcounted pool of shared UDP video flows, ONE per host — the UDP-mux (Stage S3)
/// sibling of the TCP-mux `ConnectionRegistry`. The heart of "share one UDP flow
/// (media + cursor) per host across many video panes".
///
/// ## The single invariant it enforces
/// All video panes targeting the SAME `(host, mediaPort, cursorPort)` ride ONE shared
/// flow (one media + one cursor `NWConnection`), each as a distinct `channelID` lane.
/// The pool refcounts lanes per endpoint and tears the shared flow down **only when the
/// LAST lane closes** — so one pane closing or reconnecting never drops the flow the
/// others ride (the subtlest required behaviour, spec §4 / §8.5; per-channel loss
/// isolation).
///
/// ## `@MainActor` + synchronous query
/// ``VideoWindowPipeline`` constructs the per-pane transport synchronously on `activate`,
/// so endpoint bookkeeping must be queryable without an `await`. The pool is `@MainActor`;
/// endpoint bookkeeping are plain main-actor reads. Acquiring / releasing a lane is
/// synchronous bookkeeping (the flow's own socket ops are async inside `Network.framework`),
/// so it fits the synchronous construction site.
///
/// ## Where the refcount lives
/// The lane sets and the id allocator are `mux_client_pool.rs`'s, reached through the `mux_client`
/// door; this side keeps only the FLOW OBJECTS, because an `NWConnection` is a reference the crate
/// cannot hold. The pool answers whether an acquisition must BUILD a flow and whether a release
/// must CLOSE one — the two facts this map needs and the only two it acts on.
@preconcurrency
@MainActor
public final class VideoConnectionRegistry {
    /// The far-side pool, which owns the lane sets and the allocator. `nonisolated(unsafe)` only so
    /// the deinit may free it: every other touch is a main-actor call, and the last one is this.
    private nonisolated(unsafe) let pool: OpaquePointer?
    /// The shared flows themselves, keyed exactly as the pool keys its endpoints.
    private var flows: [String: VideoMuxClientFlowing] = [:]

    /// Builds a fresh shared flow for an endpoint. Injected so tests substitute an in-memory flow.
    private let makeFlow: @MainActor (_ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16)
        -> VideoMuxClientFlowing

    @preconcurrency
    public init(
        makeFlow: @escaping @MainActor (String, UInt16, UInt16) -> VideoMuxClientFlowing,
    ) {
        self.makeFlow = makeFlow
        // The per-process random base is drawn HERE and injected: the crate stays deterministic, and
        // randomness is exactly the part that cannot be. Why a base at all: two DISTINCT clients
        // streaming the same host window each ran a counter from 1, so both minted `channelID == 1`
        // for their first lane — and the host's reply-flow maps are keyed by the BARE channelID, so
        // the second client's lane HIJACKED the first's video/cursor flow (stream theft). Separate
        // ranges, no collision.
        pool = slopdesk_video_pool_new(.random(in: 0...UInt32.max))
    }

    deinit { slopdesk_video_pool_free(pool) }

    private static func key(_ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16) -> String {
        "\(host):\(mediaPort):\(cursorPort)"
    }

    /// The number of distinct shared flows currently pooled (one per active host). A test asserts
    /// this is 1 for N same-host video panes (the lsof "one UDP flow" property, headlessly).
    public var sharedFlowCount: Int { slopdesk_video_pool_shared_flow_count(pool) }

    /// The number of live lanes on the shared flow for `(host, ports)`, or 0 if none.
    public func laneCount(host: String, mediaPort: UInt16, cursorPort: UInt16) -> Int {
        asked(host) { address, length in
            slopdesk_video_pool_lane_count(pool, address, length, mediaPort, cursorPort)
        }
    }

    // MARK: - Acquire / release (driven by VideoMuxClientTransport)

    /// Acquires a lane on the shared flow for `(host, ports)`, creating the flow on the FIRST
    /// acquisition for that endpoint and reusing it thereafter (refcount++). Returns the lane's
    /// channelID + the shared flow it rides.
    public func acquire(host: String, mediaPort: UInt16, cursorPort: UInt16) -> VideoMuxAcquisition {
        var created = false
        let channelID = asked(host) { address, length in
            slopdesk_video_pool_acquire(pool, address, length, mediaPort, cursorPort, &created)
        }
        let key = Self.key(host, mediaPort, cursorPort)
        let flow: VideoMuxClientFlowing
        if !created, let existing = flows[key] {
            flow = existing
        } else {
            flow = makeFlow(host, mediaPort, cursorPort)
            flows[key] = flow
        }
        flow.startIfNeeded()
        return VideoMuxAcquisition(channelID: channelID, flow: flow)
    }

    /// Releases a lane from the shared flow (refcount--). If it was the LAST lane on that endpoint,
    /// tears the shared flow down and drops the pool entry — so the flow survives exactly as long as
    /// at least one video pane rides it. A sibling lane keeps the flow up (loss isolation on close).
    public func release(host: String, mediaPort: UInt16, cursorPort: UInt16, channelID: UInt32) {
        let outcome = asked(host) { address, length in
            slopdesk_video_pool_release(pool, address, length, mediaPort, cursorPort, channelID)
        }
        guard outcome != SLOPDESK_LANE_UNKNOWN else { return }
        let key = Self.key(host, mediaPort, cursorPort)
        guard let flow = flows[key] else { return }
        flow.unregisterLane(channelID: channelID)
        guard outcome == SLOPDESK_LANE_FLOW_CLOSED else { return }
        flows.removeValue(forKey: key)
        flow.close()
    }

    /// One question asked of the pool with the address lent as bytes for exactly that call.
    private func asked<Answer>(_ host: String, _ ask: (UnsafePointer<UInt8>?, Int) -> Answer) -> Answer {
        let address = Array(host.utf8)
        return address.withUnsafeBufferPointer { bytes in ask(bytes.baseAddress, bytes.count) }
    }
}

/// The result of acquiring a lane on a shared video flow: the lane's channelID + the shared flow.
public struct VideoMuxAcquisition: Sendable {
    public let channelID: UInt32
    public let flow: VideoMuxClientFlowing
    public init(channelID: UInt32, flow: VideoMuxClientFlowing) {
        self.channelID = channelID
        self.flow = flow
    }
}

@preconcurrency
@MainActor
public enum VideoMuxInstaller {
    /// Installs the PRODUCTION shared-flow registry on the video pipeline — the one app-glue site
    /// (called from `Apps/ClientApp-macOS/AppMain.swift` and `Apps/ClientApp-iOS/AppMain.swift`, the two
    /// GUI targets that link `SlopDeskVideoClient`). Every
    /// pane then vends its lane from this per-host shared UDP flow (one flow per host, N panes).
    /// Idempotent.
    ///
    /// The production flow factory builds real ``NWVideoMuxClientFlow``s — the only video wire there is.
    public static func install() {
        VideoWindowPipeline.sharedRegistry = VideoConnectionRegistry { host, mediaPort, cursorPort in
            #if canImport(Network)
            return NWVideoMuxClientFlow(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
            #else
            fatalError("the GUI video mux path requires Network.framework")
            #endif
        }
    }
}
#endif
