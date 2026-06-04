import Foundation

/// The single shared definition of the `RWORK_VIDEO_MUX` env-gate for the GUI video
/// path (PATH 2 / UDP-mux Stage S3) — the UDP-side counterpart of the TCP-mux
/// `RWORK_TCP_MUX` (`ConnectionRegistry.muxEnabledFromEnvironment`).
///
/// ## Why a shared parse
/// The 15→19-byte fragment header (and the 4-byte channelID prefix on the control /
/// cursor / input lanes, see ``VideoMuxHeaderCodec``) is **NOT backward-compatible**:
/// a host parsing 19 bytes against a client that wrote 15 (or vice versa) misframes
/// every datagram. Both ends MUST therefore agree on the gate, and the only way to
/// guarantee that is one parse function both the client (`VideoConnectionRegistry`)
/// and the host (`NWVideoDatagramTransport`) call — the wire/behaviour contract is the
/// agreement, exactly like the TCP side.
///
/// ## OFF is byte-identical
/// An UNSET (or non-truthy) `RWORK_VIDEO_MUX` returns `false`, so the client builds a
/// per-pane ``VideoMuxHeaderCodec``-free transport (15-byte header) and the host pins
/// a single client slot — provably the path that shipped (the proven device-real iOS
/// video cell). The gate is read ONCE at construction sites, never on the hot
/// per-datagram path, so the OFF path never even branches on it.
public enum VideoMuxGate {
    /// The `RWORK_VIDEO_MUX` gate value from `env` (ON iff `"1"`/`"true"`/`"yes"`/`"on"`,
    /// case-insensitive). Default OFF — an unset var leaves the OFF path byte-identical
    /// to today. Same truthiness vocabulary as `ConnectionRegistry.muxEnabledFromEnvironment`.
    public static func enabledFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = env["RWORK_VIDEO_MUX"]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }
}
