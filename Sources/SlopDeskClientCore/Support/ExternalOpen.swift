import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Handing a URL to the system to open — the one place the platform fork is written.
///
/// Both link paths had their own `openURLString`: the terminal leaf's ⌘-click and the link overlay's
/// "Open" verb. Identical bodies, identical `#if` fork, and the thing that fork is easy to get subtly
/// wrong — `NSWorkspace.open` on macOS, `UIApplication.shared.open` on iOS, and NOTHING on a platform
/// with neither, rather than a `#else` that fails to compile the day a third one appears.
///
/// The parse is part of the law, not a caller's job: a string that is not a URL is DROPPED here. Both
/// copies already did that, and a caller that had to remember it would eventually pass a bare path
/// and get a silent no-op from a different line.
package enum ExternalOpen {
    /// Opens `url` with the system handler.
    package static func url(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Opens `urlString` with the system handler. A no-op when it does not parse as a URL.
    package static func url(_ urlString: String) {
        guard let parsed = URL(string: urlString) else { return }
        url(parsed)
    }
}
