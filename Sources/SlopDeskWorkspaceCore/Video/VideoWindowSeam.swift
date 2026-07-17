#if canImport(SwiftUI)
import SwiftUI

/// The **seam** between the cross-platform SwiftUI client and a remote GUI-window
/// video view (PATH 2 / Phase 4, doc 17 §3).
///
/// Like ``TerminalRendererFactory``, the cross-platform library cannot reference
/// `SlopDeskVideoClient.VideoWindowView` directly — that pulls VideoToolbox + Metal into
/// the headless `swift build`, and those HANG without a window-server + TCC session in a
/// test context. Instead the GUI app target (linking `SlopDeskVideoClient` with the
/// Screen-Recording / decode entitlements) registers a factory at launch; the library
/// calls it, falling back to a labelled placeholder when none was registered (no host
/// capturing a GUI window).
///
/// **Gated**: the GUI video path is secondary to the terminal path. A remote GUI window
/// appears only when (a) the app injects a factory AND (b) the host is actively capturing
/// a window; until then the placeholder explains the state.
///
/// Wiring (app target, once at launch):
/// ```swift
/// import SlopDeskVideoClient
/// VideoWindowFactory.shared = { descriptor, context in
///     AnyView(VideoWindowView(title: descriptor.title, context: context))
/// }
/// ```
public struct RemoteWindowDescriptor: Sendable, Equatable {
    /// The remote window's last-known title (from the geometry channel).
    public var title: String
    /// The remote window's APP display name (the picker's `appName`, "Xcode" style). Empty for
    /// a desktop target or a legacy binding with no recorded app. CLIENT-seam only (not wire) —
    /// carried so the video view can gate app-sensitive key translations (smart-zoom ⌘0).
    public var appName: String
    /// A stable identifier for the remote window (host CGWindowID). `0` for a display target.
    public var windowID: UInt32
    /// FULL-DESKTOP TARGET: non-nil ⇒ stream a whole host display (`0` = the main display)
    /// instead of a window — the desktop pane (docs/DECISIONS.md 2026-07-14). `nil` ⇒ window.
    public var displayID: UInt32?
    /// The host's NetBird-routable address (or hostname). Empty ⇒ no live endpoint
    /// (the factory then builds the chrome-only / placeholder view).
    public var host: String
    /// The host media UDP port (control/video/geometry/input). `0` ⇒ no endpoint.
    public var mediaPort: UInt16
    /// The host dedicated cursor UDP port. `0` ⇒ no endpoint.
    public var cursorPort: UInt16

    public init(
        title: String,
        appName: String = "",
        windowID: UInt32,
        displayID: UInt32? = nil,
        host: String = "",
        mediaPort: UInt16 = 0,
        cursorPort: UInt16 = 0,
    ) {
        self.title = title
        self.appName = appName
        self.windowID = windowID
        self.displayID = displayID
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
    }

    /// True when the descriptor carries a complete live endpoint (host + two DISTINCT ports).
    /// `VideoWindowFactory` uses this to pick the LIVE `VideoWindowView` vs. the chrome-only
    /// placeholder. Media + cursor must be distinct ports (PATH 2 opens two separate UDP
    /// connections).
    public var hasEndpoint: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && mediaPort != 0 && cursorPort != 0 && mediaPort != cursorPort
    }
}

/// Per-render context the canvas passes through the seam to the gated video view, so the remote-GUI pane
/// behaves like one canvas item: only the ACTIVE pane consumes pointer/scroll, a click ACTIVATES it (and
/// raises the host window), and a scroll over a NON-active pane pans the canvas instead of being swallowed
/// by the background window.
public struct RemotePaneContext {
    /// Whether this pane is the workspace's active/focused pane. The video view forwards pointer/scroll
    /// to the remote window ONLY when active; a non-active pane routes scroll to ``onCanvasScroll``.
    public var isActive: Bool
    /// READ-ONLY INPUT GATE. `false` ⇒ a read-only `.remoteGUI` pane: the app-target video client
    /// forwards NEITHER pointer/scroll NOR keycodes to the host while `!inputEnabled` — it gates every forward
    /// on `isActive && inputEnabled` (a click may still ACTIVATE the workspace pane, but nothing is relayed to
    /// the remote window, the host window is not raised, and the paste-as-keystrokes sink is cleared).
    /// Wire-compatible silence: enforced purely by NOT forwarding input — no VideoControl change, no golden
    /// touch. Defaults `true` (a normal, writable pane).
    public var inputEnabled: Bool
    /// Make this pane the workspace's active pane — called on click (mouseDown). For a GUI pane the host
    /// window is ALSO raised by the pane's own `focusWindow`; this sets the *workspace* focus.
    public var onActivate: () -> Void
    /// Pan the canvas by a (sign-adjusted) delta — called when a NON-active pane receives a scroll, so the
    /// gesture navigates the canvas rather than scrolling the background remote window.
    public var onCanvasScroll: (CGSize) -> Void
    /// 1:1 PANE SNAP: resize this pane so its VIDEO CONTENT goes from `current` to `target` points — fired
    /// when the stream's native 1:1 point size becomes known (first decoded frame) or changes (host resize),
    /// so the stream renders pixel-for-pixel with no fractional-scaling blur. `nil` (standalone default) ⇒
    /// no pane to snap; the session keeps its legacy connect-time host-follow negotiation instead.
    public var onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the live video view publishes a key-injection closure here once its session
    /// exists (`nil` on teardown), so "Paste as Keystrokes" drives the SAME per-key `CGEvent` path the
    /// keyboard uses (`InputInjector.postKey`). Closure is `(keyCode, down, shift)`. `nil` (standalone
    /// default) ⇒ no canvas to receive the sink.
    public var onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)?
    /// RESIZE (numeric popover): the live video view publishes a resize-drive closure here once its session
    /// exists (`nil` on teardown), so "Resize…" requests an ABSOLUTE host-window POINT size. Closure is
    /// `(width, height)` in host points. `nil` (standalone default) ⇒ no canvas. Withheld (bound `nil`)
    /// while read-only (see ``videoLeaf(isActive:readOnly:...)``).
    public var onResizeInjectorReady: ((((_ width: Double, _ height: Double) -> Void)?) -> Void)?
    /// VIEWPORT CONTROLS: the live video view publishes a client-viewport command sink here once its session
    /// exists (`nil` on teardown), so the bottom control bar drives zoom / pan-lock. Closure carries a raw
    /// command byte (``RemoteWindowModel/ViewportCommand``: 0 zoom-in / 1 zoom-out / 2 reset / 3 toggle-lock).
    /// Pure CLIENT compositor ops (no host input), so — unlike ``onResizeInjectorReady`` — NOT withheld while
    /// read-only. `nil` (standalone default) ⇒ no canvas to receive it.
    public var onViewportInjectorReady: ((((_ command: UInt8) -> Void)?) -> Void)?
    /// RELEASE STUCK INPUT (manual escape hatch): the live video view publishes a zero-arg release closure
    /// here (`nil` on teardown) that synthesizes a key-UP for every held modifier + a mouse-UP for every
    /// button through the synthetic-release send paths — the palette's "Release Stuck Input" drives it when
    /// the host is left with a latched modifier / button despite the automatic redundancy+dedup. SENDS host
    /// input, so — like ``onKeyInjectorReady`` — withheld (bound `nil`) while read-only. `nil` (standalone
    /// default) ⇒ no canvas.
    public var onInputReleaseReady: (((() -> Void)?) -> Void)?
    /// HOST-WINDOW RESIZE: the live video view PUSHES the remote window's current + MAX resizable POINT sizes
    /// whenever either changes (first decoded frame / host displayMax report), so "Resize…" pre-fills at the
    /// current size and caps at the remote max. `(curW, curH, maxW, maxH)`; a zero max = "not yet known"
    /// (field left uncapped). Informational view→model push (never reaches the host), so NOT read-only-gated.
    /// `nil` ⇒ none.
    public var onWindowGeometryChanged: ((_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double) -> Void)?
    /// CONNECTION STATS: the live video view PUSHES the host-announced stream cadence (frames/sec) whenever
    /// the host's FPS governor announces a new value, feeding the sidebar's per-pane "FPS" row. Informational
    /// view→model push (never reaches the host), so NOT read-only-gated. `nil` ⇒ none.
    public var onStreamCadenceChanged: ((_ fps: Int) -> Void)?
    /// CONNECTION STATS: the live video view PUSHES the client-measured video PAYLOAD bitrate
    /// (kilobits/sec, ~1 Hz) — the titlebar cluster's stream-weight complication. Informational view→model
    /// push (never reaches the host), so NOT read-only-gated. `nil` ⇒ none.
    public var onStreamBitrateChanged: ((_ kbps: Int) -> Void)?
    /// NETWORK-STATS MIRROR: the live video view PUSHES the ~2 Hz client-local telemetry aggregate —
    /// received frames/sec, FEC recoveries/sec, unrecovered losses/sec, latest host-stamp hold (ms),
    /// pacer depth. Primitives only (this seam is headless). Informational view→model push (never
    /// reaches the host), so NOT read-only-gated. `nil` ⇒ none.
    public var onNetworkStats: ((
        _ fps: Double, _ fecPerSec: Double, _ unrecoveredPerSec: Double, _ holdMs: Int, _ pacerDepth: Int,
    ) -> Void)?
    /// STREAM SETTINGS (fps cap / bitrate ceiling): the live video view publishes a settings-drive closure
    /// here once its session exists (`nil` on teardown), so the pane can request a live encode fps cap /
    /// bitrate ceiling (`(fpsCap, bitrateCeilingBps)`, 0 = auto — host clamps on apply). Changes HOST
    /// encode behaviour, so — like ``onResizeInjectorReady`` — WITHHELD (bound `nil`) while read-only.
    /// `nil` (standalone default) ⇒ no canvas.
    public var onStreamSettingsInjectorReady: ((((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?) -> Void)?
    /// SYSTEM-KEY INJECTOR (immersive-capture plumbing): the live video view publishes a programmatic
    /// key-event closure here (`nil` on teardown) driving the SAME wire path the pane's local
    /// keyDown/keyUp uses. `(keyCode, modifierFlags [raw platform flags], isDown)`. SENDS host input, so —
    /// like ``onKeyInjectorReady`` — WITHHELD (bound `nil`) while read-only. `nil` (standalone default) ⇒
    /// no canvas.
    public var onSystemKeyInjectorReady: ((((
        _ keyCode: UInt16, _ modifierFlags: UInt64, _ isDown: Bool,
    ) -> Void)?) -> Void)?
    /// STALL SCRIM: the live video view PUSHES the stream's stall state when it FLIPS — `true` ⇒
    /// host silent past the stall threshold (pane overlays "Reconnecting…"), `false` ⇒ traffic resumed.
    /// Informational view→model push (never reaches the host), so NOT read-only-gated. `nil` ⇒ none.
    public var onStreamStallChanged: ((_ stalled: Bool) -> Void)?
    /// TERMINAL REFUSAL: the live video view PUSHES this once after the host REJECTED the session
    /// (`helloAck(accepted: false)` — the window is gone on the host / version mismatch, incl. the mux
    /// mint-failure refusal). The pipeline has already torn down WITHOUT the bye path's auto-rebuild
    /// (re-helloing the same doomed request forever); the pane model should leave its live surface and
    /// fall back to the picker with an error (``RemoteWindowModel/noteSessionRejected()``).
    /// Informational view→model push (never reaches the host), so NOT read-only-gated. `nil` ⇒ none.
    public var onSessionRejected: (() -> Void)?

    public init(
        isActive: Bool = true,
        inputEnabled: Bool = true,
        onActivate: @escaping () -> Void = {},
        onCanvasScroll: @escaping (CGSize) -> Void = { _ in },
        onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)? = nil,
        onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)? = nil,
        onResizeInjectorReady: ((((_ width: Double, _ height: Double) -> Void)?) -> Void)? = nil,
        onViewportInjectorReady: ((((_ command: UInt8) -> Void)?) -> Void)? = nil,
        onInputReleaseReady: (((() -> Void)?) -> Void)? = nil,
        onWindowGeometryChanged: ((_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double) -> Void)? = nil,
        onStreamCadenceChanged: ((_ fps: Int) -> Void)? = nil,
        onStreamBitrateChanged: ((_ kbps: Int) -> Void)? = nil,
        onNetworkStats: ((
            _ fps: Double, _ fecPerSec: Double, _ unrecoveredPerSec: Double, _ holdMs: Int, _ pacerDepth: Int,
        ) -> Void)? = nil,
        onStreamSettingsInjectorReady: ((((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?) -> Void)? = nil,
        onSystemKeyInjectorReady: ((((
            _ keyCode: UInt16, _ modifierFlags: UInt64, _ isDown: Bool,
        ) -> Void)?) -> Void)? = nil,
        onStreamStallChanged: ((_ stalled: Bool) -> Void)? = nil,
        onSessionRejected: (() -> Void)? = nil,
    ) {
        self.isActive = isActive
        self.inputEnabled = inputEnabled
        self.onActivate = onActivate
        self.onCanvasScroll = onCanvasScroll
        self.onStreamNativeSize = onStreamNativeSize
        self.onKeyInjectorReady = onKeyInjectorReady
        self.onResizeInjectorReady = onResizeInjectorReady
        self.onViewportInjectorReady = onViewportInjectorReady
        self.onInputReleaseReady = onInputReleaseReady
        self.onWindowGeometryChanged = onWindowGeometryChanged
        self.onStreamCadenceChanged = onStreamCadenceChanged
        self.onStreamBitrateChanged = onStreamBitrateChanged
        self.onNetworkStats = onNetworkStats
        self.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
        self.onSystemKeyInjectorReady = onSystemKeyInjectorReady
        self.onStreamStallChanged = onStreamStallChanged
        self.onSessionRejected = onSessionRejected
    }

    /// The standalone default (no canvas around it): always active, INPUT-ENABLED, no-op callbacks — for
    /// previews / sheet hosts that render a `RemoteWindowPanel` directly.
    public static var standalone: Self { Self() }

    /// **The read-only-gated video-leaf context derivation (the pure seam the leaf and its tests
    /// share).** Maps a pane's `readOnly` policy onto the two input gates a `.remoteGUI` leaf needs, so
    /// `GuiLeafView` stays a thin renderer and the policy is unit-testable headlessly (no Metal/VT):
    ///   • `inputEnabled = !readOnly` — the app-target client gates forwarding on `isActive && inputEnabled`,
    ///     so a read-only pane relays NOTHING to the host (wire-compatible silence).
    ///   • `onKeyInjectorReady` clears the paste-as-keystrokes sink while read-only — it hands `bindKeyInjector`
    ///     a `nil` sink (not the live one), so ``RemoteWindowModel/canPasteKeystrokes`` is `false` and
    ///     ``RemoteWindowModel/pasteAsKeystrokes(_:)`` is inert. NO model→store coupling: read-only is resolved
    ///     at the seam, not threaded into the model. `bindKeyInjector` is the leaf's `{ model?.keyInjector = $0 }`.
    public static func videoLeaf(
        isActive: Bool,
        readOnly: Bool,
        onActivate: @escaping () -> Void = {},
        onCanvasScroll: @escaping (CGSize) -> Void = { _ in },
        onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)? = nil,
        bindKeyInjector: @escaping (((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void,
        bindResizeInjector: @escaping (((_ width: Double, _ height: Double) -> Void)?) -> Void = { _ in },
        bindViewportInjector: @escaping (((_ command: UInt8) -> Void)?) -> Void = { _ in },
        bindInputRelease: @escaping ((() -> Void)?) -> Void = { _ in },
        bindStreamSettingsInjector: @escaping (((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?)
            -> Void = { _ in },
        bindSystemKeyInjector: @escaping (((_ keyCode: UInt16, _ modifierFlags: UInt64, _ isDown: Bool) -> Void)?)
            -> Void = { _ in },
        onWindowGeometry: @escaping (_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double)
            -> Void = { _, _, _, _ in
            },
        onStreamCadence: @escaping (_ fps: Int) -> Void = { _ in },
        onStreamBitrate: @escaping (_ kbps: Int) -> Void = { _ in },
        onNetworkStats: @escaping (
            _ fps: Double, _ fecPerSec: Double, _ unrecoveredPerSec: Double, _ holdMs: Int, _ pacerDepth: Int,
        ) -> Void = { _, _, _, _, _ in },
        onStreamStall: @escaping (_ stalled: Bool) -> Void = { _ in },
        onSessionRejected: @escaping () -> Void = {},
    ) -> Self {
        Self(
            isActive: isActive,
            inputEnabled: !readOnly,
            onActivate: onActivate,
            onCanvasScroll: onCanvasScroll,
            onStreamNativeSize: onStreamNativeSize,
            onKeyInjectorReady: { sink in bindKeyInjector(readOnly ? nil : sink) },
            // RESIZE: a read-only pane must not resize the host window — withhold the sink (bind nil), like
            // the key sink, so the popover is inert (and `GuiLeafView` hides it) while locked.
            onResizeInjectorReady: { sink in bindResizeInjector(readOnly ? nil : sink) },
            // VIEWPORT CONTROLS: zoom / pan-lock are pure CLIENT compositor ops (they never reach the host), so
            // they stay live even on a READ-ONLY pane — bind the sink unconditionally (no read-only gate).
            onViewportInjectorReady: { sink in bindViewportInjector(sink) },
            // RELEASE STUCK INPUT: synthesizes host key/mouse RELEASES — host input, so a read-only pane
            // must not fire it. Withhold the sink (bind nil) exactly like the key sink.
            onInputReleaseReady: { sink in bindInputRelease(readOnly ? nil : sink) },
            // HOST-WINDOW RESIZE: the window geometry push (current + max size) is informational and never
            // reaches the host, so it stays live even on a read-only pane (the popover is hidden anyway, but
            // the model's size mirror stays current for when the pane is unlocked).
            onWindowGeometryChanged: onWindowGeometry,
            // CONNECTION STATS: the host-cadence + bitrate pushes are informational (never reach the host),
            // so they stay live regardless of read-only — the titlebar telemetry tracks the stream either way.
            onStreamCadenceChanged: onStreamCadence,
            onStreamBitrateChanged: onStreamBitrate,
            // NETWORK-STATS MIRROR: informational (never reaches the host) — stays live regardless of
            // read-only, so a locked pane's stats surface still tracks the stream.
            onNetworkStats: onNetworkStats,
            // STREAM SETTINGS: changes HOST encode behaviour (fps cap / bitrate ceiling) — a read-only
            // pane must not drive it. Withhold the sink (bind nil), exactly like the resize sink.
            onStreamSettingsInjectorReady: { sink in bindStreamSettingsInjector(readOnly ? nil : sink) },
            // SYSTEM-KEY INJECTOR: sends host KEY input — a read-only pane must not inject. Withhold
            // the sink (bind nil), exactly like the paste-keystrokes sink.
            onSystemKeyInjectorReady: { sink in bindSystemKeyInjector(readOnly ? nil : sink) },
            // STALL SCRIM: informational (never reaches the host) — stays live regardless of read-only, so
            // a locked pane still shows "Reconnecting…" when its host goes dark.
            onStreamStallChanged: onStreamStall,
            // TERMINAL REFUSAL: informational (never reaches the host) — stays live regardless of
            // read-only, so a locked pane still falls back to the picker when the host says no.
            onSessionRejected: onSessionRejected,
        )
    }
}

/// Injects the production remote-GUI-window video view when the app target provides
/// one. `nil` → the gated placeholder is shown.
@preconcurrency
@MainActor
public final class VideoWindowFactory {
    /// App-registered factory (set once at launch). `nil` → use the placeholder. Receives the descriptor
    /// + the per-render ``RemotePaneContext`` (active state + activate/canvas-scroll callbacks).
    public static var shared: ((RemoteWindowDescriptor, RemotePaneContext) -> AnyView)?

    /// Builds the remote-GUI-window view: the registered production renderer if
    /// present (and a host is capturing), else an empty view (the headless build registers no
    /// factory; the rebuilt `SlopDeskClientUI` provides the real placeholder body).
    public static func make(_ descriptor: RemoteWindowDescriptor, context: RemotePaneContext = .standalone) -> AnyView {
        if let factory = shared {
            return factory(descriptor, context)
        }
        return AnyView(EmptyView())
    }
}

/// One host-side window the Remote-Window PICKER lists (docs/31). The cross-platform mirror of the
/// video protocol's `WindowSummary`, kept here so `SlopDeskClientUI` needn't depend on `SlopDeskVideoProtocol`.
/// `Identifiable` (by `windowID`) so a SwiftUI `List`/`ForEach` can render it directly.
public struct RemoteWindowSummary: Sendable, Equatable, Identifiable {
    public var windowID: UInt32
    public var appName: String
    public var title: String
    public var width: UInt16
    public var height: UInt16
    public var id: UInt32 { windowID }

    public init(windowID: UInt32, appName: String, title: String, width: UInt16, height: UInt16) {
        self.windowID = windowID
        self.appName = appName
        self.title = title
        self.width = width
        self.height = height
    }

    /// "App — Title  (W×H)" for one picker row (title omitted when empty).
    public var displayLabel: String {
        let head = title.isEmpty ? appName : "\(appName) — \(title)"
        return "\(head)  (\(width)×\(height))"
    }
}

/// The **discovery seam** (docs/31): the GUI app injects a closure that queries the host for its
/// shareable windows (implemented in `SlopDeskVideoClient.VideoWindowDiscovery`), so the cross-platform UI
/// can populate the Remote-Window picker WITHOUT importing the gated video module. `nil` → no discovery
/// available → the picker shows its manual-window-id fallback.
///
/// Wiring (app target, once at launch):
/// ```swift
/// import SlopDeskVideoClient
/// RemoteWindowDiscovery.shared = { host, mediaPort, cursorPort in
///     await VideoWindowDiscovery.discoverWindows(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
///         .map { RemoteWindowSummary(windowID: $0.windowID, appName: $0.appName, title: $0.title, width: $0.width, height: $0.height) }
/// }
/// ```
@preconcurrency
@MainActor
public final class RemoteWindowDiscovery {
    /// App-registered window-list query (set once at launch). `nil` → the picker uses manual entry.
    public static var shared: (@MainActor (_ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16) async
        -> [RemoteWindowSummary])?
}

/// One host-side DISPLAY the desktop pane's display-switcher lists. The cross-platform mirror of the
/// video protocol's `DisplaySummary` (kept here so `SlopDeskClientUI` needn't depend on
/// `SlopDeskVideoProtocol`). `Identifiable` (by `displayID`) for direct `ForEach` rendering.
public struct RemoteDisplaySummary: Sendable, Equatable, Identifiable {
    public var displayID: UInt32
    /// Point size (the host's `CGDisplayBounds` size).
    public var width: UInt16
    public var height: UInt16
    public var isMain: Bool
    public var id: UInt32 { displayID }

    public init(displayID: UInt32, width: UInt16, height: UInt16, isMain: Bool) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.isMain = isMain
    }

    /// One switcher row: "Main Display (2560×1440)" / "Display 2 (1920×1080)". The ordinal is the
    /// caller's index+1 (display IDs are opaque u32s — meaningless to show).
    public func displayLabel(ordinal: Int) -> String {
        let name = isMain ? "Main Display" : "Display \(ordinal)"
        return "\(name) (\(width)×\(height))"
    }
}

/// The display-list **discovery seam** (the desktop pane's display switcher): the GUI app injects a
/// closure querying the host's online displays (implemented in
/// `SlopDeskVideoClient.VideoWindowDiscovery.discoverDisplays` — the session-less `listDisplays` ↔
/// `displayList` pair), mirroring ``RemoteWindowDiscovery`` exactly. `nil` → no discovery → the
/// switcher shows only the current display.
@preconcurrency
@MainActor
public final class RemoteDisplayDiscovery {
    /// App-registered display-list query (set once at launch). `nil` → the switcher is inert.
    public static var shared: (@MainActor (_ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16) async
        -> [RemoteDisplaySummary])?
}

/// One host-side SYSTEM dialog/prompt the client's monitor surfaces in its own pane (the user's case: a
/// SecurityAgent login/password prompt). The cross-platform mirror of the protocol's `SystemDialogSummary`
/// (kept here so `SlopDeskClientUI` needn't depend on `SlopDeskVideoProtocol`).
public struct SystemDialogInfo: Sendable, Equatable, Identifiable {
    public var windowID: UInt32
    public var owner: String
    public var title: String
    public var width: UInt16
    public var height: UInt16
    /// `true` ⇒ a Secure-Event-Input (password/auth) dialog: view + click work, typing is OS-blocked.
    public var isSecure: Bool
    public var id: UInt32 { windowID }

    public init(windowID: UInt32, owner: String, title: String, width: UInt16, height: UInt16, isSecure: Bool) {
        self.windowID = windowID
        self.owner = owner
        self.title = title
        self.width = width
        self.height = height
        self.isSecure = isSecure
    }

    /// A pane label: "owner — title" (title omitted when empty).
    public var displayLabel: String {
        title.isEmpty ? owner : "\(owner) — \(title)"
    }
}

/// The **system-dialog discovery seam** (the "show system popups in their own pane" feature): the GUI app
/// injects a closure that polls the host for its open system dialogs (implemented in
/// `SlopDeskVideoClient.VideoWindowDiscovery.discoverSystemDialogs`), so the cross-platform monitor can
/// auto-spawn dialog panes WITHOUT importing the gated video module. `nil` → no monitor activity.
@preconcurrency
@MainActor
public final class SystemDialogDiscovery {
    /// App-registered system-dialog poll (set once at launch). `nil` → the monitor is inert.
    public static var shared: (@MainActor (_ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16) async
        -> [SystemDialogInfo])?
}

// SEAM SPLIT: the headless `SlopDeskWorkspaceCore` carries no SwiftUI `RemoteWindowPlaceholderView` body —
// `SlopDeskClientUI` provides the real placeholder body; the Xcode app target injects the production
// `VideoWindowView` via `VideoWindowFactory`.
#endif
