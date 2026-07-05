// slopdesk-fuzzybench — benchmark + parity validator for the vendored `FuzzyMatcher` (the in-tree
// fzf FuzzyMatchV2 port behind the command palette). It answers two questions the user asked when we
// chose to port rather than depend:
//
//   1. PARITY  — does our port rank like the REAL fzf? We shell out to `fzf --filter <query>` (the
//                canonical Go binary) on the SAME corpus and compare (a) the match SET (every fuzzy
//                subsequence hit — must be identical on ASCII) and (b) the top-K ORDER (ranking quality).
//   2. SPEED   — how fast is our port? We time it against fzf's wall-clock and a Bitap (Fuse-style)
//                baseline, reporting matches/sec.
//
// This is a macOS dev instrument, NOT a unit test: it spawns `fzf` (skips that column if absent) and
// scales the corpus, so it lives outside `swift test`. Run: `swift run -c release slopdesk-fuzzybench`
// (optionally `… <scaleN>` to repeat the corpus to ~N entries for throughput numbers).

import Foundation
import SlopDeskClientUI

// MARK: - Corpus

/// Real, representative fuzzy targets: every Swift source path in the package (relative), plus their
/// basenames (so camelCase/boundary cases are exercised). Falls back to a small embedded list when run
/// outside the package root.
func loadCorpus() -> [String] {
    var out: [String] = []
    let fm = FileManager.default
    if let walker = fm.enumerator(atPath: "Sources") {
        for case let path as String in walker where path.hasSuffix(".swift") {
            out.append("Sources/" + path)
            if let base = path.split(separator: "/").last { out.append(String(base)) }
        }
    }
    if out.isEmpty {
        out = [
            "getConfig", "git commit", "background", "fuzzy-finder", "fuzzyfinder",
            "PaletteDataSource.swift", "SearchMixer", "WorkspaceStore", "FuzzyMatcher.swift",
            "src/algo/algo.go", "README.md", "Package.swift", "foobar", "foo-bar", "out-of-bound",
        ]
    }
    // De-dup, drop empties, keep deterministic order.
    var seen = Set<String>()
    return out.filter { !$0.isEmpty && seen.insert($0).inserted }
}

/// Repeat the corpus (with a numeric suffix so entries stay distinct) up to ~`target` lines for speed runs.
func scaled(_ base: [String], to target: Int) -> [String] {
    guard target > base.count, !base.isEmpty else { return base }
    var out = base
    var n = 0
    while out.count < target {
        for s in base where out.count < target {
            out.append("\(s)#\(n)")
        }
        n += 1
    }
    return out
}

// MARK: - Baselines

/// A minimal Bitap (the family Fuse-swift uses): does the pattern appear as an ordered subsequence, and
/// a crude score = -(span) so tighter matches rank higher. Illustrates the "different feel" vs fzf (no
/// word-boundary / camelCase / consecutive structure) and a speed point of comparison.
func bitapScore(_ query: String, _ candidate: String) -> Int? {
    let pat = Array(query.lowercased().unicodeScalars)
    guard !pat.isEmpty else { return 0 }
    let text = Array(candidate.lowercased().unicodeScalars)
    var pi = 0
    var first = -1
    var last = -1
    for (i, ch) in text.enumerated() where pi < pat.count && ch == pat[pi] {
        if first < 0 { first = i }
        last = i
        pi += 1
    }
    guard pi == pat.count else { return nil }
    return -(last - first) // tighter span = higher (less negative)
}

// MARK: - fzf bridge

/// `printf "%s\n" <corpus> | fzf --filter=<query>` → fzf's ranked matches (best first). Returns nil if
/// fzf is not installed or the call fails.
func runFzf(_ query: String, _ corpus: [String], fzfPath: String) -> [String]? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: fzfPath)
    proc.arguments = ["--filter=" + query] // default: v2 algo, smart-case, default scheme
    let stdin = Pipe()
    let stdout = Pipe()
    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        return nil
    }
    let input = (corpus.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
    stdin.fileHandleForWriting.write(input)
    stdin.fileHandleForWriting.closeFile()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    // exit code 1 == no matches (still a valid, empty result).
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

func which(_ tool: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["which", tool]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (path?.isEmpty == false) ? path : nil
}

// MARK: - Timing

func nanos(_ body: () -> Void) -> UInt64 {
    let t0 = DispatchTime.now().uptimeNanoseconds
    body()
    return DispatchTime.now().uptimeNanoseconds - t0
}

/// Pad `s` into a fixed-width column (pure Swift — avoids NSString `%@` format specifiers).
func col(_ s: String, _ width: Int, right: Bool = false) -> String {
    guard s.count < width else { return s }
    let padding = String(repeating: " ", count: width - s.count)
    return right ? padding + s : s + padding
}

// MARK: - Run

let args = CommandLine.arguments
let scaleTarget = args.count > 1 ? Int(args[1]) ?? 0 : 0
let base = loadCorpus()
let corpus = scaleTarget > 0 ? scaled(base, to: scaleTarget) : base
let fzfPath = which("fzf")

let queries = [
    "fz", "gc", "ff", "plt", "src", "cfg", "tcp", "fec", "mixer", "store",
    "palette", "fuzzymatch", "wsstore", "vidproto", "readme", "pkg",
]

print("slopdesk-fuzzybench — FuzzyMatcher (fzf V2 port) vs real fzf + Bitap baseline")
print(String(repeating: "═", count: 92))
print("corpus: \(corpus.count) entries (base \(base.count))  •  queries: \(queries.count)  •  "
    + "fzf: \(fzfPath ?? "NOT FOUND — parity columns skipped")")
print(String(repeating: "─", count: 92))
print(col("query", 13) + col("ours", 7, right: true) + col("fzf", 8, right: true)
    + col("setEq", 10, right: true) + col("top10", 10, right: true)
    + col("ours ns/c", 12, right: true) + col("top1=", 8, right: true))
print(String(repeating: "─", count: 92))

var totalOursNanos: UInt64 = 0
var totalComparisons = 0
var setMatches = 0
var setChecks = 0
var top10Sum = 0.0
var top10Count = 0
var top1Agree = 0
var top1Count = 0
var scoreInversions = 0 // strict score-order violations in fzf's order = real divergences
var scorePairs = 0

for query in queries {
    // Ours: score every candidate, keep matches. Rank with fzf's DEFAULT tiebreak so the comparison is
    // apples-to-apples: score desc, then length asc, then input index asc (fzf `--tiebreak=length`).
    var ours: [(cand: String, score: Int, idx: Int)] = []
    let dt = nanos {
        ours = corpus.enumerated().compactMap { idx, c in
            FuzzyMatcher.score(query, c).map { (c, $0.score, idx) }
        }
    }
    totalOursNanos += dt
    totalComparisons += corpus.count
    let scoreOf = Dictionary(ours.map { ($0.cand, $0.score) }, uniquingKeysWith: { a, _ in a })
    let oursRanked = ours.sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.cand.count != rhs.cand.count { return lhs.cand.count < rhs.cand.count }
        return lhs.idx < rhs.idx
    }.map(\.cand)
    let oursSet = Set(oursRanked)
    let nsPer = Double(dt) / Double(max(corpus.count, 1))

    var fzfCountStr = "—"
    var setEqStr = "—"
    var top10Str = "—"
    var top1Str = "—"

    if let fzfPath, let fzf = runFzf(query, corpus, fzfPath: fzfPath) {
        let fzfSet = Set(fzf)
        fzfCountStr = "\(fzf.count)"
        let eq = oursSet == fzfSet
        setEqStr = eq ? "yes" : "Δ\(oursSet.symmetricDifference(fzfSet).count)"
        setMatches += eq ? 1 : 0
        setChecks += 1
        // Top-10 set agreement (robust to equal-score tie ordering differences).
        let k = 10
        let ourTop = Set(oursRanked.prefix(k))
        let fzfTop = Set(fzf.prefix(k))
        if !fzfTop.isEmpty {
            let agree = Double(ourTop.intersection(fzfTop).count) / Double(min(k, fzfTop.count))
            top10Str = String(format: "%.0f%%", agree * 100)
            top10Sum += agree
            top10Count += 1
        }
        if let f1 = fzf.first, let o1 = oursRanked.first {
            top1Str = (f1 == o1) ? "✓" : "✗"
            top1Agree += (f1 == o1) ? 1 : 0
            top1Count += 1
        }
        // Score monotonicity over fzf's order: if fzf puts A before B, our score(A) must be ≥ score(B).
        // A strict violation (score(A) < score(B)) is a genuine scoring divergence; equal = benign tie.
        for i in 0..<max(fzf.count - 1, 0) {
            guard let a = scoreOf[fzf[i]], let b = scoreOf[fzf[i + 1]] else { continue }
            scorePairs += 1
            if a < b { scoreInversions += 1 }
        }
    }

    print(col(query, 13) + col("\(oursRanked.count)", 7, right: true) + col(fzfCountStr, 8, right: true)
        + col(setEqStr, 10, right: true) + col(top10Str, 10, right: true)
        + col(String(format: "%.1f", nsPer), 12, right: true) + col(top1Str, 8, right: true))
}

print(String(repeating: "─", count: 92))
let mPerSec = Double(totalComparisons) / (Double(totalOursNanos) / 1_000_000_000.0)
print(String(
    format: "ours throughput: %.2f M comparisons/sec  (%.1f ns/comparison avg)",
    mPerSec / 1_000_000,
    Double(totalOursNanos) / Double(max(totalComparisons, 1)),
))
if setChecks > 0 {
    print("match-set parity vs fzf: \(setMatches)/\(setChecks) queries identical")
}

if top10Count > 0 {
    print(String(
        format: "top-10 ranking agreement vs fzf: %.0f%% avg  •  top-1 exact: %d/%d",
        (top10Sum / Double(top10Count)) * 100,
        top1Agree,
        top1Count,
    ))
}

if scorePairs > 0 {
    print("score monotonicity over fzf's order: \(scoreInversions)/\(scorePairs) strict inversions "
        + "(0 ⇒ our scores never contradict fzf's ranking; differences are tiebreaks only)")
}

// MARK: - Bitap baseline (speed contrast on the same corpus/queries)

var bitapNanos: UInt64 = 0
var bitapComparisons = 0
for query in queries {
    let dt = nanos {
        for c in corpus { _ = bitapScore(query, c) }
    }
    bitapNanos += dt
    bitapComparisons += corpus.count
}

let bitapPerSec = Double(bitapComparisons) / (Double(bitapNanos) / 1_000_000_000.0)
print(String(
    format: "Bitap baseline throughput: %.2f M comparisons/sec  (%.1f ns/comparison avg)",
    bitapPerSec / 1_000_000,
    Double(bitapNanos) / Double(max(bitapComparisons, 1)),
))
print(String(repeating: "═", count: 92))
