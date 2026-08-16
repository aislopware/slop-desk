import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// Session bring-up control messages for the GUI video path (PATH 2), sent on the
/// **control** datagram type before any video/cursor/geometry/input flows.
///
/// PATH 2 is plain UDP (doc 17 §3.6) — no TCP handshake like PATH 1's `hello`/`helloAck`
/// (doc 20 §8). A tiny control exchange runs over the same UDP path as the media:
///
/// 1. Client → host `hello(protocolVersion, requestedWindowID, viewport)` — announces the
///    client, the window to remote, and viewport size (so the host sizes capture to it).
/// 2. Host → client `helloAck(accepted, streamID, captureWidth, captureHeight, windowBoundsCG)`
///    — confirm/reject + negotiated capture dims + the window's current CG-top-left bounds
///    (the input-mapping origin until the geometry channel updates it).
/// 3. Either side sends `bye` to tear down cleanly.
///
/// `protocolVersion` MUST equal ``SlopDeskVideoProtocol/version`` — the host accepts only
/// the exact version, no fallback (mirrors PATH 1's strict check, doc 20 §4).
///
/// In-session resize (additive after the hello/helloAck/bye trio): when the client surface
/// settles to a new size it sends `resizeRequest(desired, epoch)`; the host clamps to the live
/// window min/max, re-sizes capture/encode, and confirms with `resizeAck(captureWidth,
/// captureHeight, epoch)`. `epoch` is a client-minted monotonic counter so a stale request
/// (epoch ≤ last-applied) is ignored, coalescing a burst to the settled size. `desired` is
/// Float64 w/h (viewport precision); the ack reports UInt16 w/h (as `helloAck`).
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
/// type 13 scrollOffset:  UInt16 dx | UInt16 dy | UInt16 bandTop | UInt16 bandBottom
///                            (dx/dy are i16 stored as a bit-preserving u16; decode casts back)
/// type 14 contentMask:   UInt16 count | per rect: UInt16 x | UInt16 y | UInt16 w | UInt16 h
/// type 15 displayMax:    UInt16 width | UInt16 height
/// type 16 windowFeedSubscribe: UInt32 knownGeneration (0 = have nothing)
/// type 17 windowFeedSnapshot:  UInt32 generation | UInt8 chunkIndex | UInt8 chunkCount
///                            | UInt16 recordCount | per record: UInt32 id | UInt16 w | UInt16 h
///                            | UInt8 flags | UInt8 displayIndex | lp bundleID | lp app | lp title
/// type 18 windowFeedCurrent:   UInt32 generation
/// type 19 appIconRequest:  UInt16 sizePx | lp bundleID
/// type 20 blobChunk:       UInt8 blobKind | UInt64 blobID | UInt16 metaA | UInt16 metaB
///                            | UInt8 chunkIndex | UInt8 chunkCount | UInt16 byteCount | bytes
/// type 21 windowPreviewRequest: UInt32 windowID | UInt16 maxWidthPx
/// type 22 listDisplays:  (no body)
/// type 23 displayList:   UInt16 count | per record: UInt32 displayID | UInt16 w | UInt16 h | UInt8 isMain
/// type 24 helloDisplay:  UInt16 protocolVersion | UInt32 requestedDisplayID
///                            | Float64 viewportW | Float64 viewportH
/// type 25 streamSettings: UInt8 fpsCap | UInt32 bitrateCeilingBps
/// type 26 audioControl:  UInt8 enabled(0/1)
/// type 27 hostStats:     UInt16 rttTenthsMillis | UInt16 encodeTenthsMillis
/// type 28 privacyMode:   UInt8 enabled(0/1)
/// ```
///
/// Liveness keepalive: guards against a client that crashes without sending `bye` — a zero-body
/// `keepalive` sent every few seconds while streaming so the host's idle-timeout
/// reaper distinguishes a live-but-quiet client from a crashed (silent → reapable) one.
/// Wire-safe in BOTH directions: a peer that doesn't recognise type 6 hits the decoder's `default`
/// arm → THROWS `.malformed`, and both consumers (host `handleControl`, client
/// `ReceivedDatagramRouter`) catch-and-DROP it, never crash. Inert to a peer that doesn't speak it;
/// only a NEW host stamps it as liveness.
/// One host-side shareable window in a ``VideoControlMessage/windowList(_:)`` response — the data the
/// client's Remote-Window PICKER renders (replacing manual window-id entry). Same data as
/// `slopdesk-videohostd --list`, delivered over the wire.
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

/// Per-window state bits in a ``HostWindowRecord`` (the type-17 `flags` byte). Encoded as the raw
/// byte; unknown future bits decode inertly (an old client just never reads them).
public struct HostWindowFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The window is on the active Space and not minimized (`kCGWindowIsOnscreen`).
    public static let onScreen = Self(rawValue: 1 << 0)
    /// The window is minimized to the Dock (`AXMinimized`, best-effort).
    public static let minimized = Self(rawValue: 1 << 1)
    /// The owning application is hidden (`NSRunningApplication.isHidden`).
    public static let appHidden = Self(rawValue: 1 << 2)
    /// The owning application is frontmost on the host.
    public static let frontmostApp = Self(rawValue: 1 << 3)
    /// This window is the frontmost app's focused (first, layer-0) window — at most one per snapshot.
    public static let focusedWindow = Self(rawValue: 1 << 4)
}

/// One host window in a ``VideoControlMessage/windowFeedSnapshot(generation:chunkIndex:chunkCount:records:)``
/// — the host-windows RAIL's row data (docs/45). Richer than the picker's ``WindowSummary``: adds
/// `bundleID` (client-local app-icon resolution), the state ``HostWindowFlags``, and a display ordinal.
/// Record order on the wire is host z-order front-to-back (free data for the client's FIRST seed;
/// never a live sort key — rail rows are position-stable after seeding).
public struct HostWindowRecord: Equatable, Sendable {
    /// The host CGWindowID (`hello.requestedWindowID` streams it — same contract as ``WindowSummary``).
    public var windowID: UInt32
    /// Window size in points (clamped to UInt16 on the wire, same as ``WindowSummary``).
    public var widthPt: UInt16
    public var heightPt: UInt16
    /// State bits (see ``HostWindowFlags``).
    public var flags: HostWindowFlags
    /// Ordinal of the display the window is on (0-based; 0 when unknown) — peek/tooltip captions only.
    public var displayIndex: UInt8
    /// The owning app's bundle identifier ("" when the process has none) — the icon cache key.
    public var bundleID: String
    /// The owning application name (e.g. "Ghostty") — the section key + empty-title fallback.
    public var appName: String
    /// The window title (may be empty; host caps it to ``VideoControlMessage/feedTitleMaxBytes``).
    public var title: String

    public init(
        windowID: UInt32,
        widthPt: UInt16,
        heightPt: UInt16,
        flags: HostWindowFlags,
        displayIndex: UInt8,
        bundleID: String,
        appName: String,
        title: String,
    ) {
        self.windowID = windowID
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.flags = flags
        self.displayIndex = displayIndex
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }
}

/// One host-side display in a ``VideoControlMessage/displayList(_:)`` response — the data behind the
/// full-desktop pane's display targeting (the full-desktop pivot, docs/DECISIONS.md 2026-07-14).
/// Mirrors ``WindowSummary`` for whole displays: the client streams one by sending a
/// ``VideoControlMessage/helloDisplay(protocolVersion:requestedDisplayID:viewport:)`` with its id.
public struct DisplaySummary: Equatable, Sendable {
    /// The host `CGDirectDisplayID` to put in a `helloDisplay`'s `requestedDisplayID`.
    public var displayID: UInt32
    /// Display size in points (clamped to UInt16 on the wire, same as ``WindowSummary``).
    public var width: UInt16
    public var height: UInt16
    /// Whether this is the host's MAIN display (`CGMainDisplayID`) — the default target
    /// (`requestedDisplayID == 0` also resolves to it).
    public var isMain: Bool

    public init(displayID: UInt32, width: UInt16, height: UInt16, isMain: Bool) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.isMain = isMain
    }
}

/// DORMANT wire shape (docs/DECISIONS.md 2026-07-23 — the system-dialog-pane feature is removed;
/// codec + golden vectors kept, no live sender/consumer).
/// One host-side SYSTEM dialog/prompt in a ``VideoControlMessage/systemDialogList(_:)`` response —
/// a cross-process modal NOT attached to any app the client streams (prime case: a `SecurityAgent`
/// password/admin prompt; also save/open panels and system alerts). The client POLLS
/// `listSystemDialogs`, diffs the answer, and AUTO-SPAWNS an ephemeral pane streaming each dialog by
/// its `windowID`, closing it when the dialog leaves the list. The "show system popups in their own
/// pane" feature (mirror of ``WindowSummary`` + the picker).
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
    /// client paste-guard's "is this a password field?" reasoning + a "Secure prompt" lock chip.
    /// NOTE: does NOT block keystrokes — the host's `CGEvent(.cghidEventTap)` injection LANDS in
    /// these fields even while `IsSecureEventInputEnabled()` is true, so typing the password from
    /// the client works; secure-input mode is not a barrier to remote typing here.
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

/// One opaque content rectangle in a ``VideoControlMessage/contentMask(_:)`` — capture PIXEL coords
/// (top-left origin, the decoder's texture space). After the host DIALOG-EXPANDs the capture region
/// to cover a pop-up overhanging the streamed window, the rectangular frame has empty area flanking
/// the popup; the host lists the REAL-content rects (window block + each popup) so the client masks
/// the rest transparent.
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
    /// Host → client: accept/reject + negotiated capture size + the window's current CG-top-left
    /// bounds (the input-mapping origin until geometry updates arrive). `fullRange` tells
    /// the client the encoded stream's luma swing so it picks the matching decoder pixel-format +
    /// YCbCr→RGB shader coefficients FROM THE STREAM (no separate client env flag). `false` ⇒
    /// video-range (the default).
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
    /// Client → host: a zero-body liveness heartbeat, sent every few seconds while streaming so the
    /// host's idle-timeout reaper distinguishes a quiet-but-alive client from a crashed one. Inert to
    /// a peer that does not recognise type 6 (it drops it).
    case keepalive
    /// Client → host: "what windows can I stream?" — a session-LESS discovery request (host answers with
    /// ``windowList(_:)`` WITHOUT minting a capture session). Zero body. Powers the remote-window PICKER
    /// (replaces manual window-id entry). An old host drops it (unknown type) → the client times out and
    /// falls back to the manual id field.
    case listWindows
    /// Host → client: the shareable windows, in response to ``listWindows``. The client renders these in
    /// the picker; choosing one sends a normal `hello` with that window's id.
    case windowList([WindowSummary])
    /// Client → host: the remote-window pane was focused (hover / first-responder). Asks the host to
    /// RAISE the captured window to frontmost ONCE, proactively — so the first click lands instantly
    /// instead of paying the per-interaction activate-then-control raise stall. Zero body, idempotent
    /// (the raise short-circuits when already frontmost). Inert to an old host (unknown type → dropped).
    /// Background input injection without raising is avoided: it preserves host focus but pays a
    /// per-interaction activate-then-control stall on every click, which this proactive raise removes.
    case focusWindow
    /// Host → client: the stream's CONTENT cadence changed (FPS governor). Sent at session
    /// start and on every governed fps step (duplicated ×2, ~25 ms apart, for loss tolerance — the
    /// client's application is idempotent). The client rebases its deadline-pacer content interval +
    /// adaptive-jitter seconds→frames conversion on it. Inert to an old peer (unknown type → dropped).
    case streamCadence(fps: UInt16)
    /// DORMANT (docs/DECISIONS.md 2026-07-23): the system-dialog-pane feature is removed; no shipped
    /// peer sends this. Client → host session-LESS poll, zero body; kept for codec/golden stability.
    case listSystemDialogs
    /// DORMANT (docs/DECISIONS.md 2026-07-23): the answer to ``listSystemDialogs``; kept for
    /// codec/golden stability, never sent by the shipped host.
    case systemDialogList([SystemDialogSummary])
    /// Host → client: the per-frame content scroll offset (pixels) the host measured between captured
    /// frames — drives client-side scroll reprojection (warp the last frame on spare 120 Hz ticks so
    /// editor scroll looks local). Signed pixel shifts; `(0, 0)` = no confident scroll this frame.
    /// `bandTop`/`bandBottom` are the MOVING-content vertical band in ten-thousandths of frame height
    /// (`0..=10000`): the client warps ONLY that band so static chrome (toolbars/status bar) doesn't
    /// slide; `bandBottom <= bandTop` ⇒ no band (whole-frame warp, the A/B fallback). Sent only while
    /// reprojection is on; inert to an old peer (unknown type → dropped).
    case scrollOffset(dx: Int16, dy: Int16, bandTop: UInt16, bandBottom: UInt16)
    /// Host → client: the opaque content sub-rectangles within the captured frame (capture PIXEL coords).
    /// After a DIALOG-EXPAND the frame has empty area flanking the popup; this lists the real-content
    /// rects (window block + popups) so the client masks the rest transparent (the popup floats over the
    /// canvas instead of a black bar). An EMPTY list ⇒ the whole frame is opaque (the contracted/default
    /// state). Sent on every capture-region change; inert to an old peer (unknown type → dropped).
    case contentMask([MaskRect])
    /// Host → client: the MAXIMUM POINT size the captured window can be resized to — the bounds of its
    /// display (or the virtual-display bounds while parked). Sent once when capture starts so the client's
    /// "Resize…" popover caps its width/height fields at a reachable size (paired with the host's
    /// resize-to-display-origin). Inert to an old peer (unknown type → dropped); a client that never
    /// receives it leaves its fields uncapped.
    case displayMax(width: UInt16, height: UInt16)
    /// Client → host: "keep the host-window feed flowing; I hold `knownGeneration`" — the ONE
    /// session-less feed message (docs/45). Sent every ~2 s while the host-windows rail (or Open
    /// Quickly) is visible: it is the Phase-1 poll, the Phase-2 subscription renewal, AND the
    /// loss-healing resync anchor in one. `knownGeneration == 0` ⇒ the client has nothing. The host
    /// answers ``windowFeedSnapshot(generation:chunkIndex:chunkCount:records:)`` chunks on a
    /// generation mismatch, or the 5-byte ``windowFeedCurrent(generation:)`` ack when the client is
    /// already current. Inert to an old host (unknown type → dropped) — the rail shows its
    /// empty/disconnected state.
    case windowFeedSubscribe(knownGeneration: UInt32)
    /// Host → client: one chunk of the full host-window snapshot for `generation` (docs/45). Full
    /// snapshots, never deltas — idempotent and latest-wins on a lossy control lane. The HOST packs
    /// chunks byte-budgeted to one control datagram (``feedRecordBytesPerChunk``) and dup-sends ×2;
    /// the client assembles per generation (all chunks must agree on `chunkCount`), applies the
    /// latest fully-assembled generation, and heals any loss at the next
    /// ``windowFeedSubscribe(knownGeneration:)`` renewal. Inert to an old peer.
    case windowFeedSnapshot(generation: UInt32, chunkIndex: UInt8, chunkCount: UInt8, records: [HostWindowRecord])
    /// Host → client: "your `knownGeneration` is current — no snapshot coming" (docs/45). The 5-byte
    /// ack that lets the client distinguish a quiet host from a lost snapshot; steady state on an
    /// unchanged desktop is one subscribe + one of these per renewal. Inert to an old peer.
    case windowFeedCurrent(generation: UInt32)
    /// Client → host: "send me `bundleID`'s app icon at `sizePx`" — session-LESS like the feed
    /// subscribe (docs/45 Phase 3; the rail's LOCAL Launch-Services resolve covers most apps, so
    /// this fires only for host-only apps, once ever per bundleID thanks to the client disk cache).
    /// The host answers with ``blobChunk`` kind 0 (PNG, single-flight per blobID, LRU-cached).
    case appIconRequest(sizePx: UInt16, bundleID: String)
    /// Host → client: one chunk of a binary blob — the ONE shared blob reply for app icons (kind 0,
    /// PNG, `blobID` = FNV-1a64(bundleID), `metaA` = pxEdge) and window previews (kind 1, JPEG,
    /// `blobID` = windowID, `metaA`/`metaB` = pxW/pxH — Phase 4). Chunks fit one datagram
    /// (``blobBytesPerChunk``); the client's `BlobAssembler` reassembles per (kind, blobID) and
    /// validates image magic before use. Inert to an old peer.
    case blobChunk(
        blobKind: UInt8, blobID: UInt64, metaA: UInt16, metaB: UInt16,
        chunkIndex: UInt8, chunkCount: UInt8, bytes: Data,
    )
    /// Client → host: "capture `windowID` as a one-shot preview ≤ `maxWidthPx` wide" — the rail's
    /// PEEK (docs/45 Phase 4; Space / context menu, the ONLY window-content imagery anywhere, at a
    /// LEGIBLE size per the icon-over-thumbnail ruling). Session-less like `appIconRequest`. The
    /// host answers with ``blobChunk`` kind 1 (JPEG, paced 1 datagram/ms, single-flight per window,
    /// ≤1 s-old captures reused, ≤2 captures/s globally — SCScreenshotManager shares WindowServer
    /// with the live encoders, so previews are throttled, never eager).
    case windowPreviewRequest(windowID: UInt32, maxWidthPx: UInt16)
    /// Client → host: "what displays can I stream?" — a session-LESS discovery request mirroring
    /// ``listWindows`` (the host answers ``displayList(_:)`` WITHOUT minting a session). Zero body.
    /// Powers the full-desktop pane's multi-display rows; an old host drops it (unknown type) → the
    /// client falls back to the main display (`requestedDisplayID == 0`).
    case listDisplays
    /// Host → client: the online displays, in response to ``listDisplays``. The client streams one by
    /// sending a ``helloDisplay(protocolVersion:requestedDisplayID:viewport:)`` with its id.
    case displayList([DisplaySummary])
    /// Client → host: open a FULL-DESKTOP session streaming display `requestedDisplayID`
    /// (`0` = the host's main display), sized to `viewport`. The display sibling of ``hello`` — the
    /// host answers with the SAME ``helloAck`` shape, where `windowBoundsCG` carries the DISPLAY's
    /// CG bounds and `captureWidth/Height` its point size (the client decode/aspect-fit/input math
    /// is target-agnostic). A desktop session never resizes the host display: `resizeRequest` acks
    /// at the fixed display size and the client letterboxes.
    case helloDisplay(protocolVersion: UInt16, requestedDisplayID: UInt32, viewport: VideoSize)
    /// Client → host: LIVE per-session stream controls — a user-requested encode fps CAP and bitrate
    /// CEILING. `fpsCap == 0` / `bitrateCeilingBps == 0` mean AUTO (clear that override); non-zero
    /// values are clamped on the HOST at apply time (fps 5…120, bitrate 500 kbps…200 Mbps —
    /// validate-then-drop stays at the length level, out-of-range semantics clamp rather than drop).
    /// A later message REPLACES the earlier one wholesale. Per-session HOST state: it dies with a
    /// session re-mint, so the client re-sends its last-requested values after every accepted
    /// (re-)hello. Inert to an old host (unknown type → dropped).
    case streamSettings(fpsCap: UInt8, bitrateCeilingBps: UInt32)
    /// Client → host: the LIVE per-session audio wish — `enabled` turns the host's app-audio
    /// capture→encode→send lane (media channel tag 6) on or off. The ``streamSettings(fpsCap:bitrateCeilingBps:)``
    /// twin: applied only while STREAMING (the host SM drops it otherwise), per-session HOST
    /// state that dies with a session re-mint — a fresh session starts with audio OFF — so the
    /// client stores its last wish and re-sends it after every accepted (re-)hello. A later
    /// message REPLACES the earlier one. Inert to an old host (unknown type → dropped).
    case audioControl(enabled: Bool)
    /// Host → client: the HOST-side halves of the stats HUD, ~2 Hz while streaming — the smoothed
    /// RTT the host derives from the client's `networkStats` reports (the client cannot measure RTT
    /// itself: its telemetry fields are all relative, §9.8) and the host's encode-wall-time EWMA.
    /// Both in TENTHS of a millisecond (UInt16 saturating ⇒ caps at ~6.5 s); `0` = no reading yet
    /// (telemetry off / first window still filling). Fire-and-forget single send — the next tick
    /// heals a loss. Inert to an old client (unknown type → dropped).
    case hostStats(rttTenthsMillis: UInt16, encodeTenthsMillis: UInt16)
    /// Client → host: PRIVACY BLANK for a full-desktop session — `enabled` blacks the streamed
    /// host display (a zero `CGDisplayGammaTable`, driver-free) AND swallows local keyboard/mouse
    /// at the host (a `CGEventTap`), so a bystander at the physical Mac sees a dark screen and
    /// cannot interfere while the remote operator works. The RustDesk technique; primary-display
    /// caveat (gamma blackout is per-display but local-input tap is global). The `streamSettings`
    /// twin: applied only while a DISPLAY session streams, per-session HOST state that resets OFF
    /// on session mint, so the client re-sends its wish after every accepted (re-)hello. A later
    /// message replaces the earlier one. Inert to an old host (unknown type → dropped).
    case privacyMode(enabled: Bool)

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
        case .displayMax: 15
        case .windowFeedSubscribe: 16
        case .windowFeedSnapshot: 17
        case .windowFeedCurrent: 18
        case .appIconRequest: 19
        case .blobChunk: 20
        case .windowPreviewRequest: 21
        case .listDisplays: 22
        case .displayList: 23
        case .helloDisplay: 24
        case .streamSettings: 25
        case .audioControl: 26
        case .hostStats: 27
        case .privacyMode: 28
        }
    }

    /// One `blobChunk`'s max data bytes: `VideoPacketizer.maxDatagramSize` (1200) − 5 mux framing −
    /// 18 message header (type + kind + u64 id + 2×u16 meta + index + count + u16 byteCount). The
    /// HOST's blob chunker packs against this. Vended by the codec that writes the header.
    public static let blobBytesPerChunk = slopdesk_video_control_constant(0)
    /// Blob size caps by kind (validate-then-drop: an assembled blob past its cap is hostile).
    public static let iconBlobMaxBytes = slopdesk_video_control_constant(1)
    public static let previewBlobMaxBytes = slopdesk_video_control_constant(2)

    /// The host-side byte cap for ONE `windowFeedSnapshot` chunk's RECORDS (excluding the 9-byte
    /// message header): control datagrams are not packetized, so a chunk must fit one mux datagram —
    /// `VideoPacketizer.maxDatagramSize` (1200) − 5 mux framing (u32 channelID + u8 tag) − 9 message
    /// header (type + generation + chunkIndex + chunkCount + recordCount). The HOST's chunk packer
    /// greedy-packs against this; the codec itself does not enforce it (decode is bounds-checked
    /// per-field regardless).
    public static let feedRecordBytesPerChunk = slopdesk_video_control_constant(3)
    /// The host-side UTF-8 byte cap for a ``HostWindowRecord/title`` (truncated at a character
    /// boundary host-side) — bounds the worst-case record so the greedy packer always progresses.
    public static let feedTitleMaxBytes = slopdesk_video_control_constant(4)

    /// Encodes the message to its `[UInt8 type][body]` wire form. `rust/slopdesk-video`'s
    /// `video_control` lays every byte down — including the length-prefixed strings and the record
    /// order — and the format is pinned bit-for-bit by the `videoControl` golden vectors, which the
    /// Android client reads too.
    ///
    /// Text does not ride inside the flat message: it is appended to one ARENA and each field names
    /// its `(offset, length)` there. Five arms carry a list, so there is no single span to point at
    /// the way the smaller wires do, and the arena is the shape that scales to a list.
    ///
    /// For list messages the CALLER (host) must still cap the list to one UDP datagram — control is
    /// not packetized — and the count truncates to `UInt16` on the wire.
    public func encode() -> Data {
        var arena = Data()
        var records: [SlopDeskControlRecord] = []
        var flat = SlopDeskVideoControl()
        flat.message_type = messageType
        switch self {
        case let .hello(version, windowID, viewport):
            flat.protocol_version = version
            flat.requested_id = windowID
            flat.viewport_width = viewport.width
            flat.viewport_height = viewport.height
        case let .helloDisplay(version, displayID, viewport):
            flat.protocol_version = version
            flat.requested_id = displayID
            flat.viewport_width = viewport.width
            flat.viewport_height = viewport.height
        case let .helloAck(accepted, streamID, w, h, bounds, fullRange):
            flat.accepted = accepted
            flat.stream_id = streamID
            flat.capture_width = w
            flat.capture_height = h
            flat.bounds_x = bounds.origin.x
            flat.bounds_y = bounds.origin.y
            flat.bounds_width = bounds.size.width
            flat.bounds_height = bounds.size.height
            flat.full_range = fullRange
        case let .resizeRequest(desired, epoch):
            flat.viewport_width = desired.width
            flat.viewport_height = desired.height
            flat.epoch = epoch
        case let .resizeAck(w, h, epoch):
            flat.capture_width = w
            flat.capture_height = h
            flat.epoch = epoch
        case let .windowList(windows):
            records = windows.map { window in
                var row = SlopDeskControlRecord()
                row.id = window.windowID
                (row.name_offset, row.name_length) = Self.intern(window.appName, into: &arena)
                (row.title_offset, row.title_length) = Self.intern(window.title, into: &arena)
                row.width = window.width
                row.height = window.height
                return row
            }
        case let .systemDialogList(dialogs):
            records = dialogs.map { dialog in
                var row = SlopDeskControlRecord()
                row.id = dialog.windowID
                (row.name_offset, row.name_length) = Self.intern(dialog.owner, into: &arena)
                (row.title_offset, row.title_length) = Self.intern(dialog.title, into: &arena)
                row.width = dialog.width
                row.height = dialog.height
                row.is_secure = dialog.isSecure
                return row
            }
        case let .displayList(displays):
            records = displays.map { display in
                var row = SlopDeskControlRecord()
                row.id = display.displayID
                row.width = display.width
                row.height = display.height
                row.is_main = display.isMain
                return row
            }
        case let .contentMask(rects):
            records = rects.map { rect in
                var row = SlopDeskControlRecord()
                row.x = rect.x
                row.y = rect.y
                row.width = rect.width
                row.height = rect.height
                return row
            }
        case let .windowFeedSnapshot(generation, chunkIndex, chunkCount, feed):
            flat.generation = generation
            flat.chunk_index = chunkIndex
            flat.chunk_count = chunkCount
            records = feed.map { record in
                var row = SlopDeskControlRecord()
                row.id = record.windowID
                (row.bundle_offset, row.bundle_length) = Self.intern(record.bundleID, into: &arena)
                (row.name_offset, row.name_length) = Self.intern(record.appName, into: &arena)
                (row.title_offset, row.title_length) = Self.intern(record.title, into: &arena)
                row.width = record.widthPt
                row.height = record.heightPt
                row.flags = record.flags.rawValue
                row.display_index = record.displayIndex
                return row
            }
        case let .streamCadence(fps):
            flat.fps = fps
        case let .scrollOffset(dx, dy, bandTop, bandBottom):
            flat.scroll_dx = dx
            flat.scroll_dy = dy
            flat.band_top = bandTop
            flat.band_bottom = bandBottom
        case let .displayMax(width, height):
            flat.display_max_width = width
            flat.display_max_height = height
        case let .windowFeedSubscribe(knownGeneration):
            flat.generation = knownGeneration
        case let .windowFeedCurrent(generation):
            flat.generation = generation
        case let .appIconRequest(sizePx, bundleID):
            flat.size_px = sizePx
            (flat.span_offset, flat.span_length) = Self.intern(bundleID, into: &arena)
        case let .blobChunk(kind, blobID, metaA, metaB, chunkIndex, chunkCount, bytes):
            flat.blob_kind = kind
            flat.blob_id = blobID
            flat.meta_a = metaA
            flat.meta_b = metaB
            flat.chunk_index = chunkIndex
            flat.chunk_count = chunkCount
            let span = ArenaText.intern(bytes: bytes, into: &arena)
            flat.span_offset = span.offset
            flat.span_length = span.length
        case let .windowPreviewRequest(windowID, maxWidthPx):
            flat.requested_id = windowID
            flat.max_width_px = maxWidthPx
        case let .streamSettings(fpsCap, bitrateCeilingBps):
            flat.fps_cap = fpsCap
            flat.bitrate_ceiling_bps = bitrateCeilingBps
        case let .audioControl(enabled),
             let .privacyMode(enabled):
            flat.enabled = enabled
        case let .hostStats(rtt, encode):
            flat.rtt_tenths_millis = rtt
            flat.encode_tenths_millis = encode
        // The bodyless arms: the type byte IS the message.
        case .bye,
             .focusWindow,
             .keepalive,
             .listDisplays,
             .listSystemDialogs,
             .listWindows:
            break
        }
        flat.record_count = UInt32(records.count)
        flat.arena_length = UInt32(arena.count)
        return Self.write(flat, records, arena)
    }

    /// Parses a control datagram. Every guard is the Rust codec's: a short body (or a list count
    /// that outruns the datagram) is `.truncated`; an unknown type byte, a non-finite coordinate and
    /// a chunk that does not name a real slot in a real sequence are `.malformed`. A corrupt
    /// datagram is DROPPED by both consumers, never fatal.
    ///
    /// A title that is not valid UTF-8 decodes LOSSILY, over there — a mangled title costs that
    /// title and never the list it arrived in.
    public static func decode(_ data: Data) throws -> Self {
        // Sized from the datagram, so the answer fits on the first ask: a record is at least eight
        // wire bytes, and lossy repair can only grow a string threefold (one bad byte → U+FFFD).
        let recordRoom = data.count / 8 + 1
        let arenaRoom = data.count * 3 + 1
        var flat = SlopDeskVideoControl()
        let parsed: Self? = try data.withUnsafeBytes { bytes -> Self? in
            try withUnsafeTemporaryAllocation(of: SlopDeskControlRecord.self, capacity: recordRoom) { rows -> Self? in
                try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: arenaRoom) { arena -> Self? in
                    let verdict = slopdesk_video_control_decode(
                        bytes.baseAddress, bytes.count, &flat,
                        rows.baseAddress, rows.count, arena.baseAddress, arena.count,
                    )
                    try check(verdict)
                    guard verdict != UInt32(SLOPDESK_CONTROL_DECODE_AGAIN) else { return nil }
                    return build(flat, UnsafeBufferPointer(rows), UnsafeRawBufferPointer(arena))
                }
            }
        }
        if let parsed { return parsed }
        // The bound above is a proof rather than a guess, so this is the shape that has not happened
        // yet — kept because the boundary's contract allows it, and a wrong guess must not truncate.
        var rows = [SlopDeskControlRecord](repeating: SlopDeskControlRecord(), count: Int(flat.record_count))
        var arena = [UInt8](repeating: 0, count: Int(flat.arena_length))
        let again = data.withUnsafeBytes { bytes in
            rows.withUnsafeMutableBufferPointer { rowBuffer in
                arena.withUnsafeMutableBufferPointer { arenaBuffer in
                    slopdesk_video_control_decode(
                        bytes.baseAddress, bytes.count, &flat,
                        rowBuffer.baseAddress, rowBuffer.count,
                        arenaBuffer.baseAddress, arenaBuffer.count,
                    )
                }
            }
        }
        try check(again)
        return rows.withUnsafeBufferPointer { rowBuffer in
            arena.withUnsafeBufferPointer { arenaBuffer in
                build(flat, rowBuffer, UnsafeRawBufferPointer(arenaBuffer))
            }
        }
    }

    /// Turns a decode verdict into this side's error vocabulary. `again` is not a failure — the
    /// caller re-asks with room — so it passes through.
    private static func check(_ verdict: UInt32) throws {
        switch verdict {
        case UInt32(SLOPDESK_CONTROL_DECODE_TRUNCATED): throw VideoProtocolError.truncated
        case UInt32(SLOPDESK_CONTROL_DECODE_MALFORMED):
            throw VideoProtocolError.malformed("unacceptable video-control message")
        default: break
        }
    }

    /// Appends a string's UTF-8 to the arena and answers where it went —
    /// ``ArenaText/intern(_:into:)``, which is the same write every other door makes.
    private static func intern(_ text: String, into arena: inout Data) -> (UInt32, UInt32) {
        let span = ArenaText.intern(text, into: &arena)
        return (span.offset, span.length)
    }

    /// The §4 two-call encode, written into scratch so the ONE heap allocation this makes is the
    /// answer, at its exact length.
    ///
    /// The bound is sized from what the message actually holds — the arena is the only part that
    /// grows — so the sizing call is also the writing call for every message and short for none of
    /// them. A `keepalive` is one byte, and paying a 48-byte `Data` for it and then shrinking it was
    /// the whole cost of the heartbeat.
    private static func write(
        _ flat: SlopDeskVideoControl, _ records: [SlopDeskControlRecord], _ arena: Data,
    ) -> Data {
        let bound = Self.scalarBytes + arena.count + records.count * Self.recordBytes
        return arena.withUnsafeBytes { pool in
            records.withUnsafeBufferPointer { rows in
                withUnsafeTemporaryAllocation(byteCount: bound, alignment: 1) { scratch -> Data in
                    let needed = slopdesk_video_control_encode(
                        flat, rows.baseAddress, rows.count, pool.baseAddress, pool.count,
                        scratch.baseAddress, scratch.count,
                    )
                    precondition(needed > 0, "the control codec refused a message this type can express")
                    guard needed > bound else {
                        return Data(UnsafeRawBufferPointer(rebasing: scratch[..<needed]))
                    }
                    var grown = Data(count: needed)
                    let written = grown.withUnsafeMutableBytes { buffer in
                        slopdesk_video_control_encode(
                            flat, rows.baseAddress, rows.count, pool.baseAddress, pool.count,
                            buffer.baseAddress, buffer.count,
                        )
                    }
                    precondition(written == needed, "the control codec sized a message differently than it wrote it")
                    return grown
                }
            }
        }
    }

    /// Room for the widest scalar body (a `helloAck`: type, flags and four `Float64`s) plus the
    /// list count. Too small would only ever cost a second encode, never a wrong answer.
    private static let scalarBytes = 48
    /// Room for one record's fixed part — its ids, its two dimensions, its flags and the length
    /// prefix each of its three strings carries. The string BYTES are already counted in the arena.
    private static let recordBytes = 16

    /// Puts the flat answer back together as this enum.
    private static func build(
        _ flat: SlopDeskVideoControl,
        _ records: UnsafeBufferPointer<SlopDeskControlRecord>,
        _ arena: UnsafeRawBufferPointer,
    ) -> Self {
        let viewport = VideoSize(width: flat.viewport_width, height: flat.viewport_height)
        let rows = records.prefix(Int(flat.record_count))
        switch flat.message_type {
        case 1: return .hello(
                protocolVersion: flat.protocol_version,
                requestedWindowID: flat.requested_id,
                viewport: viewport,
            )
        case 2:
            return .helloAck(
                accepted: flat.accepted, streamID: flat.stream_id,
                captureWidth: flat.capture_width, captureHeight: flat.capture_height,
                windowBoundsCG: VideoRect(
                    x: flat.bounds_x, y: flat.bounds_y,
                    width: flat.bounds_width, height: flat.bounds_height,
                ),
                fullRange: flat.full_range,
            )
        case 3: return .bye
        case 4: return .resizeRequest(desired: viewport, epoch: flat.epoch)
        case 5: return .resizeAck(
                captureWidth: flat.capture_width,
                captureHeight: flat.capture_height,
                epoch: flat.epoch,
            )
        case 6: return .keepalive
        case 7: return .listWindows
        case 8:
            return .windowList(rows.map { row in
                WindowSummary(
                    windowID: row.id,
                    appName: text(arena, row.name_offset, row.name_length),
                    title: text(arena, row.title_offset, row.title_length),
                    width: row.width, height: row.height,
                )
            })
        case 9: return .focusWindow
        case 10: return .streamCadence(fps: flat.fps)
        case 11: return .listSystemDialogs
        case 12:
            return .systemDialogList(rows.map { row in
                SystemDialogSummary(
                    windowID: row.id,
                    owner: text(arena, row.name_offset, row.name_length),
                    title: text(arena, row.title_offset, row.title_length),
                    width: row.width, height: row.height, isSecure: row.is_secure,
                )
            })
        case 13:
            return .scrollOffset(
                dx: flat.scroll_dx,
                dy: flat.scroll_dy,
                bandTop: flat.band_top,
                bandBottom: flat.band_bottom,
            )
        case 14:
            return .contentMask(rows.map { MaskRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
        case 15: return .displayMax(width: flat.display_max_width, height: flat.display_max_height)
        case 16: return .windowFeedSubscribe(knownGeneration: flat.generation)
        case 17:
            return .windowFeedSnapshot(
                generation: flat.generation, chunkIndex: flat.chunk_index, chunkCount: flat.chunk_count,
                records: rows.map { row in
                    HostWindowRecord(
                        windowID: row.id, widthPt: row.width, heightPt: row.height,
                        flags: HostWindowFlags(rawValue: row.flags), displayIndex: row.display_index,
                        bundleID: text(arena, row.bundle_offset, row.bundle_length),
                        appName: text(arena, row.name_offset, row.name_length),
                        title: text(arena, row.title_offset, row.title_length),
                    )
                },
            )
        case 18: return .windowFeedCurrent(generation: flat.generation)
        case 19: return .appIconRequest(sizePx: flat.size_px, bundleID: text(arena, flat.span_offset, flat.span_length))
        case 20:
            return .blobChunk(
                blobKind: flat.blob_kind, blobID: flat.blob_id, metaA: flat.meta_a, metaB: flat.meta_b,
                chunkIndex: flat.chunk_index, chunkCount: flat.chunk_count,
                // The same arena span, taken as bytes rather than as text — and through the same
                // bounds check, which this read did not have either.
                bytes: Data(ArenaText.span(arena, Int(flat.span_offset), Int(flat.span_length))),
            )
        case 21: return .windowPreviewRequest(windowID: flat.requested_id, maxWidthPx: flat.max_width_px)
        case 22: return .listDisplays
        case 23:
            return .displayList(rows.map {
                DisplaySummary(displayID: $0.id, width: $0.width, height: $0.height, isMain: $0.is_main)
            })
        case 24:
            return .helloDisplay(
                protocolVersion: flat.protocol_version,
                requestedDisplayID: flat.requested_id,
                viewport: viewport,
            )
        case 25: return .streamSettings(fpsCap: flat.fps_cap, bitrateCeilingBps: flat.bitrate_ceiling_bps)
        case 26: return .audioControl(enabled: flat.enabled)
        case 27: return .hostStats(
                rttTenthsMillis: flat.rtt_tenths_millis,
                encodeTenthsMillis: flat.encode_tenths_millis,
            )
        default: return .privacyMode(enabled: flat.enabled)
        }
    }

    /// The arena span a `(offset, length)` names, as text. The bytes were written there by the Rust
    /// decode, which already did the lossy repair, so this reads them and nothing else.
    ///
    /// This face was the one of nine that bounds-checked only the LENGTH, so it now gains the far-end
    /// check the other eight already had.
    private static func text(_ arena: UnsafeRawBufferPointer, _ offset: UInt32, _ length: UInt32) -> String {
        ArenaText.text(arena, offset, length)
    }
}
