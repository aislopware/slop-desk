import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// What does the link scan actually cost, now that it crosses a boundary?
///
/// `CLAUDE.md` says a measured regression is the only veto on a port, so the ported scan owes a
/// number rather than an argument. Three shapes, all real: a viewport slice (the ⌘-hold underline
/// and Hint Mode rescan it on every frame that moves), a long pane (a tall window at a small font),
/// and a scrollback page (what Jump-To hands it). Plus the two width entries, which are called per
/// COLUMN by `ViLineMotion` and `HintLabelAssigner` and so were the part of the port most at risk.
///
/// The numbers this replaced, from the Swift implementation deleted in the same change, timed the
/// same way on this Mac Studio (`swiftc -O`, same rows, same iterations, run against the file at
/// `HEAD` before the port):
///
/// | shape | old Swift | this port |
/// | --- | --- | --- |
/// | detect, 50 rows (viewport) | 855 µs | ~203 µs |
/// | detect, 200 rows | 3397 µs | ~793 µs |
/// | detect, 2000 rows (scrollback) | 33910 µs | ~7950 µs |
/// | `displayCellWidth(of: String)` | 2.81 µs | ~0.76 µs |
/// | `displayCellWidth(of: Character)` | ~60–68 ns/char | ~92 ns/char |
///
/// The scan is 4.2–4.3× faster at every size — Swift's per-`Character` grapheme breaking is what
/// made the old one cost most of a 120 Hz frame on a plain viewport — and the string width entry is
/// 3.7× faster because its bytes are lent rather than copied.
///
/// **The per-`Character` entry is ~30 ns slower**, and that is a real measured regression, kept on
/// purpose. It is a call that cannot inline across the boundary, so the overhead is the call itself
/// and no arrangement of the Swift side removes it; the alternatives are a second copy of the
/// East-Asian width table in Swift, which is the thing this port exists to delete. The callers are
/// `ViLineMotion` and `HintLabelAssigner`, which walk one line per KEYSTROKE — 30 ns × ~200 columns
/// is ~6 µs on a path with a 16-millisecond budget, against ~650 µs saved on the per-frame scan
/// beside it. If a per-frame caller ever appears, the fix is a batch entry that answers a whole
/// row's widths in one call, not a table.
///
/// It prints a µs/op table and asserts only a loose ceiling — a hard number would flake under load.
/// Run on this Mac Studio: `swift test --filter TerminalLinkScanBenchTests`.
final class TerminalLinkScanBenchTests: XCTestCase {
    /// Sink to stop the optimizer eliding the work being measured.
    private var sink = 0

    private func usPerOp(_ iterations: Int, _ block: () -> Void) -> Double {
        // Warm up (codegen, allocator caches) so the timed loop is steady-state.
        for _ in 0..<min(iterations, 200) { block() }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { block() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(iterations) / 1000.0
    }

    /// Rows a terminal actually holds: build output, a diagnostic with a `:line:col`, a URL, a CJK
    /// row (the width table's worst case), prose that must NOT light up, and a `file://`.
    private static let templates = [
        "  Compiling slopdesk-terminal v0.1.0 (/Volumes/Lacie/Workspace/oss/slop-desk/rust/slopdesk-terminal)",
        "error[E0433]: failed to resolve: use of undeclared crate at src/link.rs:412:9",
        "see https://doc.rust-lang.org/error_codes/E0433.html for more information",
        "日本語のテキストと ./relative/path.swift:88 と ~/home/thing",
        "plain prose with and/or TODO/DONE and git@host:org/repo which must not light up",
        "file:///Volumes/Lacie/Workspace/oss/slop-desk/docs/00-overview.md",
    ]

    private func rows(_ count: Int) -> [String] {
        (0..<count).map { Self.templates[$0 % Self.templates.count] }
    }

    func testLinkScanCostIsMeasuredNotAssumed() {
        let shapes = [
            (name: "viewport", rows: 50, iterations: 1000),
            (name: "tall pane", rows: 200, iterations: 1000),
            (name: "scrollback page", rows: 2000, iterations: 100),
        ]
        print("\n=== Link scan through the door (µs/op, lower is better) ===")
        print("shape".padding(toLength: 18, withPad: " ", startingAt: 0) + "  rows   links     detect")
        var worst = 0.0
        for shape in shapes {
            let sample = rows(shape.rows)
            let links = TerminalLinkDetector.detect(rows: sample, cwd: "/work/proj", schemes: .all)
            let detect = usPerOp(shape.iterations) {
                sink &+= TerminalLinkDetector.detect(rows: sample, cwd: "/work/proj", schemes: .all).count
            }
            print(
                shape.name.padding(toLength: 18, withPad: " ", startingAt: 0)
                    + String(format: " %5d %7d %10.1f", shape.rows, links.count, detect),
            )
            worst = Swift.max(worst, detect)
            XCTAssertFalse(links.isEmpty, "\(shape.name): the sample rows carry links to find")
        }

        // Both alphabets, because the per-column entry is the one the port made slower and an
        // ASCII row is what a terminal mostly holds.
        var perCharacter = 0.0
        for (name, line) in [("ascii", Self.templates[1]), ("cjk", Self.templates[3])] {
            let characters = Array(line)
            let perLine = usPerOp(20000) {
                var total = 0
                for character in characters { total += TerminalLinkDetector.displayCellWidth(of: character) }
                sink &+= total
            }
            let perString = usPerOp(20000) { sink &+= TerminalLinkDetector.displayCellWidth(of: line) }
            print(
                "width " + name.padding(toLength: 6, withPad: " ", startingAt: 0)
                    + String(
                        format: " %3d chars: %7.3f µs/line (%5.1f ns/char), whole string %6.3f µs",
                        characters.count, perLine,
                        perLine * 1000.0 / Double(characters.count), perString,
                    ),
            )
            perCharacter = Swift.max(perCharacter, perLine)
        }
        print("one 120 Hz frame is 8333 µs; one 60 Hz frame is 16666 µs (sink: \(sink))\n")

        // Deliberately loose: this catches an order-of-magnitude change, not jitter. The old Swift
        // scan cost 33910 µs on the scrollback shape, so a ceiling of 20000 µs is already a fail if
        // the port ever slid back to it.
        XCTAssertLessThan(worst, 20000.0, "the link scan has regressed by an order of magnitude")
        XCTAssertLessThan(perCharacter, 50.0, "the per-column width call has regressed")
    }
}
