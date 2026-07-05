import Foundation
import XCTest

/// Locates fixture files relative to this source file (`#filePath`), so the tests do
/// not depend on SwiftPM resource bundling — the `Fixtures/` directory sits next to
/// this file and is read straight off disk.
enum Fixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func string(_ name: String) -> String {
        // Force-try is fine in tests: a missing fixture is a hard test-setup failure.
        try! String(contentsOf: url(name), encoding: .utf8)
    }

    static func data(_ name: String) -> Data {
        try! Data(contentsOf: url(name))
    }

    /// The non-empty lines of a JSONL fixture.
    static func lines(_ name: String) -> [String] {
        string(name).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
