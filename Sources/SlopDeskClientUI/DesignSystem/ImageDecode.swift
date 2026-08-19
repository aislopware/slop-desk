// ImageDecode — bytes off the wire become a SwiftUI `Image`, and this is the only place in the client
// that names a platform's picture type.
//
// The panels fetch pictures the server produced: a device's bezel artwork, a running device's live
// screenshot. `NSImage(data:)` and `UIImage(data:)` are the two decoders, and every consumer wants
// the same thing afterwards — an `Image` to draw. Left at each call site, that is a `#if` per
// picture; the alternative most codebases reach for, a `PlatformImage` typealias, only MOVES the
// `#if` (every consumer still writes `Image(nsImage:)` or `Image(uiImage:)`).
//
// So the boundary is here instead, at the decode, and the platform type never leaves this file.
//
// The picture's OWN scale is kept in both branches. The artwork is served at a device's native
// resolution and drawn into a rect the server also supplies, so re-deriving a scale here would fight
// geometry that is already correct.

import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Image {
    /// Decode image bytes, or `nil` when they are not a picture this platform can read. Callers treat
    /// `nil` as "draw the fallback", never as an error worth surfacing: a partial fetch of a bezel is
    /// still a usable bezel, and a screenshot that failed to decode is one missed poll.
    static func decoded(_ data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }
}
