import Foundation
import SlopDeskBenchClock
import XCTest
@testable import SlopDeskWorkspaceCore

/// What does the block store cost, now that the ring lives behind a door and `blocks` is a mirror?
///
/// The port swapped an in-place mutation of an `@Observable` array for a rebuild of it: every upsert
/// crosses, and the answer comes back as 64 rows and one arena. That is the shape most obviously at
/// risk of a regression, so it owes a number rather than an argument — a `commandBlock` update
/// arrives on every output-length growth, not just once per command.
///
/// Both sides were timed at `swiftc -O -swift-version 6` on this Mac Studio, standing alone against
/// the same 64-block ring and the same iteration counts — the deleted model taken from `HEAD` before
/// the port, this one taken from the file it became, each with `handle(_:)` stripped so it links
/// without the client. (This suite builds DEBUG, like the rest of `make test`, so the table it
/// prints reads higher than the numbers below; the comparison is release against release.)
///
/// | operation | old Swift | this port |
/// | --- | --- | --- |
/// | upsert, in place, full ring | 7.08 µs | 0.48 µs |
/// | upsert, new index, evicting | 19.86 µs | 10.33 µs |
/// | `blocks(filter: .failed)` | 2.25 µs | 0.06 µs |
/// | `navigatorBlocks` | 2.55 µs | 0.97 µs |
/// | `durationLabel` × 64 | 4.34 µs | 4.92 µs |
/// | `adjacentFailed` over 64 | 1.16 µs | 1.37 µs |
/// | `isFailed` × 64 | 0.40 µs | 0.60 µs |
///
/// The in-place upsert is the one that matters, because it is the one that arrives on every
/// output-length growth of whatever is running, and it is 15× faster — not because the crossing is
/// cheap but because the door now says WHERE the block landed, so one slot is written instead of 64
/// rows being read back. Rebuilding the mirror measured at ~8 µs no matter how the rebuild was
/// arranged (four attempts: scratch buffers kept between calls, a per-row byte diff against the
/// previous arena, one `memcmp` over the whole arena, the buffers lent once up front); ~8 µs is
/// simply what an array of 64 string-bearing structs costs to build in Swift, and the only way past
/// it was not to build one.
///
/// **The last three rows are slower, by a fraction of a microsecond each, and are kept.** They are
/// calls that cannot inline across the boundary, read per row per render — 0.6 µs for a whole 64-row
/// navigator on a 16-millisecond budget. The alternative is a second copy of "completed with a
/// non-zero code" in Swift, which is exactly the drift the port exists to remove.
///
/// It prints a µs/op table and asserts loose ceilings against ``BenchClock``, which measures THREAD
/// CPU time — so a slice lost to another target under `make quick` is not read as a regression.
/// Run on this Mac Studio: `swift test --filter TerminalBlockStoreBenchTests`.
@MainActor
final class TerminalBlockStoreBenchTests: XCTestCase {
    /// Sink to stop the optimizer eliding the work being measured.
    private var sink = 0

    /// Command lines of the length a real ring holds — long enough that the arena is not free.
    private static let commands = [
        "cargo test -p slopdesk-terminal --all-features",
        "git log --oneline -n 40 -- Sources/SlopDeskWorkspaceCore",
        "swift build 2>&1 | grep error",
        "ls -la",
    ]

    func testBlockStoreCostIsMeasuredNotAssumed() {
        let model = TerminalBlockModel()
        for index in 0..<TerminalBlockModel.maxBlocks {
            model.upsert(
                index: UInt32(index), commandText: Self.commands[index % Self.commands.count],
                exitCode: index.isMultiple(of: 7) ? 1 : 0, durationMS: UInt32(index * 37),
                complete: true, outputLen: UInt32(index * 512), promptOrdinal: UInt32(index + 1),
            )
        }
        XCTAssertEqual(model.blocks.count, TerminalBlockModel.maxBlocks, "the ring is full before timing")

        // The hot one: a running command's output length growing, which is one upsert per host
        // update on the SAME index, against a full ring.
        var grow = UInt32(0)
        let upsertInPlace = BenchClock.usPerOp(20000) {
            grow &+= 1
            model.upsert(
                index: 63,
                commandText: Self.commands[3],
                exitCode: 0,
                durationMS: 900,
                complete: false,
                outputLen: grow,
                promptOrdinal: 64,
            )
            sink &+= model.blocks.count
        }
        // The other one: a new command arriving on a full ring, so the oldest block and its
        // first-seen stamp are evicted in the same call.
        var newIndex = UInt32(TerminalBlockModel.maxBlocks)
        let upsertEvicting = BenchClock.usPerOp(20000) {
            newIndex &+= 1
            model.upsert(
                index: newIndex,
                commandText: Self.commands[Int(newIndex) % Self.commands.count],
                exitCode: 0,
                durationMS: 12,
                complete: true,
                outputLen: 4096,
                promptOrdinal: newIndex,
            )
            sink &+= model.blocks.count
        }
        let filtered = BenchClock.usPerOp(20000) { sink &+= model.blocks(filter: .failed).count }
        let navigator = BenchClock.usPerOp(20000) { sink &+= model.navigatorBlocks.count }
        let statusRead = BenchClock.usPerOp(20000) {
            for block in model.blocks { sink &+= block.isFailed ? 1 : 0 }
        }
        let labelRead = BenchClock.usPerOp(20000) {
            for block in model.blocks { sink &+= block.durationLabel?.count ?? 0 }
        }
        let rows = model.navigatorBlocks
        let jump = BenchClock.usPerOp(20000) {
            sink &+= BlockNavigation.adjacentFailed(in: rows, fromIndex: nil, forward: true) == nil ? 0 : 1
        }

        print("\n=== Block store through the door (µs/op, lower is better) ===")
        for (name, value) in [
            ("upsert (in place, full ring)", upsertInPlace),
            ("upsert (new index, evicting)", upsertEvicting),
            ("blocks(filter: .failed)", filtered),
            ("navigatorBlocks", navigator),
            ("isFailed × 64", statusRead),
            ("durationLabel × 64", labelRead),
            ("adjacentFailed over 64", jump),
        ] {
            print(name.padding(toLength: 34, withPad: " ", startingAt: 0)
                + String(format: "%8.3f µs/op", value))
        }
        print("one 60 Hz frame is 16666 µs (sink: \(sink))\n")

        // Deliberately loose: these catch an order-of-magnitude change, not jitter, and this build is
        // DEBUG, where every number above runs about three times the release figure in the doc
        // comment. A ceiling of 100 µs is still a third of what one row of the navigator may spend.
        XCTAssertLessThan(
            Swift.max(upsertInPlace, upsertEvicting),
            100.0,
            "the upsert has regressed by an order of magnitude",
        )
        XCTAssertLessThan(
            Swift.max(filtered, navigator, statusRead, labelRead, jump),
            100.0,
            "a per-render read has regressed by an order of magnitude",
        )
    }
}
