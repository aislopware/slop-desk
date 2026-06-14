#if canImport(Network)
import AislopdeskVideoProtocol
import Foundation
import Network
import OSLog

/// The CLIENT half of the shared UDP flow: ONE media + ONE cursor `NWConnection` to a
/// host, shared across all of that host's video panes and demultiplexed by a `UInt32`
/// channelID (``VideoMuxHeaderCodec``).
///
/// This is the mirror of the host's ``NWVideoMuxDatagramTransport`` — one flow per host,
/// N panes, the only video wire there is.
///
/// ## Wire (must match the host)
/// ```
///   [UInt32 BE channelID][UInt8 channelTag][payload...]   (media socket, client→host)
///   [UInt32 BE channelID][payload...]                     (cursor prime, client→host)
/// ```
/// Inbound host→client datagrams are channelID-prefixed too; this flow strips the
/// channelID and routes the rest to the matching lane's sink, so a lost datagram or a
/// sibling lane's teardown never disturbs other lanes (per-channel loss isolation).
///
/// ## HANG / SOCKET SAFETY
/// Opens real `NWConnection` `.udp` flows — COMPILED + reviewed, NEVER instantiated in
/// a test. The pure framing it drives (``VideoMuxHeaderCodec``) + the registry's refcount
/// logic ARE unit-tested.
///
/// `@unchecked Sendable` via the internal `NSLock` guarding the lane sink tables.
public final class NWVideoMuxClientFlow: @unchecked Sendable {
    private static func mediaSocket(for channel: VideoChannel) -> Bool { channel != .cursor }

    private let log = Logger(subsystem: "aislopdesk.video.client", category: "NWVideoMuxClientFlow")
    private let mediaEndpoint: NWEndpoint
    private let cursorEndpoint: NWEndpoint
    private let queue = DispatchQueue(label: "aislopdesk.video.client.transport.mux", qos: .userInteractive)

    private let lock = NSLock()
    /// KHỰNG-ladder stage 3 (AISLOPDESK_VIDEO_DEBUG): last VIDEO-datagram socket-arrival time.
    /// Owned by the serial receive queue — no lock needed.
    static let dbgGapEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil
    private var dbgLastVideoRxAt: Double = 0
    private var mediaConn: NWConnection?
    private var cursorConn: NWConnection?
    /// channelID → (onMedia, onCursor) for the lane. A datagram is delivered only to its lane.
    private var mediaSinks: [UInt32: @Sendable (VideoChannel, Data) -> Void] = [:]
    private var cursorSinks: [UInt32: @Sendable (Data) -> Void] = [:]
    private var started = false

    private final class Liveness: @unchecked Sendable {
        private let lock = NSLock()
        private var alive = true
        var isAlive: Bool { lock.withLock { alive } }
        func markDead() { lock.withLock { alive = false } }
    }

    public init(host: String, mediaPort: UInt16, cursorPort: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        guard let mediaNWPort = NWEndpoint.Port(rawValue: mediaPort) else {
            preconditionFailure("mediaPort \(mediaPort) is not a valid NWEndpoint.Port (0 is reserved)")
        }
        guard let cursorNWPort = NWEndpoint.Port(rawValue: cursorPort) else {
            preconditionFailure("cursorPort \(cursorPort) is not a valid NWEndpoint.Port (0 is reserved)")
        }
        mediaEndpoint = NWEndpoint.hostPort(host: nwHost, port: mediaNWPort)
        cursorEndpoint = NWEndpoint.hostPort(host: nwHost, port: cursorNWPort)
    }

    /// Opens the shared media + cursor connections ONCE (idempotent). Subsequent lane opens reuse
    /// them; only the registry's last-channel release tears them down.
    public func startIfNeeded() {
        lock.lock()
        if started { lock.unlock()
            return
        }
        started = true
        let params = NWParameters.udp
        params.includePeerToPeer = false
        let media = NWConnection(to: mediaEndpoint, using: params)
        let cursor = NWConnection(to: cursorEndpoint, using: params)
        mediaConn = media
        cursorConn = cursor
        lock.unlock()

        let mediaLive = Liveness()
        let cursorLive = Liveness()
        media.stateUpdateHandler = { state in
            switch state { case .failed,
                 .cancelled: mediaLive.markDead()
            default: break }
        }
        cursor.stateUpdateHandler = { state in
            switch state { case .failed,
                 .cancelled: cursorLive.markDead()
            default: break }
        }
        media.start(queue: queue)
        cursor.start(queue: queue)
        receiveMedia(on: media, live: mediaLive)
        receiveCursor(on: cursor, live: cursorLive)
        // Bind locals so the os_log interpolation captures no `self` (Swift 6 requires explicit
        // `self.` inside the OSLogMessage autoclosure, which the formatter's redundantSelf strips).
        let mediaDesc = String(describing: mediaEndpoint)
        let cursorDesc = String(describing: cursorEndpoint)
        log.info("NWVideoMuxClientFlow connected media=\(mediaDesc) cursor=\(cursorDesc) (shared)")
    }

    // MARK: - Lane registration (per channelID)

    @preconcurrency
    public func registerLane(
        channelID: UInt32,
        onMedia: @escaping @Sendable (VideoChannel, Data) -> Void,
        onCursor: @escaping @Sendable (Data) -> Void,
    ) {
        lock.withLock {
            mediaSinks[channelID] = onMedia
            cursorSinks[channelID] = onCursor
        }
        // PRIME the cursor side-channel for this lane so the host learns the lane's cursor flow
        // (the host accepts a cursor flow only on an inbound datagram; the prime is channelID-prefixed
        // so the host binds it to the right lane).
        lock.lock()
        let cursor = cursorConn
        lock.unlock()
        let prime = VideoMuxHeaderCodec.encode(channelID: channelID, payload: Data([0x00]))
        cursor?.send(content: prime, completion: .contentProcessed { [weak self] error in
            if let error { self?.log.error("mux cursor prime failed chan=\(channelID): \(String(describing: error))") }
        })
    }

    public func unregisterLane(channelID: UInt32) {
        lock.withLock {
            mediaSinks.removeValue(forKey: channelID)
            cursorSinks.removeValue(forKey: channelID)
        }
    }

    /// Whether any lane is still live (the registry tears the flow down on 0).
    public var laneCount: Int { lock.withLock { mediaSinks.count } }

    // MARK: - Send (client → host, per channelID)

    public func send(_ datagram: Data, on channel: VideoChannel, channelID: UInt32) {
        // The client sends on the media socket only (control + input). A stray cursor send is
        // dropped defensively.
        guard Self.mediaSocket(for: channel) else { return }
        lock.lock()
        let conn = mediaConn
        lock.unlock()
        guard let conn else { return }
        var inner = Data(capacity: datagram.count + 1)
        inner.append(channel.rawValue)
        inner.append(datagram)
        let framed = VideoMuxHeaderCodec.encode(channelID: channelID, payload: inner)
        conn.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log
                    .error(
                        "mux udp send failed channel=\(channel.rawValue) chan=\(channelID): \(String(describing: error))",
                    )
            }
        })
    }

    // MARK: - Receive (host → client, demuxed by channelID)

    private func receiveMedia(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let (channelID, rest) = try? VideoMuxHeaderCodec.decode(data), rest.count >= 1 {
                let tag = rest[rest.startIndex]
                if let channel = VideoChannel(rawValue: tag) {
                    // KHỰNG-ladder stage 3 (AISLOPDESK_VIDEO_DEBUG): a >28ms hole between MEDIA datagrams at
                    // the SOCKET (before any actor hop) during continuous motion = the hole already
                    // existed on the wire (host stall or path stall) — stages 4/5 can only inherit it.
                    // Serial receive queue ⇒ the stamp needs no lock.
                    if Self.dbgGapEnabled, channel == .video {
                        let now = ProcessInfo.processInfo.systemUptime
                        if dbgLastVideoRxAt > 0, now - dbgLastVideoRxAt > 0.028 {
                            FileHandle.standardError
                                .write(
                                    Data("Aislopdesk[video.client]: rx gap \(Int((now - dbgLastVideoRxAt) * 1000))ms\n"
                                        .utf8),
                                )
                        }
                        dbgLastVideoRxAt = now
                    }
                    let payload = Data(rest[(rest.startIndex + 1)...])
                    let sink = lock.withLock { self.mediaSinks[channelID] }
                    sink?(channel, payload) // a datagram for a closed/unknown lane is dropped (loss isolation)
                }
            }
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                log
                    .error(
                        "mux media receive error (transient, backing off + re-arming if alive): \(String(describing: error))",
                    )
                let next = consecutiveErrors + 1
                queue
                    .asyncAfter(deadline: .now() + UDPReceiveLoopPolicy
                        .nextBackoff(consecutiveErrors: next))
                    { [weak self] in
                        guard let self, live.isAlive else { return }
                        receiveMedia(on: conn, live: live, consecutiveErrors: next)
                    }
            } else {
                receiveMedia(on: conn, live: live, consecutiveErrors: 0)
            }
        }
    }

    private func receiveCursor(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let (channelID, payload) = try? VideoMuxHeaderCodec.decode(data), !payload.isEmpty {
                let sink = lock.withLock { self.cursorSinks[channelID] }
                sink?(payload)
            }
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                log
                    .error(
                        "mux cursor receive error (transient, backing off + re-arming if alive): \(String(describing: error))",
                    )
                let next = consecutiveErrors + 1
                queue
                    .asyncAfter(deadline: .now() + UDPReceiveLoopPolicy
                        .nextBackoff(consecutiveErrors: next))
                    { [weak self] in
                        guard let self, live.isAlive else { return }
                        receiveCursor(on: conn, live: live, consecutiveErrors: next)
                    }
            } else {
                receiveCursor(on: conn, live: live, consecutiveErrors: 0)
            }
        }
    }

    public func close() {
        lock.withLock {
            mediaConn?.cancel()
            mediaConn = nil
            cursorConn?.cancel()
            cursorConn = nil
            mediaSinks.removeAll()
            cursorSinks.removeAll()
            started = false
        }
    }
}
#endif
