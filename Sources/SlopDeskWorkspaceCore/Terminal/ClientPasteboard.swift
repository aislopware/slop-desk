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

    #if canImport(AppKit)
    /// The same funnel for a captured FRAME: decode the bytes, then clear + write the image.
    ///
    /// Answers the decoded `NSImage` so a caller can tell "those bytes were not an image" from "the
    /// write happened" — a truncated capture is a server problem worth reporting, not a silent
    /// no-op — and `nil` without touching the pasteboard, so a bad frame never destroys the clip
    /// that was already there.
    ///
    /// Format-blind on purpose. The Android panel hands it PNG and the simulator panel JPEG;
    /// `NSImage(data:)` sniffs either, and the two panels' copies of this differed in nothing but the
    /// argument label. They keep their own named faces (`AndroidPasteboard.write(png:)`,
    /// `SimulatorPasteboard.write(jpeg:)`) so each panel still says what its transport delivers.
    ///
    /// macOS-only because both device panels are: the mirror is a Mac window onto a local emulator.
    @discardableResult
    public static func write(image bytes: Data) -> NSImage? {
        guard let image = NSImage(data: bytes) else { return nil }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        return image
    }
    #endif
}
