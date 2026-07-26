import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// Mutable clock cell for the injected `HostOutputSniffer` time source. A class so the `@Sendable`
/// closure handed to the sniffer reads the LATEST value rather than capturing a copy per step.
private final class NowBox: @unchecked Sendable {
    var milliseconds: Int = 0
    /// A fixed epoch plus the step's offset — only the DELTA between a `C` and its `D` reaches the
    /// wire, so the absolute base is arbitrary and must merely be stable within a case.
    var date: Date { Date(timeIntervalSinceReferenceDate: Double(milliseconds) / 1000) }
}

/// Closes the golden corpus's blind spot over the OSC title/bell/command-status sniffer.
///
/// `golden/golden_vectors.json` holds 48 keys, but `slopdesk-corevectors` only EMITS 35 of them;
/// `scripts/golden-check.sh` diffs the emitted subset and prints the rest as "frozen keys are
/// XCTest-pinned, not emitted". Two of those frozen keys — `hostOutputSniffer` and
/// `terminalModeTracker` — sit directly on the PATH-1 title path, and nothing in the test suite
/// actually replayed them: the sniffer's own `HostOutputSnifferTests` pin BEHAVIOUR with
/// hand-written cases, not the corpus BYTES. A change to the type-21 emission therefore produced
/// no `golden-check.sh` signal and no XCTest signal either, leaving the committed vectors to rot
/// silently. That is unacceptable in the phases that deliberately touch the title path (docs/45
/// §5.7, "The golden blind spot, named").
///
/// This suite makes the frozen key a real gate: it replays the committed vectors through the LIVE
/// sniffer and asserts byte-identical framed output.
final class HostOutputSnifferGoldenGuardTests: XCTestCase {
    // MARK: - Corpus decoding

    private struct Step: Decodable {
        let inputHex: String
        let messagesHex: [String]
        /// The injected wall clock at this step, in milliseconds since an arbitrary epoch. The
        /// OSC-133 `C`→`D` duration rides the wire (type 23), so the corpus is only reproducible
        /// with the same clock the generator used — `HostOutputSniffer.init(clock:)` exists for
        /// exactly this.
        let nowMs: Int
    }

    private struct Case: Decodable {
        let name: String
        let steps: [Step]
    }

    /// `golden/` sits beside `Tests/` in the package root — walk up from this file rather than
    /// relying on a bundle resource (the corpus is deliberately NOT a SwiftPM resource; it is an
    /// artefact `scripts/golden-check.sh` reads from the working tree).
    private func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskHostTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("golden/golden_vectors.json")
    }

    private func hexToData(_ hex: String) throws -> Data {
        try XCTUnwrap(hex.count.isMultiple(of: 2) ? () : nil, "odd-length hex in the corpus: \(hex)")
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            try out.append(XCTUnwrap(UInt8(hex[index..<next], radix: 16), "bad hex byte in \(hex)"))
            index = next
        }
        return out
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The gate

    /// REVERT-TO-FAIL: change any type-21/22/23/32 emission in `HostOutputSniffer` and this fails
    /// with the exact case name and the diverged frame.
    func testFrozenSnifferVectorsStillRoundTrip() throws {
        let url = corpusURL()
        let raw = try Data(contentsOf: url)
        let corpus = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any],
            "golden_vectors.json must decode to an object",
        )
        let snifferKey = try XCTUnwrap(
            corpus["hostOutputSniffer"], "the frozen `hostOutputSniffer` key must exist in the corpus",
        )
        let cases = try JSONDecoder().decode(
            [Case].self, from: JSONSerialization.data(withJSONObject: snifferKey),
        )
        XCTAssertFalse(cases.isEmpty, "an empty frozen key would make this suite vacuous")

        for testCase in cases {
            // ONE sniffer per case: the steps are a SEQUENCE through the state machine (an OSC
            // split across two chunks is exactly what these vectors exist to pin). The clock is
            // driven from the step's own `nowMs` so the type-23 duration is deterministic.
            let now = NowBox()
            let sniffer = HostOutputSniffer(clock: { now.date })
            for (stepIndex, step) in testCase.steps.enumerated() {
                now.milliseconds = step.nowMs
                let produced = try sniffer.observe(hexToData(step.inputHex)).map { hex($0.encode()) }
                XCTAssertEqual(
                    produced, step.messagesHex,
                    "frozen vector `\(testCase.name)` step \(stepIndex) diverged — the committed "
                        + "corpus and the live sniffer disagree. If the change was INTENTIONAL, "
                        + "hand-merge the new bytes into golden/golden_vectors.json (never "
                        + "`>`-redirect the generator: it does not emit this key).",
                )
            }
        }
    }

    /// The corpus must keep covering the title path specifically — a future trim that dropped the
    /// OSC-0/2 cases would leave this suite green while re-opening the exact hole it closes.
    func testFrozenVectorsCoverTheTitlePath() throws {
        let raw = try Data(contentsOf: corpusURL())
        let corpus = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let cases = try JSONDecoder().decode(
            [Case].self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(corpus["hostOutputSniffer"])),
        )
        let names = Set(cases.map(\.name))
        XCTAssertTrue(names.contains("osc0Title"), "the BEL-terminated title case must stay pinned")
        XCTAssertTrue(names.contains("osc2TitleST"), "the ST-terminated title case must stay pinned")
    }
}
