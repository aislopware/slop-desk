#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import QuartzCore
import CoreVideo
import CoreGraphics
import OSLog
import RworkVideoProtocol
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The `@MainActor` glue that owns the GUI objects (``MetalVideoRenderer`` +
/// ``ClientCursorCompositor``) and the orchestrator (``RworkVideoClientSession``) for
/// one remote GUI window, and bridges layout + input from the platform backing view.
///
/// `VideoWindowView`'s `NSView`/`UIView` holds one of these. It is the single place
/// that constructs the live pipeline (renderer, compositor, transport, session) on
/// activate and tears it down on deactivate, computes the videoScale each layout pass,
/// and forwards input events to the host through the session.
///
/// ⚠️ **GUI-ONLY:** constructs a Metal renderer + UDP transport + orchestrator (which
/// brings up a `VTDecompressionSession` + display link). NEVER instantiated in a test.
@MainActor
final class VideoWindowPipeline {
    private let log = Logger(subsystem: "rwork.video.client", category: "VideoWindowPipeline")

    /// UDP-mux injection point: the per-host shared-flow pool every pane vends its lane from. The app
    /// installs this ONCE at launch (``VideoMuxInstaller/install()``), so panes targeting the SAME host
    /// share ONE UDP flow via per-channelID lanes (``VideoConnectionRegistry``). Read at the per-pane
    /// transport construction site in ``activate(view:videoLayer:connection:maxFrameRate:)``. The host's
    /// `NWVideoMuxDatagramTransport` speaks the same 19-byte channelID-prefixed wire — the only video
    /// wire there is now.
    static var sharedRegistry: VideoConnectionRegistry?

    private var renderer: MetalVideoRenderer?
    private var compositor: ClientCursorCompositor?
    private var pacer: FramePacer?
    private var session: RworkVideoClientSession?
    private var activeConnection: VideoWindowConnection?
    private var layerSize: VideoSize = VideoSize(width: 0, height: 0)

    /// Client half of the input-latency fix: coalesce high-rate pointer motion to one send per
    /// display-refresh interval (most-recent-wins), so a 60-120 Hz trackpad does not spawn a Task
    /// per event and flood the wire + the session actor's mailbox. `pendingMotionSend` holds the
    /// latest deferred move/drag; `motionPump` flushes it every `motionInterval`; any button /
    /// scroll / key / text flushes it FIRST so a move that physically preceded a click is never
    /// sent after it (noVNC `_flushMouseMoveTimer` / TigerVNC `pointerEventInterval`). The host
    /// additionally coalesces whatever still arrives, so this is a bandwidth/CPU optimisation
    /// layered on a correctness fix that already holds host-side.
    /// The latest deferred move/drag as an `async` action (the actual `session.sendMouseMove/Drag`
    /// await), NOT a fire-and-forget `Task`. Storing the bare async work lets a button event fold
    /// the flush + the button into ONE ordered hop (`takePendingMotion()`), while the motion pump
    /// still fire-and-forgets it on its own tick (`flushPendingMotion()`).
    private var pendingMotionSend: (@Sendable () async -> Void)?
    private var motionPump: Task<Void, Never>?
    private var motionInterval: TimeInterval = 1.0 / 30.0

    /// SINGLE ordered outbound-input FIFO + its one consumer. Every input send (move/drag/down/up/
    /// scroll/key/text) is ENQUEUED here synchronously on the @MainActor (no `await` between a
    /// pending-move flush and the button that follows it), and a single consumer Task `await`s each
    /// action in enqueue = physical order. This replaces the per-event `Task { await … }` shape, which
    /// gave NO ordering guarantee: a `mouseDown` whose Task suspended on the pending-move flush let the
    /// following `mouseUp` Task (no flush → no suspension) reach the session actor FIRST, so the host
    /// received UP-before-DOWN → a suppressed up + a held-with-no-up down = a stuck button / phantom
    /// selection (and the same race could invert keyDown/keyUp). One FIFO makes order race-free.
    private var outboundContinuation: AsyncStream<@Sendable () async -> Void>.Continuation?
    private var outboundConsumer: Task<Void, Never>?

    #if os(macOS)
    typealias HostView = NSView
    #elseif canImport(UIKit)
    typealias HostView = UIView
    #endif

    /// Brings up the pipeline against `connection`, attaching the display link to
    /// `view`. Idempotent: re-activating with the same connection is a no-op; a
    /// different connection tears the old one down first. `maxFrameRate` caps the GUI
    /// video path (~24-30fps; NOT a 60/120fps game stream).
    func activate(view: HostView, videoLayer: CAMetalLayer, connection: VideoWindowConnection?, maxFrameRate: Double = 30.0) {
        guard let connection else { return } // no live host: chrome only (placeholder owns the idle UI)
        if activeConnection == connection, session != nil { return }
        deactivate()
        activeConnection = connection

        guard let renderer = MetalVideoRenderer(metalLayer: videoLayer) else {
            log.error("MetalVideoRenderer init failed — no Metal device")
            return
        }
        let compositor = ClientCursorCompositor()
        videoLayer.addSublayer(compositor.cursorLayer)
        self.renderer = renderer
        self.compositor = compositor

        // The pacer pulls the newest decoded frame each vsync and renders it; the
        // render callback is main-confined (the renderer is `@MainActor`). The pacer's
        // callback is `@Sendable` and invoked on the display-link's main run loop.
        let pacer = FramePacer(maxFrameRate: maxFrameRate) { buffer in
            let box = UnsafeTransfer(buffer)
            Task { @MainActor in renderer.render(box.value) }
        }
        self.pacer = pacer

        // Initial viewport from the current layer size (≥1 so the hello carries a
        // sane size even before the first layout pass).
        let viewport = VideoSize(width: max(1, layerSize.width), height: max(1, layerSize.height))
        // UDP-mux: vend a per-channelID lane on the host's ONE shared UDP flow
        // (`VideoMuxClientTransport`). Panes targeting the same host share ONE flow via the registry,
        // which the app installs once at launch. The host's `NWVideoMuxDatagramTransport` speaks the
        // matching 19-byte channelID-prefixed wire — the only video wire now.
        guard let registry = Self.sharedRegistry else {
            log.error("VideoConnectionRegistry not installed — cannot bring up video pane")
            return
        }
        let host = connection.host, mediaPort = connection.mediaPort, cursorPort = connection.cursorPort
        let transport: any VideoClientTransport = VideoMuxClientTransport(
            host: host, mediaPort: mediaPort, cursorPort: cursorPort,
            acquire: { await registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort) },
            release: { channelID in await registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: channelID) }
        )

        // GUI hooks: each hops to the main actor to touch the (main-confined) pacer /
        // compositor. The orchestrator actor calls these from its own executor.
        let gui = RworkVideoClientSession.GUIHooks(
            submitDecodedFrame: { buffer in
                // CVImageBuffer is a CoreVideo handle (not Sendable); after decode it is
                // read-only for our render path, so we ferry it across the isolation
                // boundary in an unchecked-Sendable box (the idiomatic escape hatch for
                // immutable CV/CG handles under strict concurrency). The pacer's submit
                // is internally locked, so the main hop only re-presents at vsync.
                pacer.submit(buffer)
            },
            applyCursor: { [weak compositor] update, placement in
                Task { @MainActor in
                    compositor?.apply(update, viewSize: placement.viewSize, videoNativeSize: placement.videoNativeSize, zoom: placement.zoom, pan: placement.pan, mode: placement.mode)
                }
            },
            registerCursorShape: { [weak compositor] image, logicalSize, shapeID in
                let box = UnsafeTransfer(image)
                Task { @MainActor in compositor?.registerShape(box.value, logicalSize: logicalSize, for: shapeID) }
            }
        )

        let session = RworkVideoClientSession(
            requestedWindowID: connection.windowID,
            viewport: viewport,
            transport: transport,
            gui: gui
        )
        self.session = session

        // Start the display link (attached to the on-screen view) + the orchestrator.
        pacer.start(view: view)
        Task { try? await session.start() }
        let initialSize = layerSize
        Task { await session.setLayerSize(initialSize) }

        // Bring up the single ordered outbound-input consumer before any input can be enqueued.
        startOutboundConsumer()
        // Drive the motion-coalescing pump at the same cadence as the video frame cap.
        motionInterval = 1.0 / max(1, maxFrameRate)
        startMotionPump()
    }

    /// Tears the pipeline + display link + sockets down (called on disappear/dismantle).
    ///
    /// `session.stop()` (which closes the two UDP `NWConnection`s, the `VTDecompressionSession`,
    /// and the display link) is `async` and cannot be awaited here — this runs on SwiftUI's
    /// synchronous `dismantleNSView`, so it is fire-and-forget. The cap-accounting owner
    /// (``WorkspaceStore``) cannot reach this view-owned pipeline to await the real release, AND the
    /// lag it must cover is the FULL close→SwiftUI-dismantle→deactivate→stop chain (not just stop),
    /// so it holds the live-video slot for a small bounded `videoTeardownSettle` past teardown
    /// instead (FIX #4). Over-holding fails safe (at worst a brief admission delay at the cap).
    func deactivate() {
        stopMotionPump()
        stopOutboundConsumer()
        pacer?.stop()
        if let session {
            Task { await session.stop() }
        }
        compositor?.cursorLayer.removeFromSuperlayer()
        session = nil
        renderer = nil
        compositor = nil
        pacer = nil
        activeConnection = nil
    }

    /// Called each layout pass with the on-screen layer size (points). Updates the
    /// session's layer size, which recomputes `videoScale = layerSize / decodedSize`
    /// and re-places the cursor overlay.
    func layoutChanged(layerSize: VideoSize) {
        self.layerSize = layerSize
        // `layerSize` is in POINTS (the cursor/videoScale denominator stays in points). The
        // Metal DRAWABLE, however, must be sized in PIXELS — drawableSize = points ×
        // contentsScale — or the layer renders at 1× and the display upscales it to the Retina
        // screen, which looks badly BLURRED (the bug: drawableSize was set to the point size).
        if let layer = renderer?.metalLayer {
            let scale = layer.contentsScale > 0 ? layer.contentsScale : 1
            layer.drawableSize = CGSize(width: layerSize.width * scale, height: layerSize.height * scale)
            if ProcessInfo.processInfo.environment["RWORK_VIDEO_DEBUG"] != nil {
                // Proof the contentsScale fix took: on Retina this must read scale=2.0 and a
                // drawable = 2× the point size. scale=1.0 here is the "nhỏ 1 góc" regression.
                FileHandle.standardError.write(Data("Rwork[video.client]: layoutChanged layer=\(Int(layerSize.width))x\(Int(layerSize.height))pt contentsScale=\(scale) drawable=\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))px\n".utf8))
            }
        }
        guard let session else { return }
        Task { await session.setLayerSize(layerSize) }
    }

    /// VNC-style zoom/pan, forwarded to the renderer (applied as a UV crop next vsync)
    /// AND to the session, so the input encoder inverts — and the cursor overlay tracks —
    /// the EXACT SAME transform. Both must move together or a click while zoomed lands at
    /// the un-zoomed source position.
    func setZoom(_ zoom: CGFloat, pan: CGPoint) {
        renderer?.zoom = zoom
        renderer?.panNormalized = pan
        if let session {
            let z = Double(zoom)
            let p = VideoPoint(x: Double(pan.x), y: Double(pan.y))
            Task { await session.setZoom(z, pan: p) }
        }
    }

    /// fit ↔ fill content mode, forwarded to the renderer (changes the quad's cover/contain
    /// scale next vsync — the pacer re-presents the last frame so it applies live on a static
    /// window) AND to the session, so the input encoder inverts — and the cursor overlay
    /// tracks — the EXACT SAME displayed rect. Both must move together or a click in `.fill`
    /// lands against the `.fit` letterbox rect.
    func setContentMode(_ mode: VideoContentMode) {
        renderer?.contentMode = mode
        if let session {
            Task { await session.setContentMode(mode) }
        }
    }

    /// The current content mode the renderer is showing (so the backing view's toggle button
    /// can reflect + flip it). Defaults to `.fit` before the renderer is up.
    var contentMode: VideoContentMode { renderer?.contentMode ?? .fit }

    // MARK: Input forwarding

    func mouseMove(_ viewPoint: VideoPoint) {
        guard let session else { return }
        // Coalesce: defer to the motion pump (most-recent-wins) instead of a Task per event. Stored
        // as the bare async send so a following button can fold it into one ordered hop.
        pendingMotionSend = { await session.sendMouseMove(viewPoint: viewPoint) }
    }
    func mouseDrag(_ button: MouseButton, _ viewPoint: VideoPoint, _ clickCount: UInt8, _ modifiers: InputModifiers) {
        guard let session else { return }
        pendingMotionSend = { await session.sendMouseDrag(button: button, viewPoint: viewPoint, clickCount: clickCount, modifiers: modifiers) }
    }
    func mouseDown(_ button: MouseButton, _ viewPoint: VideoPoint, _ clickCount: UInt8, _ modifiers: InputModifiers) {
        guard let session else { return }
        // Flush any pending move, THEN the button — both enqueued onto the ONE ordered FIFO with no
        // `await` between, so they reach the session actor in physical order (move, then down). The
        // single consumer can never let a later event overtake this one (the old per-event-Task race).
        submitFlushingMotion { await session.sendMouseDown(button: button, viewPoint: viewPoint, clickCount: clickCount, modifiers: modifiers) }
    }
    func mouseUp(_ button: MouseButton, _ viewPoint: VideoPoint, _ clickCount: UInt8, _ modifiers: InputModifiers) {
        guard let session else { return }
        submitFlushingMotion { await session.sendMouseUp(button: button, viewPoint: viewPoint, clickCount: clickCount, modifiers: modifiers) }
    }
    func scroll(dx: Double, dy: Double, viewPoint: VideoPoint) {
        guard let session else { return }
        submitFlushingMotion { await session.sendScroll(dx: dx, dy: dy, viewPoint: viewPoint) }
    }
    func key(keyCode: UInt16, down: Bool, modifiers: InputModifiers) {
        guard let session else { return }
        submitFlushingMotion { await session.sendKey(keyCode: keyCode, down: down, modifiers: modifiers) }
    }
    func text(_ string: String) {
        guard let session else { return }
        submitFlushingMotion { await session.sendText(string) }
    }

    // MARK: Motion pump (client-side coalescing)

    /// Starts the @MainActor pump that flushes the latest deferred pointer motion every
    /// `motionInterval`. Idle ticks are a no-op (nothing pending). Restarted on each activate.
    private func startMotionPump() {
        motionPump?.cancel()
        let interval = motionInterval
        motionPump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self?.flushPendingMotion()
            }
        }
    }

    private func stopMotionPump() {
        motionPump?.cancel()
        motionPump = nil
        pendingMotionSend = nil
    }

    /// Send the latest deferred pointer motion now (most-recent-wins), if any. Used by the motion
    /// pump's own tick — enqueued onto the SAME ordered FIFO so it can never be reordered against a
    /// button/key event that races the tick (both run on the @MainActor; the FIFO holds their order).
    private func flushPendingMotion() {
        guard let send = takePendingMotion() else { return }
        outboundContinuation?.yield(send)
    }

    // MARK: Ordered outbound-input FIFO

    /// Brings up the single consumer that drains the outbound FIFO in enqueue order, awaiting each
    /// send before the next. One consumer = strict in-order delivery to the session actor.
    private func startOutboundConsumer() {
        stopOutboundConsumer()
        let stream = AsyncStream<@Sendable () async -> Void> { continuation in
            self.outboundContinuation = continuation
        }
        outboundConsumer = Task { [weak self] in
            for await action in stream {
                if Task.isCancelled { break }
                await action()
            }
            _ = self // keep the pipeline alive for the consumer's lifetime
        }
    }

    private func stopOutboundConsumer() {
        outboundContinuation?.finish()
        outboundContinuation = nil
        outboundConsumer?.cancel()
        outboundConsumer = nil
        pendingMotionSend = nil
    }

    /// Enqueues `action` onto the ordered FIFO, FIRST flushing any pending coalesced move so the move
    /// always precedes the button/key/scroll that follows it (atomic on the @MainActor — no `await`
    /// between the two yields, so nothing can interleave). This is the single ordered hop that
    /// replaces the per-event Tasks (the up-before-down / keyDown-after-keyUp race fix).
    private func submitFlushingMotion(_ action: @escaping @Sendable () async -> Void) {
        if let move = takePendingMotion() { outboundContinuation?.yield(move) }
        outboundContinuation?.yield(action)
    }

    /// Hand back (and clear) the latest deferred pointer motion as a bare async action, WITHOUT
    /// sending it. The caller (a button/scroll/key/text event) awaits this BEFORE its own send in
    /// the SAME Task, so the flushed move and the button reach the actor in physical order — the
    /// single-ordered-hop invariant the inbound path also follows (no Task-per-item race).
    private func takePendingMotion() -> (@Sendable () async -> Void)? {
        guard let send = pendingMotionSend else { return nil }
        pendingMotionSend = nil
        return send
    }
}

/// Ferries a non-`Sendable` reference handle (a CoreVideo / CoreGraphics image buffer)
/// across an isolation boundary. SAFE here because the decoded `CVImageBuffer` and the
/// cursor `CGImage` are effectively immutable for the render / register path: the
/// decoder hands ownership to the pacer (most-recent-wins), and the renderer only
/// reads. This is the documented escape hatch for immutable CV/CG handles under strict
/// concurrency — NOT a license to mutate shared state.
struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif
