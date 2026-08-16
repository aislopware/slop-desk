import Foundation

/// Locates fixture files relative to this source file (`#filePath`), so the tests do not depend on
/// SwiftPM resource bundling — the `Fixtures/` directory sits next to this file and is read
/// straight off disk. The hook bodies here are real shapes captured from Claude Code, which is the
/// whole point of keeping them as files: a literal inside a test drifts from the producer silently.
enum Fixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func data(_ name: String) -> Data {
        // Force-try is fine in tests: a missing fixture is a hard test-setup failure.
        try! Data(contentsOf: url(name))
    }
}
