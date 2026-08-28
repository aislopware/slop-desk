/// The logical sub-streams that share one PATH 2 UDP session (doc 17 §3.3/§3.6/§3.8).
///
/// The raw values are the **wire tags** — the 1-byte prefix on every media-socket datagram. They are
/// golden-pinned: changing one silently re-routes a channel on the far side.
///
/// The host and the client each carried their own copy of this enum, with the byte-identical cases
/// and a doc paragraph on each side saying so ("the wire contract is the agreement, not a shared
/// Swift type"). That was true of the *modules* — the client must not depend on the macOS-only host —
/// but not of the wire target both already depend on, which is where a shared tag belongs. Two
/// declarations of one contract is exactly the `process::basename` shape (`docs/55` §6): they agree
/// until the day a seventh channel lands on one side.
///
/// The direction and socket notes that genuinely differ per side — what the host SENDS versus what
/// the client RECEIVES, and which socket a tag rides — stay in each transport's own doc, where its
/// reader is.
///
/// The cursor channel is a **separate UDP socket** (doc 17 §3.3: "KHÔNG multiplex chung socket video"
/// — never multiplex with video, so video backpressure never delays the cursor). An orchestrator
/// treats each channel as an independent addressable lane; the concrete transport decides whether to
/// back them with one socket + a tag, or distinct sockets. The proven design uses TWO sockets: a
/// media socket (control / video / geometry / input / recovery / audio) and a dedicated cursor socket.
public enum VideoChannel: UInt8, Sendable, CaseIterable {
    /// Session bring-up control (``VideoControlMessage``): hello / helloAck / bye.
    case control = 0
    /// Encoded video fragments (``FrameFragment``) — host → client.
    case video = 1
    /// Window move/resize/title (``WindowGeometryMessage``) — host → client.
    case geometry = 2
    /// Cursor position + shape (``CursorChannelMessage``) — host → client, on its own socket.
    case cursor = 3
    /// Client → host input (``InputEvent``).
    case input = 4
    /// Client → host loss recovery (``RecoveryMessage``: requestLTRRefresh / requestIDR / ack). A
    /// DEDICATED channel, not multiplexed onto `.input`: `RecoveryMessage`'s leading type bytes
    /// (1/2/3) overlap `InputEvent`'s (mouseMove/Down/Up), so sharing `.input` would mis-decode a
    /// recovery datagram as a phantom mouse event. The per-purpose channel also lets the host route
    /// recovery to handling that never reaches `slopdesk_video::input_routing` at all.
    case recovery = 5
    /// Host → client app audio (``AudioChannelMessage``: a config packet + ~10 ms encoded frames).
    /// Rides the shared MEDIA socket (the socket-selection predicate routes every non-cursor tag
    /// there), one datagram per message, always IMMEDIATE (`transport.send`) — never through
    /// `VideoSendLane`/`sendPaced`, so audio never queues behind a fat video frame (the
    /// cursor-channel discipline, minus the dedicated socket). No FEC, no retransmit: a lost frame is
    /// concealed client-side (jitter-ring silence), never waited for.
    case audio = 6
}
