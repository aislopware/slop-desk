// CoreVectorsGoldenTests — the ONE caller of ``CoreVectors/mint()``, and the reason the minter is a
// test target rather than the executable it used to be.
//
// Two jobs, and they are different jobs:
//
//  1. ASSERT. Every key this side mints is byte-identical to the value the committed corpus holds
//     for it. That check needs no key list, because it walks what was minted — so the exact-set pin
//     (`EMITTED_KEYS` ∪ `FROZEN_KEYS`, in `rust/slopdesk-devtools/src/gates/golden.rs`) stays typed
//     in exactly one language and this suite cannot drift from it.
//
//  2. HAND THE MINT OVER. `slopdesk-gate golden` runs this suite and then reads
//     `.work/golden/corevectors.json`, which is also the file to merge from when a wire change makes
//     a vector legitimately move.
//
// ⚠️ NEVER `>` THE SCRATCH FILE OVER `golden/golden_vectors.json`. The corpus also holds the FROZEN
// keys this side can no longer mint, and a redirect drops every one of them — which the gate then
// fails on by design. Merge the changed keys in by hand.
//
// ⚠️ The mint is only meaningful with NO `SLOPDESK_*` env set, so the controllers resolve their
// default tunables; the Rust crates pin those same defaults as compile-time consts, and an
// env-shifted run records a corpus that no default build reproduces. A shell that has one exported
// SKIPS here, naming the variable, rather than failing for a reason that is not the code's. The gate
// strips them from the child, so it never takes that branch — and if it ever did, the scratch file
// would be absent and the gate would say so.

import Foundation
import XCTest

@MainActor
final class CoreVectorsGoldenTests: XCTestCase {
    /// Every minted key, against the bytes the corpus froze for it.
    func testEveryMintedVectorMatchesTheCommittedCorpus() throws {
        try skipWhenTunablesAreOverridden()
        let minted = CoreVectors.mint()
        let corpus = try corpusObject()

        for key in minted.keys.sorted() {
            guard let held = corpus[key] else {
                XCTFail("\(key) is minted but ABSENT from \(Corpus.relativePath) — hand-merge it in")
                continue
            }
            guard let value = minted[key] else { continue }
            // Canonicalised OUTSIDE the assertion: a throw inside `XCTAssertEqual`'s autoclosure
            // fails the test at a line that names the assertion rather than the serialisation.
            let fresh = try canonical(value)
            let frozen = try canonical(held)
            XCTAssertEqual(
                fresh, frozen,
                "\(key) DIVERGED from \(Corpus.relativePath) — the wire moved, or a marshaller did",
            )
        }
    }

    /// Hands the whole mint to `slopdesk-gate golden`, which owns the key-set pin this suite cannot.
    ///
    /// Written unconditionally so a stale file can never be read as a fresh one: the gate deletes it
    /// before running the suite, so its absence afterwards means the mint did not happen.
    func testTheMintIsWrittenWhereTheGateAndAMergeCanReadIt() throws {
        try skipWhenTunablesAreOverridden()
        let destination = Corpus.repositoryRoot.appending(path: Corpus.scratchRelativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let data = try JSONSerialization.data(
            withJSONObject: CoreVectors.mint(),
            options: [.sortedKeys, .prettyPrinted],
        )
        try (data + Data([0x0A])).write(to: destination)
    }

    // MARK: the corpus

    private enum Corpus {
        static let relativePath = "golden/golden_vectors.json"
        static let scratchRelativePath = ".work/golden/corevectors.json"

        /// This file is `Tests/SlopDeskCoreVectorsTests/<name>.swift`, so the root is three up.
        /// Derived from `#filePath` rather than the working directory, which `swift test` does not
        /// promise and Xcode does not honour.
        static let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func corpusObject() throws -> [String: Any] {
        let data = try Data(contentsOf: Corpus.repositoryRoot.appending(path: Corpus.relativePath))
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(parsed as? [String: Any], "\(Corpus.relativePath) is not a JSON object")
    }

    /// One spelling for both sides of a comparison, so key order and number formatting cannot fake a
    /// difference. Both operands round-trip through the SAME serialiser in the same process, which
    /// is what makes a `Double` the corpus parsed and a `Double` the minter computed comparable.
    private func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return try XCTUnwrap(String(data: data, encoding: .utf8), "the serialiser wrote non-UTF-8 JSON")
    }

    private func skipWhenTunablesAreOverridden() throws {
        let overrides = ProcessInfo.processInfo.environment.keys
            .filter { $0.hasPrefix("SLOPDESK_") }
            .sorted()
        guard overrides.isEmpty else {
            throw XCTSkip(
                "the mint needs the DEFAULT tunables, and this shell exports \(overrides.joined(separator: " ")) — "
                    + "unset them (`just golden` strips them for you) to run this suite",
            )
        }
    }
}
