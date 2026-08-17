import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The pasteboard every client-side "Copy" writes (and the paste provider reads): `.general` in the
/// app, a per-PROCESS named pasteboard under XCTest (mirrors ``SettingsKey/store``). The system
/// general pasteboard is machine-global shared state — a parallel xctest worker's copy test, or the
/// user's own ⌘C while a local test run is in flight, clobbers any test that asserts on it.
///
/// The PLATFORM fork lives in here rather than at the call sites. It used to be written out at each
/// of them — four `#if canImport(AppKit) … #elseif canImport(UIKit) …` blocks around one line each,
/// in the terminal leaf, the link overlay, the command navigator and the palette. Every one of them
/// reached the test-safe board on macOS and `UIPasteboard.general` on iOS, which is the asymmetry
/// worth hiding: a fifth copy would have had to know that, and the cost of not knowing is a test that
/// overwrites the developer's clipboard.
public enum ClientPasteboard {
    #if canImport(AppKit)
    /// `nonisolated(unsafe)`: `NSPasteboard` just lacks a `Sendable` mark; access is
    /// app-main-thread / test-serial in practice.
    public nonisolated(unsafe) static let pasteboard: NSPasteboard = {
        guard NSClassFromString("XCTestCase") != nil else { return .general }
        let name = NSPasteboard.Name("slopdesk.tests.pid\(ProcessInfo.processInfo.processIdentifier)")
        let suite = NSPasteboard(name: name)
        suite.clearContents() // pid reuse: always start from a clean slate
        atexit { // best-effort: release the per-run pasteboard from the pasteboard server
            Self.pasteboard.releaseGlobally()
        }
        return suite
    }()
    #endif

    /// The one client-side "copy" funnel — clear + write, the platform Copy idiom.
    ///
    /// On AppKit the clear is load-bearing: `NSPasteboard` accumulates types within a declaration, so
    /// a `setString` with no preceding `clearContents` appends to whatever the last writer declared.
    /// `UIPasteboard.string` replaces outright and has no such pair.
    public static func write(_ text: String) {
        #if canImport(AppKit)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// What is on the clipboard as text, or `nil` when it holds something else.
    ///
    /// The read side of "paste into the device": the Android panel takes THIS machine's clipboard and
    /// sends it, rather than asking the device for its own — a `GET_CLIPBOARD` would make the device
    /// write a reply into the video stream (see `AndroidControlMessage`). It reads the same board
    /// ``write(_:)`` writes, which under XCTest is the per-process one, so a test that copies and
    /// then pastes sees its own bytes and not the developer's clipboard.
    public static func text() -> String? {
        #if canImport(AppKit)
        return pasteboard.string(forType: .string)
        #elseif canImport(UIKit)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }

    /// The same funnel for a captured FRAME: decode the bytes, then clear + write the image.
    ///
    /// Answers whether the write happened, so a caller can tell "those bytes were not an image" from
    /// "it is on the clipboard" — a truncated capture is a server problem worth reporting, not a
    /// silent no-op — and a `false` never touches the pasteboard, so a bad frame cannot destroy the
    /// clip that was already there.
    ///
    /// Format-blind on purpose: the Android panel hands it PNG and the simulator panel JPEG, and both
    /// system decoders sniff either. The two panels used to wrap this in a named face each
    /// (`AndroidPasteboard.write(png:)`, `SimulatorPasteboard.write(jpeg:)`) whose only difference was
    /// an argument label; both were AppKit files, which is what kept the panels' MODELS out of the
    /// shared target. Returning `Bool` instead of the decoded image is what let them move (docs/56):
    /// a domain model can say "copy this frame" without naming a platform image type.
    @discardableResult
    public static func writeImage(_ bytes: Data) -> Bool {
        #if canImport(AppKit)
        guard let image = NSImage(data: bytes) else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        return true
        #elseif canImport(UIKit)
        guard let image = UIImage(data: bytes) else { return false }
        UIPasteboard.general.image = image
        return true
        #else
        return false
        #endif
    }
}
