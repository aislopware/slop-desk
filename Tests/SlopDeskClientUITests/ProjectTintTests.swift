// ProjectTintTests — pins the project-identity tint: the index is a LAUNCH-STABLE pure hash of the
// project key (FNV-1a over UTF-8 — never Swift's per-process-seeded `hashValue`, which would reshuffle
// every section's swatch colour on each relaunch), and the keyless "Other" bucket keeps a neutral
// swatch instead of borrowing a chromatic.

import XCTest
@testable import SlopDeskClientUI

final class ProjectTintTests: XCTestCase {
    /// The literal pins below are the FNV-1a-64 % 3 values — if these move, every user's project
    /// colours silently reshuffle on update, so the hash is frozen here.
    func testTintIndexIsLaunchStableAcrossProcesses() {
        XCTAssertEqual(ProjectTint.index(of: "herdr", count: 3), 0)
        XCTAssertEqual(ProjectTint.index(of: "~/api", count: 3), 1)
        XCTAssertEqual(ProjectTint.index(of: "slopdesk", count: 3), 2)
        XCTAssertEqual(ProjectTint.index(of: "/Users/abner/Workplace/herdr", count: 3), 0)
    }

    func testTintIndexStaysWithinCount() {
        for key in ["", "a", "/very/long/path/with/unicode/– dash", String(repeating: "x", count: 512)] {
            let index = ProjectTint.index(of: key, count: 3)
            XCTAssertTrue((0..<3).contains(index), "index \(index) escaped 0..<3 for key \(key)")
        }
    }

    @MainActor
    func testDistinctIndicesWearDistinctTints() {
        // herdr (0) and ~/api (1) land on different chromatics; the same key always re-resolves the
        // same colour.
        XCTAssertNotEqual(ProjectTint.color(for: "herdr"), ProjectTint.color(for: "~/api"))
        XCTAssertEqual(ProjectTint.color(for: "herdr"), ProjectTint.color(for: "herdr"))
    }

    @MainActor
    func testKeylessBucketKeepsTheNeutralSwatch() {
        // The "Other" bucket has no project identity to colour — it wears the muted metadata ink,
        // never a chromatic that would invent an identity.
        XCTAssertEqual(ProjectTint.color(for: nil), Slate.Text.tertiary)
    }
}
