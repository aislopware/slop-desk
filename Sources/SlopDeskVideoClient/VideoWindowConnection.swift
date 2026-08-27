// VideoWindowConnection — what a remote-GUI pane connects TO (PATH 2 / Phase 4, doc 17 §3).
//
// THE ONE PIECE OF `VideoWindowView.swift`'S COMMON HEAD THAT STAYED SHARED (docs/56 §3, the video
// carve). Everything else in that header was arrangement — a closure list, an ObservableObject, a
// chip's geometry — and was duplicated into the two halves deliberately. This was not: it is the
// pipeline's INPUT CONTRACT, `streamTarget` below is a rule (a display target wins over a window
// one), and a rule in two places is the defect `CLAUDE.md` names. Both halves build one of these and
// hand it to the same `VideoWindowPipeline.activate`.
//
// ONE IMPORT, DELIBERATELY. This target holds no views since the carve and `just lint` asserts it —
// the header this came from imported SwiftUI, CoreImage and QuartzCore for the view types that left.

import SlopDeskVideoProtocol

/// Connection parameters for a remote GUI window (PATH 2 / Phase 4, doc 17 §3): host
/// endpoint + the window to remote. Built by the GUI app and handed to whichever half mounts the pane.
public struct VideoWindowConnection: Sendable, Equatable {
    /// The host's NetBird-routable address (or hostname).
    public var host: String
    /// The host media UDP port (control/video/geometry/input).
    public var mediaPort: UInt16
    /// The host dedicated cursor UDP port.
    public var cursorPort: UInt16
    /// The host CGWindowID to remote (`0` for a display target).
    public var windowID: UInt32
    /// FULL-DESKTOP TARGET: non-nil ⇒ stream a whole host display (`0` = the main display) via
    /// the wire `helloDisplay` instead of a window `hello`. `nil` ⇒ window.
    public var displayID: UInt32?

    public init(host: String, mediaPort: UInt16, cursorPort: UInt16, windowID: UInt32, displayID: UInt32? = nil) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        self.windowID = windowID
        self.displayID = displayID
    }

    /// The stream target this connection names (display wins when set).
    public var streamTarget: VideoStreamTarget {
        displayID.map { .display($0) } ?? .window(windowID)
    }
}
