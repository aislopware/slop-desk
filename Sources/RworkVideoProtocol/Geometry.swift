import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A pure 2-D point (host-space, points). Mirrors `CGPoint` but carries no platform
/// dependency, so `RworkVideoProtocol` stays a leaf that compiles for macOS + iOS
/// and is unit-testable in isolation. Bridges to/from `CGPoint` where CoreGraphics
/// is available.
public struct VideoPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A pure 2-D size (points).
public struct VideoSize: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// A pure rectangle (origin + size), in whatever coordinate space the caller states.
public struct VideoRect: Equatable, Sendable {
    public var origin: VideoPoint
    public var size: VideoSize
    public init(origin: VideoPoint, size: VideoSize) { self.origin = origin; self.size = size }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = VideoPoint(x: x, y: y)
        self.size = VideoSize(width: width, height: height)
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    /// The area of intersection with `other` (0 when disjoint). Used by the
    /// multi-monitor coordinate-mapping screen pick.
    public func intersectionArea(_ other: VideoRect) -> Double {
        let ix = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let iy = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        return ix * iy
    }
}

#if canImport(CoreGraphics)
extension VideoPoint {
    public init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

extension VideoSize {
    public init(_ s: CGSize) { self.init(width: Double(s.width), height: Double(s.height)) }
    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

extension VideoRect {
    public init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height))
    }
    public var cgRect: CGRect { CGRect(x: minX, y: minY, width: size.width, height: size.height) }
}
#endif
