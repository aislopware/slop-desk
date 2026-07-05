import XCTest
@testable import SlopDeskWorkspaceCore

/// E10 WI-9 (ES-E10-6): pins the PURE Hint Mode engine ``HintLabelAssigner`` — Vimium-style 2-letter label
/// assignment, the type-to-filter resolve, and hintable-target detection (links via the shared detector, plus
/// git-hash / IPv4 / user `hint-pattern` forms with overlap dedupe + cell-accurate columns).
///
/// Headless + hang-safe: no `GhosttySurface`, no window server — the assigner is a deterministic text scan.
/// Revert-to-confirm-fail: each assertion targets behaviour that breaks if the corresponding rule is removed.
final class HintLabelAssignerTests: XCTestCase {
    // MARK: - Label assignment

    /// N targets get N UNIQUE, exactly-2-letter labels.
    func testLabelsAreUniqueAndTwoLetters() {
        let labels = HintLabelAssigner.labels(count: 30)
        XCTAssertEqual(labels.count, 30, "one label per target")
        XCTAssertTrue(labels.allSatisfy { $0.count == 2 }, "every label is exactly 2 letters")
        XCTAssertEqual(Set(labels).count, labels.count, "labels are collision-free")
    }

    /// Consecutive targets get DIFFERENT first letters (the first letter cycles fastest) so typing one key
    /// spreads the survivors instead of clustering them — the Vimium ergonomic.
    func testFirstLettersSpreadAcrossConsecutiveTargets() {
        let labels = HintLabelAssigner.labels(count: 4)
        let firsts = labels.map(\.first)
        XCTAssertEqual(Set(firsts).count, 4, "the first 4 labels each start with a distinct letter")
    }

    /// The 2-letter scheme is bounded at alphabet²: a request beyond it is clamped (never a 3-letter / ambiguous
    /// label). The caller then shows only the labelled prefix.
    func testLabelCountIsBoundedAtAlphabetSquared() {
        let k = HintLabelAssigner.defaultAlphabet.count
        let labels = HintLabelAssigner.labels(count: k * k + 50)
        XCTAssertEqual(labels.count, k * k, "clamped to alphabet² unique 2-letter labels")
        XCTAssertEqual(Set(labels).count, labels.count, "still collision-free at the cap")
    }

    func testLabelsEmptyForZeroOrNegativeCount() {
        XCTAssertTrue(HintLabelAssigner.labels(count: 0).isEmpty)
        XCTAssertTrue(HintLabelAssigner.labels(count: -3).isEmpty)
    }

    // MARK: - Filter (type-to-resolve)

    private let threeLabels = ["aa", "sa", "da"]

    /// No keys typed (also the reset / post-Esc state): every label matches, none dim, nothing confirmed.
    func testFilterEmptyMatchesAll() {
        let result = HintLabelAssigner.filter(typed: "", labels: threeLabels)
        XCTAssertEqual(result.matched, threeLabels)
        XCTAssertTrue(result.dimmed.isEmpty)
        XCTAssertNil(result.confirmed)
    }

    /// One letter dims the labels that don't start with it — and confirms NOTHING yet (a 2-letter label needs 2 keys).
    func testFilterFirstLetterDimsNonMatching() {
        let result = HintLabelAssigner.filter(typed: "a", labels: threeLabels)
        XCTAssertEqual(result.matched, ["aa"], "only 'aa' starts with 'a'")
        XCTAssertEqual(result.dimmed, ["sa", "da"])
        XCTAssertNil(result.confirmed, "one letter never confirms")
    }

    /// The second letter confirms the exact label — no Enter.
    func testFilterSecondLetterConfirms() {
        let result = HintLabelAssigner.filter(typed: "sa", labels: threeLabels)
        XCTAssertEqual(result.confirmed, "sa", "the full 2-letter label resolves immediately")
        XCTAssertEqual(result.matched, ["sa"])
    }

    /// A 2-letter prefix that is NOT a label confirms nothing (the caller ignores the stray second key).
    func testFilterTwoLettersNonLabelDoesNotConfirm() {
        let result = HintLabelAssigner.filter(typed: "ab", labels: threeLabels)
        XCTAssertNil(result.confirmed)
        XCTAssertTrue(result.matched.isEmpty, "no label starts with 'ab'")
    }

    /// Matching is case-insensitive (the typed letters are lower-cased before comparison).
    func testFilterIsCaseInsensitive() {
        XCTAssertEqual(HintLabelAssigner.filter(typed: "A", labels: threeLabels).matched, ["aa"])
        XCTAssertEqual(HintLabelAssigner.filter(typed: "SA", labels: threeLabels).confirmed, "sa")
    }

    // MARK: - Target detection: links + git-hash + IP + custom

    /// A path span is detected via the shared ``TerminalLinkDetector`` and carried as a `.link` target (so the
    /// actuator reuses the same `LinkActionPolicy`).
    func testDetectsPathLink() throws {
        let targets = HintLabelAssigner.targets(
            rows: ["see /usr/local/bin/tool here"], cwd: nil, schemes: .all,
        )
        let path = try XCTUnwrap(targets.first { $0.raw == "/usr/local/bin/tool" })
        guard case let .link(link) = path.kind else {
            XCTFail("path is a .link target")
            return
        }
        XCTAssertEqual(link.kind, .absolutePath)
    }

    /// A commit-hash-shaped token (`[0-9a-f]{7,40}` with ≥1 hex letter) is detected as `.gitHash`.
    func testDetectsGitHash() throws {
        let targets = HintLabelAssigner.targets(rows: ["commit a1b2c3d4 ok"], cwd: nil, schemes: .all)
        let hash = try XCTUnwrap(targets.first { $0.raw == "a1b2c3d4" })
        XCTAssertEqual(hash.kind, .gitHash)
    }

    /// A PURE-decimal run is NOT a git hash (it needs a hex LETTER) — so a long number never lights up.
    func testPureDecimalIsNotAGitHash() {
        let targets = HintLabelAssigner.targets(rows: ["build 1234567 done"], cwd: nil, schemes: .all)
        XCTAssertFalse(targets.contains { $0.raw == "1234567" }, "a 7-digit decimal is not a commit hash")
    }

    /// A dotted-quad IPv4 (octets ≤255) is detected as `.ipAddress`; an out-of-range octet is rejected.
    func testDetectsIPv4() throws {
        let targets = HintLabelAssigner.targets(rows: ["host 192.168.1.10 up"], cwd: nil, schemes: .all)
        let ip = try XCTUnwrap(targets.first { $0.raw == "192.168.1.10" })
        XCTAssertEqual(ip.kind, .ipAddress)

        let bad = HintLabelAssigner.targets(rows: ["host 999.1.1.1 up"], cwd: nil, schemes: .all)
        XCTAssertFalse(bad.contains { $0.kind == .ipAddress }, "999 is not a valid octet")
    }

    /// A user `hint-pattern` match is a `.custom` target carrying its `{0}` action template (the
    /// `hint-pattern` / `hint-pattern-action` config pair).
    func testDetectsCustomHintPattern() throws {
        let pattern = HintPattern(regex: "TICKET-\\d+", action: "open https://linear.app/issue/{0}")
        let targets = HintLabelAssigner.targets(
            rows: ["fix TICKET-123 today"], cwd: nil, schemes: .all, patterns: [pattern],
        )
        let custom = try XCTUnwrap(targets.first { $0.raw == "TICKET-123" })
        XCTAssertEqual(custom.kind, .custom(actionTemplate: "open https://linear.app/issue/{0}"))
    }

    /// An INVALID user regex is dropped (validate-then-drop) — never a trap; other targets still resolve.
    func testInvalidCustomPatternIsDroppedNotTrapped() {
        let bad = HintPattern(regex: "([unclosed", action: nil)
        let targets = HintLabelAssigner.targets(
            rows: ["host 10.0.0.1 up"], cwd: nil, schemes: .all, patterns: [bad],
        )
        XCTAssertTrue(targets.contains { $0.kind == .ipAddress }, "the IP still resolves past the bad regex")
    }

    /// An extra (git-hash) match INSIDE a detected URL span is dropped (overlap dedupe) — the row keeps ONE
    /// target (the URL link), not a duplicate hash for the hex tail.
    func testOverlappingHexInsideURLIsNotDoubleDetected() {
        let targets = HintLabelAssigner.targets(
            rows: ["open https://example.com/abcdef1234 now"], cwd: nil, schemes: .all,
        )
        XCTAssertEqual(targets.count, 1, "only the URL link — the hex tail inside it does NOT also light as a hash")
        guard case .link = targets.first?.kind else {
            XCTFail("the single target is the URL link")
            return
        }
    }

    // MARK: - Cell-accurate columns (East-Asian-wide aware)

    /// The extra (regex) targets carry DISPLAY-CELL columns, matching the detector's convention: an ASCII
    /// prefix advances one cell per char.
    func testExtraTargetCellColumnsASCII() throws {
        let targets = HintLabelAssigner.targets(rows: ["x 192.168.0.1"], cwd: nil, schemes: .all)
        let ip = try XCTUnwrap(targets.first { $0.kind == .ipAddress })
        XCTAssertEqual(ip.colStart, 2, "'x ' = 2 cells before the IP")
        XCTAssertEqual(ip.colEnd, 2 + "192.168.0.1".count, "colEnd spans the dotted-quad")
    }

    /// A fullwidth (East-Asian-wide) glyph before the match counts as TWO cells — so the badge lands on the
    /// right cell on a CJK line (the columns align with the link spans).
    func testExtraTargetCellColumnsWideGlyph() throws {
        let targets = HintLabelAssigner.targets(rows: ["中 192.168.0.1"], cwd: nil, schemes: .all)
        let ip = try XCTUnwrap(targets.first { $0.kind == .ipAddress })
        XCTAssertEqual(ip.colStart, 3, "中(2 cells) + space(1) = 3 cells before the IP")
    }

    // MARK: - Bounds / safety

    /// `maxScanColumns == 0` short-circuits to no targets (the anti-hang bound's edge).
    func testZeroScanColumnsYieldsNoTargets() {
        XCTAssertTrue(
            HintLabelAssigner.targets(
                rows: ["host 10.0.0.1"], cwd: nil, schemes: .all, maxScanColumns: 0,
            ).isEmpty,
        )
    }

    /// Targets are returned row-major, left-to-right (the order labels are then assigned in).
    func testTargetsAreOrderedRowMajor() {
        let targets = HintLabelAssigner.targets(
            rows: ["a 10.0.0.1 b 10.0.0.2", "c 10.0.0.3"], cwd: nil, schemes: .all,
        )
        let ips = targets.filter { $0.kind == .ipAddress }
        XCTAssertEqual(ips.map(\.raw), ["10.0.0.1", "10.0.0.2", "10.0.0.3"], "row-major, left-to-right")
    }
}
