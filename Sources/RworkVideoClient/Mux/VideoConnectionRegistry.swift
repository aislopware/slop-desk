#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import RworkVideoProtocol

/// The shared-flow seam the ``VideoConnectionRegistry`` refcounts — the UDP-mux
/// counterpart of the TCP-mux `MuxNWConnection`. The production conformer is
/// ``NWVideoMuxClientFlow`` (real `NWConnection`s); a test injects an in-memory fake so
/// the registry's refcount / teardown logic is provable WITHOUT a socket.
public protocol VideoMuxClientFlowing: AnyObject, Sendable {
    /// Opens the shared media + cursor connections once (idempotent).
    func startIfNeeded()
    /// Registers a lane's inbound sinks (demuxed by channelID) + primes its cursor flow.
    func registerLane(channelID: UInt32, onMedia: @escaping @Sendable (VideoChannel, Data) -> Void, onCursor: @escaping @Sendable (Data) -> Void)
    /// Removes a lane's sinks.
    func unregisterLane(channelID: UInt32)
    /// Sends one datagram for `channelID` on `channel` (channelID-stamped).
    func send(_ datagram: Data, on channel: VideoChannel, channelID: UInt32)
    /// Tears the shared connections down (only when the LAST lane releases).
    func close()
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
@MainActor
public final class VideoConnectionRegistry {
    private struct Entry {
        let flow: VideoMuxClientFlowing
        var channelIDs: Set<UInt32> = []
    }

    private var entries: [String: Entry] = [:]
    /// Monotonic channelID allocator, SEEDED from a per-process RANDOM base ([7]). UDP lanes need only
    /// be unique per shared flow within a process — a monotonic counter guarantees that and never reuses
    /// a retired id (reconnect-generation safety on the host's ``VideoMuxRouter``). But two DISTINCT
    /// clients streaming the SAME host window each ran their own counter from 1, so both minted
    /// `channelID == 1` for their first lane — and the host's per-channelID reply-flow maps
    /// (`channelMediaConn` / `channelCursorConn`) are keyed by the BARE channelID, so the second client's
    /// lane HIJACKED the first's video/cursor reply flow (stream theft). Seeding each process's counter
    /// from a random base separates the two clients' id RANGES, so their lanes never collide on the host.
    /// The base is masked well below `UInt32.max` so a long-lived client's `&+= 1` cannot wrap into a
    /// sibling's range within any realistic session (a client opens far fewer than the ~0xF0000000
    /// headroom of lanes). Still strictly monotonic within the process (the property the router needs).
    private var nextChannelID: UInt32 = UInt32.random(in: 1...0x0FFF_FFFF)

    /// Builds a fresh shared flow for an endpoint. Injected so tests substitute an in-memory flow.
    private let makeFlow: @MainActor (_ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16) -> VideoMuxClientFlowing

    public init(
        makeFlow: @escaping @MainActor (String, UInt16, UInt16) -> VideoMuxClientFlowing
    ) {
        self.makeFlow = makeFlow
    }

    private static func key(_ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16) -> String {
        "\(host):\(mediaPort):\(cursorPort)"
    }

    /// The number of distinct shared flows currently pooled (one per active host). A test asserts
    /// this is 1 for N same-host video panes (the lsof "one UDP flow" property, headlessly).
    public var sharedFlowCount: Int { entries.count }

    /// The number of live lanes on the shared flow for `(host, ports)`, or 0 if none.
    public func laneCount(host: String, mediaPort: UInt16, cursorPort: UInt16) -> Int {
        entries[Self.key(host, mediaPort, cursorPort)]?.channelIDs.count ?? 0
    }

    // MARK: - Acquire / release (driven by VideoMuxClientTransport)

    /// Acquires a lane on the shared flow for `(host, ports)`, creating the flow on the FIRST
    /// acquisition for that endpoint and reusing it thereafter (refcount++). Returns the lane's
    /// channelID + the shared flow it rides.
    public func acquire(host: String, mediaPort: UInt16, cursorPort: UInt16) -> VideoMuxAcquisition {
        let key = Self.key(host, mediaPort, cursorPort)
        let flow: VideoMuxClientFlowing
        if let existing = entries[key] {
            flow = existing.flow
        } else {
            flow = makeFlow(host, mediaPort, cursorPort)
            entries[key] = Entry(flow: flow)
        }
        flow.startIfNeeded()
        let channelID = nextChannelID
        nextChannelID &+= 1
        entries[key]?.channelIDs.insert(channelID)
        return VideoMuxAcquisition(channelID: channelID, flow: flow)
    }

    /// Releases a lane from the shared flow (refcount--). If it was the LAST lane on that endpoint,
    /// tears the shared flow down and drops the pool entry — so the flow survives exactly as long as
    /// at least one video pane rides it. A sibling lane keeps the flow up (loss isolation on close).
    public func release(host: String, mediaPort: UInt16, cursorPort: UInt16, channelID: UInt32) {
        let key = Self.key(host, mediaPort, cursorPort)
        guard var entry = entries[key] else { return }
        entry.flow.unregisterLane(channelID: channelID)
        entry.channelIDs.remove(channelID)
        if entry.channelIDs.isEmpty {
            entries.removeValue(forKey: key)
            entry.flow.close()
        } else {
            entries[key] = entry
        }
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

@MainActor
public enum VideoMuxInstaller {
    /// Installs the PRODUCTION shared-flow registry on the video pipeline — the one app-glue site
    /// (called from `Apps/Shared/AppMain.swift`, the GUI target that links `RworkVideoClient`). Every
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
