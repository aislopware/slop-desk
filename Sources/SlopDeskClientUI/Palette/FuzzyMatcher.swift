// FuzzyMatcher — an in-tree Swift port of fzf's `FuzzyMatchV2` (Smith–Waterman local alignment with
// fzf's structural bonuses), the ranking engine behind the command palette (`SearchMixer`). A naive
// exact/prefix/contains ladder can't rank `gc` against `getConfig`/`git commit` the way muscle memory
// expects (camelCase + word-boundary humps), so this uses fzf's actual algorithm instead — and, unlike
// a plain `Int`-only scorer, it returns the matched code-point positions so the palette can highlight
// them.
//
// WHY VENDOR (not a dependency, not a shell-out): the algorithm is small, hot, and carries identity
// (it must produce ranges over OUR `PaletteItem` strings). Shelling out to the real `fzf` binary is
// impossible on iOS (no subprocess) and a per-keystroke fork on macOS; no SPM port is both faithful and
// healthy. So we vendor it from source — the same discipline as `CSlopDeskSIMD` (a vendored algorithm
// pinned by a differential/golden test). Pure `Foundation`; builds headless for macOS 26 + iOS 26.
//
// PORTED FROM: junegunn/fzf, `src/algo/algo.go` — `FuzzyMatchV2` (the default "v2" matcher), MIT License,
// Copyright (c) 2013-2024 Junegunn Choi. Faithful port of the DEFAULT scheme (`Init("default")`):
//   scoreMatch 16 · scoreGapStart -3 · scoreGapExtension -1 · bonusBoundary 8 · bonusNonWord 8
//   bonusCamel123 7 · bonusConsecutive 4 · bonusFirstCharMultiplier 2
//   bonusBoundaryWhite 10 · bonusBoundaryDelimiter 9 · delimiters "/,:;|"
// Simplifications vs the Go original (none change scores): we always run forward, drop the int16
// overflow / slab / asciiFuzzyIndex micro-optimisations (using `Int` and the full scan window), and skip
// the `normalize` (accent-fold) table. Ranking parity with the real `fzf --filter` is verified by
// `slopdesk-fuzzybench`; score/range goldens are pinned by `FuzzyMatcherTests`.

import Foundation

/// fzf's `FuzzyMatchV2` over Unicode code points. Smart-case, returns the score and matched positions.
public enum FuzzyMatcher {
    // MARK: Scoring constants (fzf default scheme — see algo.go const block)

    private static let scoreMatch = 16
    private static let scoreGapStart = -3
    private static let scoreGapExtension = -1
    private static let bonusBoundary = scoreMatch / 2 // 8
    private static let bonusNonWord = scoreMatch / 2 // 8
    private static let bonusCamel123 = bonusBoundary + scoreGapExtension // 7
    private static let bonusConsecutive = -(scoreGapStart + scoreGapExtension) // 4
    private static let bonusFirstCharMultiplier = 2
    private static let bonusBoundaryWhite = bonusBoundary + 2 // 10
    private static let bonusBoundaryDelimiter = bonusBoundary + 1 // 9

    /// Default-scheme delimiters (`/,:;|`) — a match right after one earns `bonusBoundaryDelimiter`.
    private static let delimiters: Set<Unicode.Scalar> = ["/", ",", ":", ";", "|"]

    // MARK: Result

    /// A successful match: the fzf score (higher = better) and the matched code-point indices into the
    /// candidate, ascending. `positions` map 1:1 onto `candidate.unicodeScalars` offsets.
    public struct Match: Sendable, Equatable {
        public let score: Int
        public let positions: [Int]
        public init(score: Int, positions: [Int]) {
            self.score = score
            self.positions = positions
        }
    }

    // MARK: Public API

    /// Smart-case fuzzy match of `query` against `candidate`, returning the score and the matched ranges
    /// (merged into runs) over the ORIGINAL candidate for highlighting. `nil` ⇒ no match. An empty query
    /// matches everything with score 0 (the zero-state path keeps source order).
    public static func score(_ query: String, _ candidate: String) -> (score: Int, ranges: [Range<String.Index>])? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, []) }

        // Smart case: case-sensitive iff the query carries an uppercase scalar (fzf's rule).
        let caseSensitive = trimmed.unicodeScalars.contains { classOf($0) == .upper }
        let pattern: [Unicode.Scalar] = caseSensitive
            ? Array(trimmed.unicodeScalars)
            : trimmed.unicodeScalars.map(lower)
        let text = Array(candidate.unicodeScalars)

        guard let result = match(pattern: pattern, in: text, caseSensitive: caseSensitive) else { return nil }
        return (result.score, ranges(of: result.positions, in: candidate))
    }

    /// Core matcher. `pattern` MUST be pre-lowercased when `caseSensitive` is false (the text is folded
    /// internally). Returns `nil` when not every pattern code point is matched in order.
    public static func match(pattern: [Unicode.Scalar], in input: [Unicode.Scalar], caseSensitive: Bool) -> Match? {
        let patternCount = pattern.count
        if patternCount == 0 { return Match(score: 0, positions: []) }
        let textCount = input.count
        if patternCount > textCount { return nil }

        // Mutable, folded copy of the text (fzf folds T in place; phase 3 compares the folded runes).
        var chars = input
        var h0 = [Int](repeating: 0, count: textCount) // best score of a chunk ending at each col (row 0)
        var c0 = [Int](repeating: 0, count: textCount) // consecutive-run length ending at each col (row 0)
        var bonuses = [Int](repeating: 0, count: textCount) // edge-triggered position bonus
        var firstOcc = [Int](repeating: 0, count: patternCount) // first occurrence col of each pattern char

        // Phase 2 — classify + bonus per position, build row 0, and locate every pattern char in order.
        var maxScore = 0
        var maxScorePos = 0
        var matchedCount = 0
        var lastIdx = 0
        let pchar0 = pattern[0]
        var pchar = pattern[0]
        var prevH0 = 0
        var prevClass: CharClass = .white // fzf's `initialCharClass` for the default scheme
        var inGap = false

        for off in 0..<textCount {
            var ch = chars[off]
            let cls = classOf(ch)
            if !caseSensitive, cls == .upper {
                ch = lower(ch)
                chars[off] = ch
            }
            let bonus = bonusMatrix[prevClass.rawValue][cls.rawValue]
            bonuses[off] = bonus
            prevClass = cls

            if ch == pchar {
                if matchedCount < patternCount {
                    firstOcc[matchedCount] = off
                    matchedCount += 1
                    pchar = pattern[min(matchedCount, patternCount - 1)]
                }
                lastIdx = off
            }

            if ch == pchar0 {
                let scored = scoreMatch + bonus * bonusFirstCharMultiplier
                h0[off] = scored
                c0[off] = 1
                if patternCount == 1, scored > maxScore {
                    maxScore = scored
                    maxScorePos = off
                    if bonus >= bonusBoundary { break }
                }
                inGap = false
            } else {
                h0[off] = max(inGap ? prevH0 + scoreGapExtension : prevH0 + scoreGapStart, 0)
                c0[off] = 0
                inGap = true
            }
            prevH0 = h0[off]
        }

        if matchedCount != patternCount { return nil }
        if patternCount == 1 { return Match(score: maxScore, positions: [maxScorePos]) }

        // Phase 3 — fill the (patternCount × width) score matrix `hmat` and consecutive matrix `cmat`.
        let f0 = firstOcc[0]
        let width = lastIdx - f0 + 1
        var hmat = [Int](repeating: 0, count: width * patternCount)
        var cmat = [Int](repeating: 0, count: width * patternCount)
        for k in 0..<width {
            hmat[k] = h0[f0 + k]
            cmat[k] = c0[f0 + k]
        }

        for row in 1..<patternCount {
            let f = firstOcc[row]
            let rowBase = row * width
            let target = pattern[row]
            var rowGap = false
            hmat[rowBase + f - f0 - 1] = 0 // Hleft[0]
            for off in 0...(lastIdx - f) {
                let col = off + f
                let ch = chars[col]
                var s1 = 0
                var consecutive = 0
                let hleft = hmat[rowBase + f - f0 - 1 + off]
                let s2 = hleft + (rowGap ? scoreGapExtension : scoreGapStart)

                if target == ch {
                    let hdiag = hmat[rowBase + f - f0 - 1 - width + off]
                    s1 = hdiag + scoreMatch
                    var b = bonuses[col]
                    consecutive = cmat[rowBase + f - f0 - 1 - width + off] + 1
                    if consecutive > 1 {
                        let fb = bonuses[col - consecutive + 1]
                        if b >= bonusBoundary, b > fb {
                            consecutive = 1 // start of a stronger boundary chunk
                        } else {
                            b = max(b, max(bonusConsecutive, fb))
                        }
                    }
                    if s1 + b < s2 {
                        s1 += bonuses[col]
                        consecutive = 0
                    } else {
                        s1 += b
                    }
                }
                cmat[rowBase + f - f0 + off] = consecutive
                rowGap = s1 < s2
                let scored = max(s1, max(s2, 0))
                if row == patternCount - 1, scored > maxScore {
                    maxScore = scored
                    maxScorePos = col
                }
                hmat[rowBase + f - f0 + off] = scored
            }
        }

        return Match(score: maxScore, positions: backtrace(
            hmat: hmat, cmat: cmat, width: width, firstOcc: firstOcc,
            patternCount: patternCount, f0: f0, maxScorePos: maxScorePos,
        ))
    }

    // MARK: Backtrace (fzf phase 4)

    /// Walk back from the best cell, preferring diagonal (match) moves, to recover the matched columns
    /// (ascending). Mirrors algo.go's `withPos` backtrace exactly.
    private static func backtrace(
        hmat: [Int], cmat: [Int], width: Int, firstOcc: [Int],
        patternCount: Int, f0: Int, maxScorePos: Int,
    ) -> [Int] {
        var positions: [Int] = []
        positions.reserveCapacity(patternCount)
        var row = patternCount - 1
        var col = maxScorePos
        var preferMatch = true
        while true {
            let iBase = row * width
            let colOff = col - f0
            let s = hmat[iBase + colOff]
            var s1 = 0
            var s2 = 0
            if row > 0, col >= firstOcc[row] { s1 = hmat[iBase - width + colOff - 1] }
            if col > firstOcc[row] { s2 = hmat[iBase + colOff - 1] }
            if s > s1, s > s2 || s == s2 && preferMatch {
                positions.append(col)
                if row == 0 { break }
                row -= 1
            }
            let downRight = iBase + width + colOff + 1
            preferMatch = cmat[iBase + colOff] > 1 || (downRight < cmat.count && cmat[downRight] > 0)
            col -= 1
        }
        return positions.reversed()
    }

    // MARK: Char classification + folding

    /// fzf's `charClass` (default scheme). Raw values match algo.go's ordering so `class > .nonWord` and
    /// the camelCase test port directly.
    private enum CharClass: Int, CaseIterable {
        case white = 0
        case nonWord
        case delimiter
        case lower
        case upper
        case letter
        case number
    }

    private static func classOf(_ scalar: Unicode.Scalar) -> CharClass {
        let v = scalar.value
        if v <= 127 {
            if v >= 97, v <= 122 { return .lower } // a-z
            if v >= 65, v <= 90 { return .upper } // A-Z
            if v >= 48, v <= 57 { return .number } // 0-9
            if v == 32 || (v >= 9 && v <= 13) { return .white } // space \t \n \v \f \r
            if delimiters.contains(scalar) { return .delimiter }
            return .nonWord
        }
        let c = Character(scalar)
        if c.isLowercase { return .lower }
        if c.isUppercase { return .upper }
        if c.isNumber { return .number }
        if c.isLetter { return .letter }
        if c.isWhitespace { return .white } // covers NEL (0x85) / NBSP (0xA0)
        if delimiters.contains(scalar) { return .delimiter }
        return .nonWord
    }

    /// Single-scalar lowercase (ASCII fast path; best-effort first-scalar for the rest), keeping a 1:1
    /// code-point mapping so matched positions stay valid against the original candidate.
    private static func lower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let v = scalar.value
        if v >= 65, v <= 90 { return Unicode.Scalar(UInt8(v + 32)) }
        if v <= 127 { return scalar }
        return String(scalar).lowercased().unicodeScalars.first ?? scalar
    }

    /// fzf's `bonusFor(prevClass, class)` — the edge-triggered structural bonus.
    private static func bonusFor(_ prev: CharClass, _ cur: CharClass) -> Int {
        // Upstream fzf gates the word-boundary bonuses on `class > charNonWord` (STRICT): a non-word char
        // never enters this branch — it falls through to `bonusNonWord` (8) regardless of the previous class.
        // A `>=` here would over-reward a non-word char after whitespace (10) / a delimiter (9), diverging
        // from fzf's ranking.
        if cur.rawValue > CharClass.nonWord.rawValue {
            switch prev {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if (prev == .lower && cur == .upper) || (prev != .number && cur == .number) {
            return bonusCamel123
        }
        switch cur {
        case .nonWord,
             .delimiter: return bonusNonWord
        case .white: return bonusBoundaryWhite
        default: return 0
        }
    }

    /// Precomputed `bonusFor` table (algo.go's `bonusMatrix`), indexed by `CharClass.rawValue`.
    private static let bonusMatrix: [[Int]] = {
        let classes = CharClass.allCases
        var matrix = Array(repeating: Array(repeating: 0, count: classes.count), count: classes.count)
        for prev in classes {
            for cur in classes {
                matrix[prev.rawValue][cur.rawValue] = bonusFor(prev, cur)
            }
        }
        return matrix
    }()

    // MARK: Position → range mapping

    /// Merge ascending scalar positions into `Range<String.Index>` runs over `candidate` for highlighting.
    private static func ranges(of positions: [Int], in candidate: String) -> [Range<String.Index>] {
        guard !positions.isEmpty else { return [] }
        let scalarIndices = Array(candidate.unicodeScalars.indices)
        var out: [Range<String.Index>] = []
        var runStart = positions[0]
        var prev = positions[0]
        func flush() {
            let lo = scalarIndices[runStart]
            let hi = candidate.unicodeScalars.index(after: scalarIndices[prev])
            out.append(lo..<hi)
        }
        for p in positions.dropFirst() {
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
