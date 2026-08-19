// SimulatorChromeAssets — a fetched `SimulatorChromeBundle`, decoded into pictures the PHONE can draw.
//
// The FETCH is the domain's (`SlopDeskDevicePanels.SimulatorChromeBundle`): which resources a bezel
// references, and what makes a fetch a failure, is the same answer on every platform. What is not the
// same is the picture type, so the bytes stop at the module edge and each half decodes them — the phone
// here into a SwiftUI `Image`, the Mac in `MacSimulatorChrome` into an `NSImage`.
//
// ## What moved down in docs/56 increment 52a, and what deliberately did not
//
// The two RULES moved: all-or-nothing on the body, best-effort on the buttons, and one decode per
// device cached one entry deep. They are ``SimulatorChromeArt`` and ``SimulatorChromeArtCache`` now,
// generic over the picture type, so neither half re-derives them — and the "a failed decode is not
// cached" clause in particular is the sort of thing a second renderer gets wrong once and nobody
// notices until a bezel is permanently missing.
//
// The DECODE did not move, and could not: `Image` is a SwiftUI type and `NSImage` an AppKit one, and a
// shared target that named either would be a view target below the split — the thing docs/56 stage D
// exists to prevent. What is left in this file is one closure.
//
// iOS-ONLY since increment 52a: the Mac mounts `MacSimulatorBezelView`, which decodes the same bundle
// through the same cache into `NSImage`, so this decode has no caller on that platform.

#if os(iOS)
import Foundation
import SlopDeskDevicePanels
import SwiftUI

/// The phone's decode of a device's chrome. A `typealias` rather than a wrapper: the shape is entirely
/// ``SimulatorChromeArt``'s, and a struct that only forwarded three stored properties would be a second
/// name for the same value that could drift from it.
typealias SimulatorChromeAssets = SimulatorChromeArt<Image>

/// The one decode of a given device's chrome, kept for as long as that device is on screen.
@MainActor
enum SimulatorChromeDecoder {
    private static let cache = SimulatorChromeArtCache<Image>()

    /// Decode `bundle`, reusing the last decode when it is for the same device. `nil` ⇒ undrawable
    /// body, which the stage renders as a bare screen rather than as an error: a working screen with no
    /// body around it is still a working screen.
    static func assets(for bundle: SimulatorChromeBundle) -> SimulatorChromeAssets? {
        cache.art(for: bundle) { Image.decoded($0) }
    }
}
#endif
