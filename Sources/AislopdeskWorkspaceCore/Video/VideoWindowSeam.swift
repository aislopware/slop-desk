#if canImport(SwiftUI)
import SwiftUI

/// The **seam** between the cross-platform SwiftUI client and a remote GUI-window
/// video view (PATH 2 / Phase 4, doc 17 §3).
///
/// Like ``TerminalRendererFactory`` for the terminal pixels, the cross-platform
/// library cannot reference `AislopdeskVideoClient.VideoWindowView` directly — that would
/// pull VideoToolbox + Metal into the headless `swift build` (and those frameworks
/// HANG without a window-server + TCC session in a test context). Instead the GUI
/// app target — which links `AislopdeskVideoClient` and runs with the Screen-Recording /
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
/// import AislopdeskVideoClient
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

    public init(
        isActive: Bool = true,
        inputEnabled: Bool = true,
        onActivate: @escaping () -> Void = {},
        onCanvasScroll: @escaping (CGSize) -> Void = { _ in },
        onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)? = nil,
        onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)? = nil,
    ) {
        self.isActive = isActive
        self.inputEnabled = inputEnabled
        self.onActivate = onActivate
        self.onCanvasScroll = onCanvasScroll
        self.onStreamNativeSize = onStreamNativeSize
        self.onKeyInjectorReady = onKeyInjectorReady
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
    ) -> Self {
        Self(
            isActive: isActive,
            inputEnabled: !readOnly,
            onActivate: onActivate,
            onCanvasScroll: onCanvasScroll,
            onStreamNativeSize: onStreamNativeSize,
            onKeyInjectorReady: { sink in bindKeyInjector(readOnly ? nil : sink) },
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
    /// factory; the rebuilt `AislopdeskClientUI` provides the real placeholder body).
    public static func make(_ descriptor: RemoteWindowDescriptor, context: RemotePaneContext = .standalone) -> AnyView {
        if let factory = shared {
            return factory(descriptor, context)
        }
        return AnyView(EmptyView())
    }
}

/// One host-side window the Remote-Window PICKER lists (docs/31). The cross-platform mirror of the
/// video protocol's `WindowSummary`, kept here so `AislopdeskClientUI` needn't depend on `AislopdeskVideoProtocol`.
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
/// shareable windows (implemented in `AislopdeskVideoClient.VideoWindowDiscovery`), so the cross-platform UI
/// can populate the Remote-Window picker WITHOUT importing the gated video module. `nil` → no discovery
/// available → the picker shows its manual-window-id fallback.
///
/// Wiring (app target, once at launch):
/// ```swift
/// import AislopdeskVideoClient
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
/// (kept here so `AislopdeskClientUI` needn't depend on `AislopdeskVideoProtocol`).
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
/// `AislopdeskVideoClient.VideoWindowDiscovery.discoverSystemDialogs`), so the cross-platform monitor can
/// auto-spawn dialog panes WITHOUT importing the gated video module. `nil` → no monitor activity.
@preconcurrency
@MainActor
public final class SystemDialogDiscovery {
    /// App-registered system-dialog poll (set once at launch). `nil` → the monitor is inert.
    public static var shared: (@MainActor (_ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16) async
        -> [SystemDialogInfo])?
}

// L0 / A2 SEAM SPLIT: the SwiftUI `RemoteWindowPlaceholderView` body has been DELETED from the headless
// `AislopdeskWorkspaceCore`. The rebuilt `AislopdeskClientUI` provides the real placeholder body; the
// Xcode app target injects the production `VideoWindowView` via `VideoWindowFactory`.
#endif
