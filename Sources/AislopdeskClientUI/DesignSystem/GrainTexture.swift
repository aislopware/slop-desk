// GrainTexture — the static film-grain tile for the depth-ladder canvas margin (2026-07-04 v4).
//
// A flat colour band across a wide window visibly bands/reads as "CSS swatch"; a few percent of
// monochrome noise turns it into a coated material (the 2025-26 "grainy blur" idiom — grain is what
// separates "designed surface" from "flat fill" in a static screenshot). The tile is 128×128 grey
// noise from a FIXED-SEED SplitMix64 stream — fully deterministic (no `Math.random`/`Date`), so the
// texture is byte-identical across launches and pinnable by tests. Rendered by tiling one small
// decorative `Image` at low opacity with `.overlay` blending — a one-time CGImage, zero per-frame cost.

#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

enum GrainTexture {
    /// Tile edge in pixels — small enough to be free, large enough that the repeat is invisible at 1×/2×.
    static let tileSize = 128
    /// The fixed stream seed. Changing it re-rolls the texture; tests pin the current roll.
    static let seed: UInt64 = 0x5EED_A150_D35C

    /// The deterministic grey-noise bytes (one per pixel, row-major, `tileSize²` long) — SplitMix64
    /// folded to 8 bits. Pure: same seed ⇒ same bytes, forever (the test pin).
    static func pixels(size: Int = tileSize, seed: UInt64 = seed) -> [UInt8] {
        var state = seed
        var out = [UInt8]()
        out.reserveCapacity(size * size)
        for _ in 0..<(size * size) {
            // SplitMix64 step (public-domain constants) — wrapping arithmetic IS the algorithm.
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            out.append(UInt8(truncatingIfNeeded: z))
        }
        return out
    }

    /// The tiled SwiftUI image (grayscale, opaque). Built once per process — SwiftUI `Image` is a value,
    /// the backing `CGImage` is shared.
    static let image: Image? = {
        let size = tileSize
        var bytes = pixels()
        guard let provider = CGDataProvider(data: Data(bytes: &bytes, count: bytes.count) as CFData),
              let cg = CGImage(
                  width: size, height: size,
                  bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
              )
        else { return nil }
        return Image(decorative: cg, scale: 1)
    }()
}

/// The tiled grain overlay: mid-grey noise under `.overlay` blending brightens and darkens the surface
/// beneath it symmetrically — texture, never a tint. Never hit-tests.
struct GrainOverlay: View {
    /// How loud the grain is. The daily-driver band is 3–6%; past ~8% it reads as dirt.
    var opacity: Double = 0.045

    var body: some View {
        if let tile = GrainTexture.image {
            tile
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.overlay)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
#endif
