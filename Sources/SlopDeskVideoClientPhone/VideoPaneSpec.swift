// VideoPaneSpec — the plain value one phone canvas hands `VideoSurfaceHost` to mount a remote-GUI
// pane (docs/56 §3, the video carve).
//
// THIS IS THE PHONE'S HALF OF THE SEAM'S PAYLOAD, laid out as a value now that nothing here renders
// through SwiftUI's diffing. Its predecessor was `VideoWindowView` (a SwiftUI `View` whose stored
// `let`s were exactly these fields, deleted whole in commit 3f11c6e6 along with the rest of the
// phone's SwiftUI). That file carried TWO initializers — a legacy title-only one and a live one
// requiring `connection` — because a SwiftUI `View`'s `body` needed both spellings to type-check the
// same way regardless of which ran. A plain struct has no `body` to gate on which initializer ran, so
// there is nothing left for the second spelling to buy: `connection` just defaults to `nil` here.
//
// ONE DELIBERATE ASYMMETRY FROM THE MAC'S EQUIVALENT SPEC: no `onSystemKeyInjectorReady`. Its sink's
// middle argument is a raw `NSEvent.ModifierFlags` bit pattern, and its only producer is
// `SystemKeyCaptureController`'s `CGEventTap` — neither exists on iOS, which is why
// `PaneImmersiveCapture.isSupported` is already `false` on this platform
// (`SlopDeskClientCore/Input/PaneImmersiveCapture.swift`) and the phone footer draws no immersive
// chip. Accepting the parameter anyway would light `RemoteWindowModel.canInjectSystemKeys` for a
// capture that can never run, so the parameter is absent from the signature rather than
// accepted-and-ignored.
#if os(iOS)
import CoreGraphics
import SlopDeskVideoClient

/// Everything ``VideoSurfaceHost`` needs to mount one remote-GUI pane: the title/app-name/connection
/// triple, the MOUNT-TIME pane gates, and the seam's `on…`/`on…Ready` callbacks. A plain value — NOT
/// a `View`, NOT an `ObservableObject` — because nothing here is bound to a render pass any more; the
/// app target builds one of these once per mount, and every LATER gate change goes through
/// ``VideoSurfaceHost/setPaneGates(isActive:inputEnabled:backgroundPointer:)`` instead of a new spec.
public struct VideoPaneSpec {
    /// The remote window's title. Read once, at mount, for the container's `accessibilityLabel` — the
    /// pixels the Metal view draws have no structure to expose, so accessibility rides the container.
    public var title: String
    /// The remote window's APP display name ("Xcode"/"Google Chrome" — the picker's `appName`).
    /// SIGNATURE PARITY WITH THE MAC ONLY: the smart-zoom ⌘0 gate this would feed
    /// (``PinchZeroPolicy``) is a TRACKPAD `smartMagnify` translation, and a phone has no two-finger
    /// double-tap on a trackpad to gate — `VideoSurfaceHost` accepts this field and never reads it,
    /// exactly as the deleted `VideoLayerRepresentable.targetAppName` did.
    public var targetAppName: String
    /// `nil` ⇒ no live connection (chrome-only / placeholder mount, e.g. before the host is
    /// discovered). When set, the host brings up the full client pipeline — decoder, two UDP sockets,
    /// display link — on mount.
    public var connection: VideoWindowConnection?

    /// Whether this pane is the workspace's active/focused pane AT MOUNT. Drives the KEYBOARD only:
    /// pointer traffic forwards from whichever pane a touch lands on, matching the Mac's
    /// never-`isActive`-gated `mouseDown` — only the first-responder claim is active-gated. Every
    /// LATER change goes through ``VideoSurfaceHost/setPaneGates(isActive:inputEnabled:backgroundPointer:)``.
    public var isActive: Bool
    /// READ-ONLY INPUT GATE at MOUNT: `false` ⇒ forward NEITHER touch-derived pointer traffic NOR
    /// keycodes to the host, and withhold the host-affecting injector sinks. A touch still ACTIVATES
    /// the pane (`onActivate` still fires) — exactly like a click on a locked Mac pane.
    public var inputEnabled: Bool
    /// BACKGROUND POINTER at MOUNT (satellite windows): `true` ⇒ keep taking pointer input while the
    /// surface's window is not key. iOS has no key-window state to read this against (nor a second
    /// window a pane can pop into), so `VideoSurfaceHost` accepts and ignores it — signature parity
    /// with the Mac spec only. Defaults `false`.
    public var backgroundPointer: Bool

    /// Make this pane the workspace's active pane — fired on the first touch contact (the phone's
    /// click-to-activate). A read-only pane still fires this.
    public var onActivate: () -> Void
    /// SIGNATURE PARITY WITH THE MAC ONLY: ⌥-scroll-to-pan-the-canvas is a trackpad route with no
    /// phone equivalent (the canvas is navigated by its own gestures outside this surface), so
    /// `VideoSurfaceHost` accepts this and nothing ever calls it.
    public var onCanvasScroll: (CGSize) -> Void
    /// 1:1 PANE SNAP: ask the surrounding canvas pane to resize its VIDEO CONTENT from `current` to
    /// `target` points so the stream renders pixel-for-pixel, fired on the first decoded frame and on
    /// host-side capture-size changes. `nil` ⇒ standalone (no pane to snap) — the session keeps the
    /// legacy connect-time host-follow negotiation instead.
    public var onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the host publishes a key-injection closure here once its session exists
    /// (`nil` on teardown), routed to the same secure-input-aware path the hardware keyboard uses.
    /// `(keyCode, down, shift)`.
    public var onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)?
    /// RESIZE (numeric popover): the host publishes a resize-drive closure here once its session
    /// exists (`nil` on teardown), requesting an ABSOLUTE host-window POINT size.
    public var onResizeInjectorReady: ((((_ width: Double, _ height: Double) -> Void)?) -> Void)?
    /// VIEWPORT CONTROLS: the host publishes a client-viewport command closure here once its session
    /// exists — fit / zoom-in / zoom-out / reset / pan-lock on/off, carrying a raw command byte
    /// (`RemoteWindowModel.ViewportCommand`). Pure CLIENT compositor ops (no host round-trip), so —
    /// unlike the sinks above — this one is never withheld while read-only.
    public var onViewportInjectorReady: ((((_ command: UInt8) -> Void)?) -> Void)?
    /// RELEASE STUCK INPUT: the host publishes a zero-arg release closure here (`nil` on teardown)
    /// that synthesizes a key-up for every held modifier plus a mouse-up for every button — the
    /// palette's chord-less escape hatch for a host left holding input.
    public var onInputReleaseReady: (((() -> Void)?) -> Void)?
    /// HOST-WINDOW GEOMETRY: the host pushes the window's current + MAX resizable POINT sizes here
    /// whenever either changes (first decoded frame / host `displayMax` report). A zero max means "not
    /// yet known". Informational (never reaches the host), so never withheld while read-only.
    public var onWindowGeometryReady: ((_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double) -> Void)?
    /// CONNECTION STATS: the host pushes the host-announced stream CADENCE (frames/sec) here whenever
    /// the host's FPS governor announces a new value.
    public var onStreamCadenceReady: ((_ fps: Int) -> Void)?
    /// CONNECTION STATS: the host pushes the client-measured video PAYLOAD bitrate (kilobits/sec,
    /// ~1 Hz) here.
    public var onStreamBitrateReady: ((_ kbps: Int) -> Void)?
    /// NETWORK-STATS MIRROR: the ~2 Hz client-local telemetry aggregate — received frames/sec, FEC
    /// recoveries/sec, unrecovered losses/sec, latest hold (ms), pacer depth, host-reported RTT/encode
    /// (ms) and client decode (ms) EWMAs (`0` = no reading yet). Primitives only (the seam is
    /// headless).
    public var onNetworkStatsReady: ((
        _ fps: Double, _ fecPerSec: Double, _ unrecoveredPerSec: Double, _ holdMs: Int, _ pacerDepth: Int,
        _ rttMs: Double, _ encodeMs: Double, _ decodeMs: Double,
    ) -> Void)?
    /// STREAM SETTINGS (fps cap / bitrate ceiling): the host publishes a settings-drive closure here
    /// once its session exists (`nil` on teardown), `(fpsCap, bitrateCeilingBps)`, `0` = auto.
    /// Host-affecting — withheld while read-only, like the resize sink.
    public var onStreamSettingsInjectorReady: ((((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?) -> Void)?
    /// HOST AUDIO: the footer speaker toggle's enable/disable drive, absolute (the session stores the
    /// wish and re-sends it after every re-hello). Host-affecting — withheld while read-only.
    public var onAudioInjectorReady: ((((_ enabled: Bool) -> Void)?) -> Void)?
    /// PRIVACY BLANK: the desktop pane's shield toggle's enable/disable drive (blacks the host display
    /// + swallows local host input). Host-affecting — withheld while read-only.
    public var onPrivacyInjectorReady: ((((_ enabled: Bool) -> Void)?) -> Void)?
    /// STALL SCRIM: the host pushes the stream's stall state here when it FLIPS — `true` ⇒ the host
    /// went silent past the stall threshold, `false` ⇒ traffic resumed. Informational, never
    /// read-only-gated.
    public var onStreamStallChanged: ((_ stalled: Bool) -> Void)?
    /// TERMINAL REFUSAL: fired once after the host REJECTED the session (`helloAck(accepted: false)`
    /// — window gone / version mismatch). The pipeline has already torn down with no auto-rebuild;
    /// this is what moves the pane off a dead surface and onto the picker/error state.
    public var onSessionRejected: (() -> Void)?

    public init(
        title: String,
        targetAppName: String = "",
        connection: VideoWindowConnection? = nil,
        isActive: Bool = true,
        inputEnabled: Bool = true,
        backgroundPointer: Bool = false,
        onActivate: @escaping () -> Void = {},
        onCanvasScroll: @escaping (CGSize) -> Void = { _ in },
        onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)? = nil,
        onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)? = nil,
        onResizeInjectorReady: ((((_ width: Double, _ height: Double) -> Void)?) -> Void)? = nil,
        onViewportInjectorReady: ((((_ command: UInt8) -> Void)?) -> Void)? = nil,
        onInputReleaseReady: (((() -> Void)?) -> Void)? = nil,
        onWindowGeometryReady: ((_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double) -> Void)? = nil,
        onStreamCadenceReady: ((_ fps: Int) -> Void)? = nil,
        onStreamBitrateReady: ((_ kbps: Int) -> Void)? = nil,
        onNetworkStatsReady: ((
            _ fps: Double, _ fecPerSec: Double, _ unrecoveredPerSec: Double, _ holdMs: Int, _ pacerDepth: Int,
            _ rttMs: Double, _ encodeMs: Double, _ decodeMs: Double,
        ) -> Void)? = nil,
        onStreamSettingsInjectorReady: ((((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?) -> Void)? = nil,
        onAudioInjectorReady: ((((_ enabled: Bool) -> Void)?) -> Void)? = nil,
        onPrivacyInjectorReady: ((((_ enabled: Bool) -> Void)?) -> Void)? = nil,
        onStreamStallChanged: ((_ stalled: Bool) -> Void)? = nil,
        onSessionRejected: (() -> Void)? = nil,
    ) {
        self.title = title
        self.targetAppName = targetAppName
        self.connection = connection
        self.isActive = isActive
        self.inputEnabled = inputEnabled
        self.backgroundPointer = backgroundPointer
        self.onActivate = onActivate
        self.onCanvasScroll = onCanvasScroll
        self.onStreamNativeSize = onStreamNativeSize
        self.onKeyInjectorReady = onKeyInjectorReady
        self.onResizeInjectorReady = onResizeInjectorReady
        self.onViewportInjectorReady = onViewportInjectorReady
        self.onInputReleaseReady = onInputReleaseReady
        self.onWindowGeometryReady = onWindowGeometryReady
        self.onStreamCadenceReady = onStreamCadenceReady
        self.onStreamBitrateReady = onStreamBitrateReady
        self.onNetworkStatsReady = onNetworkStatsReady
        self.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
        self.onAudioInjectorReady = onAudioInjectorReady
        self.onPrivacyInjectorReady = onPrivacyInjectorReady
        self.onStreamStallChanged = onStreamStallChanged
        self.onSessionRejected = onSessionRejected
    }
}
#endif
