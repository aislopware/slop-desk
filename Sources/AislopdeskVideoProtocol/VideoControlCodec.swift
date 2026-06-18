import Foundation

/// Session bring-up control messages for the GUI video path (PATH 2). These travel
/// on the **control** datagram type of the video session and establish a session
/// before any video/cursor/geometry/input datagram flows.
///
/// The PATH 2 session is plain UDP (doc 17 §3.6) — there is no TCP handshake like
/// PATH 1's `hello`/`helloAck` (doc 20 §8). Instead a tiny control exchange runs
/// over the same UDP path the media uses:
///
/// 1. Client → host `hello(protocolVersion, requestedWindowID, viewport)` —
///    announces the client, the window it wants to remote, and the client viewport
///    size (so the host can size capture/encode to the client surface).
/// 2. Host → client `helloAck(accepted, streamID, captureWidth, captureHeight,
///    windowBoundsCG)` — confirms (or rejects) and reports the negotiated capture
///    dimensions + the window's current CG-top-left bounds (the client maps input
///    against these until the geometry channel updates them).
/// 3. Either side may send `bye` to tear the session down cleanly.
///
/// `protocolVersion` MUST equal ``AislopdeskVideoProtocol/version`` — the host accepts
/// only the exact version (no fallback, mirroring PATH 1's strict version check,
/// doc 20 §4).
///
/// In-session resize (the host-window-resize feature, additive after the original
/// hello/helloAck/bye trio): when the client surface settles to a new size, the client
/// sends `resizeRequest(desired, epoch)` on the control channel; the host clamps it to
/// the live window min/max and re-sizes capture/encode, then confirms the size it
/// actually adopted with `resizeAck(captureWidth, captureHeight, epoch)`. `epoch` is a
/// client-minted monotonic counter so a stale request (one whose epoch ≤ the
/// last-applied) is ignored — coalescing a burst to the settled size. `desired` is
/// Float64 w/h (the viewport precision); the ack reports UInt16 w/h (the same capture-
/// size wire `helloAck` uses).
///
/// Wire layout (big-endian), `[UInt8 type][body]`:
/// ```
/// type 1 hello:         UInt16 protocolVersion | UInt32 requestedWindowID
///                       | Float64 viewportW | Float64 viewportH
/// type 2 helloAck:      UInt8 accepted(0/1) | UInt32 streamID
///                       | UInt16 captureWidth | UInt16 captureHeight
///                       | UInt8 fullRange(0/1)
///                       | Float64 boundsX | boundsY | boundsW | boundsH
/// type 3 bye:           (no body)
/// type 4 resizeRequest: Float64 desiredW | Float64 desiredH | UInt32 epoch
/// type 5 resizeAck:     UInt16 captureWidth | UInt16 captureHeight | UInt32 epoch
/// type 6 keepalive:     (no body)
/// type 7 listWindows:   (no body)
/// type 8 windowList:    UInt16 count | per record: UInt32 id | UInt16 w | UInt16 h | lp app | lp title
/// type 9 focusWindow:   (no body)
/// type 10 streamCadence: UInt16 fps
/// type 11 listSystemDialogs: (no body)
/// type 12 systemDialogList:  UInt16 count | per record: UInt32 id | UInt16 w | UInt16 h
///                            | UInt8 isSecure | lp owner | lp title
/// ```
///
/// Liveness keepalive (additive after the resize pair — CONCURRENCY-HOST-1 crash-without-bye):
/// the client sends a zero-body `keepalive` on the control channel
/// every few seconds while streaming so the host's idle-timeout reaper can tell a live-but-quiet
/// client (still alive, just not interacting) from a crashed one (truly silent → reapable). It is
/// wire-safe in BOTH directions: a peer that does not recognise type 6 hits the decoder's `default`
/// arm, which THROWS `.malformed` — both consumers catch-and-DROP it (the host's `handleControl`,
/// the client's `ReceivedDatagramRouter`), never crash. A keepalive is meant to be inert to a peer
/// that doesn't speak it; only a NEW host stamps it as liveness.
/// One host-side shareable window in a ``VideoControlMessage/windowList(_:)`` response — the data the
/// client's Remote-Window PICKER renders (replacing manual window-id entry). Mirrors what
/// `aislopdesk-videohostd --list` prints, but delivered over the wire.
public struct WindowSummary: Equatable, Sendable {
    /// The host CGWindowID to put in a `hello`'s `requestedWindowID` to stream this window.
    public var windowID: UInt32
    /// The owning application name (e.g. "Google Chrome").
    public var appName: String
    /// The window title (may be empty).
    public var title: String
    /// Window size in points (for display in the picker; clamped to UInt16 on the wire).
    public var width: UInt16
    public var height: UInt16

    public init(windowID: UInt32, appName: String, title: String, width: UInt16, height: UInt16) {
        self.windowID = windowID
        self.appName = appName
        self.title = title
        self.width = width
        self.height = height
    }
}

/// One host-side SYSTEM dialog/prompt in a ``VideoControlMessage/systemDialogList(_:)`` response —
/// a cross-process modal window NOT attached to any app the client is already streaming (the prime
/// case: a `SecurityAgent` password / admin prompt, but also save/open panels and system alerts).
/// The client POLLS `listSystemDialogs`, diffs the answer, and AUTO-SPAWNS an ephemeral pane that
/// streams each dialog by its `windowID` — closing it again when the dialog leaves the list. This is
/// the "show system popups in their own pane" feature (mirror of ``WindowSummary`` + the picker).
public struct SystemDialogSummary: Equatable, Sendable {
    /// Host CGWindowID — the client puts this in a `hello`'s `requestedWindowID` to stream the dialog.
    public var windowID: UInt32
    /// The owning process name (e.g. "SecurityAgent", "Open and Save Panel Service").
    public var owner: String
    /// The dialog title (often empty / "Untitled" for SecurityAgent — owner is the useful label).
    public var title: String
    public var width: UInt16
    public var height: UInt16
    /// `true` ⇒ a `SecurityAgent`/`coreauthd` secure-credential (password/auth) prompt. Drives the
    /// client paste-guard's "is this a password field?" reasoning + a small "Secure prompt" lock chip.
    /// NOTE: it does NOT mean keystrokes are blocked — HW-proven (2026-06-15, Tahoe 26.5.1) the host's
    /// `CGEvent(.cghidEventTap)` injection LANDS in these fields even while `IsSecureEventInputEnabled()`
    /// is true, so typing the password from the client works (the old "view-only" claim was wrong).
    public var isSecure: Bool

    public init(windowID: UInt32, owner: String, title: String, width: UInt16, height: UInt16, isSecure: Bool) {
        self.windowID = windowID
        self.owner = owner
        self.title = title
        self.width = width
        self.height = height
        self.isSecure = isSecure
    }
}

/// One opaque content rectangle in a ``VideoControlMessage/contentMask(_:)`` — capture PIXEL
/// coords (top-left origin), the texture space the client's decoder produces. After the host
/// DIALOG-EXPANDs the capture region to cover a pop-up overhanging the streamed window, the
/// rectangular frame has empty area flanking the popup; the host lists the rects that are REAL
/// content (the window block + each popup) so the client masks the rest transparent.
public struct MaskRect: Equatable, Sendable {
    public var x: UInt16
    public var y: UInt16
    public var width: UInt16
    public var height: UInt16

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum VideoControlMessage: Equatable, Sendable {
    /// Client → host: open a session for `requestedWindowID`, sized to `viewport`.
    case hello(protocolVersion: UInt16, requestedWindowID: UInt32, viewport: VideoSize)
    /// Host → client: accept/reject + negotiated capture size + the window's current
    /// CG-top-left bounds (the input-mapping origin until geometry updates arrive).
    /// `fullRange` (WF-6 #8) tells the client the encoded stream's luma swing so it picks
    /// the matching decoder pixel-format + YCbCr→RGB shader coefficients FROM THE STREAM
    /// (no separate client env flag). `false` ⇒ today's video-range (the default).
    case helloAck(
        accepted: Bool,
        streamID: UInt32,
        captureWidth: UInt16,
        captureHeight: UInt16,
        windowBoundsCG: VideoRect,
        fullRange: Bool,
    )
    /// Either side: clean session teardown.
    case bye
    /// Client → host: the client surface settled to `desired` (points); please re-size
    /// capture to it. `epoch` is a monotonic counter so the host can drop a stale request.
    case resizeRequest(desired: VideoSize, epoch: UInt32)
    /// Host → client: capture was re-sized to `captureWidth`×`captureHeight` for the
    /// request carrying `epoch` (the client re-bases its aspect-fit denominator on it).
    case resizeAck(captureWidth: UInt16, captureHeight: UInt16, epoch: UInt32)
    /// Client → host: a zero-body liveness heartbeat. Sent every few
    /// seconds while streaming so the host's idle-timeout reaper distinguishes a quiet-but-alive
    /// client from a crashed one. Inert to a peer that does not recognise type 6 (it drops it).
    case keepalive
    /// Client → host: "what windows can I stream?" — a session-LESS discovery request (the host answers
    /// with ``windowList(_:)`` WITHOUT minting a capture session). Zero body. Carries the remote-window
    /// PICKER (replaces manual window-id entry). An old host drops it (unknown type) → the client times
    /// out + falls back to the manual id field.
    case listWindows
    /// Host → client: the shareable windows, in response to ``listWindows``. The client renders these in
    /// the picker; choosing one sends a normal `hello` with that window's id.
    case windowList([WindowSummary])
    /// Client → host: the remote-window pane was focused on the client (hover / first-responder). Asks the
    /// host to RAISE the captured window to frontmost ONCE, proactively — so the user's first click lands
    /// instantly instead of paying the per-interaction activate-then-control raise stall. Zero body,
    /// idempotent on the host (the raise short-circuits when the window is already frontmost). Inert to an
    /// old host (unknown type → dropped). This is the "raise the focused pane's window" model that
    /// replaced the abandoned no-raise background-injection approach.
    case focusWindow
    /// Host → client: the stream's CONTENT cadence changed (FPS governor, 2026-06-11). Sent once at
    /// session start and on every governed fps step (duplicated ×2, ~25 ms apart, for loss
    /// tolerance — the client's application is idempotent). The client rebases its deadline-pacer
    /// content interval + adaptive-jitter seconds→frames conversion on it. Inert to an old peer
    /// (unknown type → dropped).
    case streamCadence(fps: UInt16)
    /// Client → host: "what SYSTEM dialogs/prompts are open right now?" — a session-LESS poll (the host
    /// answers with ``systemDialogList(_:)`` WITHOUT minting a session), mirroring ``listWindows``. The
    /// client polls this on a slow cadence and diffs the result to auto-spawn/close ephemeral dialog
    /// panes. Zero body. An old host drops it (unknown type) → the feature is simply inert.
    case listSystemDialogs
    /// Host → client: the currently-open system dialogs, in response to ``listSystemDialogs``. The client
    /// streams each by sending a normal `hello` for its `windowID`.
    case systemDialogList([SystemDialogSummary])
    /// Host → client: the per-frame content scroll offset (pixels) the host measured between captured
    /// frames — drives client-side scroll reprojection (warp the last frame by this on spare 120 Hz
    /// display ticks so editor scroll looks local). Signed pixel shifts; `(0, 0)` = no confident scroll
    /// this frame. Sent only while reprojection is on; inert to an old peer (unknown type → dropped).
    case scrollOffset(dx: Int16, dy: Int16)
    /// Host → client: the opaque content sub-rectangles within the captured frame (capture PIXEL
    /// coords). After a DIALOG-EXPAND the rectangular frame has empty area flanking the popup; this
    /// lists the rects that are real content (window block + popups) so the client masks the rest
    /// transparent (the popup floats over the canvas instead of a black bar). An EMPTY list ⇒ the
    /// whole frame is opaque (the contracted / default state). Sent on every capture-region change;
    /// inert to an old peer (unknown type → dropped).
    case contentMask([MaskRect])

    public var messageType: UInt8 {
        switch self {
        case .hello: 1
        case .helloAck: 2
        case .bye: 3
        case .resizeRequest: 4
        case .resizeAck: 5
        case .keepalive: 6
        case .listWindows: 7
        case .windowList: 8
        case .focusWindow: 9
        case .streamCadence: 10
        case .listSystemDialogs: 11
        case .systemDialogList: 12
        case .scrollOffset: 13
        case .contentMask: 14
        }
    }

    /// Encodes the message to its `[UInt8 type][body]` wire form through the Rust `aislopdesk-core`
    /// codec (``RustVideoFFI/encode(_:)-(VideoControlMessage)``) — the single source of truth shared
    /// with the Android client. The `windowList`/`systemDialogList` records cross as a borrowed array
    /// Rust copies; the CALLER (host) must still cap a list to fit one UDP datagram (control is not
    /// packetized). The wire layout above is what the core emits.
    public func encode() -> Data {
        RustVideoFFI.encode(self)
    }

    /// Decodes a message from its `[UInt8 type][body]` payload through the Rust core
    /// (``RustVideoFFI/decodeVideoControl(_:)``), throwing ``VideoProtocolError/truncated`` for a
    /// short body and ``VideoProtocolError/malformed(_:)`` for a non-finite coordinate or unknown
    /// type. The list decoders are hardened against an untrusted record count (a short datagram
    /// throws `.truncated` rather than over-reading); record strings decode lossily.
    public static func decode(_ data: Data) throws -> Self {
        try RustVideoFFI.decodeVideoControl(data)
    }
}
