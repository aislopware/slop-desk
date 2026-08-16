import Foundation
import XCTest

/// Reads ONE key out of `golden/golden_vectors.json`.
///
/// ## Why a lift-then-decode rather than a typed whole file
///
/// The corpus holds 52 keys of unrelated shapes. Typing the whole document here would make every
/// other codec's vector schema this target's problem — a key added elsewhere would fail to decode in
/// a suite that has nothing to do with it. So the subtree is lifted with `JSONSerialization` first
/// and only that one is given a type.
///
/// The corpus is READ, never written. `docs/…`/`CLAUDE.md`: never `>`-redirect the generator over it.
enum GoldenCorpus {
    /// Decodes the array stored under `key`.
    static func load<Case: Decodable>(
        _ key: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws -> [Case] {
        let corpus = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // SlopDeskVideoHostTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("golden/golden_vectors.json")
        let all = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus)) as? [String: Any]
        let subtree = try XCTUnwrap(all?[key], "the corpus lost the \(key) key", file: file, line: line)
        return try JSONDecoder().decode([Case].self, from: JSONSerialization.data(withJSONObject: subtree))
    }
}
