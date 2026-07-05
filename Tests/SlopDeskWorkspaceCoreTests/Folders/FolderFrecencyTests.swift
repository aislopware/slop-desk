import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// E11 WI-1 — the Folders frecency engine + persisted store.
///
/// Two surfaces under test:
/// - ``FolderFrecency`` (PURE): `score(entry:now:)` = frequency × bucketed-recency, and `ranked(...)`
///   orders frequent×recent above stale with a deterministic, NaN-faithful tie-break. Integer / ordered
///   math only (no FMA, no bare `</>` on a NaN-capable float — a corrupt/non-finite date can never crash
///   nor out-rank a real entry).
/// - ``FolderFrecencyStore`` (client-side, persisted): `record`/`ranked`/`forget` with a bounded entry
///   cap + path-length cap (validate-then-store, no force-unwrap), a schema-versioned JSON sidecar that
///   decode-fails to an empty default, and an injectable `fileURL`/`now` so the IO is unit-testable.
@MainActor
final class FolderFrecencyTests: XCTestCase {
    // A 2026-anchored reference instant so the bucket arithmetic is independent of wall-clock.
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Pure engine: recency buckets

    func testRecencyWeightBuckets() {
        // Each age falls in exactly one bucket; the boundaries are STRICT `< threshold`.
        XCTAssertEqual(
            FolderFrecency.recencyWeight(now: base, lastAccess: base.addingTimeInterval(-1800)),
            FolderFrecency.weightHour,
            "30 min ago → hour bucket",
        )
        XCTAssertEqual(
            FolderFrecency.recencyWeight(now: base, lastAccess: base.addingTimeInterval(-43200)),
            FolderFrecency.weightDay,
            "12 h ago → day bucket",
        )
        XCTAssertEqual(
            FolderFrecency.recencyWeight(now: base, lastAccess: base.addingTimeInterval(-259_200)),
            FolderFrecency.weightWeek,
            "3 d ago → week bucket",
        )
        XCTAssertEqual(
            FolderFrecency.recencyWeight(now: base, lastAccess: base.addingTimeInterval(-864_000)),
            FolderFrecency.weightMonth,
            "10 d ago → month bucket",
        )
        XCTAssertEqual(
            FolderFrecency.recencyWeight(now: base, lastAccess: base.addingTimeInterval(-5_184_000)),
            FolderFrecency.weightStale,
            "60 d ago → stale bucket",
        )
    }

    func testRecencyWeightBoundaryIsStrict() {
        // Exactly one hour old is NOT in the hour bucket (`age < hour` is strict); one second under is.
        XCTAssertEqual(
            FolderFrecency.recencyWeight(now: base, lastAccess: base.addingTimeInterval(-3600)),
            FolderFrecency.weightDay,
            "exactly 1 h → day bucket",
        )
        XCTAssertEqual(
            FolderFrecency.recencyWeight(now: base, lastAccess: base.addingTimeInterval(-3599)),
            FolderFrecency.weightHour,
            "1 s under an hour → hour bucket",
        )
    }

    // MARK: - Pure engine: score

    func testScoreIsFrequencyTimesRecencyWeight() {
        let recent = FolderEntry(path: "/p", accessCount: 3, lastAccess: base.addingTimeInterval(-60))
        XCTAssertEqual(FolderFrecency.score(entry: recent, now: base), 3 * FolderFrecency.weightHour)
    }

    func testScoreZeroWhenNeverAccessed() {
        let zero = FolderEntry(path: "/p", accessCount: 0, lastAccess: base)
        XCTAssertEqual(FolderFrecency.score(entry: zero, now: base), 0, "count 0 → score 0 regardless of recency")
    }

    func testScoreClampsNegativeCount() {
        // A corrupt negative count clamps to 0 — it can never produce a negative score that inverts ordering.
        let negative = FolderEntry(path: "/p", accessCount: -5, lastAccess: base)
        XCTAssertEqual(FolderFrecency.score(entry: negative, now: base), 0)
    }

    func testScoreToleratesNonFiniteAndFutureDates() {
        // A non-finite (corrupt) lastAccess must NOT crash and must score as ancient (stale weight), so it
        // can never out-rank a real entry.
        let corrupt = FolderEntry(path: "/p", accessCount: 4, lastAccess: Date(timeIntervalSinceReferenceDate: .nan))
        XCTAssertEqual(FolderFrecency.score(entry: corrupt, now: base), 4 * FolderFrecency.weightStale)
        // A future-dated lastAccess (clock skew → negative age) counts as "just now" (freshest bucket).
        let future = FolderEntry(path: "/p", accessCount: 4, lastAccess: base.addingTimeInterval(3600))
        XCTAssertEqual(FolderFrecency.score(entry: future, now: base), 4 * FolderFrecency.weightHour)
    }

    // MARK: - Pure engine: ranking

    func testFrequentRecentRanksAboveStale() {
        let fresh = FolderEntry(path: "/fresh", accessCount: 10, lastAccess: base.addingTimeInterval(-60))
        let stale = FolderEntry(path: "/stale", accessCount: 10, lastAccess: base.addingTimeInterval(-5_184_000))
        XCTAssertEqual(
            FolderFrecency.ranked(entries: [stale, fresh], now: base).map(\.path),
            ["/fresh", "/stale"],
            "equal frequency → more-recent ranks first",
        )
    }

    func testHigherFrequencyWinsAtEqualRecency() {
        let many = FolderEntry(path: "/many", accessCount: 9, lastAccess: base.addingTimeInterval(-60))
        let few = FolderEntry(path: "/few", accessCount: 1, lastAccess: base.addingTimeInterval(-60))
        XCTAssertEqual(
            FolderFrecency.ranked(entries: [few, many], now: base).map(\.path),
            ["/many", "/few"],
            "equal recency → more-frequent ranks first",
        )
    }

    func testRankedTieBreakIsRecencyThenPath() {
        // Identical score (same count + same recency bucket): tie-break newer-first, then path ascending.
        let a = FolderEntry(path: "/a", accessCount: 1, lastAccess: base.addingTimeInterval(-120))
        let b = FolderEntry(path: "/b", accessCount: 1, lastAccess: base.addingTimeInterval(-60))
        let c = FolderEntry(path: "/c", accessCount: 1, lastAccess: base.addingTimeInterval(-60))
        // b and c share a timestamp → path ascending ("/b" < "/c"); a is older → last.
        XCTAssertEqual(FolderFrecency.ranked(entries: [a, c, b], now: base).map(\.path), ["/b", "/c", "/a"])
    }

    func testRankedLimitClampsAndPrefixes() {
        let entries = (0..<5).map { i in
            FolderEntry(path: "/p\(i)", accessCount: 1, lastAccess: base.addingTimeInterval(Double(-i * 60)))
        }
        XCTAssertEqual(FolderFrecency.ranked(entries: entries, now: base, limit: 2).count, 2)
        XCTAssertEqual(FolderFrecency.ranked(entries: entries, now: base, limit: 0).count, 0)
        XCTAssertEqual(FolderFrecency.ranked(entries: entries, now: base, limit: -3).count, 0, "negative clamps to 0")
        XCTAssertEqual(FolderFrecency.ranked(entries: entries, now: base, limit: 99).count, 5, "over-limit returns all")
    }

    // MARK: - Store helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-frecency-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("folders-frecency.json", isDirectory: false)
    }

    /// A mutable, captured-by-reference clock the store reads through its injected `now` closure.
    private final class Clock { var t: Date
        init(_ t: Date) { self.t = t }
    }

    // MARK: - Store: record / ranked

    func testRecordInsertsThenIncrementsCountAndTime() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock(base)
        let store = FolderFrecencyStore(fileURL: url, now: { clock.t })

        store.record(cwd: "/work/proj")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.accessCount, 1)
        XCTAssertEqual(store.entries.first?.lastAccess, base)

        clock.t = base.addingTimeInterval(120)
        store.record(cwd: "/work/proj")
        XCTAssertEqual(store.entries.count, 1, "same path updates in place, no duplicate")
        XCTAssertEqual(store.entries.first?.accessCount, 2)
        XCTAssertEqual(store.entries.first?.lastAccess, base.addingTimeInterval(120), "lastAccess advances")
    }

    func testRecordRejectsEmptyAndOverLongPath() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FolderFrecencyStore(fileURL: url, now: { self.base })

        store.record(cwd: "")
        store.record(cwd: "    \n\t ")
        store.record(cwd: String(repeating: "x", count: FolderFrecencyStore.maxPathLength + 1))
        XCTAssertTrue(store.entries.isEmpty, "validate-then-store rejects empty/whitespace/over-long paths")

        store.record(cwd: "/ok")
        XCTAssertEqual(store.entries.map(\.path), ["/ok"], "a valid path still stores")
    }

    func testEntryCapEvictsOldest() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock(base)
        let store = FolderFrecencyStore(fileURL: url, now: { clock.t }, maxEntries: 3)

        // Four distinct folders, each recorded once, one minute apart (all in the same recency bucket → equal
        // score). The cap keeps the 3 most-frecent; with equal scores the OLDEST falls off.
        for (i, path) in ["/a", "/b", "/c", "/d"].enumerated() {
            clock.t = base.addingTimeInterval(Double(i * 60))
            store.record(cwd: path)
        }
        XCTAssertEqual(store.entries.count, 3, "entry cap holds")
        XCTAssertFalse(store.entries.contains { $0.path == "/a" }, "the oldest folder is evicted")
        XCTAssertTrue(store.entries.contains { $0.path == "/d" }, "the newest folder is retained")
    }

    func testRankedReflectsFrecencyOrder() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock(base.addingTimeInterval(-5_184_000)) // start 60 d in the past
        let store = FolderFrecencyStore(fileURL: url, now: { clock.t })

        // /old visited once long ago; /hot visited many times recently.
        store.record(cwd: "/old")
        clock.t = base
        for _ in 0..<5 { store.record(cwd: "/hot") }

        XCTAssertEqual(store.ranked(now: base).map(\.path), ["/hot", "/old"])
    }

    // MARK: - Store: forget

    func testForgetRemovesAndPersists() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FolderFrecencyStore(fileURL: url, now: { self.base })
        store.record(cwd: "/a")
        store.record(cwd: "/b")

        store.forget(path: "/a")
        XCTAssertEqual(store.entries.map(\.path), ["/b"])

        // The removal is durable across a reload.
        let reloaded = FolderFrecencyStore(fileURL: url, now: { self.base })
        XCTAssertEqual(reloaded.entries.map(\.path), ["/b"])
    }

    // MARK: - Persistence round-trip + decode-fail-to-default

    func testPersistenceRoundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock(base)
        do {
            let store = FolderFrecencyStore(fileURL: url, now: { clock.t })
            store.record(cwd: "/a")
            clock.t = base.addingTimeInterval(30)
            store.record(cwd: "/a")
            store.record(cwd: "/b")
        }
        let reloaded = FolderFrecencyStore(fileURL: url, now: { clock.t })
        let byPath = Dictionary(uniqueKeysWithValues: reloaded.entries.map { ($0.path, $0) })
        XCTAssertEqual(byPath["/a"]?.accessCount, 2, "count survives the round-trip")
        XCTAssertEqual(byPath["/a"]?.lastAccess, base.addingTimeInterval(30), "timestamp survives the round-trip")
        XCTAssertEqual(byPath["/b"]?.accessCount, 1)
    }

    func testCorruptFileDecodesToEmpty() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{ not valid json".utf8).write(to: url)
        let store = FolderFrecencyStore(fileURL: url, now: { self.base })
        XCTAssertTrue(store.entries.isEmpty, "hard-corrupt JSON falls back to an empty default, never crashes")
    }

    func testFutureSchemaVersionDecodesToEmpty() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = """
        { "schemaVersion": 9999, "entries": [ { "path": "/a", "accessCount": 1, "lastAccess": 0 } ] }
        """
        try? Data(future.utf8).write(to: url)
        let store = FolderFrecencyStore(fileURL: url, now: { self.base })
        XCTAssertTrue(store.entries.isEmpty, "an unreadable future schemaVersion falls back to empty (no backcompat)")
    }

    func testLoadDropsInvalidEntries() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let longPath = String(repeating: "x", count: FolderFrecencyStore.maxPathLength + 1)
        let payload = """
        { "schemaVersion": \(FolderFrecencyStore.currentSchemaVersion), "entries": [
          { "path": "/keep", "accessCount": 2, "lastAccess": 0 },
          { "path": "", "accessCount": 1, "lastAccess": 0 },
          { "path": "\(longPath)", "accessCount": 1, "lastAccess": 0 }
        ] }
        """
        try? Data(payload.utf8).write(to: url)
        let store = FolderFrecencyStore(fileURL: url, now: { self.base })
        XCTAssertEqual(store.entries.map(\.path), ["/keep"], "validate-on-load drops empty/over-long paths")
    }
}
