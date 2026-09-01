#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import SlopDeskVideoProtocol
import Synchronization

/// A per-pane ``VideoClientTransport`` backed by ONE channelID lane on a SHARED video
/// flow — the channelID-stamping facade vended to ``SlopDeskVideoClientSession``. This is
/// the only client video transport (one flow per host, N panes).
///
/// From the session's point of view it is just a ``VideoClientTransport`` (the session is
/// transport-agnostic via that protocol), so nothing upstream — ``SlopDeskVideoClientSession``,
/// the orchestrator's hello/input/recovery sends — knows about the shared flow. The
/// difference is entirely below: `start` acquires a lane on the shared flow for `(host, ports)`
/// from the ``VideoConnectionRegistry`` and wires this lane's inbound sink; `send` stamps this
/// lane's `channelID`; `stop` releases the lane (refcount--), tearing the shared flow down only
/// when this was the last pane on the host.
///
/// `Sendable`, and CHECKED: every binding is immutable, and the one piece of mutable state — which
/// lane of the shared flow this transport holds — lives in a `Mutex`.
public final class VideoMuxClientTransport: VideoClientTransport, Sendable {
    private let host: String
    private let mediaPort: UInt16
    private let cursorPort: UInt16
    /// Acquire a lane (refcount++) — hops to the `@MainActor` registry.
    private let acquire: @Sendable () async -> VideoMuxAcquisition
    /// Release this lane (refcount--, tear down the shared flow on 0) — hops to the registry.
    private let release: @Sendable (_ channelID: UInt32) async -> Void

    /// The acquired lane: the shared flow and the id inside it. One value because they are
    /// acquired and released together — a flow without its channelID addresses nothing.
    private struct Lane {
        var flow: VideoMuxClientFlowing?
        var channelID: UInt32?
    }

    private let lane = Mutex(Lane())

    @preconcurrency
    public init(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        acquire: @escaping @Sendable () async -> VideoMuxAcquisition,
        release: @escaping @Sendable (UInt32) async -> Void,
    ) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        self.acquire = acquire
        self.release = release
    }

    @preconcurrency
    public func start(
        onMedia: @escaping @Sendable (VideoChannel, Data) -> Void,
        onCursor: @escaping @Sendable (Data) -> Void,
    ) async {
        let acquisition = await acquire()
        lane.withLock { $0 = Lane(flow: acquisition.flow, channelID: acquisition.channelID) }
        // Wire this lane's inbound sinks (the shared flow demuxes host→client datagrams by channelID
        // and calls only this lane's sink) + prime the cursor side-channel for the lane.
        acquisition.flow.registerLane(channelID: acquisition.channelID, onMedia: onMedia, onCursor: onCursor)
    }

    public func send(_ datagram: Data, on channel: VideoChannel) {
        let (flow, id) = lane.withLock { ($0.flow, $0.channelID) }
        guard let flow, let id else { return }
        flow.send(datagram, on: channel, channelID: id)
    }

    /// The shared flow's media-path viability (dead-path gate for the session's periodic
    /// senders). Optimistic `true` before `start` / after `stop` — sends are no-ops then anyway.
    public var sendPathViable: Bool {
        lane.withLock { $0.flow }?.isSendPathViable ?? true
    }

    public func stop() async {
        let id: UInt32? = lane.withLock { lane in
            defer { lane = Lane() }
            return lane.channelID
        }
        guard let id else { return }
        await release(id)
    }
}
#endif
