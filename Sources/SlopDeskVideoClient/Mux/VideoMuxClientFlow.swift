import CSlopDeskFFI
import Foundation
import OSLog
import SlopDeskVideoProtocol

/// The CLIENT half of the shared UDP flow, as a handle on `slopdesk_videolink`.
///
/// One media and one cursor socket to a host, shared by every video pane pointed at it and
/// demultiplexed by a `UInt32` channelID. The sockets, the two reader threads, the lane table, the
/// framing, the re-arm and the send-path reading are all Rust's — see `slopdesk_video_flow_*` in
/// `slopdesk_ffi.h` and the crate header of `rust/slopdesk-videolink`. This file is the handle's
/// lifetime and the callback boxes, and decides nothing.
///
/// ## Why there is no `NWConnection` here any more
/// `Network.framework` bought a state machine this path never wanted and cost it three things: a
/// bring-up failure that could only arrive through a state handler, a class no test could
/// instantiate, and a `.waiting` queue deep enough that the client needed a whole send-path POLICY
/// to stop feeding it. A plain `UdpSocket` has none of those, so `open` answers its own failure,
/// `rust/slopdesk-videolink`'s suite drives the real thing against a second socket, and viability is
/// simply whether the last send left.
///
/// `@unchecked Sendable` via the `NSLock` guarding the handle.
public final class VideoMuxClientFlow: @unchecked Sendable {
    private static func mediaSocket(for channel: VideoChannel) -> Bool { channel != .cursor }

    private let log = Logger(subsystem: "slopdesk.video.client", category: "VideoMuxClientFlow")
    private let host: String
    private let mediaPort: UInt16
    private let cursorPort: UInt16

    private let lock = NSLock()
    private var handle: OpaquePointer?

    public init(host: String, mediaPort: UInt16, cursorPort: UInt16) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
    }

    deinit {
        if let handle { slopdesk_video_flow_free(handle) }
    }

    /// Opens the shared media + cursor sockets ONCE (idempotent). Subsequent lane opens reuse them;
    /// only the registry's last-channel release tears them down.
    public func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { return }
        handle = Array(host.utf8).withUnsafeBufferPointer {
            slopdesk_video_flow_open($0.baseAddress, $0.count, mediaPort, cursorPort)
        }
        if handle == nil {
            // A bring-up failure is answered HERE, which is the point of the port: the next lane
            // open retries rather than the pane waiting on a state that never settles.
            //
            // Bind locals so the os_log interpolation captures no `self` — Swift 6 requires an
            // explicit `self.` inside the OSLogMessage autoclosure, which the formatter strips.
            let media = mediaPort
            let cursor = cursorPort
            log.error("video mux flow failed to open media=\(media) cursor=\(cursor)")
        }
    }

    // MARK: - Lane registration (per channelID)

    @preconcurrency
    public func registerLane(
        channelID: UInt32,
        onMedia: @escaping @Sendable (VideoChannel, Data) -> Void,
        onCursor: @escaping @Sendable (Data) -> Void,
    ) {
        startIfNeeded()
        lock.lock()
        let flow = handle
        lock.unlock()
        guard let flow else { return }
        // Retained here, released by `onRelease` below — the one lifetime rule the door states, and
        // the reason a release callback exists at all: unregistering a lane cannot join the reader
        // that still serves the flow's other lanes.
        let box = Unmanaged.passRetained(LaneBox(onMedia: onMedia, onCursor: onCursor)).toOpaque()
        slopdesk_video_flow_register_lane(flow, channelID, box, { context, tag, bytes, length in
            guard let context, let channel = VideoChannel(rawValue: tag) else { return }
            Unmanaged<LaneBox>.fromOpaque(context).takeUnretainedValue().onMedia(channel, lent(bytes, length))
        }, { context, bytes, length in
            guard let context else { return }
            Unmanaged<LaneBox>.fromOpaque(context).takeUnretainedValue().onCursor(lent(bytes, length))
        }, { context in
            guard let context else { return }
            Unmanaged<LaneBox>.fromOpaque(context).release()
        })
    }

    public func unregisterLane(channelID: UInt32) {
        lock.lock()
        let flow = handle
        lock.unlock()
        guard let flow else { return }
        slopdesk_video_flow_unregister_lane(flow, channelID)
    }

    // MARK: - Send (client → host, per channelID)

    /// Whether the media send path is currently viable. The session's PERIODIC senders (20 Hz
    /// NetworkStats, 5 s keepalive) skip their fire while this is false so a client on a dead path
    /// stops handing the kernel datagrams that cannot leave; sparse best-effort sends (input, hello,
    /// recovery) are not gated.
    public var isSendPathViable: Bool {
        lock.lock()
        let flow = handle
        lock.unlock()
        return slopdesk_video_flow_send_path_viable(flow)
    }

    public func send(_ datagram: Data, on channel: VideoChannel, channelID: UInt32) {
        lock.lock()
        let flow = handle
        lock.unlock()
        guard let flow else { return }
        // A `.cursor` send is the lane's flow (re-)prime: it rides the CURSOR socket with the
        // channelID-only framing (no tag), so the host (re-)stamps this lane's cursor reply flow.
        // The session re-primes with every hello and each keepalive tick because the cursor socket
        // carries no other client→host traffic — a host restart or NAT rebind would otherwise kill
        // cursor updates for the lane's whole life while video and input self-heal.
        let sent = datagram.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress
            guard Self.mediaSocket(for: channel) else {
                return slopdesk_video_flow_send_cursor(flow, channelID, bytes, raw.count)
            }
            return slopdesk_video_flow_send_media(flow, channelID, channel.rawValue, bytes, raw.count)
        }
        if !sent {
            log.error("mux udp send failed channel=\(channel.rawValue) chan=\(channelID)")
        }
    }

    public func close() {
        lock.lock()
        let flow = handle
        handle = nil
        lock.unlock()
        // Outside the lock: `free` joins both readers, and a callback still in flight takes no lock
        // of ours but a re-entrant `close` from one would.
        if let flow { slopdesk_video_flow_free(flow) }
    }
}

/// The two closures one lane delivers into, boxed so a `@convention(c)` callback can reach them.
private final class LaneBox: Sendable {
    let onMedia: @Sendable (VideoChannel, Data) -> Void
    let onCursor: @Sendable (Data) -> Void

    init(
        onMedia: @escaping @Sendable (VideoChannel, Data) -> Void,
        onCursor: @escaping @Sendable (Data) -> Void,
    ) {
        self.onMedia = onMedia
        self.onCursor = onCursor
    }
}

/// A payload LENT for the callback, copied because the sink outlives the call.
///
/// The sink enqueues what it is handed on the session's inbound queue, so a view onto Rust's read
/// window would dangle the moment the reader loops. One memcpy of at most a datagram is what that
/// costs, and it is the same copy `Network.framework` used to make before the old flow ever saw it.
private func lent(_ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Data {
    guard let bytes, length > 0 else { return Data() }
    return Data(bytes: bytes, count: length)
}
