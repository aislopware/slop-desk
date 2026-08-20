// ImageDecode — bytes off the wire become a SwiftUI `Image`, and this is the only place in the client
// that names UIKit's picture type.
//
// The panels fetch pictures the server produced: a device's bezel artwork, a running device's live
// screenshot. `UIImage(data:)` is the decoder, and every consumer wants the same thing afterwards —
// an `Image` to draw. Left at each call site, that is a `UIKit` import and an `Image(uiImage:)` per
// picture. So the boundary is here instead, at the decode, and `UIImage` never leaves this file.
//
// The picture's OWN scale is kept. The artwork is served at a device's native resolution and drawn
// into a rect the server also supplies, so re-deriving a scale here would fight geometry that is
// already correct.

#if os(iOS)
import Foundation
import SwiftUI
import UIKit

extension Image {
    /// Decode image bytes, or `nil` when they are not a picture UIKit can read. Callers treat `nil`
    /// as "draw the fallback", never as an error worth surfacing: a partial fetch of a bezel is
    /// still a usable bezel, and a screenshot that failed to decode is one missed poll.
    static func decoded(_ data: Data) -> Image? {
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
    }
}
#endif
