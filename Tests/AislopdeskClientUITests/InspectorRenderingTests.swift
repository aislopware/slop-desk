// InspectorRenderingTests — the PURE logic the Git details window depends on (no view rendering,
// no libghostty / Metal / theme read). Covers the two headlessly-testable helpers `GitStatusView` leans on:
//   • `GitStatusPresentation` (porcelain-byte unpack → category + badge, the INVERSE of the host's
//     `HostMetadataProbe.statusNibble`/`packStatus`),
//   • `GitDiffPresentation` (unified-diff line classification + line split) — the diff overlay.
// (The other Details-panel helpers this file used to pin — MetadataFormatting / RemoteFileTree /
// AgentTranscript / InfoTabFormatting / DetailsPanelTab — were DELETED with the inspector column; the
// Git window is the panel's one surviving surface.)
//
// Each assertion would FAIL on a logic regression (a flipped nibble map, a missing `+++`-before-`+`
// order). NOT tautological — the git-status pins are tied to the host's packing convention.

import AislopdeskProtocol
import XCTest
@testable import AislopdeskClientUI

final class InspectorRenderingTests: XCTestCase {
    // MARK: - GitStatusPresentation (mirror of the host's nibble packing)

    func testStatusUnpackMirrorsHostPacking() {
        // Host packs (X<<4)|Y with space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9.
        // Worktree-modified ` M` → 0x01.
        XCTAssertEqual(GitStatusPresentation.category(0x01), .modified)
        XCTAssertEqual(GitStatusPresentation.badge(0x01), "M")
        // Staged-modified `M ` → 0x10 (the index char wins when the worktree is clean).
        XCTAssertEqual(GitStatusPresentation.category(0x10), .modified)
        XCTAssertEqual(GitStatusPresentation.badge(0x10), "M")
        // Staged-added `A ` → 0x20.
        XCTAssertEqual(GitStatusPresentation.category(0x20), .added)
        XCTAssertEqual(GitStatusPresentation.badge(0x20), "A")
        // Worktree-deleted ` D` → 0x03.
        XCTAssertEqual(GitStatusPresentation.category(0x03), .deleted)
        XCTAssertEqual(GitStatusPresentation.badge(0x03), "D")
        // Renamed `R ` → 0x40.
        XCTAssertEqual(GitStatusPresentation.category(0x40), .renamed)
        XCTAssertEqual(GitStatusPresentation.badge(0x40), "R")
        // Untracked `??` → 0x77.
        XCTAssertEqual(GitStatusPresentation.category(0x77), .untracked)
        XCTAssertEqual(GitStatusPresentation.badge(0x77), "?")
    }

    func testStatusUnpackXYAndUnknown() {
        let (x, y) = GitStatusPresentation.xy(0x12) // M index, A worktree
        XCTAssertEqual(x, "M")
        XCTAssertEqual(y, "A")
        // An all-blank / unrecognised packing → `unknown`, rendered as the neutral bullet (never a crash).
        XCTAssertEqual(GitStatusPresentation.category(0x00), .unknown)
        XCTAssertEqual(GitStatusPresentation.badge(0x00), "•")
        XCTAssertEqual(GitStatusPresentation.badge(0xF0), "•", "unrecognised high nibble → unknown")
    }

    // MARK: - GitDiffPresentation (unified-diff line classification)

    func testDiffClassifyTagsEachLineKind() {
        XCTAssertEqual(GitDiffPresentation.classify("@@ -1,2 +1,3 @@"), .hunk)
        XCTAssertEqual(GitDiffPresentation.classify("+++ b/file.swift"), .fileHeader)
        XCTAssertEqual(GitDiffPresentation.classify("--- a/file.swift"), .fileHeader)
        XCTAssertEqual(GitDiffPresentation.classify("diff --git a/x b/x"), .meta)
        XCTAssertEqual(GitDiffPresentation.classify("index 9abc..0def 100644"), .meta)
        XCTAssertEqual(GitDiffPresentation.classify("\\ No newline at end of file"), .meta)
        XCTAssertEqual(GitDiffPresentation.classify("+added"), .added)
        XCTAssertEqual(GitDiffPresentation.classify("-removed"), .removed)
        XCTAssertEqual(GitDiffPresentation.classify(" context"), .context)
    }

    func testDiffFileMarkersBeatBareAddRemove() {
        // `+++`/`---` MUST classify as file headers, not add/remove (the order-of-checks invariant).
        XCTAssertNotEqual(GitDiffPresentation.classify("+++ b/x"), .added)
        XCTAssertNotEqual(GitDiffPresentation.classify("--- a/x"), .removed)
    }

    func testDiffLinesSplitAndDropTrailingNewline() {
        let raw = "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n"
        let lines = GitDiffPresentation.lines(from: Data(raw.utf8))
        XCTAssertEqual(
            lines.map(\.kind),
            [.meta, .hunk, .removed, .added],
            "the trailing newline yields no phantom blank line",
        )
        XCTAssertEqual(lines.map(\.text), ["diff --git a/x b/x", "@@ -1 +1 @@", "-old", "+new"])
    }

    func testDiffLinesDecodeNonUTF8WithoutTrapping() {
        // A hostile / binary diff body must decode lossily, never trap.
        let bytes = Data([0xFF, 0xFE, 0x0A, 0x2B, 0x41]) // garbage, "\n", "+A"
        let lines = GitDiffPresentation.lines(from: bytes)
        XCTAssertEqual(lines.last?.kind, .added)
    }
}
