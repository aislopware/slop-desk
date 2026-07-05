import Foundation

// MARK: - E11 WI-1: Folders frecency (pure scoring)

/// One persisted folder record: a visited working directory, how often it has been visited, and when it
/// was last visited. The store keys entries by ``path``; ``accessCount`` is the frequency term and
/// ``lastAccess`` the recency term of the frecency score.
///
/// `Codable` so it round-trips through the JSON sidecar; a `Date` encodes as its
/// `timeIntervalSinceReferenceDate` `Double`, which JSON preserves losslessly for the round-trip tests.
public struct FolderEntry: Codable, Equatable, Hashable, Sendable {
    /// The visited directory path (the frecency key). Validated by the store before storage.
    public var path: String
    /// How many times this folder has been visited — the frequency term. Never negative in a store-built
    /// entry; ``FolderFrecency/score(entry:now:)`` defensively clamps a hand-edited negative to 0.
    public var accessCount: Int
    /// When the folder was last visited — the recency term.
    public var lastAccess: Date

    public init(path: String, accessCount: Int, lastAccess: Date) {
        self.path = path
        self.accessCount = accessCount
        self.lastAccess = lastAccess
    }
}

/// The PURE frecency scorer — `frequency × recency`, used to rank visited folders (frequently-used
/// folders ranked by a built-in frecency score). No IO, no SwiftUI, no store: a caseless namespace so
/// it stays headlessly testable and is the single source of truth for the ordering the store enforces.
///
/// ### Integer / ordered math only (CLAUDE.md core convention #2)
/// The recency term is a small set of **integer** bucket weights keyed on the entry's age, and the score is
/// an `Int` multiply — there is no FMA and no bare `</>` on a NaN-capable float. The one place a `Double`
/// appears is the age in seconds (`Date.timeIntervalSince`); it is immediately guarded for finiteness and
/// reduced to whole `Int` seconds (clamped into a sane range so the `Int()` conversion can never trap),
/// after which all comparisons are NaN-free `Int`/`Date` ordered comparisons. A corrupt/non-finite date can
/// therefore never crash nor out-rank a real entry — it scores as ancient.
public enum FolderFrecency {
    // MARK: Recency bucket weights (public — the tests pin the bucketing to these named constants)

    /// Visited within the last hour — the freshest, highest-weight bucket.
    public static let weightHour = 16
    /// Visited within the last day.
    public static let weightDay = 8
    /// Visited within the last week.
    public static let weightWeek = 4
    /// Visited within the last month (~30 days).
    public static let weightMonth = 2
    /// Older than a month — the lowest, "stale" weight (still > 0 so a frequent old folder is not erased).
    public static let weightStale = 1

    // MARK: Bucket thresholds (whole seconds — Int domain, no NaN)

    private static let hourSeconds = 3600
    private static let daySeconds = 86400
    private static let weekSeconds = 604_800
    private static let monthSeconds = 2_592_000 // 30 days

    /// An upper clamp on the age before the `Double → Int` reduction, so an absurd far-future `lastAccess`
    /// (or a corrupt huge interval) can never trap the `Int(...)` conversion. ~317 years of seconds.
    private static let maxAgeSeconds = 10_000_000_000

    /// A clamp on the frequency term so `frequency × weight` cannot overflow `Int` for a hand-edited absurd
    /// count. Bounded inputs keep the score a well-defined non-negative `Int`.
    private static let maxScoredFrequency = 1_000_000

    // MARK: Scoring

    /// The recency weight for an entry whose `lastAccess` is `ageSeconds = now - lastAccess` old.
    /// Returns a small integer bucket weight; ``weightStale`` for a non-finite age (validate-then-default).
    public static func recencyWeight(now: Date, lastAccess: Date) -> Int {
        let ageSeconds = now.timeIntervalSince(lastAccess)
        // Validate-then-default: a non-finite interval (NaN/inf from a corrupt date) is treated as ancient.
        // After this guard `ageSeconds` is finite (no NaN), so the ordered comparisons below are well-defined.
        guard ageSeconds.isFinite else { return weightStale }
        // A future-dated `lastAccess` (clock skew → negative age) counts as "just now". `isLess(than:)` is the
        // IEEE ordered predicate (NaN-safe); NaN is already excluded.
        let nonNegative = ageSeconds.isLess(than: 0) ? 0 : ageSeconds
        // Clamp above the max age before the Int reduction so `Int(...)` can never trap on an absurd interval.
        let bounded = nonNegative.isLess(than: Double(maxAgeSeconds)) ? nonNegative : Double(maxAgeSeconds)
        let age = Int(bounded) // finite, in [0, maxAgeSeconds] → safe, NaN-free Int from here on
        if age < hourSeconds { return weightHour }
        if age < daySeconds { return weightDay }
        if age < weekSeconds { return weightWeek }
        if age < monthSeconds { return weightMonth }
        return weightStale
    }

    /// The frecency score = `frequency × recencyWeight`. A non-positive / corrupt frequency clamps to a
    /// non-negative bounded `Int`, so the score is always a well-defined `Int ≥ 0` and ordering never inverts.
    public static func score(entry: FolderEntry, now: Date) -> Int {
        let frequency = max(0, min(entry.accessCount, maxScoredFrequency)) // Int clamp — no NaN, no overflow
        return frequency * recencyWeight(now: now, lastAccess: entry.lastAccess)
    }

    /// Entries ordered by descending frecency. Ties (equal score) break NEWER-first (so the cap keeps the
    /// freshest), then by `path` ascending for a fully deterministic, stable order. `limit` (clamped to
    /// `≥ 0`) keeps only the top-N; `nil` returns every entry.
    public static func ranked(entries: [FolderEntry], now: Date, limit: Int? = nil) -> [FolderEntry] {
        let scored = entries.map { (entry: $0, score: score(entry: $0, now: now)) }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.lastAccess != rhs.entry.lastAccess { return lhs.entry.lastAccess > rhs.entry.lastAccess }
            return lhs.entry.path < rhs.entry.path
        }.map(\.entry)
        guard let limit else { return sorted }
        let clamped = max(0, limit)
        return Array(sorted.prefix(clamped))
    }
}
