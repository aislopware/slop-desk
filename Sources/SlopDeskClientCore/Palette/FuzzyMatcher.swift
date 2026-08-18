import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// MARK: - FuzzyMatcher (the ranking every search field asks)

/// How a typed query ranks against one candidate, and which of its characters matched.
///
/// ## This is a call, not an implementation
/// The matcher is `rust/slopdesk-fuzzy` — fzf's `FuzzyMatchV2`, Smith–Waterman local alignment with
/// fzf's structural bonuses. What used to be here was a second copy of it, 300 lines of Swift doing
/// the same job in the same repository, which is what `CLAUDE.md`'s one-implementation rule exists
/// to stop. What is left is an argument marshaller over `slopdesk_fuzzy_score` / `slopdesk_fuzzy_rank`
/// plus the one thing the door cannot answer: a scalar offset means nothing to a caller holding a
/// `String`, so the run merging into `Range<String.Index>` stays on this side, where `String.Index`
/// lives.
///
/// The scoring constants, the port's provenance and every deviation from algo.go are documented
/// where they are decided (`rust/slopdesk-fuzzy/src/lib.rs`) rather than restated here where they
/// would drift.
///
/// ## Why fzf's algorithm and not a contains-ladder
/// An exact/prefix/contains ladder cannot rank `gc` against `getConfig` / `git commit` the way
/// muscle memory expects — the camelCase and word-boundary humps are the whole ranking. Ranking
/// parity with the real `fzf --filter` is checked by `slopdesk-fuzzybench`; the exact scores and
/// ranges are pinned by `FuzzyMatcherTests`.
public enum FuzzyMatcher {
    /// First guess at the answer's size: a score plus 63 positions. Queries are typed by a person
    /// into a palette field, so the retry below exists to be correct, not to be used.
    private static let firstGuessBytes = 256

    /// Smart-case fuzzy match of `query` against `candidate`: the fzf score (higher = better) and
    /// the matched ranges, merged into runs, over the ORIGINAL candidate for highlighting.
    ///
    /// `nil` ⇒ the candidate does not carry the query's characters in order. An empty or
    /// whitespace-only query matches everything with score 0 and no ranges, which is what keeps a
    /// search field's zero state in its source order.
    public static func score(_ query: String, _ candidate: String) -> (score: Int, ranges: [Range<String.Index>])? {
        guard let answer = ask(query, candidate) else { return nil }
        return (answer.score, ranges(of: answer.positions, in: candidate))
    }

    /// The same ranking for a caller that will not underline anything — a list that sorts by score
    /// and highlights only the handful of rows it draws. `nil` ⇒ no match, as above.
    ///
    /// This is not a second answer: it is the same matcher told to skip fzf's phase 4, so the score
    /// is bit-identical to ``score(_:_:)``'s (`rust/slopdesk-fuzzy` pins that in a test). What it
    /// skips is the backtrace, the positions and, on this side, walking the candidate's scalar
    /// indices — all of it per candidate, per keystroke.
    public static func rank(_ query: String, _ candidate: String) -> Int? {
        var query = query
        var candidate = candidate
        let answer = query.withUTF8 { q in
            candidate.withUTF8 { c in
                slopdesk_fuzzy_rank(q.baseAddress, q.count, c.baseAddress, c.count)
            }
        }
        return answer < 0 ? nil : Int(answer)
    }

    /// A whole list ranked at once: every candidate that matches, best first, with the underline for
    /// the ONE field the caller draws large.
    ///
    /// A candidate is offered as its fields in priority order — the palette's title, subtitle and
    /// hidden synonyms — and the FIRST one that matches decides both its score and its rank, so a row
    /// found by its title leads a row found only by its synonyms whatever the two scored. That rule
    /// is `slopdesk_workspace::search_rank`; what is here is the same thing ``score(_:_:)`` adds over
    /// ``rank(_:_:)`` — scalar offsets are meaningless to a caller holding a `String`, so the run
    /// merging stays on this side.
    ///
    /// This is ONE call rather than one per candidate because the underline is one pass with the
    /// score: the matcher backtraces while its matrix is still filled, and asking afterwards would
    /// mean scoring every title a second time on every keystroke.
    public static func ranked(
        _ query: String,
        candidates: [(title: String, subtitle: String?, keywords: String?)],
    ) -> [(candidate: Int, titleRanges: [Range<String.Index>])] {
        var fields: [String?] = []
        fields.reserveCapacity(candidates.count * 3)
        for candidate in candidates {
            fields.append(candidate.title)
            fields.append(candidate.subtitle)
            fields.append(candidate.keywords)
        }
        return wsSearchRank(query: query, fields: fields, stride: 3, underlining: 0).map { placed in
            guard placed.tier == 0, candidates.indices.contains(placed.candidate) else {
                return (placed.candidate, [])
            }
            return (placed.candidate, ranges(of: placed.positions, in: candidates[placed.candidate].title))
        }
    }

    // MARK: The door

    /// The door's answer: a score, and the candidate scalar offsets it matched, ascending.
    private struct Answer {
        package let score: Int
        package let positions: [Int]
    }

    private static func ask(_ query: String, _ candidate: String) -> Answer? {
        // Two nested `withUTF8` and nothing else between them: the ABI's whole safety contract is
        // that both pointers stay live for the call, and that is exactly what these scopes mean.
        // Both are `var` because `withUTF8` may have to break a non-contiguous string's storage.
        var query = query
        var candidate = candidate
        return query.withUTF8 { q in
            candidate.withUTF8 { c in
                // The answer buffer is a STACK allocation, not an `[UInt8]`. This runs once per
                // candidate per keystroke — a palette scores hundreds of rows before it draws a
                // frame — and a heap allocation per row would be the whole cost of the call.
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: firstGuessBytes) { out in
                    let needed = call(q, c, into: out)
                    guard needed > 0 else { return nil }
                    guard needed > out.count else { return decode(out, needed) }
                    // The answer outgrew the guess — a query longer than 63 characters. Nothing was
                    // written, so this is a clean retry; the wrapped function is pure, so the second
                    // call cannot disagree.
                    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: needed) { wide in
                        let again = call(q, c, into: wide)
                        guard again > 0, again <= wide.count else { return nil }
                        return decode(wide, again)
                    }
                }
            }
        }
    }

    /// One invocation of the C entry point. Returns how many bytes the answer needs; see
    /// `rust/slopdesk-ffi/include/slopdesk_ffi.h` for the convention.
    private static func call(
        _ query: UnsafeBufferPointer<UInt8>,
        _ candidate: UnsafeBufferPointer<UInt8>,
        into out: UnsafeMutableBufferPointer<UInt8>,
    ) -> Int {
        slopdesk_fuzzy_score(
            query.baseAddress,
            query.count,
            candidate.baseAddress,
            candidate.count,
            out.baseAddress,
            out.count,
        )
    }

    /// Reads `[i32 BE score][u32 BE position]*` out of the first `count` bytes. A length that is not
    /// a whole number of words is a broken answer, not a partial one, so it reads as no match.
    private static func decode(_ bytes: UnsafeMutableBufferPointer<UInt8>, _ count: Int) -> Answer? {
        guard count >= 4, count <= bytes.count, count.isMultiple(of: 4) else { return nil }
        func word(_ index: Int) -> UInt32 {
            let base = index * 4
            return UInt32(bytes[base]) << 24
                | UInt32(bytes[base + 1]) << 16
                | UInt32(bytes[base + 2]) << 8
                | UInt32(bytes[base + 3])
        }
        let words = count / 4
        return Answer(
            score: Int(Int32(bitPattern: word(0))),
            positions: (1..<words).map { Int(word($0)) },
        )
    }

    // MARK: Position → range mapping

    /// Merge ascending scalar positions into `Range<String.Index>` runs over `candidate` for
    /// highlighting. Positions come from the same candidate the door was handed, so an out-of-range
    /// one is impossible; the bound is here because a highlight is not worth a trap if it ever is.
    private static func ranges(of positions: [Int], in candidate: String) -> [Range<String.Index>] {
        // Before the walk, not after: an empty query matches every candidate with no positions, and
        // materialising the index array for each one would be the zero state's whole cost.
        guard !positions.isEmpty else { return [] }
        let scalarIndices = Array(candidate.unicodeScalars.indices)
        let inBounds = positions.filter { $0 >= 0 && $0 < scalarIndices.count }
        guard let first = inBounds.first else { return [] }
        var out: [Range<String.Index>] = []
        var runStart = first
        var prev = first
        func flush() {
            let lo = scalarIndices[runStart]
            let hi = candidate.unicodeScalars.index(after: scalarIndices[prev])
            out.append(lo..<hi)
        }
        for p in inBounds.dropFirst() {
            if p == prev + 1 {
                prev = p
                continue
            }
            flush()
            runStart = p
            prev = p
        }
        flush()
        return out
    }
}

// MARK: - The marked title, cut into runs

/// One stretch of a title, and whether the query hit it.
///
/// A title with no match is ONE run with `matched == false` rather than an empty list — so a caller
/// draws runs unconditionally and never needs a zero-state branch of its own.
public struct FuzzyRun: Equatable, Sendable {
    public let text: String
    public let matched: Bool

    public init(text: String, matched: Bool) {
        self.text = text
        self.matched = matched
    }
}

public extension FuzzyMatcher {
    /// Cuts `title` at `ranges` into alternating unmatched / matched runs.
    ///
    /// ⚠️ Four surfaces mark an fzf hit — the palette and Open Quickly, each drawn twice since
    /// docs/56 stage D — and every one of them wants the same cut and a different INK. So the cut is
    /// here and the ink is theirs: `Text` + `foregroundStyle` on the phone, `NSAttributedString` +
    /// a heavier face on the Mac. The mark itself is CONTRAST rather than colour at all four (the
    /// hit keeps the reading ink and goes a weight up, the letters around it step back), which is
    /// the house rule a single accent-blue row on a monochrome card was written against.
    ///
    /// Ranges that OVERLAP a run already emitted are skipped rather than trusted — the matcher
    /// merges its runs, so an overlap would mean the answer disagreed with itself, and re-slicing on
    /// it would trap on a `String.Index` behind the cursor.
    static func runs(of title: String, ranges: [Range<String.Index>]) -> [FuzzyRun] {
        guard !ranges.isEmpty else { return [FuzzyRun(text: title, matched: false)] }
        var out: [FuzzyRun] = []
        var cursor = title.startIndex
        for range in ranges where range.lowerBound >= cursor {
            if cursor < range.lowerBound {
                out.append(FuzzyRun(text: String(title[cursor..<range.lowerBound]), matched: false))
            }
            out.append(FuzzyRun(text: String(title[range]), matched: true))
            cursor = range.upperBound
        }
        if cursor < title.endIndex {
            out.append(FuzzyRun(text: String(title[cursor...]), matched: false))
        }
        return out
    }
}
