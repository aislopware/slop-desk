#if canImport(SwiftUI) && canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import AislopdeskVideoProtocol
import CoreVideo
import Metal
import QuartzCore
import SwiftUI

/// Connection parameters for a remote GUI window (PATH 2 / Phase 4, doc 17 §3): the
/// host endpoint + the window to remote. The GUI app builds this once it knows a host
/// is capturing a window and hands it to ``VideoWindowView``.
public struct VideoWindowConnection: Sendable, Equatable {
    /// The host's NetBird-routable address (or hostname).
    public var host: String
    /// The host media UDP port (control/video/geometry/input).
    public var mediaPort: UInt16
    /// The host dedicated cursor UDP port.
    public var cursorPort: UInt16
    /// The host CGWindowID to remote.
    public var windowID: UInt32

    public init(host: String, mediaPort: UInt16, cursorPort: UInt16, windowID: UInt32) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        self.windowID = windowID
    }
}

/// Bridges the SwiftUI control overlay (fit/fill toggle + zoom reset) to the platform
/// backing view's pipeline. The backing view sets the `onToggle*` closures on `activate`
/// and publishes `mode`/`zoomed` so the overlay icons reflect live state. Deliberately a
/// SwiftUI overlay — NOT AppKit/UIKit subviews of the Metal view: adding subviews +
/// gesture recognizers to the layer-backed Metal view perturbed its geometry and swallowed
/// the `mouseUp` of a trackpad three-finger-drag (→ a stuck remote button). The overlay
/// touches none of that.
@preconcurrency
@MainActor
public final class VideoPaneControls: ObservableObject {
    @Published public var mode: VideoContentMode = .fit
    @Published public var zoomed: Bool = false
    var onToggleFill: () -> Void = {}
    var onResetZoom: () -> Void = {}
    public init() {}
    func toggleFill() { onToggleFill() }
    func resetZoom() { onResetZoom() }
}

/// A SwiftUI view that hosts the `CAMetalLayer` + cursor overlay for one remote GUI
/// window (doc 17 §3 PATH 2). It owns the Metal layer/view, builds the
/// ``MetalVideoRenderer`` + ``ClientCursorCompositor`` + ``AislopdeskVideoClientSession``,
/// starts the orchestrator on appear and stops it on disappear, drives the decoded-
/// frame → renderer path through the ``FramePacer`` display link, and forwards input.
///
/// Each layout pass it computes `videoScale = layerSize / decodedFrameSize` and feeds
/// it to ``ClientCursorCompositor`` (via the session) so the composited cursor lands
/// on the right pixel.
///
/// ⚠️ **GUI-ONLY:** instantiating the renderer / decoder / display link / sockets
/// needs a real device + screen + TCC. COMPILED + reviewed; not driven from tests.
/// This is the wiring point `AislopdeskClientUI` injects via `VideoWindowFactory`.
public struct VideoWindowView: View {
    /// The remote window's title, shown for accessibility.
    public let title: String
    /// `nil` ⇒ no live connection (the seam's placeholder path / preview). When set,
    /// the backing view brings up the full client pipeline.
    public let connection: VideoWindowConnection?

    /// Whether this pane is the active/focused pane on the canvas. Only the active pane forwards
    /// pointer/scroll to the remote window; a non-active pane routes scroll to ``onCanvasScroll`` (the
    /// "only the active pane swallows pointer" rule). Plain (non-isolated) closures + Bool so the
    /// `AppMain` factory can bridge them across the seam without importing `AislopdeskClientUI`.
    let isActive: Bool
    /// Make this pane active (set workspace focus) — called on click. The host window is also raised
    /// (via the pane's own `focusWindow`).
    let onActivate: () -> Void
    /// Pan the canvas when a NON-active pane is scrolled (so scroll over a background pane navigates the
    /// canvas instead of being swallowed by the remote window).
    let onCanvasScroll: (CGSize) -> Void
    /// 1:1 PANE SNAP: ask the surrounding canvas pane to resize its VIDEO CONTENT from `current`
    /// to `target` points so the stream renders pixel-for-pixel (`target` = decoded pixels /
    /// contentsScale, fired on the first decoded frame and on host-side capture-size changes).
    /// `nil` ⇒ standalone window (no pane to snap) → the session keeps the legacy connect-time
    /// host-follow negotiation instead.
    let onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the backing view publishes a key-injection closure here once it exists
    /// (and `nil` on teardown), routed to `pipeline.key(...)` — the same secure-input-aware path the
    /// keyboard uses. `(keyCode, down, shift)`. `nil` ⇒ no canvas wants the sink (preview/standalone).
    let onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)?

    /// The existing seam signature (title-only): renders the Metal-backed view chrome
    /// without a live connection. Kept so `VideoWindowFactory` callers compile.
    public init(title: String) {
        self.title = title
        connection = nil
        isActive = true
        onActivate = {}
        onCanvasScroll = { _ in }
        onStreamNativeSize = nil
        onKeyInjectorReady = nil
    }

    /// Live remote-window view: brings up the orchestrator against `connection`. `isActive` /
    /// `onActivate` / `onCanvasScroll` carry the canvas pane behaviour (active-only pointer + click-to-
    /// activate + non-active scroll-to-pan); they default to the standalone (always-active) values.
    public init(
        title: String,
        connection: VideoWindowConnection,
        isActive: Bool = true,
        onActivate: @escaping () -> Void = {},
        onCanvasScroll: @escaping (CGSize) -> Void = { _ in },
        onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)? = nil,
        onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)? = nil,
    ) {
        self.title = title
        self.connection = connection
        self.isActive = isActive
        self.onActivate = onActivate
        self.onCanvasScroll = onCanvasScroll
        self.onStreamNativeSize = onStreamNativeSize
        self.onKeyInjectorReady = onKeyInjectorReady
    }

    /// Owns the control bridge for this view's lifetime; the backing view wires its closures.
    @StateObject private var controls = VideoPaneControls()

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MetalVideoLayerView(
                connection: connection,
                controls: controls,
                isActive: isActive,
                onActivate: onActivate,
                onCanvasScroll: onCanvasScroll,
                onStreamNativeSize: onStreamNativeSize,
                onKeyInjectorReady: onKeyInjectorReady,
            )
            // FILL THE PANE. Without this the bare representable does not claim the
            // ZStack's space, so the `.bottomTrailing` alignment pins the Metal view as a
            // small island in the BOTTOM-RIGHT corner (the "nhỏ 1 góc" bug) — and clicks
            // across the rest of the pane then miss it (the "toạ độ sai" bug). Mirrors the
            // PROVEN terminal seam (`TerminalScreenView`), which puts this frame directly
            // on the renderer view inside its ZStack. The overlay below stays the small
            // bottom-trailing control cluster.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text("Remote GUI window: \(title)"))
            if connection != nil {
                controlOverlay
            }
        }
    }

    /// fit/fill toggle (+ a zoom-reset that appears only while zoomed), bottom-right.
    private var controlOverlay: some View {
        HStack(spacing: 6) {
            if controls.zoomed {
                Button(action: { controls.resetZoom() }) {
                    Image(systemName: "1.magnifyingglass").padding(6)
                }
                .help("Reset zoom (1×)")
            }
            Button(action: { controls.toggleFill() }) {
                Image(systemName: controls.mode == .fill
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .padding(6)
            }
            .help(controls.mode == .fill ? "Fit — xem trọn cửa sổ"
                : "Fill — phủ kín pane (giữ tỉ lệ, cắt mép)")
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }
}

#if os(macOS)
/// Env-gated (`AISLOPDESK_VIDEO_DEBUG`) stderr diagnostics for the remote-GUI VIEW layer (scroll routing +
/// isActive delivery) — the BUG-2 ground-truth probe. A non-active pane that logs `isActive=true` proves a
/// stale/sticky focus value; `isActive=false` with no pan proves a downstream scroll-routing problem.
func videoViewDbg(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("Aislopdesk[video.client.view]: \(message())\n".utf8))
}

/// `NSViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on macOS.
struct MetalVideoLayerView: NSViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls?
    var isActive: Bool = true
    var onActivate: () -> Void = {}
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?

    func makeNSView(context _: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.isActive = isActive
        view.onActivate = onActivate
        view.onCanvasScroll = onCanvasScroll
        view.onStreamNativeSize = onStreamNativeSize // before activate — its nil-ness picks snap vs host-follow
        view.activate(connection: connection)
        // PASTE AS KEYSTROKES: publish a key-injection sink routed to THIS view's pipeline (the
        // `pipeline.key` guard no-ops until the session is up, so publishing now is safe). The
        // backing view clears it on `deactivate`.
        view.onKeyInjectorReady = onKeyInjectorReady
        view.publishKeyInjector()
        // BUG-2 probe: a recreate (makeNSView) on focus change — vs an in-place updateNSView — would reset
        // isActive to its `true` default mid-stream; logging it distinguishes "stale Bool" from "recreate".
        videoViewDbg("makeNSView (CREATED) isActive=\(isActive)")
        return view
    }

    func updateNSView(_ nsView: MetalLayerBackedView, context _: Context) {
        nsView.controls = controls
        if nsView.isActive != isActive { videoViewDbg("updateNSView isActive \(nsView.isActive)→\(isActive)") }
        nsView.isActive = isActive
        nsView.onActivate = onActivate
        nsView.onCanvasScroll = onCanvasScroll
        nsView.onStreamNativeSize = onStreamNativeSize
        nsView.activate(connection: connection)
    }

    static func dismantleNSView(_ nsView: MetalLayerBackedView, coordinator _: ()) {
        nsView.deactivate()
    }
}

/// A layer-backed `NSView` whose backing layer is a `CAMetalLayer`, with a cursor
/// overlay layer on top. It owns the client pipeline for its lifetime.
final class MetalLayerBackedView: NSView {
    let videoLayer = CAMetalLayer()
    private let pipeline = VideoWindowPipeline()

    /// Whether THIS pane is the canvas's active/focused pane. Only the active pane forwards
    /// pointer/scroll to the remote window; a non-active pane routes a scroll to ``onCanvasScroll`` (so
    /// scroll navigates the canvas) and ignores hover, matching the terminal pane's `isFocusedPane` rule.
    /// Set by `MetalVideoLayerView` on every render (reactive to focus changes). On change it re-applies
    /// the local cursor — a pane losing focus must drop the host shape back to the arrow even if the
    /// pointer never moved.
    var isActive: Bool = true { didSet { applyLocalCursor() } }

    // ── CURSOR (Parsec model): the host streams its cursor SHAPE (cached bitmaps); the OS draws that
    //    shape on the LOCAL cursor at the INSTANT mouse position — zero added latency, and exactly ONE
    //    cursor because macOS does NOT composite the host's RTT-delayed POSITION overlay. While the
    //    pointer is inside an ACTIVE pane and the host cursor is visible we set the host's shape; in a
    //    `.fit` letterbox margin / host-hidden-cursor / a background pane we keep the plain arrow.
    //    `pointerInside` gates the work to when the pointer is actually over this view.
    private var pointerInside = false
    /// Make this pane the active pane — called at the top of `mouseDown` (click-to-activate). Sets the
    /// *workspace* focus; the host window is raised separately via `pipeline.focusWindow()`.
    var onActivate: () -> Void = {}
    /// Pan the canvas by a (sign-adjusted) delta — called from `scrollWheel` when this pane is NOT active.
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    /// 1:1 PANE SNAP: ask the canvas pane to resize its video content from `current` to `target`
    /// points so the stream renders pixel-for-pixel. `nil` ⇒ standalone (no pane). Set by the
    /// representable BEFORE ``activate(connection:)`` — its nil-ness picks pane-follows-stream
    /// vs the legacy connect-time host-follow when the session's GUI hooks are built.
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the canvas publishes a key-injection sink through this (and `nil` on
    /// teardown), so the pane's "Paste as Keystrokes" can drive `pipeline.key(...)` — the same
    /// secure-input-aware key path the keyboard uses. Set by the representable before `activate`.
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?

    /// Hands the canvas a key-injection closure routed to THIS view's pipeline (Shift folded into the
    /// modifiers; `pipeline.key` no-ops until the session is up). Idempotent — safe to call on every
    /// render; the sink captures `self` weakly so a torn-down view injects nothing.
    func publishKeyInjector() {
        onKeyInjectorReady? { [weak self] keyCode, down, shift in
            self?.pipeline.key(keyCode: keyCode, down: down, modifiers: shift ? .shift : [])
        }
    }

    // ── Local view navigation (macOS): pinch-zoom (+ pan-when-zoomed) via the RESPONDER
    //    `magnify`/`scrollWheel` methods — NOT gesture recognizers. A recognizer on this
    //    layer-backed view swallowed the `mouseUp` of a trackpad three-finger-drag, leaving
    //    the remote button stuck down. The fit/fill toggle + zoom-reset live in a SwiftUI
    //    OVERLAY (see `VideoPaneControls`), not AppKit subviews, so they never perturb this
    //    view's geometry or its mouse-event delivery.
    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    /// Bridge to the SwiftUI control overlay; the SwiftUI view owns it. Set by the
    /// representable before `activate`.
    weak var controls: VideoPaneControls?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = videoLayer
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }
    override func makeBackingLayer() -> CALayer { videoLayer }

    func activate(connection: VideoWindowConnection?) {
        // 1:1 PANE SNAP — wire BEFORE pipeline.activate: the session decides pane-follows-stream
        // (snap) vs the legacy connect-time host-follow by whether this hook exists when the GUI
        // hooks are built. The closure reads the live `onStreamNativeSize`, so updateNSView
        // refreshing the seam closure stays picked up without re-activation.
        pipeline.onDecodedPixelSize = onStreamNativeSize == nil ? nil : { [weak self] px in
            self?.adoptStreamPixelSize(px)
        }
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        // Re-apply the local cursor when the host SWAPS shape, or when the host cursor enters/leaves the
        // captured window (visible flip) — so the pointer shape tracks the remote with no RTT lag.
        pipeline.onServerCursorVisibilityChanged = { [weak self] _ in self?.applyLocalCursor() }
        pipeline.onRemoteCursorChanged = { [weak self] in self?.applyLocalCursor() }
        // Wire the SwiftUI overlay's buttons to THIS view's pipeline (live connection only).
        if connection != nil, let controls {
            controls.onToggleFill = { [weak self] in self?.applyToggleFill() }
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }

    func deactivate() {
        if pointerInside { NSCursor.arrow.set() } // restore the arrow before the pipeline tears down
        pointerInside = false
        onKeyInjectorReady?(nil) // PASTE AS KEYSTROKES: drop the stale sink before teardown
        pipeline.deactivate()
    }

    /// 1:1 PANE SNAP: the stream's decoded PIXEL size changed (first frame, or the host
    /// re-captured after a window resize). Compute the point size at which THIS view renders the
    /// stream pixel-for-pixel (`pixels / contentsScale`), rebase the session's resize debounce on
    /// it FIRST (so the snap-induced layout pass holds instead of echoing a `resizeRequest` back
    /// to the host — the snap is client-side only), then ask the canvas pane to adopt it. Skips
    /// the pane mutation for a sub-half-point delta (already 1:1; the rebase alone suffices).
    private func adoptStreamPixelSize(_ pixelSize: VideoSize) {
        guard let handler = onStreamNativeSize else { return }
        let scale = videoLayer.contentsScale > 0 ? videoLayer.contentsScale : 1
        let target = StreamSizeSnap.targetPoints(pixelSize: pixelSize, contentsScale: Double(scale))
        pipeline.adoptLayerSize(target)
        let current = VideoSize(width: Double(bounds.width), height: Double(bounds.height))
        guard StreamSizeSnap.shouldSnap(target: target, current: current) else { return }
        videoViewDbg(
            "1:1 snap → video \(Int(current.width))x\(Int(current.height)) → \(Int(target.width))x\(Int(target.height))pt (pixels \(Int(pixelSize.width))x\(Int(pixelSize.height)) @\(scale)x)",
        )
        handler(
            CGSize(width: target.width, height: target.height),
            CGSize(width: current.width, height: current.height),
        )
    }

    // MARK: Local cursor (Parsec model — host shape on the instant local pointer)

    /// Sets the local OS cursor to the host's CURRENT shape while the pointer is inside an ACTIVE pane
    /// and the host cursor is visible there; otherwise the plain arrow. The OS draws it at the live mouse
    /// position so there's no RTT lag, and macOS composites no host-position overlay so there's no
    /// duplicate. No-op unless the pointer is over this view (so a shape swap elsewhere can't hijack the
    /// global cursor).
    private func applyLocalCursor() {
        guard pointerInside else { return }
        if isActive, pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor {
            cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func layout() {
        super.layout()
        // macOS layer-HOSTING views (we assign `layer = videoLayer`) do NOT get contentsScale
        // auto-promoted to the window's backing scale — only layer-BACKED views do. A hosted
        // CAMetalLayer therefore stays at contentsScale 1.0, so `layoutChanged` computes
        // drawableSize = points × 1 (half-res on a 2× display) and the undersized drawable is
        // presented into a CORNER of the pane (the "nhỏ 1 góc" bug — and it also throws the
        // click mapping off, since input assumes the video fills the layer). Set the scale from
        // the window's backingScaleFactor BEFORE `layoutChanged` reads it. Never hardcode 2 (1×
        // external displays / Sidecar); fall back to the last good value so a window==nil
        // teardown layout never drops back to 1×. (Mirrors the iOS `layoutSubviews` site below.)
        let scale = window?.backingScaleFactor ?? videoLayer.contentsScale
        videoLayer.contentsScale = scale
        // Own the drawable's PIXEL size here in the VIEW, which ALWAYS lays out — NOT only in
        // the pipeline, which sets it solely once a renderer exists. `layout()` runs BEFORE
        // `activate()` builds the renderer, and on a stable size no relayout follows, so the
        // pipeline-only path left `drawableSize` unset for the whole session (proven by the
        // absent `layoutChanged` debug line) → an upscaled/blurry frame. Setting it directly
        // every pass mirrors the proven `GhosttyLayerBackedView.layout()`.
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }

    /// Fires on window-attach and when the view moves between Retina/non-Retina displays.
    /// Re-syncs the hosted layer's scale and re-lays-out so the drawable is sized for the new
    /// backing scale (the initial scale is set in `layout()`; this keeps it correct across moves).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard window != nil else { return } // can fire with window==nil during teardown
        videoLayer.contentsScale = window?.backingScaleFactor ?? videoLayer.contentsScale
        needsLayout = true
    }

    // MARK: Local navigation (zoom/pan) — responder methods, never gesture recognizers

    /// Trackpad pinch. `NSEvent.magnification` is the INCREMENTAL delta for this event, so
    /// `zoom *= (1 + magnification)` accumulates across the pinch. Drives the SAME pipeline
    /// zoom transform the host-input encoder inverts. Using the responder method (not
    /// `NSMagnificationGestureRecognizer`) leaves mouse click/drag delivery untouched.
    override func magnify(with event: NSEvent) {
        zoom = min(max(zoom * (1 + event.magnification), 1), 8)
        if zoom <= 1.001 { pan = .zero }
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = zoom > 1.001
    }

    private func applyToggleFill() {
        let next: VideoContentMode = (pipeline.contentMode == .fit) ? .fill : .fit
        pipeline.setContentMode(next)
        controls?.mode = next
    }

    private func applyResetZoom() {
        zoom = 1
        pan = .zero
        pipeline.setZoom(1, pan: .zero)
        controls?.zoomed = false
    }

    // MARK: Input forwarding (view space → normalised → host)

    private func viewPoint(_ event: NSEvent) -> VideoPoint {
        // Convert to this view's coordinates, then flip Y so origin is TOP-left (the
        // orientation the host window space + InputEventEncoder normalisation expect).
        let p = convert(event.locationInWindow, from: nil)
        return VideoPoint(x: Double(p.x), y: Double(bounds.height - p.y))
    }

    private func mods(_ event: NSEvent) -> InputModifiers { Self.modifiers(event.modifierFlags) }

    /// Clamps `NSEvent.clickCount` (an unbounded `Int` — AppKit keeps incrementing it for consecutive
    /// in-place clicks within the double-click interval) into the wire `UInt8`. `UInt8(clamping:)`
    /// saturates at 255 instead of the trapping `UInt8(Int)` that would crash the client on a 256th rapid
    /// click; identical for every real 1/2/3-click, and the host only uses it as a click-state hint
    /// (`max(1, Int(clickCount))`), so saturating is harmless (R14).
    nonisolated static func clampClickCount(_ n: Int) -> UInt8 { UInt8(clamping: n) }

    // Only the ACTIVE pane tracks hover (the "only the active pane swallows pointer" rule). A non-active
    // pane ignores hover so it never injects a stray remote mouse-move; you must click it first.
    override func mouseMoved(with event: NSEvent) {
        guard isActive else { return }
        pipeline.mouseMove(viewPoint(event))
    }

    // A drag (a button is HELD) is a DISTINCT NSView callback from a hover `mouseMoved`, so the
    // client KNOWS which button is down and forwards an explicit `.mouseDrag`; the host posts
    // the matching `*MouseDragged` STATELESSLY — no host-side held-button guess. NOT gated on
    // `isActive`: a drag only follows a `mouseDown` on THIS pane, which already activated it, so the
    // in-gesture frames must keep flowing even before SwiftUI re-renders `isActive` true.
    override func mouseDragged(with event: NSEvent) { pipeline.mouseDrag(
        .left,
        viewPoint(event),
        Self.clampClickCount(event.clickCount),
        mods(event),
    ) }
    override func rightMouseDragged(with event: NSEvent) { pipeline.mouseDrag(
        .right,
        viewPoint(event),
        Self.clampClickCount(event.clickCount),
        mods(event),
    ) }
    // CLICK = ACTIVATE: a mouseDown makes this the active pane (`onActivate` → workspace focus) AND
    // raises the host window to top (`focusWindow`), THEN lands as a remote click. This is the
    // "click to activate + raise GUI window on click" model (replaces the earlier hover-raise). The
    // activating click is always forwarded so clicking a control in a background window just works.
    override func mouseDown(with event: NSEvent) {
        // BUG-1 probe: clicking is the reported freeze trigger. Correlate this line with `cursorAPPLY`/
        // `RENDER` gaps (client main-actor block from focus()) and `mediaRX` gaps (host capture hitch on
        // window-raise) to see which path stalls on a click.
        videoViewDbg("click → activate isActive=\(isActive)")
        onActivate()
        // Send the host window-raise ONLY when (re)activating an UNfocused pane — not on every click of
        // an already-active pane. The host raise is best-effort + costly (AX IPC); re-raising on each
        // click of the focused pane is wasted work (the host throttles redundant raises as a backstop).
        if !isActive { pipeline.focusWindow() }
        pipeline.mouseDown(.left, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func mouseUp(with event: NSEvent) { pipeline.mouseUp(
        .left,
        viewPoint(event),
        Self.clampClickCount(event.clickCount),
        mods(event),
    ) }
    override func rightMouseDown(with event: NSEvent) {
        onActivate()
        if !isActive { pipeline.focusWindow() }
        pipeline.mouseDown(.right, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseUp(with event: NSEvent) { pipeline.mouseUp(
        .right,
        viewPoint(event),
        Self.clampClickCount(event.clickCount),
        mods(event),
    ) }
    override func scrollWheel(with event: NSEvent) {
        // Zoomed in (local crop): a two-finger scroll pans the LOCAL view so you can reach the off-screen
        // parts of the zoomed window. This is the ONE case where a scroll stays INSIDE the pane, and it is
        // independent of canvas focus. (At 1× the renderer clamps panLimit to 0, so a local pan is inert
        // anyway — fall through to the canvas pan below.)
        if zoom > 1.001 {
            let invZoom = 1.0 / Double(zoom)
            pan.x = CGFloat(min(
                max(Double(pan.x) - Double(event.scrollingDeltaX) / Double(max(bounds.width, 1)) * invZoom, -0.5),
                0.5,
            ))
            pan.y = CGFloat(min(
                max(Double(pan.y) - Double(event.scrollingDeltaY) / Double(max(bounds.height, 1)) * invZoom, -0.5),
                0.5,
            ))
            pipeline.setZoom(zoom, pan: pan)
            return
        }
        // SCROLL ROUTING (1× zoom) — gated on EXPLICIT canvas focus (`isActive == store.isFocused(id)`),
        // the desktop model the user asked for ("khi focus vào pane gui rồi, pane gui phải nuốt scroll"):
        //   • FOCUSED pane   → forward the scroll to the REMOTE window (you clicked in, you're scrolling
        //     its content). Forwarding is a UDP send — no `@Observable` mutation, so it never blocks the
        //     stream. Mirrors the terminal pane's focused-scrollback rule.
        //   • UNFOCUSED pane → PAN THE CANVAS, never swallow — so panning across a background pane keeps
        //     navigating instead of stopping at its edge. Routed through the debounced `onCanvasScroll`
        //     accumulator (NOT a per-step commitCamera), so it never blocks the stream either.
        //   • ⌥ held         → ALWAYS pan the canvas, even while focused (escape hatch to pan a focused
        //     pane without first unfocusing it).
        // Natural-scroll sign matches `CanvasView.PanView` so a pane-pan feels identical to the bg pan.
        if isActive, !event.modifierFlags.contains(.option) {
            videoViewDbg("scroll → remote (focused)")
            pipeline.scroll(
                dx: Double(event.scrollingDeltaX),
                dy: Double(event.scrollingDeltaY),
                viewPoint: viewPoint(event),
            )
            return
        }
        let dx: CGFloat, dy: CGFloat
        if event.hasPreciseScrollingDeltas { dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else { dx = event.scrollingDeltaX * 10
            dy = event.scrollingDeltaY * 10
        }
        videoViewDbg("scroll → canvas pan d=(\(Int(-dx)),\(Int(-dy))) isActive=\(isActive)")
        onCanvasScroll(CGSize(width: -dx, height: -dy))
    }

    // ALL keys (printable + special) go through the layout-level keycode `.key` path so
    // the HOST's keyboard layout + input method (e.g. OpenKey/xkey Telex) interpret and
    // COMPOSE them server-side — exactly like Parsec/VNC/Screen-Sharing "scancode mode".
    // The old `.text` path posted a virtualKey-0 CGEvent + keyboardSetUnicodeString, which
    // is invisible to an IME's keycode-driven composer (OpenKey reads only the virtual
    // keycode + shift/caps flag, never the event's Unicode string), so the pre-baked glyph
    // rode straight through and Vietnamese never composed (`tieesng` inserted literally).
    // Forwarding the real keycode + modifier flags lets the host IME compose normally.
    //
    // We send ONLY `.key` per keypress (never `.key` + `.text` together) — sending both was
    // the old duplicate-character bug, because the host injects a char from EACH path.
    // The `.text` / pipeline.text(...) / host `postText` plumbing stays in place (now unused
    // by live typing) for future layout-independent input such as clipboard paste.
    override func keyDown(with event: NSEvent) {
        pipeline.key(keyCode: event.keyCode, down: true, modifiers: mods(event))
    }

    override func keyUp(with event: NSEvent) {
        pipeline.key(keyCode: event.keyCode, down: false, modifiers: mods(event))
    }

    // Modifier press/release. Without this, ⌘/⇧/⌃/⌥ are NEVER sent as discrete key
    // events — they only ride as per-event flags on key/mouse events. On the host
    // `postKey` posts a CGEvent whose flags come from those per-event mods, but the
    // shared `CGEventSource(stateID:.hidSystemState)` LATCHES modifier state: a ⌘ flag
    // injected on (say) Delete with no matching modifier KEY-UP stays latched and
    // corrupts every later `.text` insertion (e.g. ⌘+Delete then a stuck ⌘ turns the
    // next Return into a newline-with-⌘). Emitting the real modifier key-up here posts a
    // CGEvent that clears the latched flag. (`pipeline.key` already carries
    // keyCode+down+modifiers — no protocol change.)
    override func flagsChanged(with event: NSEvent) {
        guard let down = Self.modifierDown(keyCode: event.keyCode, flags: event.modifierFlags) else { return }
        pipeline.key(keyCode: event.keyCode, down: down, modifiers: mods(event))
    }

    override var acceptsFirstResponder: Bool { true }

    /// AppKit only delivers `mouseMoved` when a tracking area requests it, and
    /// `acceptsFirstResponder` alone does NOT focus a bare layer-backed view inside a
    /// SwiftUI sheet — so without these two the cursor-follow + keyboard input paths are
    /// dead. Install/refresh a tracking area for the visible bounds, and grab first
    /// responder when the view enters a window.
    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            // `.mouseEnteredAndExited` tracks whether the pointer is in the pane; `.cursorUpdate` makes
            // AppKit call `cursorUpdate(with:)` on each move so we re-assert the host's cursor shape.
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        pointerInside = true
        applyLocalCursor()
    }

    override func mouseExited(with _: NSEvent) {
        pointerInside = false
        NSCursor.arrow.set() // leaving the pane → restore the normal pointer
    }

    /// AppKit's per-move cursor callback while the pointer is in the pane: re-assert the host shape (or
    /// fall through to AppKit's default arrow) so a transient `.set()` from elsewhere can't win on a move.
    override func cursorUpdate(with event: NSEvent) {
        if isActive, pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor {
            cursor.set()
        } else {
            super.cursorUpdate(with: event) // AppKit already set the window's default (arrow) pre-callback
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
    }

    /// Restore the arrow when the view leaves its window (drag-out / pane close): a teardown that skipped
    /// `mouseExited` must not leave a stale host-shape cursor set.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { if pointerInside { NSCursor.arrow.set() }
            pointerInside = false
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> InputModifiers {
        var m: InputModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.capsLock) { m.insert(.capsLock) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }

    /// Pure: decide whether a `flagsChanged` keyCode is a modifier press (`down`) or a
    /// release. `flagsChanged` fires for BOTH edges with the same keyCode; the only way
    /// to tell them apart is to ask whether the corresponding modifier is still present
    /// in `flags` after the event. Returns `nil` for a keyCode that is not a known
    /// modifier (so the caller sends nothing). Factored out so the keyCode→modifier-mask
    /// mapping is unit-testable without an `NSEvent`.
    static func modifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        switch Int(keyCode) {
        case 55,
             54: flags.contains(.command) // ⌘ left / right
        case 56,
             60: flags.contains(.shift) // ⇧ left / right
        case 59,
             62: flags.contains(.control) // ⌃ left / right
        case 58,
             61: flags.contains(.option) // ⌥ left / right
        case 57: flags.contains(.capsLock) // ⇪
        case 63: flags.contains(.function) // fn
        default: nil
        }
    }
}

#elseif os(iOS)
import UIKit

/// `UIViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on iOS.
struct MetalVideoLayerView: UIViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls?
    // Accepted for signature parity with the macOS representable (the shared `VideoWindowView.body`
    // constructs both). iOS pane activation already runs through the canvas's per-pane SwiftUI tap
    // gesture + a background `DragGesture` for panning, so these are currently unused on iOS.
    var isActive: Bool = true
    var onActivate: () -> Void = {}
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?

    func makeUIView(context _: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.onStreamNativeSize = onStreamNativeSize // before activate — nil-ness picks snap vs host-follow
        view.activate(connection: connection)
        return view
    }

    func updateUIView(_ uiView: MetalLayerBackedView, context _: Context) {
        uiView.controls = controls
        uiView.onStreamNativeSize = onStreamNativeSize
        uiView.activate(connection: connection)
    }

    static func dismantleUIView(_ uiView: MetalLayerBackedView, coordinator _: ()) {
        uiView.deactivate()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the client pipeline. Adds VNC-style
/// pinch-to-zoom + one-finger pan (+ double-tap to reset) over the remote window.
final class MetalLayerBackedView: UIView, UIGestureRecognizerDelegate {
    override static var layerClass: AnyClass { CAMetalLayer.self }
    var videoLayer: CAMetalLayer {
        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("layerClass is CAMetalLayer, so the backing layer is always a CAMetalLayer")
        }
        return metalLayer
    }

    private let pipeline = VideoWindowPipeline()

    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var gestureBaseZoom: CGFloat = 1
    private var gestureBasePan: CGPoint = .zero
    private var gesturesInstalled = false
    /// Bridge to the SwiftUI control overlay (fit/fill toggle + zoom reset). Set by the
    /// representable before `activate`.
    weak var controls: VideoPaneControls?
    /// 1:1 PANE SNAP (see the macOS sibling): ask the canvas pane to resize its video content from
    /// `current` to `target` points. Set by the representable BEFORE ``activate(connection:)``.
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?

    func activate(connection: VideoWindowConnection?) {
        installGesturesIfNeeded()
        // 1:1 PANE SNAP — wire BEFORE pipeline.activate (nil-ness picks snap vs host-follow at
        // session construction; mirrors the macOS sibling).
        pipeline.onDecodedPixelSize = onStreamNativeSize == nil ? nil : { [weak self] px in
            self?.adoptStreamPixelSize(px)
        }
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        if connection != nil, let controls {
            controls.onToggleFill = { [weak self] in self?.applyToggleFill() }
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }

    func deactivate() { pipeline.deactivate() }

    /// 1:1 PANE SNAP: compute the point size at which this view renders the stream
    /// pixel-for-pixel, rebase the session's resize debounce (no host echo), then ask the pane
    /// to adopt it — mirrors the macOS sibling.
    private func adoptStreamPixelSize(_ pixelSize: VideoSize) {
        guard let handler = onStreamNativeSize else { return }
        let scale = videoLayer.contentsScale > 0 ? videoLayer.contentsScale : 1
        let target = StreamSizeSnap.targetPoints(pixelSize: pixelSize, contentsScale: Double(scale))
        pipeline.adoptLayerSize(target)
        let current = VideoSize(width: Double(bounds.width), height: Double(bounds.height))
        guard StreamSizeSnap.shouldSnap(target: target, current: current) else { return }
        handler(
            CGSize(width: target.width, height: target.height),
            CGSize(width: current.width, height: current.height),
        )
    }

    private func applyToggleFill() {
        let next: VideoContentMode = (pipeline.contentMode == .fit) ? .fill : .fit
        pipeline.setContentMode(next)
        controls?.mode = next
    }

    private func applyResetZoom() {
        zoom = 1
        pan = .zero
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = false
    }

    private func installGesturesIfNeeded() {
        guard !gesturesInstalled else { return }
        gesturesInstalled = true
        isUserInteractionEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        for g in [pinch, pan, doubleTap] as [UIGestureRecognizer] { g.delegate = self
            addGestureRecognizer(g)
        }
    }

    // Let pinch + pan run together (zoom while dragging).
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool { true }

    @objc
    private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { gestureBaseZoom = zoom }
        zoom = min(max(gestureBaseZoom * g.scale, 1), 8)
        if zoom <= 1.001 { pan = .zero }
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = zoom > 1.001
    }

    @objc
    private func onPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { gestureBasePan = pan }
        let t = g.translation(in: self)
        let invZoom = 1.0 / zoom
        pan.x = gestureBasePan.x - (t.x / max(bounds.width, 1)) * invZoom
        pan.y = gestureBasePan.y - (t.y / max(bounds.height, 1)) * invZoom
        pipeline.setZoom(zoom, pan: pan)
    }

    @objc
    private func onDoubleTap() { applyResetZoom() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Render at native Retina resolution: set the layer's contentsScale to the screen
        // scale so the pipeline's drawableSize (points × contentsScale) is the pixel size.
        let scale = window?.screen.scale ?? traitCollection.displayScale
        videoLayer.contentsScale = scale
        // Own drawableSize in the view (always lays out), same as the macOS sibling — so the
        // pixel size is correct regardless of renderer-activation ordering.
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }
}
#endif
#endif
