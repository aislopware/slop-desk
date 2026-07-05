// WorkspaceConnectionAlertTests — pins the C8 improvement-3 fold behind the collapsed-sidebar connection
// indicator: hidden when every pane is healthy, a count of the unhealthy panes, the worst severity by the
// sidebar's fold order (unreachable > failed > reconnecting), and the worst-pane click target with a stable
// first-at-worst tie-break. Pure value — headless, no view / no socket.

import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

final class WorkspaceConnectionAlertTests: XCTestCase {
    private func entry(_ status: ConnectionStatus?) -> (pane: PaneID, status: ConnectionStatus?) {
        (pane: PaneID(), status: status)
    }

    // MARK: - Hidden when healthy

    /// Every healthy / non-alarm status folds to `nil` (the chip renders nothing): connected, an initial
    /// `.connecting` dial, a deliberate `.disconnected`, and a pane with no PATH-1 connection (`nil` status).
    func testAllHealthyProducesNoAlert() {
        XCTAssertNil(WorkspaceConnectionAlert.resolve(from: []), "no panes ⇒ nothing to surface")
        XCTAssertNil(
            WorkspaceConnectionAlert.resolve(from: [
                entry(.connected), entry(.connecting), entry(.disconnected), entry(nil),
            ]),
            "no unhealthy pane ⇒ the indicator stays hidden",
        )
    }

    // MARK: - Count + worst severity

    /// A single reconnecting pane surfaces a 1-count amber (`.reconnecting`) alert with a "1 reconnecting"
    /// label, pointing at that pane. REVERT-TO-FAIL: a fold that returned nil for a live reconnect (or
    /// mislabelled it) would fail here.
    func testSingleReconnectingPane() throws {
        let target = PaneID()
        let alert = try XCTUnwrap(WorkspaceConnectionAlert.resolve(from: [
            (pane: target, status: .reconnecting(attempt: 2, nextRetry: nil)),
            entry(.connected),
        ]))
        XCTAssertEqual(alert.count, 1)
        XCTAssertEqual(alert.worst, .reconnecting)
        XCTAssertEqual(alert.worstPane, target, "the click target is the unhealthy pane")
        XCTAssertEqual(alert.label, "1 reconnecting")
    }

    /// The count spans EVERY unhealthy pane regardless of severity, and the worst is the highest-salience one.
    /// A reconnecting + a failed + an unreachable ⇒ count 3, worst unreachable, "3 unreachable".
    func testCountsAllUnhealthyAndPicksWorstSeverity() throws {
        let unreachable = PaneID()
        let alert = try XCTUnwrap(WorkspaceConnectionAlert.resolve(from: [
            (pane: PaneID(), status: .reconnecting(attempt: 0, nextRetry: nil)),
            (pane: PaneID(), status: .failed("refused")),
            (pane: unreachable, status: .unreachable),
            entry(.connected),
        ]))
        XCTAssertEqual(alert.count, 3, "every unhealthy pane is counted")
        XCTAssertEqual(alert.worst, .unreachable, "unreachable outranks failed + reconnecting")
        XCTAssertEqual(alert.worstPane, unreachable, "the click target is the worst-severity pane")
        XCTAssertEqual(alert.label, "3 unreachable")
    }

    /// `.failed` (an initial connect that never landed) reads to the user as "disconnected".
    func testFailedLabelReadsAsDisconnected() throws {
        let alert = try XCTUnwrap(WorkspaceConnectionAlert.resolve(from: [entry(.failed("timeout"))]))
        XCTAssertEqual(alert.worst, .failed)
        XCTAssertEqual(alert.label, "1 disconnected")
    }

    // MARK: - Worst-pane tie-break (stable, first-at-worst)

    /// Two panes at the SAME worst severity ⇒ the click target is the FIRST one in the caller's (stable, tree
    /// DFS) order — never the later one. Pins the deterministic tie-break.
    func testTieKeepsFirstPaneAtWorstSeverity() throws {
        let first = PaneID()
        let second = PaneID()
        let alert = try XCTUnwrap(WorkspaceConnectionAlert.resolve(from: [
            (pane: first, status: .failed("a")),
            (pane: second, status: .failed("b")),
        ]))
        XCTAssertEqual(alert.count, 2)
        XCTAssertEqual(alert.worst, .failed)
        XCTAssertEqual(alert.worstPane, first, "ties keep the earlier pane (stable order)")
    }

    /// A worst pane that appears AFTER a lower-severity one still wins the click target (severity beats
    /// position): a reconnecting pane first, then an unreachable one ⇒ the unreachable is the target.
    func testHigherSeverityLaterStillWinsTarget() throws {
        let worse = PaneID()
        let alert = try XCTUnwrap(WorkspaceConnectionAlert.resolve(from: [
            (pane: PaneID(), status: .reconnecting(attempt: 1, nextRetry: nil)),
            (pane: worse, status: .unreachable),
        ]))
        XCTAssertEqual(alert.worstPane, worse)
        XCTAssertEqual(alert.worst, .unreachable)
    }

    // MARK: - severity(of:) classification

    /// The per-status classifier: the three alarm states map to their severity, everything else to `nil`.
    func testSeverityClassification() {
        XCTAssertEqual(WorkspaceConnectionAlert.severity(of: .reconnecting(attempt: 0, nextRetry: nil)), .reconnecting)
        XCTAssertEqual(WorkspaceConnectionAlert.severity(of: .failed("x")), .failed)
        XCTAssertEqual(WorkspaceConnectionAlert.severity(of: .unreachable), .unreachable)
        XCTAssertNil(WorkspaceConnectionAlert.severity(of: .connected))
        XCTAssertNil(WorkspaceConnectionAlert.severity(of: .connecting))
        XCTAssertNil(WorkspaceConnectionAlert.severity(of: .disconnected))
        XCTAssertNil(WorkspaceConnectionAlert.severity(of: nil))
    }
}
