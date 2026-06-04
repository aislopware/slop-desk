#if os(macOS)
import Foundation
import AppKit
import RworkVideoProtocol

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
    private let queue = DispatchQueue(label: "rwork.video.cursor", qos: .userInteractive)

    /// The captured window's bounds in CG top-left space (kept in sync by the
    /// geometry watcher) — used to convert global mouse position to window space.
    private var windowBoundsCG: VideoRect
    private let boundsLock = NSLock()

    /// Stable shape-id assignment: each distinct `NSCursor` gets an incrementing id.
    private var shapeIDs: [ObjectIdentifier: UInt16] = [:]
    private var nextShapeID: UInt16 = 0
    /// The already-encoded ``CursorShapeMessage`` per `shapeID`, retained so a client that
    /// LOST the one-shot shipment can ask for it again (FIX B self-heal — `reshipShape`). Guarded
    /// by `shapeLock` because `reshipShape` may be called off the main actor (the recovery path).
    private var shapeMessages: [UInt16: CursorShapeMessage] = [:]
    private let shapeLock = NSLock()

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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Self.sampleHz
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One sample: read mouse position + shape, convert to window space, emit.
    /// `NSEvent.mouseLocation` is Cocoa bottom-left global; we keep the math in
    /// window-relative normalized-free points (the side channel carries host-window
    /// points, which the client composites directly — doc 17 §3.3).
    @MainActor
    private func sampleOnMain() {
        let globalCocoa = NSEvent.mouseLocation // bottom-left, +Y up
        boundsLock.lock(); let bounds = windowBoundsCG; boundsLock.unlock()

        // Convert global Cocoa point to window-relative top-left points. The window
        // bounds are CG top-left; flip the cursor's Cocoa Y using the main screen
        // height so both are in the same top-left space, then subtract the origin.
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let cgY = primaryHeight - Double(globalCocoa.y)
        let windowX = Double(globalCocoa.x) - bounds.origin.x
        let windowY = cgY - bounds.origin.y

        let cursor = NSCursor.current
        let hotspot = VideoPoint(x: Double(cursor.hotSpot.x), y: Double(cursor.hotSpot.y))
        let id = shapeID(for: cursor, hotspot: hotspot)
        let visible = windowX >= 0 && windowY >= 0 && windowX <= bounds.size.width && windowY <= bounds.size.height

        let update = CursorUpdate(
            position: VideoPoint(x: windowX, y: windowY),
            shapeID: id, hotspot: hotspot, visible: visible
        )
        updateHandler(update)
    }

    private func sample() {
        // Hop to main for AppKit reads (NSCursor.current / NSEvent.mouseLocation are
        // main-thread reads; doc 18 §C main-thread contract for AppKit state).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.sampleOnMain() }
        }
    }

    @MainActor
    private func shapeID(for cursor: NSCursor, hotspot: VideoPoint) -> UInt16 {
        let key = ObjectIdentifier(cursor)
        if let id = shapeIDs[key] { return id }
        let id = nextShapeID
        nextShapeID &+= 1
        shapeIDs[key] = id
        // OOB cursor-bitmap channel (doc 17 §3.3): the FIRST time a distinct cursor
        // appears, ship its bitmap + hotspot ONCE so the client caches it by `id` and
        // composites the pointer itself (`showsCursor` stays false on capture). The
        // hot per-sample message stays position-only. The encoded message is also RETAINED
        // (FIX B) so a client that loses this one-shot shipment can re-request it.
        if let shapeHandler, let message = Self.encodeShape(cursor.image, shapeID: id, hotspot: hotspot) {
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
#endif
