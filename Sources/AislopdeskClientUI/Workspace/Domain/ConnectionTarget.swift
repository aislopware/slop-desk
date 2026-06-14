import Foundation

// MARK: - ConnectionTarget (the ONE app-global host the whole app connects to)

/// The single host the whole app connects to (docs/31 app-global connection): the TCP-mux terminal
/// port AND the two UDP video ports all live on ONE host. Replaces the old per-pane ``Endpoint`` /
/// ``VideoEndpoint`` host/port fields — every terminal/Claude pane now opens a *channel* on the one
/// shared mux at `host:port`, and every `.remoteGUI` pane opens a *lane* on the one shared UDP flow at
/// `host:mediaPort`/`cursorPort` (the transport already pools both per-host — see `ConnectionRegistry`
/// / `VideoConnectionRegistry`). Only the per-pane `windowID` (which remote window to mirror) stays on
/// the pane (``VideoEndpoint``).
///
/// Value-typed + `Codable` so it persists once at the ``Workspace`` level and is the *intent* the
/// ``AppConnection`` model dials from the connect-gate. The tree never holds the live connection.
public struct ConnectionTarget: Codable, Sendable, Equatable {
    /// The host all terminals + video panes connect to.
    public var host: String
    /// TCP-mux control/data port (terminals + Claude Code).
    public var port: UInt16
    /// UDP port carrying the encoded video frames (`.remoteGUI` panes).
    public var mediaPort: UInt16
    /// UDP port carrying the cursor side-channel (`.remoteGUI` panes).
    public var cursorPort: UInt16

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 7420,
        mediaPort: UInt16 = 9000,
        cursorPort: UInt16 = 9001,
    ) {
        self.host = host
        self.port = port
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
    }

    /// The default target: the local host on the conventional ports. Used as the connect-gate's prefill
    /// when nothing has been persisted yet.
    public static let `default` = Self()
}
