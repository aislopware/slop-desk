// CommandElapsedChipTests — pins the long-command elapsed/outcome chip's PURE rules (design-craft pass,
// 2026-07-04): the ≥2s appear threshold, the coarse elapsed label, the watched-it-run latch (a reconnect
// resync of already-completed history must NEVER flash a stale outcome), and the progress-ring upgrade of
// the sidebar `.running` badge. Headless VALUE assertions — no SwiftUI render.

import AislopdeskWorkspaceCore
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class CommandElapsedChipTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Presentation thresholds + labels

    /// The running chip stays hidden under the 2s threshold and shows from 2s on.
    func testRunningVisibilityThreshold() {
        XCTAssertFalse(ElapsedChipPresentation.runningVisible(firstSeen: t0, now: t0.addingTimeInterval(1.9)))
        XCTAssertTrue(ElapsedChipPresentation.runningVisible(firstSeen: t0, now: t0.addingTimeInterval(2.0)))
    }

    /// Coarse elapsed formatting: whole seconds under a minute, then "Nm SSs" with a padded second.
    func testElapsedLabelFormatting() {
        XCTAssertEqual(ElapsedChipPresentation.elapsedLabel(from: t0, now: t0.addingTimeInterval(4.7)), "4s")
        XCTAssertEqual(ElapsedChipPresentation.elapsedLabel(from: t0, now: t0.addingTimeInterval(65)), "1m 05s")
        XCTAssertEqual(ElapsedChipPresentation.elapsedLabel(from: t0, now: t0.addingTimeInterval(754)), "12m 34s")
        // A clock that runs backwards (resync weirdness) clamps to zero, never a negative label.
        XCTAssertEqual(ElapsedChipPresentation.elapsedLabel(from: t0, now: t0.addingTimeInterval(-5)), "0s")
    }

    /// The outcome gate follows the HOST-measured duration: only commands ≥ the appear threshold flash.
    func testOutcomeGateOnHostDuration() {
        XCTAssertFalse(ElapsedChipPresentation.showsOutcome(durationMS: nil))
        XCTAssertFalse(ElapsedChipPresentation.showsOutcome(durationMS: 1999))
        XCTAssertTrue(ElapsedChipPresentation.showsOutcome(durationMS: 2000))
    }

    // MARK: Watched-it-run latch

    /// The happy path: a block folded RUNNING then COMPLETE (long enough) latches its outcome.
    func testLatchRunningThenCompleteLatchesOutcome() {
        var latch = ElapsedChipLatch()
        XCTAssertFalse(latch.fold(latestIndex: 7, complete: false, durationMS: nil))
        XCTAssertTrue(latch.fold(latestIndex: 7, complete: true, durationMS: 3500))
        XCTAssertEqual(latch.outcomeIndex, 7)
        latch.clearOutcome()
        XCTAssertNil(latch.outcomeIndex)
    }

    /// The resync guard: a block that arrives ALREADY complete (never folded running here) must not
    /// latch — reconnect history floods would otherwise flash stale outcomes.
    func testLatchIgnoresBlocksNeverSeenRunning() {
        var latch = ElapsedChipLatch()
        XCTAssertFalse(latch.fold(latestIndex: 3, complete: true, durationMS: 60000))
        XCTAssertNil(latch.outcomeIndex)
    }

    /// A short command (< 2s host duration) completes without an outcome even when watched running.
    func testLatchSkipsShortCommands() {
        var latch = ElapsedChipLatch()
        _ = latch.fold(latestIndex: 9, complete: false, durationMS: nil)
        XCTAssertFalse(latch.fold(latestIndex: 9, complete: true, durationMS: 300))
        XCTAssertNil(latch.outcomeIndex)
    }

    /// A NEW running block supersedes the old candidate: the stale index can no longer latch.
    func testLatchRunningIndexSupersedes() {
        var latch = ElapsedChipLatch()
        _ = latch.fold(latestIndex: 1, complete: false, durationMS: nil)
        _ = latch.fold(latestIndex: 2, complete: false, durationMS: nil)
        XCTAssertFalse(latch.fold(latestIndex: 1, complete: true, durationMS: 9000))
        XCTAssertNil(latch.outcomeIndex)
    }

    // MARK: Sidebar progress ring

    /// A `.running` badge with a DETERMINATE OSC 9;4 percent upgrades to the ring (fraction + label);
    /// indeterminate/absent progress keeps the plain spinner, and a non-running kind never rings.
    func testRunningBadgeUpgradesToRingOnDeterminateProgress() {
        XCTAssertEqual(
            StatusPresentation.tabBadge(.running, progress: .determinate(percent: 42)),
            .ring(fraction: 0.42, label: "42%"),
        )
        XCTAssertEqual(StatusPresentation.tabBadge(.running, progress: .indeterminate), .spinner)
        XCTAssertEqual(StatusPresentation.tabBadge(.running, progress: nil), .spinner)
        XCTAssertEqual(
            StatusPresentation.tabBadge(.error, progress: .determinate(percent: 42)),
            StatusPresentation.tabBadge(.error),
        )
    }
}
