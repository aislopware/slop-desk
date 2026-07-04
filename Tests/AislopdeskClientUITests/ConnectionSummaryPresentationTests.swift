// ConnectionSummaryPresentationTests — pins the ambient status item's trailing-summary contract
// (`StatusPresentation.connectionSummary`, UI restructure 2026-07-04): a CONNECTED item shows live
// telemetry only (metrics, never the word "connected"); a connected item with no sample yet shows
// NOTHING (nil — the dot + host alone read as connected); every non-connected state shows the status
// word. Headless VALUE assertions — no SwiftUI render. Each test fails on the pre-restructure code
// (the helper did not exist; the derivation lived inline in the deleted TitlebarConnectionCluster).

import AislopdeskWorkspaceCore
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class ConnectionSummaryPresentationTests: XCTestCase {
    /// Connected + both samples ⇒ the joined "ping · fps" metric string, flagged metric.
    func testConnectedWithPingAndFpsJoinsMetrics() {
        let summary = StatusPresentation.connectionSummary(status: .connected, pingMS: 9.4, fps: 30)
        XCTAssertEqual(summary?.text, "9 ms · 30 fps")
        XCTAssertEqual(summary?.isMetric, true)
    }

    /// Connected + ping only ⇒ just the ping (no fps segment, no separator).
    func testConnectedWithPingOnly() {
        let summary = StatusPresentation.connectionSummary(status: .connected, pingMS: 12.6, fps: nil)
        XCTAssertEqual(summary?.text, "13 ms")
        XCTAssertEqual(summary?.isMetric, true)
    }

    /// Connected with NO samples ⇒ nil — the healthy state collapses to dot + host (the dropped-
    /// "connected" rule: the word would be redundant ink).
    func testConnectedWithNoSamplesCollapsesToNil() {
        XCTAssertNil(StatusPresentation.connectionSummary(status: .connected, pingMS: nil, fps: nil))
    }

    /// A degraded state earns the space: the status word shows even when stale metrics are around,
    /// and it is flagged NON-metric (secondary tone, not tertiary mono).
    func testReconnectingShowsStatusWordNotStaleMetrics() {
        let summary = StatusPresentation.connectionSummary(
            status: .reconnecting(attempt: 3, nextRetry: nil), pingMS: 9, fps: 30,
        )
        XCTAssertEqual(summary?.text, ConnectionPresenter.shortLabel(for: .reconnecting(attempt: 3, nextRetry: nil)))
        XCTAssertEqual(summary?.isMetric, false)
    }

    /// Every non-connected state produces a non-empty status word (the item never renders blank while
    /// something is wrong).
    func testNonConnectedStatesAlwaysProduceText() {
        let states: [ConnectionStatus] = [
            .disconnected, .connecting, .reconnecting(attempt: 0, nextRetry: nil),
            .unreachable, .failed("boom"),
        ]
        for status in states {
            let summary = StatusPresentation.connectionSummary(status: status, pingMS: nil, fps: nil)
            XCTAssertEqual(summary?.isMetric, false, "\(status) must show a status word")
            XCTAssertFalse(summary?.text.isEmpty ?? true, "\(status) must not be blank")
        }
    }

    /// The breathing-dot gate (design-craft pass, 2026-07-04): ONLY `.connected` is a genuinely ongoing
    /// healthy state — every other status must keep a STILL dot (stillness beside the live dot is itself
    /// the degraded cue, and a looped ambient animation on a non-ongoing state is noise).
    func testOnlyConnectedIsLive() {
        XCTAssertTrue(StatusPresentation.isLive(.connected))
        let stillStates: [ConnectionStatus] = [
            .disconnected, .connecting, .reconnecting(attempt: 1, nextRetry: nil),
            .unreachable, .failed("boom"),
        ]
        for status in stillStates {
            XCTAssertFalse(StatusPresentation.isLive(status), "\(status) must NOT breathe")
        }
    }
}
