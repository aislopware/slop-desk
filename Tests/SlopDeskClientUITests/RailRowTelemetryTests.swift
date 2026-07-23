// RailRowTelemetryTests — pins the sidebar row's telemetry slot: the ≤4-character duration grammar and
// the one-value-per-row resolution (which badge shows which number, when it reveals, and its tone).
// The slot is AGES only — the failed exit code rides the badge's `!<code>` reading, never this slot.
// Headless VALUE assertions over the pure resolver — no view, no store, injected clock.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class RailRowTelemetryTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    // MARK: - The duration grammar (clamped ≤4 characters)

    func testCompactDurationGrammar() {
        XCTAssertEqual(RailRowTelemetry.compactDuration(0), "0s")
        XCTAssertEqual(RailRowTelemetry.compactDuration(42), "42s")
        XCTAssertEqual(RailRowTelemetry.compactDuration(59.9), "59s")
        XCTAssertEqual(RailRowTelemetry.compactDuration(60), "1m")
        XCTAssertEqual(RailRowTelemetry.compactDuration(12 * 60), "12m")
        XCTAssertEqual(RailRowTelemetry.compactDuration(59 * 60 + 59), "59m")
        XCTAssertEqual(RailRowTelemetry.compactDuration(64 * 60), "1h04")
        XCTAssertEqual(RailRowTelemetry.compactDuration(9 * 3600 + 59 * 60), "9h59")
        XCTAssertEqual(RailRowTelemetry.compactDuration(10 * 3600), ">9h")
        XCTAssertEqual(RailRowTelemetry.compactDuration(-5), "0s", "a negative interval clamps to zero")
    }

    /// Every grammar output fits the 4-character column — the reservation the layout depends on.
    func testCompactDurationNeverExceedsFourCharacters() {
        for interval in [0.0, 1, 59, 60, 61, 599, 600, 3599, 3600, 3840, 35940, 36000, 500_000] {
            XCTAssertLessThanOrEqual(
                RailRowTelemetry.compactDuration(interval).count, 4,
                "\(interval)s must fit the 4ch column",
            )
        }
    }

    // MARK: - Reveal delay (fresh states carry no number)

    func testYoungStatesShowNothing() {
        for badge in [TabBadgeKind.awaitingInput, .error, .running, .completed, .finished] {
            XCTAssertNil(
                RailRowTelemetry.value(
                    badge: badge,
                    attentionAt: ago(30), completedAt: ago(30), commandStartedAt: ago(30),
                    progressPercent: nil, now: now,
                ),
                "\(badge): under the 60s reveal the slot stays empty",
            )
        }
    }

    // MARK: - Per-badge resolution

    /// The blocked-age is the SOLE amber number — asked AND ignored is live attention data.
    func testAwaitingShowsAmberBlockedAge() {
        let value = RailRowTelemetry.value(
            badge: .awaitingInput,
            attentionAt: ago(12 * 60), completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(value, RailTelemetryValue(text: "12m", tone: .amber))
    }

    /// A working turn's elapsed stays on the grey ladder, escalating one luminance step at ≥10m.
    func testWorkingElapsedEscalatesAtTenMinutes() {
        let young = RailRowTelemetry.value(
            badge: .running,
            attentionAt: ago(5 * 60), completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(young, RailTelemetryValue(text: "5m", tone: .secondary))
        let stuck = RailRowTelemetry.value(
            badge: .running,
            attentionAt: ago(25 * 60), completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(stuck, RailTelemetryValue(text: "25m", tone: .primary))
    }

    /// An error shows its TIME-IN-ERROR — "how long has it sat broken". The exit code is the badge's
    /// `!<code>` reading, so the slot never repeats the number next to it.
    func testErrorShowsTimeInError() {
        let value = RailRowTelemetry.value(
            badge: .error,
            attentionAt: ago(4 * 60), completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(value, RailTelemetryValue(text: "4m", tone: .secondary))
    }

    /// A determinate OSC 9;4 percent shows immediately on the command tiers, displacing the elapsed.
    func testCommandPercentBeatsElapsed() {
        let value = RailRowTelemetry.value(
            badge: .commandRunning,
            attentionAt: nil, completedAt: nil, commandStartedAt: ago(10 * 60),
            progressPercent: "68%", now: now,
        )
        XCTAssertEqual(value, RailTelemetryValue(text: "68%", tone: .secondary))
    }

    /// Without a percent, a long-running command shows its elapsed from the command-start stamp.
    func testCommandElapsedFromStartStamp() {
        let value = RailRowTelemetry.value(
            badge: .commandBusy,
            attentionAt: nil, completedAt: nil, commandStartedAt: ago(14 * 60),
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(value, RailTelemetryValue(text: "14m", tone: .secondary))
    }

    /// The unread finish shows its age from the completion stamp.
    func testUnreadFinishShowsAge() {
        let value = RailRowTelemetry.value(
            badge: .finished,
            attentionAt: nil, completedAt: ago(8 * 60), commandStartedAt: nil,
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(value, RailTelemetryValue(text: "8m", tone: .secondary))
    }

    /// The privilege markers and the all-clear row carry no number, ever.
    func testPrivilegeAndClearShowNothing() {
        for badge in [TabBadgeKind.caffeinate, .sudo] {
            XCTAssertNil(RailRowTelemetry.value(
                badge: badge,
                attentionAt: ago(3600), completedAt: ago(3600), commandStartedAt: ago(3600),
                progressPercent: "50%", now: now,
            ))
        }
        XCTAssertNil(RailRowTelemetry.value(
            badge: nil,
            attentionAt: ago(3600), completedAt: ago(3600), commandStartedAt: ago(3600),
            progressPercent: "50%", now: now,
        ))
    }

    /// A state with no stamp shows nothing (no placeholder) rather than a bogus age.
    func testMissingStampShowsNothing() {
        XCTAssertNil(RailRowTelemetry.value(
            badge: .awaitingInput,
            attentionAt: nil, completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        ))
    }

    /// The LIVE progress-error wiring (an OSC 9;4;2 while the command still runs): no attention stamp
    /// exists yet — the slot stays empty rather than showing a stale number.
    func testProgressErrorWithoutStampShowsNothing() {
        XCTAssertNil(RailRowTelemetry.value(
            badge: .error,
            attentionAt: nil, completedAt: nil, commandStartedAt: ago(10 * 60),
            progressPercent: nil, now: now,
        ))
    }

    // MARK: - Exact boundaries

    /// The hour rung zero-pads its minutes so the column width is constant: exactly one hour is
    /// "1h00", never "1h" or "60m".
    func testHourBoundaryZeroPads() {
        XCTAssertEqual(RailRowTelemetry.compactDuration(3600), "1h00")
    }

    /// The reveal boundary: exactly 60s shows "1m"; one second under shows nothing.
    func testRevealBoundaryIsInclusive() {
        XCTAssertNil(RailRowTelemetry.value(
            badge: .awaitingInput,
            attentionAt: ago(59), completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        ))
        let atBoundary = RailRowTelemetry.value(
            badge: .awaitingInput,
            attentionAt: ago(60), completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(atBoundary, RailTelemetryValue(text: "1m", tone: .amber))
    }

    /// The working escalation boundary: exactly 10 minutes steps the tone to primary.
    func testEscalationBoundaryIsInclusive() {
        let under = RailRowTelemetry.value(
            badge: .running,
            attentionAt: ago(599), completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(under?.tone, .secondary)
        let at = RailRowTelemetry.value(
            badge: .running,
            attentionAt: ago(600), completedAt: nil, commandStartedAt: nil,
            progressPercent: nil, now: now,
        )
        XCTAssertEqual(at, RailTelemetryValue(text: "10m", tone: .primary))
    }
}
