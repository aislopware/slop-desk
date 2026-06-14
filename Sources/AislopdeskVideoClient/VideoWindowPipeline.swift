#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import AislopdeskVideoProtocol
import CoreGraphics
import CoreVideo
import Foundation
import OSLog
import QuartzCore
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The `@MainActor` glue that owns the GUI objects (``MetalVideoRenderer`` +
/// ``ClientCursorCompositor``) and the orchestrator (``AislopdeskVideoClientSession``) for
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
    private let log = Logger(subsystem: "aislopdesk.video.client", category: "VideoWindowPipeline")

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
    private var session: AislopdeskVideoClientSession?
    private var activeConnection: VideoWindowConnection?
    private var layerSize: VideoSize = .init(width: 0, height: 0)

    /// INBOUND cursor-overlay coalescing (BUG-1 freeze fix). The ~120 Hz cursor stream used to spawn ONE
    /// `Task { @MainActor in compositor.apply }` PER packet. When a click flips workspace focus, the
    /// resulting synchronous SwiftUI re-render holds the MAIN ACTOR for a span; every queued cursor Task
    /// is head-of-line-blocked behind it, then drains as a BURST of now-stale positions — the overlay
    /// "freezes for a moment, then lurches". (The host keeps emitting fine — verified — so the freeze is
    /// purely client main-actor contention, which is why the prior host-side off-main fix changed
    /// nothing.) The coalescer keeps only the LATEST update+placement (most-recent-wins) and schedules at
    /// most ONE flush Task at a time, so a busy span collapses to a SINGLE fresh apply the instant the
    /// actor frees — no stale burst, and 120 Tasks/s never pile up. Mirrors the OUTBOUND `motionPump`
    /// most-recent-wins discipline above.
    private var pendingCursorUpdate: CursorUpdate?
    private var pendingCursorPlacement: AislopdeskVideoClientSession.CursorPlacement?
    private var cursorFlushScheduled = false

    /// Whether the server (host) cursor overlay is CURRENTLY visible — the latest applied
    /// ``CursorUpdate/visible`` flag (the host reports `true` only while its mouse is inside the captured
    /// window, so this is `false` in `.fit` letterbox margins or when the host hides its own cursor). The
    /// macOS backing view reads this to decide whether to hide the LOCAL OS arrow while the pointer is
    /// inside an active pane, so the host-streamed cursor and the OS cursor don't BOTH show ("duplicate
    /// cursor"). Defaults `false` (no overlay yet ⇒ keep the OS arrow).
    private(set) var isServerCursorVisible = false
    /// Fired on the @MainActor whenever ``isServerCursorVisible`` FLIPS (not per 120 Hz packet). The
    /// backing view re-evaluates its OS-cursor decision. Set by the view in `activate`; `nil` on iOS.
    var onServerCursorVisibilityChanged: ((Bool) -> Void)?

    /// 1:1 PANE SNAP: fired on the @MainActor when the stream's decoded PIXEL size changes (first
    /// decoded frame, or the first frame at a new capture size after a host-side resize). Carries
    /// the raw pixel dims; the view derives the 1:1 point size from its own `contentsScale`
    /// (``StreamSizeSnap``) and snaps its canvas pane. MUST be set (or left nil) BEFORE
    /// ``activate(view:videoLayer:connection:maxFrameRate:)`` — its nil-ness decides at session
    /// construction whether the pane follows the stream (snap) or the legacy connect-time
    /// host-follow negotiation runs (standalone windows).
    var onDecodedPixelSize: ((VideoSize) -> Void)?

    #if os(macOS)
    /// The LOCAL `NSCursor` mirroring the host's CURRENT cursor SHAPE (Parsec model: the OS draws it at
    /// the instant local mouse position, so the pointer never lags by an RTT). `nil` until the shape
    /// bitmap arrives → the view shows the plain arrow. Rebuilt only when the host shapeID changes.
    private(set) var currentRemoteCursor: NSCursor?
    private var currentRemoteCursorShapeID: UInt16?
    /// Fired on the @MainActor when ``currentRemoteCursor`` changes (host swapped cursor shape). The
    /// backing view re-applies it so the shape updates even while the mouse is stationary.
    var onRemoteCursorChanged: (() -> Void)?
    #endif

    /// BUG-1 freeze LOCALISATION (env-gated `AISLOPDESK_VIDEO_DEBUG`). Monotonic gap probes on the two
    /// MAIN-ACTOR paths whose stall the user perceives as "the pointer freezes when I click back": the
    /// cursor APPLY (``coalesceCursor``) and the video RENDER hop. Compared against the SESSION-ACTOR cursor
    /// RX probe in ``AislopdeskVideoClientSession``: if RX gaps stay SMALL on click-back while these spike, the
    /// freeze is a main-actor BLOCK (the click→focus SwiftUI re-render holding the main thread), which the
    /// coalescer cannot shorten — not a host/network stall. Decisive data instead of a 4th blind guess.
    private static let dbgGapEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil
    private var dbgLastCursorApply: Double = 0
    private var dbgLastRender: Double = 0

    /// Client half of the input-latency fix: coalesce high-rate HOVER motion to one send per
    /// display-refresh interval (most-recent-wins), so a 60-120 Hz trackpad does not spawn a Task
    /// per event and flood the wire + the session actor's mailbox. `pendingMotionSend` holds the
    /// latest deferred hover move; `motionPump` flushes it every `motionInterval`; any drag /
    /// button / scroll / key / text flushes it FIRST so a move that physically preceded it is never
    /// sent after it (noVNC `_flushMouseMoveTimer` / TigerVNC `pointerEventInterval`). The host
    /// additionally coalesces whatever still arrives, so this is a bandwidth/CPU optimisation
    /// layered on a correctness fix that already holds host-side. DRAGS no longer defer here
    /// (2026-06-10 select-text latency — see `mouseDrag`): they are feedback-critical, so they ride
    /// the ordered FIFO immediately like buttons/scroll.
    /// The latest deferred hover move as an `async` action (the actual `session.sendMouseMove`
    /// await), NOT a fire-and-forget `Task`. Storing the bare async work lets a following event fold
    /// the flush + itself into ONE ordered hop (`takePendingMotion()`), while the motion pump
    /// still fire-and-forgets it on its own tick (`flushPendingMotion()`).
    private var pendingMotionSend: (@Sendable () async -> Void)?
    private var motionPump: Task<Void, Never>?
    private var motionInterval: TimeInterval = 1.0 / 120.0

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
    func activate(
        view: HostView,
        videoLayer: CAMetalLayer,
        connection: VideoWindowConnection?,
        maxFrameRate: Double = 60.0,
    ) {
        guard let connection else { return } // no live host: chrome only (placeholder owns the idle UI)
        if activeConnection == connection, session != nil { return }
        deactivate()
        activeConnection = connection

        guard let renderer = MetalVideoRenderer(metalLayer: videoLayer) else {
            log.error("MetalVideoRenderer init failed — no Metal device")
            return
        }
        let compositor = ClientCursorCompositor()
        #if !os(macOS)
        // iOS composites the host cursor POSITION as an overlay layer. macOS instead draws the host
        // SHAPE on the LOCAL OS cursor at the instant mouse position (Parsec model — see flushCursor),
        // so it does NOT add the position overlay (that would re-introduce a duplicate, RTT-lagged cursor).
        videoLayer.addSublayer(compositor.cursorLayer)
        #endif
        self.renderer = renderer
        self.compositor = compositor

        // The pacer drains its jitter buffer one frame per vsync and renders; the render
        // callback is main-confined (the renderer is `@MainActor`). The pacer's callback is
        // `@Sendable` and invoked on the display-link's main run loop. Jitter-buffer depths
        // are env-tunable for on-device A/B without a rebuild (`AISLOPDESK_JITTER_DEPTH` =
        // priming/slack frames ≈ added latency; `AISLOPDESK_JITTER_MAX` = hard cap before
        // dropping the oldest). Defaults 2 / 5 absorb the idle→scroll size-jump backlog at
        // ~33 ms latency.
        let env = ProcessInfo.processInfo.environment
        // LAT-2 (2026-06-09): default 3 → 2. At 60fps depth 2 ≈ 33ms standing buffer = Parsec's budget.
        // 2026-06-11 defaults consolidation: 2 → 1 (R4/R7 HW-validated "gần bằng parsec" state ran
        // depth 1; present-on-arrival — default ON — is depth-1-only, and the extra frame was pure
        // latency). `AISLOPDESK_JITTER_DEPTH=2` restores the slack frame for a jittery link A/B.
        let jitterDepth = env["AISLOPDESK_JITTER_DEPTH"].flatMap(Int.init).map { min(8, max(1, $0)) } ?? 1
        let jitterMax = env["AISLOPDESK_JITTER_MAX"].flatMap(Int.init).map { min(16, max(1, $0)) } ?? 5
        // Component 4 (adaptive pacer depth, 2026-06-11): network-late driven 1↔2 depth boost
        // (PacerDepthPolicy — pay latency only AFTER observed network lates, refund after a clean
        // dwell). v2's present-gap promotion pinned the depth at 2 on sub-cadence content
        // (structural — see PacerDepthPolicy header); v3 (2026-06-12) promotes on owd spikes
        // (`OwdLateDetector`), which can't self-sustain or misread content cadence — so the boost
        // is now DEFAULT ON (`AISLOPDESK_ADAPTIVE_DEPTH=0` restores fixed depth 1 for A/B).
        // TELEMETRY is NOT gated by this — the policy's late/gap counters always run and ride
        // every NetworkStats report.
        let adaptiveDepth = env["AISLOPDESK_ADAPTIVE_DEPTH"].map { !($0 == "0" || $0.lowercased() == "false") } ?? true
        let depthPolicyConfig = PacerDepthPolicy.Config.fromEnvironment(env)
        // Adaptive jitter buffer (default OFF ⇒ fixed depth exactly as today). When on, the pacer
        // self-measures decoded-frame arrival jitter and floats the depth between 1 and jitterMax:
        // it shrinks toward the latency floor on a clean LAN and re-inflates on a real spike/underrun.
        // v2 SUPERSEDES v1 (one writer of the live depth) — both set ⇒ v1 is forced off.
        let adaptiveV1Requested = env["AISLOPDESK_ADAPTIVE_JITTER"]
            .map { $0 == "1" || $0.lowercased() == "true" } ?? false
        let adaptive = adaptiveV1Requested && !adaptiveDepth
        if adaptiveV1Requested, adaptiveDepth, Self.dbgGapEnabled {
            FileHandle.standardError
                .write(
                    Data(
                        "Aislopdesk[video.client]: AISLOPDESK_ADAPTIVE_JITTER ignored — AISLOPDESK_ADAPTIVE_DEPTH (v2) supersedes v1\n"
                            .utf8,
                    ),
                )
        }
        // Present-on-arrival for a starved display (FramePacer header; select-text/typing feedback
        // latency). Default ON — it only fires where the old hold-for-vsync was strictly worse;
        // `AISLOPDESK_PRESENT_ON_ARRIVAL=0` restores the pure vsync-paced pacer for A/B.
        let presentOnArrival = env["AISLOPDESK_PRESENT_ON_ARRIVAL"]
            .map { !($0 == "0" || $0.lowercased() == "false") } ?? true
        // DISPLAY-NATIVE TICK (2026-06-10 latency audit): the link was hard-locked to the host
        // content fps (60), so on a 120 Hz ProMotion panel a decoded frame could sit up to a full
        // 16.7 ms waiting for the next tick. Resolve the tick rate from the view's ACTUAL screen
        // (floored at the content fps): worst-case hold halves, and at depth 1 the between-arrival
        // drain makes the dense stream present-on-arrival (see the FramePacer header).
        // `AISLOPDESK_TICK_HZ` overrides for A/B without a rebuild.
        #if os(macOS)
        let displayMaxHz = view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 0
        #else
        let displayMaxHz = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 0
        #endif
        let tickRate = FramePacer.resolveTickRate(
            envOverride: env["AISLOPDESK_TICK_HZ"],
            displayMaxHz: displayMaxHz,
            floor: maxFrameRate,
        )
        // DEADLINE PACER (AISLOPDESK_PACER=deadline; see the FramePacer header): schedule presentation
        // on the CONTENT rhythm with a small playout delay (AISLOPDESK_PLAYOUT_MS, default 20) instead
        // of on arrival events — the research-validated fix for jitter-induced "bunched frame"
        // stutter (WebRTC VCMTiming / Moonlight model).
        let deadlineMode = env["AISLOPDESK_PACER"]?.lowercased() == "deadline"
        let playoutMs = env["AISLOPDESK_PLAYOUT_MS"].flatMap(Double.init) ?? 20.0
        let contentFps = env["AISLOPDESK_CONTENT_FPS"].flatMap(Double.init) ?? 60.0
        let pacer = FramePacer(
            maxFrameRate: tickRate,
            targetDepth: jitterDepth,
            maxDepth: jitterMax,
            adaptiveJitter: adaptive,
            presentOnArrival: presentOnArrival,
            adaptiveDepth: adaptiveDepth,
            depthPolicyConfig: depthPolicyConfig,
            deadlineMode: deadlineMode,
            contentFps: contentFps,
            playoutDelayMs: playoutMs,
        ) { [weak self] buffer in
            // CAD-2 (2026-06-09 smoothness): present SYNCHRONOUSLY on the display-link tick instead of
            // hopping through `Task { @MainActor }`. The FramePacer is driven by `NSView.displayLink` /
            // `CADisplayLink`, which fires on the MAIN run loop — so this callback is ALREADY on the main
            // actor's executor. The old async `Task` deferred the render to a LATER main-actor slot, so a
            // frame could miss its own vsync (0-16ms present jitter under main-actor load = cadence khựng).
            // `assumeIsolated` runs it now, in-tick, landing the frame on THIS vsync. Safe: the only caller
            // (display-link `step()` → `tick()` → `frameForVSync()`) is main-thread; off-main would trap.
            // `UnsafeTransfer` boxes the non-Sendable CVImageBuffer across the @Sendable→@MainActor closure
            // boundary; it is sound here because the hand-off is SYNCHRONOUS (no escape, same thread/tick).
            let box = UnsafeTransfer(buffer)
            MainActor.assumeIsolated {
                renderer.render(box.value)
                self?.dbgNoteRender() // BUG-1: time consecutive MAIN-ACTOR renders (freeze localisation)
            }
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
            release: { channelID in await registry.release(
                host: host,
                mediaPort: mediaPort,
                cursorPort: cursorPort,
                channelID: channelID,
            ) },
        )

        // 1:1 PANE SNAP: only a view that wired `onDecodedPixelSize` gets the hook — its
        // nil-ness is how the session distinguishes a canvas pane (pane follows the stream)
        // from a standalone window (legacy connect-time host-follow negotiation). Hoisted out
        // of the GUIHooks init with an explicit type (the ternary inside the big call defeated
        // the type-checker).
        let notifyDecodedPixelSize: (@Sendable (VideoSize) -> Void)? =
            if onDecodedPixelSize == nil {
                nil
            } else {
                { [weak self] px in
                    Task { @MainActor in self?.onDecodedPixelSize?(px) }
                }
            }
        // GUI hooks: each hops to the main actor to touch the (main-confined) pacer /
        // compositor. The orchestrator actor calls these from its own executor.
        let gui = AislopdeskVideoClientSession.GUIHooks(
            submitDecodedFrame: { buffer in
                // CVImageBuffer is a CoreVideo handle (not Sendable); after decode it is
                // read-only for our render path, so we ferry it across the isolation
                // boundary in an unchecked-Sendable box (the idiomatic escape hatch for
                // immutable CV/CG handles under strict concurrency). The pacer's submit
                // is internally locked, so the main hop only re-presents at vsync.
                pacer.submit(buffer)
            },
            applyCursor: { [weak self] update, placement in
                // COALESCE onto the main actor (BUG-1): store most-recent-wins + schedule at most one
                // flush, instead of one apply Task per 120 Hz packet (which piled up behind the
                // click→focus re-render and drained as a stale burst → the "freeze then lurch").
                Task { @MainActor in self?.coalesceCursor(update, placement) }
            },
            registerCursorShape: { [weak compositor] image, logicalSize, shapeID in
                let box = UnsafeTransfer(image)
                Task { @MainActor in compositor?.registerShape(box.value, logicalSize: logicalSize, for: shapeID) }
            },
            setColorRange: { [weak self] range in
                // WF-6 (#8): point the (main-confined) renderer at the stream's negotiated luma range
                // before the first frame. `ColorRange` is Sendable; the renderer is @MainActor.
                Task { @MainActor in self?.renderer?.colorRange = range }
            },
            notifyDecodedPixelSize: notifyDecodedPixelSize,
            applyStreamCadence: { fps in
                // FPS GOVERNOR: rebase the pacer's content-cadence assumptions (deadline-mode
                // interval + adaptive-jitter frames conversion + the depth-v2 policy's expected
                // interval). `setContentFps` is lock-guarded and callable off-main, so no actor
                // hop is needed. The default arrival-mode pacing is fps-agnostic
                // (present-on-arrival) — this is a rhythm rebase only.
                pacer.setContentFps(Double(fps))
            },
            readPacerTelemetry: {
                // Component 4: synchronous lock-guarded drain (no main hop — the pacer carries its
                // own NSLock). Strong `pacer` capture matches `submitDecodedFrame` above:
                // session→hooks→pacer is acyclic.
                pacer.drainTelemetry()
            },
            noteNetworkLate: {
                // Depth v3: one owd-spike event from the session's OwdLateDetector → the depth
                // policy's promotion input. Lock-guarded, no main hop (same as drainTelemetry).
                pacer.noteNetworkLate()
            },
        )

        let session = AislopdeskVideoClientSession(
            requestedWindowID: connection.windowID,
            viewport: viewport,
            transport: transport,
            gui: gui,
        )
        self.session = session

        // Start the display link (attached to the on-screen view) + the orchestrator.
        pacer.start(view: view)
        Task { try? await session.start() }
        let initialSize = layerSize
        Task { await session.setLayerSize(initialSize) }

        // Bring up the single ordered outbound-input consumer before any input can be enqueued.
        startOutboundConsumer()
        // WF-5 (#7): drive the motion-coalescing pump at its own (more responsive) cadence,
        // DECOUPLED from the video frame cap. Default 120Hz (~8.3ms), down from 1/maxFrameRate
        // (~16.7ms @60). most-recent-wins + move-before-button ordering are interval-independent.
        motionInterval = Self.resolveMotionInterval()
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
        setServerCursorVisible(false) // host cursor gone ⇒ let the view restore the OS arrow
        #if os(macOS)
        currentRemoteCursor = nil
        currentRemoteCursorShapeID = nil
        onRemoteCursorChanged?()
        #endif
        pendingCursorUpdate = nil
        pendingCursorPlacement = nil
        cursorFlushScheduled = false
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
            if ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil {
                // Proof the contentsScale fix took: on Retina this must read scale=2.0 and a
                // drawable = 2× the point size. scale=1.0 here is the "nhỏ 1 góc" regression.
                FileHandle.standardError
                    .write(
                        Data(
                            "Aislopdesk[video.client]: layoutChanged layer=\(Int(layerSize.width))x\(Int(layerSize.height))pt contentsScale=\(scale) drawable=\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))px\n"
                                .utf8,
                        ),
                    )
            }
        }
        // The layer geometry changed under an unchanged frame — force the next tick to render
        // (the pacer skips identical re-shows; without this arm, a resize would show a stale
        // stretch until the next content frame).
        pacer?.setNeedsRedisplay()
        guard let session else { return }
        Task { await session.setLayerSize(layerSize) }
    }

    /// 1:1 PANE SNAP: the view computed the stream's 1:1 point size and is snapping its pane to
    /// it (or found the pane already there). Rebase the session's resize debounce on `size` so
    /// the snap-induced layout pass does NOT echo a `resizeRequest` back to the host — the snap
    /// stays client-side (see ``AislopdeskVideoClientSession/noteLayerSizeAdopted(_:)``).
    func adoptLayerSize(_ size: VideoSize) {
        guard let session else { return }
        Task { await session.noteLayerSizeAdopted(size) }
    }

    /// VNC-style zoom/pan, forwarded to the renderer (applied as a UV crop next vsync)
    /// AND to the session, so the input encoder inverts — and the cursor overlay tracks —
    /// the EXACT SAME transform. Both must move together or a click while zoomed lands at
    /// the un-zoomed source position.
    func setZoom(_ zoom: CGFloat, pan: CGPoint) {
        renderer?.zoom = zoom
        renderer?.panNormalized = pan
        pacer?.setNeedsRedisplay() // transform changed under an unchanged frame (see layoutChanged)
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
        // SELECT-TEXT LATENCY (2026-06-10): a drag is FEEDBACK-CRITICAL — the host-rendered
        // selection highlight tracks it — so it goes out IMMEDIATELY through the ordered FIFO
        // like a button/scroll, NOT deferred to the motion pump. At the 120 Hz pump the deferral
        // coalesced almost nothing anyway (trackpad events arrive at 90-120 Hz) yet cost 0-8.3 ms
        // on every drag step. Hover moves (cosmetic, no host-side feedback the user is tracking)
        // stay pump-coalesced. Flushing any pending hover first preserves physical order.
        submitFlushingMotion { await session.sendMouseDrag(
            button: button,
            viewPoint: viewPoint,
            clickCount: clickCount,
            modifiers: modifiers,
        ) }
    }

    func mouseDown(_ button: MouseButton, _ viewPoint: VideoPoint, _ clickCount: UInt8, _ modifiers: InputModifiers) {
        guard let session else { return }
        // Flush any pending move, THEN the button — both enqueued onto the ONE ordered FIFO with no
        // `await` between, so they reach the session actor in physical order (move, then down). The
        // single consumer can never let a later event overtake this one (the old per-event-Task race).
        submitFlushingMotion { await session.sendMouseDown(
            button: button,
            viewPoint: viewPoint,
            clickCount: clickCount,
            modifiers: modifiers,
        ) }
    }

    func mouseUp(_ button: MouseButton, _ viewPoint: VideoPoint, _ clickCount: UInt8, _ modifiers: InputModifiers) {
        guard let session else { return }
        submitFlushingMotion { await session.sendMouseUp(
            button: button,
            viewPoint: viewPoint,
            clickCount: clickCount,
            modifiers: modifiers,
        ) }
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

    /// Tell the host to raise the captured window because this pane gained focus on the client
    /// (hover / first-responder). Fire-and-forget + idempotent on the host (raises once, skips when
    /// already frontmost), so the user's first click lands instantly. NOT routed through the ordered
    /// input FIFO — it is a pre-warm hint, not an input event, and need not be ordered against clicks.
    func focusWindow() {
        guard let session else { return }
        Task { await session.sendFocusWindow() }
    }

    // MARK: Cursor-overlay coalescing (inbound; BUG-1 freeze fix)

    /// Stores the freshest cursor update+placement (most-recent-wins) and schedules a SINGLE flush if one
    /// is not already pending. Called from the per-packet `applyCursor` hook (after a main-actor hop).
    /// During a busy main-actor span (the click→focus SwiftUI re-render) many of these queue, but each is
    /// a cheap store and only ONE `flushCursor` is ever queued — so when the actor frees, the overlay
    /// snaps once to the LATEST position instead of replaying a burst of stale ones.
    private func coalesceCursor(_ update: CursorUpdate, _ placement: AislopdeskVideoClientSession.CursorPlacement) {
        dbgNoteCursorApply() // BUG-1: time consecutive MAIN-ACTOR cursor applies (freeze localisation)
        pendingCursorUpdate = update
        pendingCursorPlacement = placement
        guard !cursorFlushScheduled else { return }
        cursorFlushScheduled = true
        Task { @MainActor [weak self] in self?.flushCursor() }
    }

    /// BUG-1: logs a MAIN-ACTOR cursor-APPLY gap > 100 ms. A spike here while the session-actor RX gap
    /// (``AislopdeskVideoClientSession``) stays small means the overlay froze because the main thread was
    /// BLOCKED (the click→focus SwiftUI re-render) — which the coalescer cannot shorten; it only prevents
    /// the post-block stale burst. This pinpoints the cause the prior coalescing fix could not address.
    private func dbgNoteCursorApply() {
        guard Self.dbgGapEnabled else { return }
        let now = FramePacer.currentHostTimeSeconds()
        if dbgLastCursorApply > 0 {
            let gap = now - dbgLastCursorApply
            if gap >
                0.1
            {
                FileHandle.standardError
                    .write(
                        Data("Aislopdesk[video.client.view]: cursorAPPLY gap \(Int(gap * 1000))ms (main-actor block)\n"
                            .utf8),
                    )
            }
        }
        dbgLastCursorApply = now
    }

    /// BUG-1: logs a MAIN-ACTOR render gap > 120 ms. Spikes TOGETHER with `cursorAPPLY` ⇒ the whole main
    /// actor stalled (video + overlay both freeze). A RENDER spike WITHOUT a matching media-datagram gap in
    /// the log ⇒ frames arrived but couldn't be presented (main-actor block), not a host/network stall.
    private func dbgNoteRender() {
        guard Self.dbgGapEnabled else { return }
        let now = FramePacer.currentHostTimeSeconds()
        if dbgLastRender > 0 {
            let gap = now - dbgLastRender
            if gap >
                0.12
            {
                FileHandle.standardError
                    .write(Data("Aislopdesk[video.client.view]: RENDER gap \(Int(gap * 1000))ms (main-actor)\n".utf8))
            }
        }
        dbgLastRender = now
    }

    /// Applies the latest pending cursor update to the compositor (one CALayer placement). Re-arms by
    /// clearing the scheduled flag so the NEXT packet schedules a fresh flush. No-op once torn down.
    private func flushCursor() {
        cursorFlushScheduled = false
        guard let update = pendingCursorUpdate, let placement = pendingCursorPlacement, let compositor else {
            pendingCursorUpdate = nil
            pendingCursorPlacement = nil
            setServerCursorVisible(false) // torn down / nothing to draw ⇒ no overlay ⇒ show the OS arrow
            return
        }
        pendingCursorUpdate = nil
        pendingCursorPlacement = nil
        #if os(macOS)
        // macOS Parsec model: DON'T composite the host POSITION (it lags by an RTT + the outbound
        // motion-coalescing interval). Just track the host's SHAPE + visibility; the backing view
        // draws that shape on the LOCAL OS cursor at the instant mouse position.
        updateRemoteCursor(update)
        #else
        compositor.apply(
            update,
            viewSize: placement.viewSize,
            videoNativeSize: placement.videoNativeSize,
            zoom: placement.zoom,
            pan: placement.pan,
            mode: placement.mode,
        )
        #endif
        // Mirror the host cursor's just-applied visibility so the view can choose remote-shape vs arrow.
        setServerCursorVisible(update.visible)
    }

    #if os(macOS)
    /// Rebuilds ``currentRemoteCursor`` when the host shapeID changes (or when its bitmap finally
    /// arrives after a re-request for an id we'd already seen), and notifies the view. Cheap: a real
    /// rebuild happens only on a shape SWAP, not per 120 Hz position packet.
    private func updateRemoteCursor(_ update: CursorUpdate) {
        guard let compositor else { return }
        if currentRemoteCursorShapeID != update.shapeID {
            currentRemoteCursorShapeID = update.shapeID
            currentRemoteCursor = compositor.makeCursor(shapeID: update.shapeID, hotspot: update.hotspot)
            onRemoteCursorChanged?()
        } else if currentRemoteCursor == nil,
                  let cursor = compositor.makeCursor(shapeID: update.shapeID, hotspot: update.hotspot)
        {
            currentRemoteCursor = cursor
            onRemoteCursorChanged?()
        }
    }
    #endif

    /// Updates ``isServerCursorVisible`` and notifies the view ONLY on a real flip (the apply path runs at
    /// ~120 Hz but `visible` rarely changes), so the OS-cursor hide/show toggles at most when the host
    /// cursor actually enters/leaves the captured window.
    private func setServerCursorVisible(_ visible: Bool) {
        guard visible != isServerCursorVisible else { return }
        isServerCursorVisible = visible
        onServerCursorVisibilityChanged?(visible)
    }

    // MARK: Motion pump (client-side coalescing)

    /// WF-5 (#7) INPUT-MOTION INTERVAL. The motion pump flushes the most-recent deferred pointer
    /// move once per this interval (most-recent-wins; absolute coords; NO delta-summing). Lower =
    /// snappier. Default 1/120s (~8.3ms), down from the old 1/maxFrameRate (~16.7ms @60). The host
    /// re-coalesces whatever arrives, so a tighter interval is safe. A/B via `AISLOPDESK_INPUT_HZ` (Hz)
    /// or `AISLOPDESK_INPUT_INTERVAL_MS` (ms); HZ takes precedence if both set. Clamped to avoid wire spam.
    static func resolveMotionInterval() -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        return resolveMotionInterval(hz: env["AISLOPDESK_INPUT_HZ"], ms: env["AISLOPDESK_INPUT_INTERVAL_MS"])
    }

    /// PURE (nonisolated so it is unit-testable headlessly): map the two env strings to a sane
    /// interval. `AISLOPDESK_INPUT_HZ` (1…1000 Hz) wins over `AISLOPDESK_INPUT_INTERVAL_MS` (1…1000 ms); any
    /// missing / unparseable / out-of-range value falls through to the next, finally to 1/120s
    /// (~8.3ms). The clamp bounds wire spam (≤1000Hz) and pathological near-zero cadence (≥1Hz).
    nonisolated static func resolveMotionInterval(hz: String?, ms: String?) -> TimeInterval {
        if let hz, let v = Double(hz), v >= 1, v <= 1000 { return 1.0 / v }
        if let ms, let v = Double(ms), v >= 1, v <= 1000 { return v / 1000.0 }
        return 1.0 / 120.0
    }

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
