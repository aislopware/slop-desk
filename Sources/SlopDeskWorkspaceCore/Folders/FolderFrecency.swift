import CSlopDeskFFI
import Foundation
import SlopDeskArena

// MARK: - Folders frecency (the Swift face of `rust/slopdesk-workspace`'s `frecency`)

// The scorer, the bucket weights and the tie-breaking order are the crate's — one function rather
// than three sorts, because the folder rail, the open-quickly overlay, the store's own cap and
// `slopdesk jump` all order the same set and must agree. This module lends the database across and
// reads the answer back.

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
/// folders ranked by a built-in frecency score). A caseless namespace over the crate's `frecency`, so
/// the ordering the store enforces and the ordering `slopdesk jump` searches are the same one.
///
/// ### Integer / ordered math only (CLAUDE.md core convention #2)
/// The recency term is a small set of **integer** bucket weights keyed on the entry's age, and the score
/// is an integer multiply — there is no FMA and no bare `</>` on a NaN-capable float. The one place a
/// `Double` appears is the age in seconds, which the crate guards for finiteness and clamps with ordered
/// `max`/`min` before reducing it to whole seconds. A corrupt/non-finite date can therefore never crash
/// nor out-rank a real entry: it scores as ancient.
public enum FolderFrecency {
    // MARK: Recency bucket weights (public — the tests pin the bucketing to these named constants)

    /// Visited within the last hour — the freshest, highest-weight bucket.
    public static let weightHour = Int(slopdesk_folder_weight(SLOPDESK_FOLDER_WEIGHT_HOUR))
    /// Visited within the last day.
    public static let weightDay = Int(slopdesk_folder_weight(SLOPDESK_FOLDER_WEIGHT_DAY))
    /// Visited within the last week.
    public static let weightWeek = Int(slopdesk_folder_weight(SLOPDESK_FOLDER_WEIGHT_WEEK))
    /// Visited within the last month (~30 days).
    public static let weightMonth = Int(slopdesk_folder_weight(SLOPDESK_FOLDER_WEIGHT_MONTH))
    /// Older than a month — the lowest, "stale" weight (still > 0 so a frequent old folder is not erased).
    public static let weightStale = Int(slopdesk_folder_weight(SLOPDESK_FOLDER_WEIGHT_STALE))

    // MARK: The store's limits (the crate's, so neither language writes the numbers down twice)

    /// The default ceiling on stored entries — past it the least-frecent are evicted.
    public static let defaultMaxEntries = Int(slopdesk_folder_limit(SLOPDESK_FOLDER_LIMIT_MAX_ENTRIES))
    /// The longest storable path, in Unicode scalars. A longer cwd is refused rather than stored.
    public static let maxPathScalars = Int(slopdesk_folder_limit(SLOPDESK_FOLDER_LIMIT_PATH_SCALARS))

    // MARK: Validity + repair

    /// Whether a path may be STORED: non-blank once surrounding whitespace is discounted, and within the
    /// scalar cap. The path is kept verbatim — the store keys on what the shell reported.
    public static func isValidPath(_ path: String) -> Bool {
        let utf8 = Array(path.utf8)
        return utf8.withUnsafeBufferPointer { slopdesk_folder_path_is_valid($0.baseAddress, $0.count) }
    }

    /// The entries of a LOADED database worth keeping, in the order they should be stored.
    ///
    /// A file a person can open in an editor is repaired rather than trusted: an entry that could not have
    /// been written is dropped, and an over-cap file is trimmed to the `maxEntries` most recently accessed.
    /// The trim reads no clock, so the same file always repairs into the same database.
    public static func sanitized(entries: [FolderEntry], maxEntries: Int) -> [FolderEntry] {
        let cap = Swift.max(0, maxEntries)
        // The kept set is a SUBSET of what was lent, truncated at the cap, so `min(count, cap)` is not an
        // estimate of the answer's size — it is its ceiling. See ``ranked(entries:now:limit:)``.
        let order: [UInt32] = lent(entries) { records, arena in
            answer(sizedAt: Swift.min(records.count, cap)) { out, capacity in
                slopdesk_folder_sanitized(
                    records.baseAddress, records.count, arena.baseAddress, arena.count, cap, out, capacity,
                )
            }
        }
        return order.compactMap { index in entries.indices.contains(Int(index)) ? entries[Int(index)] : nil }
    }

    // MARK: Scoring

    /// The recency weight for an entry whose `lastAccess` is `now - lastAccess` old.
    /// Returns a small integer bucket weight; ``weightStale`` for a non-finite age (validate-then-default).
    public static func recencyWeight(now: Date, lastAccess: Date) -> Int {
        Int(slopdesk_folder_recency_weight(
            now.timeIntervalSinceReferenceDate, lastAccess.timeIntervalSinceReferenceDate,
        ))
    }

    /// The frecency score = `frequency × recencyWeight`. A non-positive / corrupt frequency clamps to a
    /// non-negative bounded `Int`, so the score is always a well-defined `Int ≥ 0` and ordering never inverts.
    public static func score(entry: FolderEntry, now: Date) -> Int {
        Int(slopdesk_folder_score(
            Int64(clamping: entry.accessCount),
            entry.lastAccess.timeIntervalSinceReferenceDate,
            now.timeIntervalSinceReferenceDate,
        ))
    }

    /// Entries ordered by descending frecency. Ties (equal score) break NEWER-first (so the cap keeps the
    /// freshest), then by `path` ascending for a fully deterministic, stable order. `limit` (clamped to
    /// `≥ 0`) keeps only the top-N; `nil` returns every entry.
    ///
    /// The rank comes back as the caller's OWN indices — a rank is a permutation of what was just lent,
    /// so the paths never re-cross the door.
    public static func ranked(entries: [FolderEntry], now: Date, limit: Int? = nil) -> [FolderEntry] {
        let ceiling = Swift.min(entries.count, limit.map { Swift.max(0, $0) } ?? entries.count)
        let bound = Int64(limit.map { Swift.max(0, $0) } ?? -1)
        // A rank is a PERMUTATION of what was lent, truncated at the limit — so the first guess is the
        // arithmetic ceiling of the answer, not an estimate of it, and the retry below is unreachable.
        // Probing with a null output instead would rebuild the whole database and sort it to learn a
        // number the caller can already compute: measured 30.9 µs against 15.6 µs at the shipped
        // 200-entry cap, and the overlay asks for this twice per keystroke.
        let order: [UInt32] = lent(entries) { records, arena in
            answer(sizedAt: ceiling) { out, capacity in
                slopdesk_folder_ranked(
                    records.baseAddress, records.count, arena.baseAddress, arena.count,
                    now.timeIntervalSinceReferenceDate, bound, out, capacity,
                )
            }
        }
        return order.compactMap { index in entries.indices.contains(Int(index)) ? entries[Int(index)] : nil }
    }

    /// Reads an index answer out of `ask` under docs/55 §4's convention, guessing `guess` first.
    ///
    /// Both index doors answer a subset of what was lent, so every caller here has an exact ceiling in
    /// hand and the `needed > guess` arm cannot be reached. It is written anyway, and written as the
    /// retry rather than as a refusal, because the convention is what makes the guess safe to change:
    /// a bound that is one day wrong costs a second call, never a truncated ranking.
    private static func answer(
        sizedAt guess: Int,
        _ ask: (UnsafeMutablePointer<UInt32>?, Int) -> Int,
    ) -> [UInt32] {
        guard guess > 0 else { return [] }
        var indices = [UInt32](repeating: 0, count: guess)
        let needed = indices.withUnsafeMutableBufferPointer { out in ask(out.baseAddress, out.count) }
        guard needed > 0 else { return [] }
        guard needed > guess else {
            indices.removeLast(guess - needed)
            return indices
        }
        var wider = [UInt32](repeating: 0, count: needed)
        let written = wider.withUnsafeMutableBufferPointer { out in ask(out.baseAddress, out.count) }
        return written == needed ? wider : []
    }

    // MARK: - Lending a database

    /// Lends `entries` as a record array plus the one arena their paths live in, for exactly one call.
    /// Public because a jump lends the same database to the same door — ``JumpResolver`` is the only
    /// other caller, and a second copy of this marshalling is exactly the drift the port removes.
    public static func lent<Answer>(
        _ entries: [FolderEntry],
        _ ask: (UnsafeBufferPointer<SlopDeskFolderEntry>, UnsafeRawBufferPointer) -> Answer,
    ) -> Answer {
        var arena = [UInt8]()
        let records = entries.map { entry -> SlopDeskFolderEntry in
            let path = ArenaText.intern(entry.path, into: &arena)
            return SlopDeskFolderEntry(
                path: SlopDeskByteSpan(offset: path.offset, length: path.length),
                access_count: Int64(clamping: entry.accessCount),
                last_access: entry.lastAccess.timeIntervalSinceReferenceDate,
            )
        }
        return records.withUnsafeBufferPointer { records in
            arena.withUnsafeBytes { arena in ask(records, arena) }
        }
    }
}
