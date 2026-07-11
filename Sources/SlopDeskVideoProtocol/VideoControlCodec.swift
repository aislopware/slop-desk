import Foundation

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
/// ```
///
/// Liveness keepalive (additive after the resize pair — CONCURRENCY-HOST-1 crash-without-bye):
/// a zero-body `keepalive` sent every few seconds while streaming so the host's idle-timeout
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
    /// NOTE: does NOT block keystrokes — HW-proven (2026-06-15, Tahoe 26.5.1) the host's
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
    /// bounds (the input-mapping origin until geometry updates arrive). `fullRange` (WF-6 #8) tells
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
    /// The "raise the focused pane's window" model that replaced the abandoned no-raise
    /// background-injection approach.
    case focusWindow
    /// Host → client: the stream's CONTENT cadence changed (FPS governor, 2026-06-11). Sent at session
    /// start and on every governed fps step (duplicated ×2, ~25 ms apart, for loss tolerance — the
    /// client's application is idempotent). The client rebases its deadline-pacer content interval +
    /// adaptive-jitter seconds→frames conversion on it. Inert to an old peer (unknown type → dropped).
    case streamCadence(fps: UInt16)
    /// Client → host: "what SYSTEM dialogs/prompts are open now?" — a session-LESS poll (host answers
    /// with ``systemDialogList(_:)`` WITHOUT minting a session), mirroring ``listWindows``. The client
    /// polls on a slow cadence and diffs the result to auto-spawn/close ephemeral dialog panes. Zero
    /// body. An old host drops it (unknown type) → the feature is inert.
    case listSystemDialogs
    /// Host → client: the currently-open system dialogs, in response to ``listSystemDialogs``. The client
    /// streams each by sending a normal `hello` for its `windowID`.
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
        }
    }

    /// One `blobChunk`'s max data bytes: `VideoPacketizer.maxDatagramSize` (1200) − 5 mux framing −
    /// 18 message header (type + kind + u64 id + 2×u16 meta + index + count + u16 byteCount). The
    /// HOST's blob chunker packs against this.
    public static let blobBytesPerChunk = 1177
    /// Blob size caps by kind (validate-then-drop: an assembled blob past its cap is hostile).
    public static let iconBlobMaxBytes = 32 * 1024
    public static let previewBlobMaxBytes = 48 * 1024

    /// The host-side byte cap for ONE `windowFeedSnapshot` chunk's RECORDS (excluding the 9-byte
    /// message header): control datagrams are not packetized, so a chunk must fit one mux datagram —
    /// `VideoPacketizer.maxDatagramSize` (1200) − 5 mux framing (u32 channelID + u8 tag) − 9 message
    /// header (type + generation + chunkIndex + chunkCount + recordCount). The HOST's chunk packer
    /// greedy-packs against this; the codec itself does not enforce it (decode is bounds-checked
    /// per-field regardless).
    public static let feedRecordBytesPerChunk = 1186
    /// The host-side UTF-8 byte cap for a ``HostWindowRecord/title`` (truncated at a character
    /// boundary host-side) — bounds the worst-case record so the greedy packer always progresses.
    public static let feedTitleMaxBytes = 120

    /// Encodes the message to its `[UInt8 type][body]` wire form. Single source of truth shared with the
    /// Android client (pinned bit-for-bit by the `videoControl` golden vectors). For list messages the
    /// CALLER (host) must cap the list to one UDP datagram (control is not packetized); the count
    /// truncates to `UInt16`.
    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case let .hello(version, windowID, viewport):
            out.appendBE(version)
            out.appendBE(windowID)
            out.appendBE(viewport.width)
            out.appendBE(viewport.height)
        case let .helloAck(accepted, streamID, w, h, bounds, fullRange):
            out.append(accepted ? 1 : 0)
            out.appendBE(streamID)
            out.appendBE(w)
            out.appendBE(h)
            out.append(fullRange ? 1 : 0) // WF-6 (#8): negotiated luma range (after captureHeight)
            out.appendBE(bounds.origin.x)
            out.appendBE(bounds.origin.y)
            out.appendBE(bounds.size.width)
            out.appendBE(bounds.size.height)
        case .bye:
            break
        case let .resizeRequest(desired, epoch):
            out.appendBE(desired.width)
            out.appendBE(desired.height)
            out.appendBE(epoch)
        case let .resizeAck(w, h, epoch):
            out.appendBE(w)
            out.appendBE(h)
            out.appendBE(epoch)
        case .keepalive:
            break
        case .listWindows:
            break
        case let .windowList(windows):
            // `UInt16 count` then per record: UInt32 id | UInt16 w | UInt16 h | len-prefixed app | len-prefixed title.
            // The CALLER (host) must cap the list to fit one UDP datagram (control is not packetized).
            out.appendBE(UInt16(truncatingIfNeeded: windows.count))
            for w in windows {
                out.appendBE(w.windowID)
                out.appendBE(w.width)
                out.appendBE(w.height)
                out.appendVideoControlLengthPrefixed(w.appName)
                out.appendVideoControlLengthPrefixed(w.title)
            }
        case .focusWindow:
            break
        case let .streamCadence(fps):
            out.appendBE(fps)
        case .listSystemDialogs:
            break
        case let .systemDialogList(dialogs):
            // Mirrors windowList; CALLER caps the list to fit one UDP datagram (control is not packetized).
            out.appendBE(UInt16(truncatingIfNeeded: dialogs.count))
            for d in dialogs {
                out.appendBE(d.windowID)
                out.appendBE(d.width)
                out.appendBE(d.height)
                out.append(d.isSecure ? 1 : 0)
                out.appendVideoControlLengthPrefixed(d.owner)
                out.appendVideoControlLengthPrefixed(d.title)
            }
        case let .scrollOffset(dx, dy, bandTop, bandBottom):
            // i16 → u16 is a bit-preserving reinterpret; the decoder casts back. Matches the Rust
            // core's `dx.cast_unsigned()` / `band_*` raw-u16 layout.
            out.appendBE(UInt16(bitPattern: dx))
            out.appendBE(UInt16(bitPattern: dy))
            out.appendBE(bandTop)
            out.appendBE(bandBottom)
        case let .contentMask(rects):
            // `UInt16 count` then per rect: UInt16 x | UInt16 y | UInt16 w | UInt16 h.
            // The CALLER (host) must cap the list to fit one UDP datagram (control is not packetized).
            out.appendBE(UInt16(truncatingIfNeeded: rects.count))
            for r in rects {
                out.appendBE(r.x)
                out.appendBE(r.y)
                out.appendBE(r.width)
                out.appendBE(r.height)
            }
        case let .displayMax(width, height):
            out.appendBE(width)
            out.appendBE(height)
        case let .windowFeedSubscribe(knownGeneration):
            out.appendBE(knownGeneration)
        case let .windowFeedSnapshot(generation, chunkIndex, chunkCount, records):
            // The CALLER (host) must byte-budget records to one datagram (`feedRecordBytesPerChunk`);
            // the count truncates to UInt16 like the other list messages.
            out.appendBE(generation)
            out.append(chunkIndex)
            out.append(chunkCount)
            out.appendBE(UInt16(truncatingIfNeeded: records.count))
            for r in records {
                out.appendBE(r.windowID)
                out.appendBE(r.widthPt)
                out.appendBE(r.heightPt)
                out.append(r.flags.rawValue)
                out.append(r.displayIndex)
                out.appendVideoControlLengthPrefixed(r.bundleID)
                out.appendVideoControlLengthPrefixed(r.appName)
                out.appendVideoControlLengthPrefixed(r.title)
            }
        case let .windowFeedCurrent(generation):
            out.appendBE(generation)
        case let .appIconRequest(sizePx, bundleID):
            out.appendBE(sizePx)
            out.appendVideoControlLengthPrefixed(bundleID)
        case let .blobChunk(blobKind, blobID, metaA, metaB, chunkIndex, chunkCount, bytes):
            // The CALLER (host) must cap `bytes` to one datagram (`blobBytesPerChunk`).
            out.append(blobKind)
            out.appendBE(blobID)
            out.appendBE(metaA)
            out.appendBE(metaB)
            out.append(chunkIndex)
            out.append(chunkCount)
            out.appendBE(UInt16(truncatingIfNeeded: bytes.count))
            out.append(bytes)
        }
        return out
    }

    /// Decodes a message from its `[UInt8 type][body]` payload, throwing ``VideoProtocolError/truncated``
    /// for a short body and ``VideoProtocolError/malformed(_:)`` for a non-finite coordinate or unknown
    /// type. The list decoders are hardened against an untrusted record count (a short datagram throws
    /// `.truncated` rather than over-reading or pre-allocating); record strings decode lossily.
    public static func decode(_ data: Data) throws -> Self {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            let version = try reader.readUInt16()
            let windowID = try reader.readUInt32()
            let w = try reader.readFiniteFloat64("hello.viewport.w")
            let h = try reader.readFiniteFloat64("hello.viewport.h")
            return .hello(
                protocolVersion: version,
                requestedWindowID: windowID,
                viewport: VideoSize(width: w, height: h),
            )
        case 2:
            let accepted = try reader.readUInt8() != 0
            let streamID = try reader.readUInt32()
            let cw = try reader.readUInt16()
            let ch = try reader.readUInt16()
            let fr = try reader.readUInt8() != 0 // WF-6 (#8): negotiated luma range (after captureHeight)
            let bx = try reader.readFiniteFloat64("helloAck.bounds.x")
            let by = try reader.readFiniteFloat64("helloAck.bounds.y")
            let bw = try reader.readFiniteFloat64("helloAck.bounds.w")
            let bh = try reader.readFiniteFloat64("helloAck.bounds.h")
            return .helloAck(
                accepted: accepted,
                streamID: streamID,
                captureWidth: cw,
                captureHeight: ch,
                windowBoundsCG: VideoRect(x: bx, y: by, width: bw, height: bh),
                fullRange: fr,
            )
        case 3:
            return .bye
        case 4:
            let w = try reader.readFiniteFloat64("resizeRequest.w")
            let h = try reader.readFiniteFloat64("resizeRequest.h")
            let epoch = try reader.readUInt32()
            return .resizeRequest(desired: VideoSize(width: w, height: h), epoch: epoch)
        case 5:
            let w = try reader.readUInt16()
            let h = try reader.readUInt16()
            let epoch = try reader.readUInt32()
            return .resizeAck(captureWidth: w, captureHeight: h, epoch: epoch)
        case 6:
            return .keepalive
        case 7:
            return .listWindows
        case 8:
            let count = try Int(reader.readUInt16())
            var windows: [WindowSummary] = []
            // Do NOT reserveCapacity(count) — count is untrusted. Each record read throws `.truncated` the
            // instant the datagram runs short, so a bogus huge count can't over-allocate or over-read.
            for _ in 0..<count {
                let id = try reader.readUInt32()
                let w = try reader.readUInt16()
                let h = try reader.readUInt16()
                let app = try reader.readVideoControlLengthPrefixed()
                let title = try reader.readVideoControlLengthPrefixed()
                windows.append(WindowSummary(windowID: id, appName: app, title: title, width: w, height: h))
            }
            return .windowList(windows)
        case 9:
            return .focusWindow
        case 10:
            return try .streamCadence(fps: reader.readUInt16())
        case 11:
            return .listSystemDialogs
        case 12:
            let count = try Int(reader.readUInt16())
            var dialogs: [SystemDialogSummary] = []
            // Same untrusted-count discipline as windowList: no reserveCapacity; each record read throws
            // `.truncated` the instant the datagram runs short, so a bogus huge count can't over-read.
            for _ in 0..<count {
                let id = try reader.readUInt32()
                let w = try reader.readUInt16()
                let h = try reader.readUInt16()
                let isSecure = try reader.readUInt8() != 0
                let owner = try reader.readVideoControlLengthPrefixed()
                let title = try reader.readVideoControlLengthPrefixed()
                dialogs.append(SystemDialogSummary(
                    windowID: id,
                    owner: owner,
                    title: title,
                    width: w,
                    height: h,
                    isSecure: isSecure,
                ))
            }
            return .systemDialogList(dialogs)
        case 13:
            // u16 → i16 is a bit-preserving reinterpret (counterpart to the encoder's `UInt16(bitPattern:)`).
            let dx = try Int16(bitPattern: reader.readUInt16())
            let dy = try Int16(bitPattern: reader.readUInt16())
            let bandTop = try reader.readUInt16()
            let bandBottom = try reader.readUInt16()
            return .scrollOffset(dx: dx, dy: dy, bandTop: bandTop, bandBottom: bandBottom)
        case 14:
            let count = try Int(reader.readUInt16())
            var rects: [MaskRect] = []
            // Same untrusted-count discipline as windowList/systemDialogList: no reserveCapacity; each rect
            // read throws `.truncated` the instant the datagram runs short, so a bogus huge count (e.g. 65535
            // with no body) bails on the first missing byte rather than OOM-ing.
            for _ in 0..<count {
                let x = try reader.readUInt16()
                let y = try reader.readUInt16()
                let w = try reader.readUInt16()
                let h = try reader.readUInt16()
                rects.append(MaskRect(x: x, y: y, width: w, height: h))
            }
            return .contentMask(rects)
        case 15:
            let w = try reader.readUInt16()
            let h = try reader.readUInt16()
            return .displayMax(width: w, height: h)
        case 16:
            return try .windowFeedSubscribe(knownGeneration: reader.readUInt32())
        case 17:
            let generation = try reader.readUInt32()
            let chunkIndex = try reader.readUInt8()
            let chunkCount = try reader.readUInt8()
            // Validate-then-drop: a chunk must identify a real slot in a real chunk sequence. A zero
            // chunkCount or out-of-range index can only be corruption/hostile — drop the datagram
            // rather than hand the assembler an unsatisfiable generation.
            guard chunkCount >= 1, chunkIndex < chunkCount else {
                throw VideoProtocolError.malformed(
                    "windowFeedSnapshot chunk \(chunkIndex)/\(chunkCount) is not a valid slot",
                )
            }
            let count = try Int(reader.readUInt16())
            var records: [HostWindowRecord] = []
            // Same untrusted-count discipline as windowList: no reserveCapacity; each record read
            // throws `.truncated` the instant the datagram runs short, so a bogus huge count can't
            // over-allocate or over-read.
            for _ in 0..<count {
                let id = try reader.readUInt32()
                let w = try reader.readUInt16()
                let h = try reader.readUInt16()
                let flags = try HostWindowFlags(rawValue: reader.readUInt8())
                let display = try reader.readUInt8()
                let bundleID = try reader.readVideoControlLengthPrefixed()
                let app = try reader.readVideoControlLengthPrefixed()
                let title = try reader.readVideoControlLengthPrefixed()
                records.append(HostWindowRecord(
                    windowID: id,
                    widthPt: w,
                    heightPt: h,
                    flags: flags,
                    displayIndex: display,
                    bundleID: bundleID,
                    appName: app,
                    title: title,
                ))
            }
            return .windowFeedSnapshot(
                generation: generation, chunkIndex: chunkIndex, chunkCount: chunkCount, records: records,
            )
        case 18:
            return try .windowFeedCurrent(generation: reader.readUInt32())
        case 19:
            let sizePx = try reader.readUInt16()
            let bundleID = try reader.readVideoControlLengthPrefixed()
            return .appIconRequest(sizePx: sizePx, bundleID: bundleID)
        case 20:
            let blobKind = try reader.readUInt8()
            let blobID = try reader.readUInt64()
            let metaA = try reader.readUInt16()
            let metaB = try reader.readUInt16()
            let chunkIndex = try reader.readUInt8()
            let chunkCount = try reader.readUInt8()
            // Validate-then-drop: a chunk must identify a real slot (mirrors windowFeedSnapshot).
            guard chunkCount >= 1, chunkIndex < chunkCount else {
                throw VideoProtocolError.malformed(
                    "blobChunk chunk \(chunkIndex)/\(chunkCount) is not a valid slot",
                )
            }
            let byteCount = try Int(reader.readUInt16())
            // `readBytes` bounds-checks against the buffer BEFORE reading, so a corrupt byteCount
            // drops the datagram rather than over-reading.
            let bytes = try reader.readBytes(byteCount)
            return .blobChunk(
                blobKind: blobKind, blobID: blobID, metaA: metaA, metaB: metaB,
                chunkIndex: chunkIndex, chunkCount: chunkCount, bytes: bytes,
            )
        default:
            throw VideoProtocolError.malformed("unknown video control message type \(type)")
        }
    }
}

// MARK: - Length-prefixed UTF-8 string helpers

// The UInt16-length-prefixed UTF-8 record-string contract used by `windowList` / `systemDialogList`,
// kept byte/bit-parity with the Rust core (`put_length_prefixed_str` / `read_length_prefixed_str`
// → `String::from_utf8_lossy`).

private extension Data {
    /// Appends a `UInt16`-length-prefixed UTF-8 string. UTF-8 exceeding `UInt16.max` bytes is truncated
    /// at a byte boundary (titles are never that long; guards a pathological input) — matching the core's
    /// wire contract.
    mutating func appendVideoControlLengthPrefixed(_ string: String) {
        var bytes = Array(string.utf8)
        if bytes.count > Int(UInt16.max) { bytes = Array(bytes.prefix(Int(UInt16.max))) }
        appendBE(UInt16(bytes.count))
        append(contentsOf: bytes)
    }
}

private extension VideoByteReader {
    /// Reads a `UInt16`-length-prefixed UTF-8 string (counterpart to
    /// ``Data/appendVideoControlLengthPrefixed(_:)``). `readBytes` throws
    /// ``VideoProtocolError/truncated`` if the datagram is too short for the declared length (VALIDATED
    /// against the buffer BEFORE the read), so a corrupt/oversized prefix DROPS the datagram rather than
    /// over-reading or crashing. Invalid UTF-8 decodes lossily — a remote title must never crash the
    /// receiver, and it matches the Rust core's `String::from_utf8_lossy` for byte/bit parity.
    mutating func readVideoControlLengthPrefixed() throws -> String {
        let len = try Int(readUInt16())
        let bytes = try readBytes(len)
        // The failable `String(bytes:encoding:)` the lint rule prefers returns nil on invalid UTF-8,
        // diverging from the core's lossy parity, so the lossy initializer is kept on purpose.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }
}
