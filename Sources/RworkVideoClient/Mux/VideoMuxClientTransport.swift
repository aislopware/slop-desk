#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import RworkVideoProtocol

/// A per-pane ``VideoClientTransport`` backed by ONE channelID lane on a SHARED video
/// flow (Stage S3) — the channelID-stamping facade vended (behind `RWORK_VIDEO_MUX`) to
/// ``RworkVideoClientSession`` in place of the today-shaped one-flow-per-pane
/// ``NWVideoClientTransport``.
///
/// From the session's point of view it has the IDENTICAL surface as
/// ``NWVideoClientTransport`` (same ``VideoClientTransport`` protocol), so nothing
/// upstream — ``RworkVideoClientSession``, the orchestrator's hello/input/recovery
/// sends — changes. The difference is entirely below: `start` acquires a lane on the
/// shared flow for `(host, ports)` from the ``VideoConnectionRegistry`` and wires this
/// lane's inbound sink; `send` stamps this lane's `channelID`; `stop` releases the lane
/// (refcount--), tearing the shared flow down only when this was the last pane on the host.
///
/// `@unchecked Sendable`: it holds immutable bindings + delegates all shared mutable state
/// to the (`@MainActor`) registry and the internally-locked shared flow.
public final class VideoMuxClientTransport: VideoClientTransport, @unchecked Sendable {
    private let host: String
    private let mediaPort: UInt16
    private let cursorPort: UInt16
    /// Acquire a lane (refcount++) — hops to the `@MainActor` registry.
    private let acquire: @Sendable () async -> VideoMuxAcquisition
    /// Release this lane (refcount--, tear down the shared flow on 0) — hops to the registry.
    private let release: @Sendable (_ channelID: UInt32) async -> Void

    private let stateLock = NSLock()
    private var flow: VideoMuxClientFlowing?
    private var channelID: UInt32?

    public init(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        acquire: @escaping @Sendable () async -> VideoMuxAcquisition,
        release: @escaping @Sendable (UInt32) async -> Void
    ) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        self.acquire = acquire
        self.release = release
    }

    public func start(
        onMedia: @escaping @Sendable (VideoChannel, Data) -> Void,
        onCursor: @escaping @Sendable (Data) -> Void
    ) async throws {
        let acquisition = await acquire()
        stateLock.withLock {
            flow = acquisition.flow
            channelID = acquisition.channelID
        }
        // Wire this lane's inbound sinks (the shared flow demuxes host→client datagrams by channelID
        // and calls only this lane's sink) + prime the cursor side-channel for the lane.
        acquisition.flow.registerLane(channelID: acquisition.channelID, onMedia: onMedia, onCursor: onCursor)
    }

    public func send(_ datagram: Data, on channel: VideoChannel) {
        let (f, id): (VideoMuxClientFlowing?, UInt32?) = stateLock.withLock { (flow, channelID) }
        guard let f, let id else { return }
        f.send(datagram, on: channel, channelID: id)
    }

    public func stop() async {
        let id: UInt32? = stateLock.withLock {
            let captured = channelID
            flow = nil
            channelID = nil
            return captured
        }
        guard let id else { return }
        await release(id)
    }
}
#endif
