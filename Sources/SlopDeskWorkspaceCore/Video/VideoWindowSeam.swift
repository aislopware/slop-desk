#if canImport(SwiftUI)
import SwiftUI

/// The **seam** between the cross-platform SwiftUI client and a remote GUI-window
/// video view (PATH 2 / Phase 4, doc 17 §3).
///
/// Like ``TerminalRendererFactory`` for the terminal pixels, the cross-platform
/// library cannot reference `SlopDeskVideoClient.VideoWindowView` directly — that would
/// pull VideoToolbox + Metal into the headless `swift build` (and those frameworks
/// HANG without a window-server + TCC session in a test context). Instead the GUI
/// app target — which links `SlopDeskVideoClient` and runs with the Screen-Recording /
/// decode entitlements — registers a factory at launch; the library calls it and
/// falls back to a clearly-labelled placeholder when no factory was registered
/// (i.e. when no host is capturing a GUI window).
///
/// This is **gated**: the GUI video path is secondary to the terminal path. A remote
/// GUI window only appears when (a) the app injects a factory AND (b) the host is
/// actively capturing a window. Until then the placeholder explains the state.
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
    /// A stable identifier for the remote window (host CGWindowID).
    public var windowID: UInt32
    /// The host's NetBird-routable address (or hostname). Empty ⇒ no live endpoint
    /// (the factory then builds the chrome-only / placeholder view).
    public var host: String
    /// The host media UDP port (control/video/geometry/input). `0` ⇒ no endpoint.
    public var mediaPort: UInt16
    /// The host dedicated cursor UDP port. `0` ⇒ no endpoint.
    public var cursorPort: UInt16

    public init(
        title: String,
        windowID: UInt32,
        host: String = "",
        mediaPort: UInt16 = 0,
        cursorPort: UInt16 = 0,
    ) {
        self.title = title
        self.windowID = windowID
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
    }

    /// True when the descriptor carries a complete live endpoint (host + two DISTINCT ports).
    /// The app's `VideoWindowFactory` uses this to choose the LIVE `VideoWindowView`
    /// (orchestrator comes up) vs. the chrome-only placeholder. The media + cursor sockets
    /// must be distinct ports (PATH 2 opens two separate UDP connections).
    public var hasEndpoint: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && mediaPort != 0 && cursorPort != 0 && mediaPort != cursorPort
    }
}

/// Per-render context the cross-platform canvas passes through the seam to the gated video view, so the
/// remote-GUI pane behaves like one item on the infinite canvas: only the ACTIVE pane consumes
/// pointer/scroll, a click ACTIVATES it (and raises the host window), and a scroll over a NON-active pane
/// pans the canvas instead of being swallowed by the (background) remote window.
public struct RemotePaneContext {
    /// Whether this pane is the workspace's active/focused pane. The video view forwards pointer/scroll
    /// to the remote window ONLY when active; a non-active pane routes scroll to ``onCanvasScroll``.
    public var isActive: Bool
    /// READ-ONLY INPUT GATE (E21 WI-3). `false` ⇒ a read-only `.remoteGUI` pane: the app-target video client
    /// must forward NEITHER pointer/scroll NOR keycodes to the host while `!inputEnabled` — it gates every
    /// forward on `isActive && inputEnabled` (a click may still ACTIVATE the workspace pane, but it is not
    /// relayed to the remote window, the host window is not raised, and the paste-as-keystrokes sink is
    /// cleared). Wire-compatible silence: read-only is enforced purely by NOT forwarding input — no
    /// VideoControl change, no golden touch. Defaults `true` (a normal, writable pane).
    public var inputEnabled: Bool
    /// Make this pane the workspace's active pane — called on click (mouseDown). For a GUI pane the host
    /// window is ALSO raised by the pane's own `focusWindow`; this sets the *workspace* focus.
    public var onActivate: () -> Void
    /// Pan the canvas by a (sign-adjusted) delta — called when a NON-active pane receives a scroll, so the
    /// gesture navigates the canvas rather than scrolling the background remote window.
    public var onCanvasScroll: (CGSize) -> Void
    /// 1:1 PANE SNAP: resize this pane so its VIDEO CONTENT goes from `current` to `target`
    /// points — fired by the video view when the stream's native 1:1 point size becomes known
    /// (first decoded frame) or changes (host-side resize), so the stream renders pixel-for-pixel
    /// with no fractional-scaling blur. `nil` (the standalone default) ⇒ no pane to snap; the
    /// video session then keeps its legacy connect-time host-follow negotiation instead.
    public var onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the live video view publishes a key-injection closure here once its
    /// session exists (and `nil` on teardown), so the pane's "Paste as Keystrokes" action can drive
    /// the SAME per-key `CGEvent` path the keyboard uses (`InputInjector.postKey`). The closure is
    /// `(keyCode, down, shift)`. `nil` (the standalone default) ⇒ no canvas to receive the sink.
    public var onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)?
    /// RESIZE (numeric popover): the live video view publishes a resize-drive closure here once its session
    /// exists (and `nil` on teardown), so the pane's "Resize…" popover requests an ABSOLUTE host-window
    /// POINT size. The closure is `(width, height)` in host points. `nil` (the standalone default) ⇒ no
    /// canvas. Withheld (bound `nil`) while the pane is read-only (see ``videoLeaf(isActive:readOnly:...)``).
    public var onResizeInjectorReady: ((((_ width: Double, _ height: Double) -> Void)?) -> Void)?
    /// VIEWPORT CONTROLS: the live video view publishes a client-viewport command sink here once its session
    /// exists (and `nil` on teardown), so the pane's bottom control bar drives zoom / pan-lock. The closure
    /// carries a raw command byte (``RemoteWindowModel/ViewportCommand``: 0 zoom-in / 1 zoom-out / 2 reset /
    /// 3 toggle-lock). Pure CLIENT compositor ops (no host input), so — unlike ``onResizeInjectorReady`` — it
    /// is NOT withheld while read-only. `nil` (the standalone default) ⇒ no canvas to receive it.
    public var onViewportInjectorReady: ((((_ command: UInt8) -> Void)?) -> Void)?
    /// RELEASE STUCK INPUT (C5, the manual escape hatch): the live video view publishes a zero-arg release
    /// closure here (and `nil` on teardown) that synthesizes a key-UP for every held modifier + a mouse-UP
    /// for every button through the existing synthetic-release send paths — the palette's chord-less
    /// "Release Stuck Input" drives it when the host is left with a latched modifier / button despite the
    /// automatic redundancy+dedup. SENDS host input, so — like ``onKeyInjectorReady`` — the seam withholds
    /// it (binds `nil`) while the pane is read-only. `nil` (the standalone default) ⇒ no canvas.
    public var onInputReleaseReady: (((() -> Void)?) -> Void)?
    /// HOST-WINDOW RESIZE: the live video view PUSHES the remote window's current + MAX resizable POINT
    /// sizes through this whenever either changes (first decoded frame / host displayMax report), so the
    /// "Resize…" popover pre-fills its fields at the current size and caps them at the remote max. `(curW,
    /// curH, maxW, maxH)`; a zero max = "not yet known" (the popover then leaves that field uncapped).
    /// Pure informational view→model push (never reaches the host), so it is NOT read-only-gated. `nil` ⇒ none.
    public var onWindowGeometryChanged: ((_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double) -> Void)?
    /// CONNECTION STATS: the live video view PUSHES the host-announced stream cadence (frames/sec) through
    /// this whenever the host's FPS governor announces a new value, so the sidebar's Connection section shows
    /// a per-pane "FPS" row. Pure informational view→model push (never reaches the host), so it is NOT
    /// read-only-gated. `nil` ⇒ none.
    public var onStreamCadenceChanged: ((_ fps: Int) -> Void)?
    /// CONNECTION STATS (2026-07-04): the live video view PUSHES the client-measured video PAYLOAD bitrate
    /// (kilobits/sec, ~1 Hz) through this — the titlebar cluster's stream-weight complication. Pure
    /// informational view→model push (never reaches the host), so it is NOT read-only-gated. `nil` ⇒ none.
    public var onStreamBitrateChanged: ((_ kbps: Int) -> Void)?
    /// STALL SCRIM (2026-07-03): the live video view PUSHES the stream's stall state through this when it
    /// FLIPS — `true` ⇒ the host went silent past the stall threshold (the pane overlays "Reconnecting…"),
    /// `false` ⇒ traffic resumed. Pure informational view→model push (never reaches the host), so it is NOT
    /// read-only-gated. `nil` ⇒ none.
    public var onStreamStallChanged: ((_ stalled: Bool) -> Void)?

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
        onStreamStallChanged: ((_ stalled: Bool) -> Void)? = nil,
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
        self.onStreamStallChanged = onStreamStallChanged
    }

    /// The standalone default (no canvas around it): always active, INPUT-ENABLED, no-op callbacks — for
    /// previews / sheet hosts that render a `RemoteWindowPanel` directly.
    public static var standalone: Self { Self() }

    /// **E21 WI-3 — the read-only-gated video-leaf context derivation (the pure seam the leaf and its tests
    /// share).** Maps a pane's `readOnly` policy onto the two input gates a `.remoteGUI` leaf needs, so the
    /// SwiftUI `GuiLeafView` stays a thin renderer and the policy is unit-testable headlessly (no Metal/VT):
    ///   • `inputEnabled = !readOnly` — the app-target client gates pointer/scroll/keycode forwarding on
    ///     `isActive && inputEnabled`, so a read-only pane relays NOTHING to the host (wire-compatible silence).
    ///   • `onKeyInjectorReady` clears the paste-as-keystrokes sink while read-only — it hands `bindKeyInjector`
    ///     a `nil` sink (instead of the live one the video view publishes), so the model's
    ///     ``RemoteWindowModel/canPasteKeystrokes`` is `false` and ``RemoteWindowModel/pasteAsKeystrokes(_:)``
    ///     is inert. NO model→store coupling: the read-only state is resolved at the seam, not threaded into
    ///     the model. `bindKeyInjector` is the leaf's `{ model?.keyInjector = $0 }` write.
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
        onWindowGeometry: @escaping (_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double)
            -> Void = { _, _, _, _ in
            },
        onStreamCadence: @escaping (_ fps: Int) -> Void = { _ in },
        onStreamBitrate: @escaping (_ kbps: Int) -> Void = { _ in },
        onStreamStall: @escaping (_ stalled: Bool) -> Void = { _ in },
    ) -> Self {
        Self(
            isActive: isActive,
            inputEnabled: !readOnly,
            onActivate: onActivate,
            onCanvasScroll: onCanvasScroll,
            onStreamNativeSize: onStreamNativeSize,
            onKeyInjectorReady: { sink in bindKeyInjector(readOnly ? nil : sink) },
            // RESIZE: a read-only pane must not resize the host window — withhold the sink (bind nil),
            // exactly like the key sink, so the popover is inert (and `GuiLeafView` hides it) while locked.
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
            // STALL SCRIM: informational (never reaches the host) — stays live regardless of read-only, so
            // a locked pane still shows "Reconnecting…" when its host goes dark.
            onStreamStallChanged: onStreamStall,
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

// L0 / A2 SEAM SPLIT: the SwiftUI `RemoteWindowPlaceholderView` body has been DELETED from the headless
// `SlopDeskWorkspaceCore`. The rebuilt `SlopDeskClientUI` provides the real placeholder body; the
// Xcode app target injects the production `VideoWindowView` via `VideoWindowFactory`.
#endif
