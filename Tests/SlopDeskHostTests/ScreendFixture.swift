import Foundation
import SlopDeskScreen
import XCTest

/// A private `slopdesk-screend` for the tests whose subject reaches the screen engine.
///
/// ## Why a fixture at all, when the client autostarts one
/// Because a test must not depend on — or disturb — the developer's live engine, and because a
/// clean checkout has no binary at all. `swift build` never sees cargo (`CLAUDE.md`), so the
/// fixture SKIPS by name when `slopdesk-screend` is absent rather than silently reporting green
/// having tested nothing. `make test` and `make test-touched` build it first, exactly as they do
/// for superd.
///
/// ## One daemon for the whole run
/// screend is stateless apart from a per-pane grid cache keyed by a UUID the scanner mints, so one
/// engine serves every test with no cross-talk, and starting one per test class would cost a fork
/// per class for nothing. It is torn down by the process exiting — a daemon on a socket in the
/// per-run temp directory, holding no children, whose death costs nothing.
enum ScreendFixture {
    /// Points this process at the private engine, or throws `XCTSkip`.
    ///
    /// Call from `setUpWithError()`. Idempotent and thread-safe.
    static func requireDaemon() throws {
        try state.get()
    }

    /// A client aimed at the private engine. `requireDaemon()` must have succeeded first.
    static func client() throws -> ScreenClient {
        try requireDaemon()
        return try ScreenClient(socketPath: socketPath, binaryPath: binaryPath(), autostart: true)
    }

    private static let socketPath: String = {
        // Short stem: `sun_path` is 104 bytes and a `$TMPDIR` already eats ~49 of them.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("slopdesk-screend.sock").path
    }()

    /// Resolved once, on whichever thread asks first. A `lazy static` is exactly the "run the body
    /// once, hand everyone the same answer" this needs, and Swift guarantees it under concurrency.
    private static let state: Result<Void, Error> = {
        do {
            let binary = try binaryPath()
            // Both ends read the same variable, so setting it here aims the production
            // `ScreenClient.shared` — which is what every subject under test actually calls — at
            // the private engine instead of the login session's.
            setenv(ScreenPaths.socketEnvKey, socketPath, 1)
            setenv(ScreenPaths.binaryEnvKey, binary, 1)
            // The client starts it: one start path, exercised by the tests rather than bypassed.
            try ScreenClient(socketPath: socketPath, binaryPath: binary).hello()
            return .success(())
        } catch {
            return .failure(error)
        }
    }()

    /// `rust/slopdesk-screend/target/{release,debug}/slopdesk-screend`, or the override, or a skip.
    private static func binaryPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment[ScreenPaths.binaryEnvKey],
           !override.isEmpty, FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskHostTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("rust/slopdesk-screend/target")
        for profile in ["release", "debug"] {
            let candidate = root.appendingPathComponent("\(profile)/slopdesk-screend").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw XCTSkip("slopdesk-screend is not built — run `make screend` (or `make test`)")
    }
}
