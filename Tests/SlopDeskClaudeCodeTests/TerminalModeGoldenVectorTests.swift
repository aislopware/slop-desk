import Foundation
import XCTest
@testable import SlopDeskClaudeCode

/// Replays the `terminalModeTracker` key of `golden/golden_vectors.json` through the live tracker.
///
/// ## Why this suite exists
///
/// The corpus has carried 16 cases under that key — the alt-screen modes, every OSC 133 mark and
/// exit-code shape, sequences split across chunks, a DCS spoof, invalid UTF-8, an unterminated OSC —
/// and `golden-check.sh` listed the key as "pinned by its own XCTest suite". No suite read it. The
/// vectors were a frozen record of a behaviour nothing enforced, which is the worst state for a
/// pin: it looks like coverage.
///
/// It matters now because the grammar moved to `rust/slopdesk-terminal`. These vectors were emitted
/// by the Swift original, so replaying them through the door is the differential the port needs:
/// same bytes in, same events and same final mode out, case by case. Every one of them is
/// stream-shaped, so they also exercise the handle across calls rather than one function at a time.
///
/// The corpus is READ here, never written. A vector that disagrees is a regression in the tracker,
/// not a stale expectation to refresh.
final class TerminalModeGoldenVectorTests: XCTestCase {
    /// One `consume` call: the bytes to feed, the events expected back, and the mode afterwards.
    private struct Step: Decodable {
        let inputHex: String
        let events: [String]
        let mode: String
    }

    private struct Case: Decodable {
        let name: String
        let steps: [Step]
    }

    func testGoldenVectorsReplayThroughTheDoor() throws {
        let cases = try loadCases()
        XCTAssertEqual(cases.count, 16, "the corpus lost cases — vectors are added, never dropped")

        for testCase in cases {
            // ONE tracker per case, stepped: several vectors only mean anything as a sequence (a
            // repeated enter that must not fire twice, a sequence split across two chunks).
            let tracker = TerminalModeTracker()
            for (index, step) in testCase.steps.enumerated() {
                let produced = try tracker.consume(bytes(step.inputHex))
                XCTAssertEqual(
                    produced.map(Self.name(of:)),
                    step.events,
                    "\(testCase.name) step \(index): events",
                )
                XCTAssertEqual(
                    Self.name(of: tracker.mode),
                    step.mode,
                    "\(testCase.name) step \(index): mode",
                )
            }
        }
    }

    /// The whole point of the split-chunk vectors, made total: EVERY case must produce the same
    /// events when its bytes arrive one at a time as when they arrive whole.
    ///
    /// Per-byte feeding is the oracle for the door's internal skim — a chunk of one byte can never
    /// take the scan path, so the two runs agreeing pins the fast path to the transition table.
    func testEveryVectorIsInvariantUnderPerByteChunking() throws {
        for testCase in try loadCases() {
            let whole = TerminalModeTracker()
            let perByte = TerminalModeTracker()
            for step in testCase.steps {
                let chunk = try bytes(step.inputHex)
                let atOnce = whole.consume(chunk)
                var split: [TerminalModeEvent] = []
                for byte in chunk { split += perByte.consume(Data([byte])) }
                XCTAssertEqual(atOnce, split, "\(testCase.name): chunking changed the events")
            }
            XCTAssertEqual(whole.mode, perByte.mode, "\(testCase.name): chunking changed the mode")
        }
    }

    // MARK: Corpus

    private func loadCases() throws -> [Case] {
        let corpus = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskClaudeCodeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("golden/golden_vectors.json")
        // Only THIS key is decoded, by lifting the subtree out first: the corpus holds 39 keys of
        // unrelated shapes, and typing the whole file here would make every other vector's schema
        // this suite's problem.
        let all = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus)) as? [String: Any]
        let subtree = try XCTUnwrap(all?["terminalModeTracker"], "the corpus lost the terminalModeTracker key")
        let vectors = try JSONSerialization.data(withJSONObject: subtree)
        return try JSONDecoder().decode([Case].self, from: vectors)
    }

    private func bytes(_ hex: String) throws -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = try XCTUnwrap(hex.index(index, offsetBy: 2, limitedBy: hex.endIndex))
            try out.append(XCTUnwrap(UInt8(hex[index..<next], radix: 16), "bad hex in \(hex)"))
            index = next
        }
        return out
    }

    // MARK: The corpus spelling

    private static func name(of event: TerminalModeEvent) -> String {
        switch event {
        case .enteredAltScreen: "enteredAltScreen"
        case .exitedAltScreen: "exitedAltScreen"
        case .promptStart: "promptStart"
        case .commandStart: "commandStart"
        case .commandStarted: "commandStarted"
        case let .commandFinished(exitCode):
            "commandFinished:\(exitCode.map(String.init) ?? "nil")"
        }
    }

    private static func name(of mode: TerminalMode) -> String {
        switch mode {
        case .shellPrompt: "shellPrompt"
        case .altScreen: "altScreen"
        }
    }
}
