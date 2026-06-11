#if os(macOS)
import Foundation
import AppKit
import AislopdeskVideoProtocol

/// Samples the mouse position + current cursor shape and emits ``CursorUpdate``
/// messages for the cursor side-channel (doc 17 §3.3).
///
/// ⚠️ **HANG-SAFETY / GUI-ONLY:** uses AppKit (`NSEvent`, `NSCursor`) which require
/// an AppKit run loop. COMPILED + reviewed; not driven from tests.
///
/// Production wiring: a ~120 Hz timer samples `NSEvent.mouseLocation` (host CG/Cocoa
/// space) and the current `NSCursor`, converts the position into **host-window
/// space** (relative to the captured window's origin), assigns a stable `shapeID`
/// per distinct cursor image (the bitmap is shipped once, out of band, when a new
/// id appears), and sends a tiny <64-byte ``CursorUpdate``. The channel is a
/// **separate UDP socket** — never multiplexed with video — so video backpressure
/// never delays the cursor (doc 17 §3.3).
public final class CursorSampler: @unchecked Sendable {
    /// Sample rate (doc 17 §3.3: "~120 Hz").
    public static let sampleHz: Double = 120

    /// Emits a cursor position update for the side-channel socket to send (~120 Hz).
    public typealias UpdateHandler = @Sendable (CursorUpdate) -> Void
    /// Emits a cursor SHAPE bitmap ONCE per newly-seen `shapeID`, out of band, for the
    /// client to cache and composite (doc 17 §3.3). The orchestrator routes this to the
    /// cursor socket as a ``CursorShapeMessage``.
    public typealias ShapeHandler = @Sendable (CursorShapeMessage) -> Void

    private let updateHandler: UpdateHandler
    private let shapeHandler: ShapeHandler?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "aislopdesk.video.cursor", qos: .userInteractive)

    /// The captured window's bounds in CG top-left space (kept in sync by the
    /// geometry watcher) — used to convert global mouse position to window space.
    private var windowBoundsCG: VideoRect
    private let boundsLock = NSLock()

    /// Content key for shape dedup: the cursor's rendered bitmap bytes + hotspot. Two reads of the
    /// same displayed shape compare equal even though `NSCursor.currentSystem` hands back distinct
    /// objects, so the same shape keeps ONE stable `shapeID` (no churn, no bitmap re-ship spam).
    private struct ShapeKey: Hashable {
        let bitmap: Data
        let hotspotX: Double
        let hotspotY: Double
    }
    /// Stable shape-id assignment: each distinct cursor SHAPE (keyed by its rendered bitmap + hotspot,
    /// NOT object identity — `NSCursor.currentSystem` returns a FRESH object per read) gets an
    /// incrementing id. Mutated only on the main actor (in ``refreshShapeAndScreen()``), so it needs
    /// no lock. Bounded in practice by the OS's finite cursor repertoire (arrow, I-beam, hand, the
    /// resize variants, …) — a few dozen per session, never unbounded.
    private var shapeIDs: [ShapeKey: UInt16] = [:]
    private var nextShapeID: UInt16 = 0

    /// CACHE for the off-main hot position path (the "cursor freezes during click-to-raise" fix).
    /// The 120 Hz position sample runs OFF the main thread so a main-thread window raise
    /// (``InputInjector/raiseTargetWindow()`` — ~6–10 synchronous AX IPC calls that hold the main
    /// thread) can no longer starve the cursor stream. `NSEvent.mouseLocation` (the only per-sample
    /// read) is a window-server query that is safe off-main; the main-ONLY reads — `NSCursor.currentSystem`
    /// (the system-wide displayed shape) and `NSScreen` (primary height for the Y-flip) — are refreshed on a slower main cadence
    /// and cached here. Guarded by ``stateLock`` (written on main, read on the cursor queue).
    private var cachedShapeID: UInt16 = 0
    private var cachedHotspot: VideoPoint = VideoPoint(x: 0, y: 0)
    private var cachedPrimaryHeight: Double = 0
    /// Set true after the first main-thread shape/screen prime; until then the position path emits
    /// nothing (so no update ever carries a bogus shape id or an unset screen height).
    private var shapePrimed = false
    private let stateLock = NSLock()
    /// Counts cursor-queue ticks for the shape-refresh policy's fallback/safety cadences.
    /// Touched only on the serial cursor queue.
    private var tickCount = 0
    /// SHAPE-LAG FIX (2026-06-10): the window server's cursor SEED — a counter that increments
    /// whenever the DISPLAYED system cursor image changes. Polling it is a cheap off-main mach call,
    /// so the 120 Hz cursor-queue tick can detect a shape change the same tick it happens and hop to
    /// main ONLY then — instead of the old unconditional every-4th-tick (30 Hz) main-thread refresh
    /// whose worst case (33 ms + main-queue delay) made the client's cursor shape visibly lag Parsec.
    /// Private CGS API (re-exported from SkyLight; probed FOUND on this OS) resolved via `dlsym` with
    /// a graceful fallback: symbol missing ⇒ the policy reverts to the legacy 30 Hz cadence.
    private typealias CursorSeedFn = @convention(c) () -> Int32
    private static let currentCursorSeed: CursorSeedFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        for name in ["CGSCurrentCursorSeed", "SLSCurrentCursorSeed"] {
            if let sym = dlsym(rtldDefault, name) {
                return unsafeBitCast(sym, to: CursorSeedFn.self)
            }
        }
        return nil
    }()
    /// Pure seed→refresh decision state (touched only on the serial cursor queue).
    private var shapeRefreshPolicy = ShapeRefreshPolicy()
    /// The already-encoded ``CursorShapeMessage`` per `shapeID`, retained so a client that
    /// LOST the one-shot shipment can ask for it again (FIX B self-heal — `reshipShape`). Guarded
    /// by `shapeLock` because `reshipShape` may be called off the main actor (the recovery path).
    private var shapeMessages: [UInt16: CursorShapeMessage] = [:]
    private let shapeLock = NSLock()
    /// Opt-in stderr trace (`AISLOPDESK_VIDEO_DEBUG=1`): logs each NEWLY-minted cursor shapeID so a HW run
    /// can confirm distinct shapes (I-beam / hand / resize) are actually being detected and shipped —
    /// the symptom of the `NSCursor.current` → `currentSystem` fix. Fires only on a new shape (rare).
    private static let debugStderr = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil

    public init(windowBoundsCG: VideoRect, updateHandler: @escaping UpdateHandler, shapeHandler: ShapeHandler? = nil) {
        self.windowBoundsCG = windowBoundsCG
        self.updateHandler = updateHandler
        self.shapeHandler = shapeHandler
    }

    /// FIX B self-heal: re-emit the already-cached shape bitmap for `shapeID` on the OOB shape
    /// channel (a client whose one-shot shipment was lost / over-MTU re-requested it via the
    /// recovery channel). No-op if the id was never shipped (nothing to re-send) or there is no
    /// shape handler. Safe to call off the main actor — `shapeMessages` is lock-guarded and the
    /// `CursorShapeMessage` value is `Sendable`, so re-shipping needs no `NSCursor` re-read.
    public func reshipShape(_ shapeID: UInt16) {
        shapeLock.lock(); let message = shapeMessages[shapeID]; shapeLock.unlock()
        guard let message, let shapeHandler else { return }
        shapeHandler(message)
    }

    /// Updates the tracked window bounds (call from the geometry watcher).
    public func updateWindowBounds(_ bounds: VideoRect) {
        boundsLock.lock(); windowBoundsCG = bounds; boundsLock.unlock()
    }

    /// Starts the ~120 Hz sampling timer. GUI-only.
    public func start() {
        // Prime the cached shape + primary-screen height on main BEFORE the position timer fires, so
        // the first emitted position already carries a valid shape id (and the Y-flip height). The
        // position path stays gated on `shapePrimed` until this completes.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refreshShapeAndScreen() }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Self.sampleHz
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One cursor-queue tick (off the main thread). Emits the hot POSITION sample every tick so the
    /// cursor never freezes during a main-thread window raise, and refreshes the cold shape/screen
    /// state on main per ``ShapeRefreshPolicy``: the SAME tick the window-server cursor seed changes
    /// (shape-change detection ≤ 8.3 ms), at ~1 Hz as a safety net while the seed is stable, or at
    /// the legacy ~30 Hz when the seed symbol is unavailable.
    private func tick() {
        emitPositionOffMain()
        tickCount &+= 1
        if shapeRefreshPolicy.shouldRefresh(seed: Self.currentCursorSeed?(), tickCount: tickCount) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.refreshShapeAndScreen() }
            }
        }
    }

    /// Hot path (runs OFF the main thread, on the cursor queue): read the live mouse position and
    /// emit a ``CursorUpdate`` with the CACHED shape/height. `NSEvent.mouseLocation` is Cocoa
    /// bottom-left global and is safe to query off-main; we keep the math in window-relative
    /// normalized-free points (the side channel carries host-window points, which the client
    /// composites directly — doc 17 §3.3). Because this never touches the main thread, a concurrent
    /// main-thread `raiseTargetWindow()` (the ~6–10 AX IPC calls) can't stall the cursor stream.
    private func emitPositionOffMain() {
        boundsLock.lock(); let bounds = windowBoundsCG; boundsLock.unlock()
        stateLock.lock()
        let primed = shapePrimed
        let primaryHeight = cachedPrimaryHeight
        let id = cachedShapeID
        let hotspot = cachedHotspot
        stateLock.unlock()
        guard primed else { return } // wait for the first main-thread shape/screen prime

        let globalCocoa = NSEvent.mouseLocation // bottom-left, +Y up (off-main-safe window-server read)
        // Convert global Cocoa point to window-relative top-left points. The window bounds are CG
        // top-left; flip the cursor's Cocoa Y using the cached main screen height so both are in the
        // same top-left space, then subtract the origin.
        let cgY = primaryHeight - Double(globalCocoa.y)
        let windowX = Double(globalCocoa.x) - bounds.origin.x
        let windowY = cgY - bounds.origin.y
        let visible = windowX >= 0 && windowY >= 0 && windowX <= bounds.size.width && windowY <= bounds.size.height

        let update = CursorUpdate(
            position: VideoPoint(x: windowX, y: windowY),
            shapeID: id, hotspot: hotspot, visible: visible
        )
        updateHandler(update)
    }

    /// Cold path (~30 Hz on the MAIN actor): read the main-ONLY AppKit state — `NSCursor.currentSystem`
    /// (the system-wide displayed shape) and `NSScreen` (primary height) — and cache it for the off-main position path. Ships a
    /// new shape bitmap the first time a distinct cursor appears (via ``shapeID(for:hotspot:)``).
    /// During a window raise this refresh is delayed (the main thread is busy), but the off-main
    /// position path keeps flowing, so the cursor never freezes — only the shape briefly lags.
    @MainActor
    private func refreshShapeAndScreen() {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        // The system-wide DISPLAYED cursor (crosses the process boundary via the window server) — NOT
        // `NSCursor.current`, which is only THIS background `.accessory` daemon's own (empty) cursor
        // stack and so is permanently the arrow, freezing the client's shape. `currentSystem` reflects
        // the foreground app's I-beam / hand / resize shapes; fall back to `.current` only if nil.
        let cursor = NSCursor.currentSystem ?? NSCursor.current
        let hotspot = VideoPoint(x: Double(cursor.hotSpot.x), y: Double(cursor.hotSpot.y))
        let id = shapeID(for: cursor, hotspot: hotspot)
        stateLock.lock()
        let idChanged = shapePrimed && cachedShapeID != id
        cachedPrimaryHeight = primaryHeight
        cachedShapeID = id
        cachedHotspot = hotspot
        shapePrimed = true
        stateLock.unlock()
        // SHAPE-LAG FIX: the client switches its local pointer on the NEXT CursorUpdate that carries
        // the new shapeID. Emit one immediately on a shape CHANGE (on the cursor queue, where every
        // other emission runs) instead of waiting up to 8.3 ms for the next 120 Hz position tick.
        if idChanged {
            queue.async { [weak self] in self?.emitPositionOffMain() }
        }
    }

    @MainActor
    private func shapeID(for cursor: NSCursor, hotspot: VideoPoint) -> UInt16 {
        // Key on the cursor's RENDERED BITMAP + hotspot, not `ObjectIdentifier(cursor)`:
        // `NSCursor.currentSystem` hands back a freshly-constructed object on every read, so object
        // identity would mint a new id on EVERY 30 Hz sample → shapeID churn + a bitmap re-ship each
        // sample. The content key maps the same displayed shape to one stable id.
        let image = cursor.image
        let key = ShapeKey(bitmap: image.tiffRepresentation ?? Data(), hotspotX: hotspot.x, hotspotY: hotspot.y)
        if let id = shapeIDs[key] { return id }
        let id = nextShapeID
        nextShapeID &+= 1
        shapeIDs[key] = id
        if Self.debugStderr {
            FileHandle.standardError.write(Data("[cursor] mint shapeID=\(id) hotspot=(\(hotspot.x),\(hotspot.y)) bitmapBytes=\(key.bitmap.count)\n".utf8))
        }
        // OOB cursor-bitmap channel (doc 17 §3.3): the FIRST time a distinct shape
        // appears, ship its bitmap + hotspot ONCE so the client caches it by `id` and
        // composites the pointer itself (`showsCursor` stays false on capture). The
        // hot per-sample message stays position-only. The encoded message is also RETAINED
        // (FIX B) so a client that loses this one-shot shipment can re-request it.
        if let shapeHandler, let message = Self.encodeShape(image, shapeID: id, hotspot: hotspot) {
            shapeLock.lock(); shapeMessages[id] = message; shapeLock.unlock()
            shapeHandler(message)
        }
        return id
    }

    /// The single-datagram budget for a cursor shape: the video packetizer's MTU cap minus the
    /// shape message header. A shape PNG larger than this would be IP-fragmented (loss of ANY
    /// fragment loses the whole shape, amplifying the lost-shape hazard FIX B heals), so a too-big
    /// bitmap is DOWNSCALED to fit before send.
    static let maxShapeBitmapBytes = VideoPacketizer.maxDatagramSize - CursorShapeMessage.headerSize

    /// Encodes an `NSImage` cursor bitmap as a PNG ``CursorShapeMessage`` for the OOB
    /// shape channel. Returns `nil` if the image yields no bitmap representation.
    ///
    /// FIX B size guard: a typical cursor PNG is well under the single-datagram budget, but a
    /// large/HiDPI custom cursor could exceed it. If the PNG does not fit one datagram, the bitmap
    /// is progressively DOWNSCALED (halving the pixel dimensions) until it fits, so the shape
    /// always rides ONE datagram and is never IP-fragmented. The reported `size`/`hotspot` stay in
    /// the ORIGINAL points (the client composites at the logical cursor size; the bitmap is
    /// self-describing and the client scales it to `bounds`), so a downscale is a pure
    /// transport-fit optimisation that does not move the hotspot.
    @MainActor
    static func encodeShape(_ image: NSImage, shapeID: UInt16, hotspot: VideoPoint) -> CursorShapeMessage? {
        guard let png = pngFittingDatagram(image) else { return nil }
        return CursorShapeMessage(
            shapeID: shapeID,
            size: VideoSize(width: Double(image.size.width), height: Double(image.size.height)),
            hotspot: hotspot,
            bitmap: png
        )
    }

    /// Renders `image` to a PNG that fits ``maxShapeBitmapBytes``, halving the pixel dimensions
    /// (down to a 1px floor) until it does. Returns `nil` only if no bitmap representation exists.
    @MainActor
    private static func pngFittingDatagram(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        if let png = rep.representation(using: .png, properties: [:]), png.count <= maxShapeBitmapBytes {
            return png
        }
        // Over budget: progressively downscale the pixel grid until the PNG fits one datagram.
        var width = rep.pixelsWide
        var height = rep.pixelsHigh
        var lastPNG = rep.representation(using: .png, properties: [:])
        // Bound the loop (≤ ~12 halvings reaches 1px from any realistic cursor) so it always ends.
        for _ in 0 ..< 16 {
            guard width > 1 || height > 1 else { break }
            width = Swift.max(1, width / 2)
            height = Swift.max(1, height / 2)
            guard let scaled = downscaledBitmap(rep, toPixelWidth: width, height: height),
                  let png = scaled.representation(using: .png, properties: [:]) else { break }
            lastPNG = png
            if png.count <= maxShapeBitmapBytes { return png }
        }
        return lastPNG
    }

    /// Draws `source` into a fresh `width × height` RGBA bitmap (no window-server: an offscreen
    /// `NSBitmapImageRep` draw context). Returns `nil` if the context can't be made.
    @MainActor
    private static func downscaledBitmap(_ source: NSBitmapImageRep, toPixelWidth width: Int, height: Int) -> NSBitmapImageRep? {
        guard let dest = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        dest.size = NSSize(width: width, height: height)
        guard let ctx = NSGraphicsContext(bitmapImageRep: dest) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return dest
    }
}

/// PURE decision: should this cursor-queue tick dispatch the main-thread shape/screen refresh?
/// (The "decider beside the actor" discipline — headlessly unit-testable; the `dlsym` seed read and
/// the `DispatchQueue.main.async` side effects stay thin in ``CursorSampler/tick()``.)
///
/// - `seed != nil` (the private window-server cursor-seed API resolved): refresh the SAME tick the
///   seed changes — shape-change detection within one 120 Hz tick (≤ 8.3 ms) — plus a slow ~1 Hz
///   safety refresh (`safetyDivisor`) so screen-height changes (the Y-flip input) and any seed edge
///   case the API misses still converge.
/// - `seed == nil` (symbol unavailable on this OS): the legacy unconditional ~30 Hz cadence
///   (`fallbackDivisor`, every 4th 120 Hz tick).
///
/// The FIRST call with a non-nil seed always refreshes (`lastSeed` starts nil ≠ any seed) — that is
/// the main-thread prime that unblocks the position path's `shapePrimed` gate.
struct ShapeRefreshPolicy {
    private(set) var lastSeed: Int32?
    let fallbackDivisor: Int
    let safetyDivisor: Int

    init(fallbackDivisor: Int = 4, safetyDivisor: Int = 120) {
        self.fallbackDivisor = fallbackDivisor
        self.safetyDivisor = safetyDivisor
    }

    mutating func shouldRefresh(seed: Int32?, tickCount: Int) -> Bool {
        guard let seed else { return tickCount % fallbackDivisor == 0 }
        if seed != lastSeed {
            lastSeed = seed
            return true
        }
        return tickCount % safetyDivisor == 0
    }
}
#endif
