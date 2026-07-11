// App-icon fetch (docs/45 Phase 3): answers `appIconRequest` with `blobChunk` kind-0 PNGs. The
// client resolves icons LOCALLY first (its own Launch Services), so this path fires only for
// host-only apps — once ever per bundleID per client (disk-cached there). Session-less
// request/reply like `listWindows`: the lane bootstraps, is answered from the LRU chunk cache
// (single-flight per key), and retires.

import Foundation

#if os(macOS)
import AppKit
import SlopDeskVideoHost
import SlopDeskVideoProtocol

/// Renders + serves app icons, serialized on this actor. Encoded CHUNKS are cached (LRU 64 keys) so
/// re-requests and multiple clients cost zero renders; the ~40 ms cold `NSRunningApplication.icon`
/// render happens on the main queue (AppKit) at most once per (bundleID, sizePx).
actor AppIconService {
    private let mux: NWVideoMuxDatagramTransport
    /// "bundleID|px" → ready-to-send chunks. LRU by insertion refresh; 64 keys ≈ every app a
    /// desktop realistically runs.
    private var cache: [String: [Data]] = [:]
    private var lruOrder: [String] = []
    private static let cacheCapacity = 64

    init(mux: NWVideoMuxDatagramTransport) {
        self.mux = mux
    }

    /// Answers one `appIconRequest` on `channelID`: cached chunks, or render → chunk → cache →
    /// send. No icon (app not running / no icon) ⇒ silence — the client's fetch round times out and
    /// its NEGATIVE cache entry stops re-asking. The lane retires after the answer (request/reply).
    func answer(
        channelID: UInt32,
        sizePx: UInt16,
        bundleID: String,
        answerGuard: ListAnswerGuard,
    ) async {
        defer { answerGuard.end(channelID) }
        // Clamp the requested edge to a sane range (validate-then-drop on untrusted input).
        let px = max(16, min(256, Int(sizePx)))
        let key = "\(bundleID)|\(px)"
        if let chunks = hitCache(key) {
            for chunk in chunks { mux.send(chunk, on: .control, channelID: channelID) }
            mux.retire(channelID)
            return
        }
        let png = await Self.renderIconPNG(bundleID: bundleID, sizePx: px)
        guard let png,
              let chunks = BlobChunker.encodedChunks(
                  blobKind: BlobAssembler.iconKind,
                  blobID: BlobChunker.fnv1a64(bundleID),
                  metaA: UInt16(clamping: px),
                  metaB: 0,
                  bytes: png,
              )
        else {
            mux.retire(channelID)
            return
        }
        storeCache(key, chunks: chunks)
        log("answered appIconRequest \(bundleID)@\(px)px: \(png.count) bytes in \(chunks.count) chunk(s)")
        for chunk in chunks { mux.send(chunk, on: .control, channelID: channelID) }
        mux.retire(channelID)
    }

    private func hitCache(_ key: String) -> [Data]? {
        guard let chunks = cache[key] else { return nil }
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
        return chunks
    }

    private func storeCache(_ key: String, chunks: [Data]) {
        if cache.count >= Self.cacheCapacity, let oldest = lruOrder.first {
            cache[oldest] = nil
            lruOrder.removeFirst()
        }
        cache[key] = chunks
        lruOrder.append(key)
    }

    /// Renders the RUNNING app's icon to a `sizePx`-edge PNG. MainActor — `NSRunningApplication` +
    /// AppKit drawing belong there; ~40 ms cold, once per (bundleID, px) thanks to the chunk cache.
    @MainActor
    private static func renderIconPNG(bundleID: String, sizePx: Int) -> Data? {
        guard !bundleID.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let icon = app.icon,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: sizePx, pixelsHigh: sizePx,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
              )
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        icon.draw(
            in: NSRect(x: 0, y: 0, width: sizePx, height: sizePx),
            from: .zero, operation: .copy, fraction: 1,
        )
        context.flushGraphics()
        let png = rep.representation(using: .png, properties: [:])
        // The wire cap is the assembler's validate-then-drop bound — an icon past it never ships.
        guard let png, png.count <= VideoControlMessage.iconBlobMaxBytes else { return nil }
        return png
    }
}
#endif
