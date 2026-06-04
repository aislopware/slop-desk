#if os(macOS)
import XCTest
import AppKit
@testable import RworkVideoHost
import RworkVideoProtocol

/// FIX B size guard: a cursor shape PNG MUST fit one datagram (≤ MTU − header). A larger
/// bitmap would be IP-fragmented, so losing ANY fragment loses the whole shape — amplifying the
/// exact lost-shape hazard the self-heal addresses. `encodeShape` downscales an over-budget
/// bitmap until it fits ONE datagram.
///
/// Offscreen-only: builds the synthetic bitmaps with `NSBitmapImageRep` (no window-server, no
/// `NSCursor`, no timer, no socket), and only calls the pure `static encodeShape`. The size
/// budget itself is asserted against the wire constants so a future header change can't silently
/// re-introduce fragmentation.
@MainActor
final class CursorShapeSizeCapTests: XCTestCase {

    func testBudgetMatchesWireConstants() {
        XCTAssertEqual(CursorSampler.maxShapeBitmapBytes,
                       VideoPacketizer.maxDatagramSize - CursorShapeMessage.headerSize)
    }

    /// A small (typical) cursor encodes unchanged and trivially fits — no downscale needed.
    func testSmallCursorFitsOneDatagram() throws {
        let image = Self.noiseImage(width: 24, height: 24)
        let message = try XCTUnwrap(CursorSampler.encodeShape(image, shapeID: 1, hotspot: .init(x: 0, y: 0)))
        XCTAssertLessThanOrEqual(message.encode().count, VideoPacketizer.maxDatagramSize)
        XCTAssertLessThanOrEqual(message.bitmap.count, CursorSampler.maxShapeBitmapBytes)
        // The reported logical size stays the ORIGINAL points (clients composite at logical size).
        XCTAssertEqual(message.size.width, 24)
        XCTAssertEqual(message.size.height, 24)
    }

    /// A large, high-entropy bitmap whose PNG vastly exceeds the datagram budget is DOWNSCALED
    /// until it fits a single datagram — never fragmented.
    func testOversizedCursorIsDownscaledToFitOneDatagram() throws {
        // 512×512 of incompressible random RGBA → a PNG far over the ~1173-byte budget.
        let image = Self.noiseImage(width: 512, height: 512)
        let message = try XCTUnwrap(CursorSampler.encodeShape(image, shapeID: 2, hotspot: .init(x: 4, y: 4)))
        XCTAssertLessThanOrEqual(message.bitmap.count, CursorSampler.maxShapeBitmapBytes,
                                 "an oversized cursor PNG must be downscaled to fit one datagram")
        XCTAssertLessThanOrEqual(message.encode().count, VideoPacketizer.maxDatagramSize)
        // Logical size + hotspot are preserved (downscale is a transport-fit only).
        XCTAssertEqual(message.size.width, 512)
        XCTAssertEqual(message.size.height, 512)
        XCTAssertEqual(message.hotspot.x, 4)
        XCTAssertEqual(message.hotspot.y, 4)
        // Re-decodes as a valid shape message (the wire shape is well-formed after downscale).
        let round = try CursorShapeMessage.decode(message.encode())
        XCTAssertEqual(round.shapeID, 2)
    }

    /// Builds a `width × height` NSImage filled with high-entropy noise so its PNG does not
    /// compress away (forcing the downscale path for the large case). Offscreen — no window-server.
    private static func noiseImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        var rng = SystemRandomNumberGenerator()
        if let base = rep.bitmapData {
            let count = rep.bytesPerRow * height
            for i in 0 ..< count { base[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
#endif
