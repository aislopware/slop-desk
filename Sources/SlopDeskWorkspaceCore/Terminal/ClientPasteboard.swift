#if canImport(AppKit)
import AppKit

/// The pasteboard every client-side "Copy" writes (and the paste provider reads): `.general` in the
/// app, a per-PROCESS named pasteboard under XCTest (mirrors ``SettingsKey/store``). The system
/// general pasteboard is machine-global shared state — a parallel xctest worker's copy test, or the
/// user's own ⌘C while a local test run is in flight, clobbers any test that asserts on it.
public enum ClientPasteboard {
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

    /// The one client-side "copy" funnel — clear + write, the platform Copy idiom.
    public static func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
