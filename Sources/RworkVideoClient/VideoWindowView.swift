#if canImport(SwiftUI) && canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import SwiftUI
import QuartzCore
import Metal
import CoreVideo
import RworkVideoProtocol

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
/// ``MetalVideoRenderer`` + ``ClientCursorCompositor`` + ``RworkVideoClientSession``,
/// starts the orchestrator on appear and stops it on disappear, drives the decoded-
/// frame → renderer path through the ``FramePacer`` display link, and forwards input.
///
/// Each layout pass it computes `videoScale = layerSize / decodedFrameSize` and feeds
/// it to ``ClientCursorCompositor`` (via the session) so the composited cursor lands
/// on the right pixel.
///
/// ⚠️ **GUI-ONLY:** instantiating the renderer / decoder / display link / sockets
/// needs a real device + screen + TCC. COMPILED + reviewed; not driven from tests.
/// This is the wiring point `RworkClientUI` injects via `VideoWindowFactory`.
public struct VideoWindowView: View {
    /// The remote window's title, shown for accessibility.
    public let title: String
    /// `nil` ⇒ no live connection (the seam's placeholder path / preview). When set,
    /// the backing view brings up the full client pipeline.
    public let connection: VideoWindowConnection?

    /// The existing seam signature (title-only): renders the Metal-backed view chrome
    /// without a live connection. Kept so `VideoWindowFactory` callers compile.
    public init(title: String) {
        self.title = title
        self.connection = nil
    }

    /// Live remote-window view: brings up the orchestrator against `connection`.
    public init(title: String, connection: VideoWindowConnection) {
        self.title = title
        self.connection = connection
    }

    /// Owns the control bridge for this view's lifetime; the backing view wires its closures.
    @StateObject private var controls = VideoPaneControls()

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MetalVideoLayerView(connection: connection, controls: controls)
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
/// `NSViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on macOS.
struct MetalVideoLayerView: NSViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls? = nil

    func makeNSView(context: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.activate(connection: connection)
        return view
    }

    func updateNSView(_ nsView: MetalLayerBackedView, context: Context) {
        nsView.controls = controls
        nsView.activate(connection: connection)
    }

    static func dismantleNSView(_ nsView: MetalLayerBackedView, coordinator: ()) {
        nsView.deactivate()
    }
}

/// A layer-backed `NSView` whose backing layer is a `CAMetalLayer`, with a cursor
/// overlay layer on top. It owns the client pipeline for its lifetime.
final class MetalLayerBackedView: NSView {
    let videoLayer = CAMetalLayer()
    private let pipeline = VideoWindowPipeline()

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
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func makeBackingLayer() -> CALayer { videoLayer }

    func activate(connection: VideoWindowConnection?) {
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        // Wire the SwiftUI overlay's buttons to THIS view's pipeline (live connection only).
        if connection != nil, let controls {
            controls.onToggleFill = { [weak self] in self?.applyToggleFill() }
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }
    func deactivate() { pipeline.deactivate() }

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
        zoom = 1; pan = .zero
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

    override func mouseMoved(with event: NSEvent) { pipeline.mouseMove(viewPoint(event)) }
    // A drag (a button is HELD) is a DISTINCT NSView callback from a hover `mouseMoved`, so the
    // client KNOWS which button is down and forwards an explicit `.mouseDrag`; the host posts
    // the matching `*MouseDragged` STATELESSLY — no host-side held-button guess. (No local
    // gesture interception here — that is what previously left the remote button stuck.)
    override func mouseDragged(with event: NSEvent) { pipeline.mouseDrag(.left, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func rightMouseDragged(with event: NSEvent) { pipeline.mouseDrag(.right, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func mouseDown(with event: NSEvent) { pipeline.mouseDown(.left, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func mouseUp(with event: NSEvent) { pipeline.mouseUp(.left, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func rightMouseDown(with event: NSEvent) { pipeline.mouseDown(.right, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func rightMouseUp(with event: NSEvent) { pipeline.mouseUp(.right, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func scrollWheel(with event: NSEvent) {
        // Zoomed in → two-finger scroll PANS the local view (reach the off-screen crop). At 1×
        // it forwards as a remote scroll (the renderer clamps panLimit to 0 at 1× anyway, so a
        // local pan would be inert). Scroll is separate from clicks, so this can't stick a button.
        if zoom > 1.001 {
            let invZoom = 1.0 / Double(zoom)
            pan.x = CGFloat(min(max(Double(pan.x) - Double(event.scrollingDeltaX) / Double(max(bounds.width, 1)) * invZoom, -0.5), 0.5))
            pan.y = CGFloat(min(max(Double(pan.y) - Double(event.scrollingDeltaY) / Double(max(bounds.height, 1)) * invZoom, -0.5), 0.5))
            pipeline.setZoom(zoom, pan: pan)
            return
        }
        pipeline.scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), viewPoint: viewPoint(event))
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
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
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
        case 55, 54: return flags.contains(.command)   // ⌘ left / right
        case 56, 60: return flags.contains(.shift)     // ⇧ left / right
        case 59, 62: return flags.contains(.control)   // ⌃ left / right
        case 58, 61: return flags.contains(.option)    // ⌥ left / right
        case 57:     return flags.contains(.capsLock)  // ⇪
        case 63:     return flags.contains(.function)  // fn
        default:     return nil
        }
    }
}

#elseif os(iOS)
import UIKit
/// `UIViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on iOS.
struct MetalVideoLayerView: UIViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls? = nil

    func makeUIView(context: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.activate(connection: connection)
        return view
    }
    func updateUIView(_ uiView: MetalLayerBackedView, context: Context) {
        uiView.controls = controls
        uiView.activate(connection: connection)
    }
    static func dismantleUIView(_ uiView: MetalLayerBackedView, coordinator: ()) {
        uiView.deactivate()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the client pipeline. Adds VNC-style
/// pinch-to-zoom + one-finger pan (+ double-tap to reset) over the remote window.
final class MetalLayerBackedView: UIView, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var videoLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let pipeline = VideoWindowPipeline()

    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var gestureBaseZoom: CGFloat = 1
    private var gestureBasePan: CGPoint = .zero
    private var gesturesInstalled = false
    /// Bridge to the SwiftUI control overlay (fit/fill toggle + zoom reset). Set by the
    /// representable before `activate`.
    weak var controls: VideoPaneControls?

    func activate(connection: VideoWindowConnection?) {
        installGesturesIfNeeded()
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        if connection != nil, let controls {
            controls.onToggleFill = { [weak self] in self?.applyToggleFill() }
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }
    func deactivate() { pipeline.deactivate() }

    private func applyToggleFill() {
        let next: VideoContentMode = (pipeline.contentMode == .fit) ? .fill : .fit
        pipeline.setContentMode(next)
        controls?.mode = next
    }
    private func applyResetZoom() {
        zoom = 1; pan = .zero
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = false
    }

    private func installGesturesIfNeeded() {
        guard !gesturesInstalled else { return }
        gesturesInstalled = true
        isUserInteractionEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        for g in [pinch, pan, doubleTap] as [UIGestureRecognizer] { g.delegate = self; addGestureRecognizer(g) }
    }

    // Let pinch + pan run together (zoom while dragging).
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { gestureBaseZoom = zoom }
        zoom = min(max(gestureBaseZoom * g.scale, 1), 8)
        if zoom <= 1.001 { pan = .zero }
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = zoom > 1.001
    }
    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { gestureBasePan = pan }
        let t = g.translation(in: self)
        let invZoom = 1.0 / zoom
        pan.x = gestureBasePan.x - (t.x / max(bounds.width, 1)) * invZoom
        pan.y = gestureBasePan.y - (t.y / max(bounds.height, 1)) * invZoom
        pipeline.setZoom(zoom, pan: pan)
    }
    @objc private func onDoubleTap() { applyResetZoom() }

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
