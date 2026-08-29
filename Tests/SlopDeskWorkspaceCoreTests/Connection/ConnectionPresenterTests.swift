import SlopDeskClient
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING behind ``ConnectionPresenter`` and the gate's recent-hosts MRU on
/// ``AppConnection``.
///
/// What each failure payload MAPS to, how the campaign phrases itself and what a menu-bar label may
/// dump are `slopdesk_workspace::connection`'s, tested there (`every_failure_shape_gets_its_own_remedy`,
/// `an_unrecognised_payload_passes_through_verbatim`, `the_campaign_reads_honestly_in_both_registers`,
/// `a_failure_never_dumps_its_payload_into_a_menu_bar_label`). Restating them here would be the
/// cross-language mirror fixture `CLAUDE.md` forbids: two copies of one table, free to disagree, with
/// the Swift one able to stay green while the rule underneath it changed.
///
/// What is left is what only THIS side can get wrong:
///
/// - the reconnect ceiling is `ReconnectManager`'s, and it actually REACHES the door;
/// - the three registers come back from ONE crossing, in their own places;
/// - ``ConnectionStatus/terms`` names six states with six codes, and carries the two payloads the
///   cases hold;
/// - ``ConnectionPresenter/rawDetail(for:)`` answers with the caller's OWN string, never a copy that
///   made the trip;
/// - the MRU, which is not a port at all.
@MainActor
final class ConnectionPresenterTests: XCTestCase {
    // MARK: - The ceiling is one number, and it travels

    func testReconnectCapMirrorsTheOneConstant() {
        // The displayed "attempt N of M" cap and the per-pane transport campaign length must be the SAME
        // number, or the UI lies (it once showed "of 20" while the per-pane campaign ran to 30).
        XCTAssertEqual(
            ConnectionPresenter.maxReconnectAttempts,
            ReconnectManager.maxReconnectAttempts,
            "ConnectionPresenter must mirror ReconnectManager's give-up ceiling",
        )
    }

    /// The ceiling is an ARGUMENT to the door, and this is the failure that would prove it stopped
    /// being one: a rule crate holding its own copy would still print a number, just not this one.
    func testTheCeilingReachesBothRegistersOfTheCampaign() {
        let ceiling = ConnectionPresenter.maxReconnectAttempts
        let words = ConnectionPresenter.words(for: .reconnecting(attempt: 3, nextRetry: nil))
        XCTAssertEqual(words.headline, "Reconnecting — attempt 3 of \(ceiling)")
        XCTAssertEqual(words.shortLabel, "reconnecting 3/\(ceiling)")
    }

    // MARK: - One crossing, three registers

    func testTheThreeRegistersComeBackInTheirOwnPlaces() {
        // A delivery read in the wrong order is the port's own failure mode: three plausible strings,
        // each in the wrong slot, and every one of them a real answer to a different question.
        let words = ConnectionPresenter.words(for: .failed("Connection refused"))
        XCTAssertTrue(words.headline.contains("slopdesk-hostd"), "the gate card's actionable copy")
        XCTAssertEqual(words.shortLabel, "failed", "the toolbar's compact form")
        XCTAssertEqual(words.statusLabel, "failed: Connection refused", "the plain state name")
        XCTAssertEqual(ConnectionPresenter.headline(for: .failed("Connection refused")), words.headline)
        XCTAssertEqual(ConnectionPresenter.shortLabel(for: .failed("Connection refused")), words.shortLabel)
    }

    /// ``ConnectionStatus/label`` IS the third run — not a switch that happens to agree with it. The
    /// break this catches is the one the port exists to remove: a state named one thing by the enum
    /// and another by the door.
    func testTheStatusLabelIsTheDoorsThirdRunAndNotASecondSwitch() {
        for status in Self.everyStatus {
            XCTAssertEqual(status.label, ConnectionPresenter.statusLabel(for: status))
        }
    }

    // MARK: - The vocabulary

    func testEveryStateNamesItsOwnCodeAndCarriesItsOwnPayload() {
        XCTAssertEqual(
            Set(Self.everyStatus.map(\.terms.code)).count, Self.everyStatus.count,
            "six states, six codes — a collision would make two of them the same reading",
        )
        XCTAssertEqual(
            ConnectionStatus.reconnecting(attempt: 7, nextRetry: nil).terms.attempt, 7,
            "the campaign's progress crosses",
        )
        XCTAssertEqual(
            ConnectionStatus.failed("a raw dump").terms.raw, "a raw dump",
            "and so does the transport's payload",
        )
        XCTAssertEqual(
            ConnectionStatus.reconnecting(attempt: -1, nextRetry: nil).terms.attempt, 0,
            "a negative attempt is clamped rather than wrapped into a huge one",
        )
    }

    // MARK: - The payload never makes a round trip

    func testRawDetailAnswersWithTheCallersOwnString() {
        XCTAssertEqual(
            ConnectionPresenter.rawDetail(for: .failed("Connection refused")),
            "Connection refused",
            "a mapped failure keeps its raw payload as the tooltip",
        )
        XCTAssertNil(
            ConnectionPresenter.rawDetail(for: .failed("some exotic failure")),
            "a passthrough message would duplicate the headline",
        )
        XCTAssertNil(ConnectionPresenter.rawDetail(for: .connected))
        XCTAssertNil(ConnectionPresenter.rawDetail(for: .failed("")), "an empty payload rewrites nothing")
    }

    private static let everyStatus: [ConnectionStatus] = [
        .disconnected,
        .connecting,
        .connected,
        .reconnecting(attempt: 3, nextRetry: nil),
        .unreachable,
        .failed("Connection refused"),
    ]

    // MARK: - Recent-hosts MRU

    private func target(_ host: String, _ port: UInt16) -> ConnectionTarget {
        ConnectionTarget(host: host, port: port)
    }

    func testPushingRecentFrontsDedupesAndCaps() {
        var list: [ConnectionTarget] = []
        list = AppConnection.pushingRecent(target("a", 1), into: list)
        list = AppConnection.pushingRecent(target("b", 2), into: list)
        XCTAssertEqual(list.map(\.host), ["b", "a"], "newest first")

        // Re-connecting to an existing host:port REPLACES its entry (and re-fronts it) — even when
        // the video ports changed (ports are settings, host:port is the identity).
        let aNewPorts = ConnectionTarget(host: "a", port: 1, mediaPort: 9100, cursorPort: 9101)
        list = AppConnection.pushingRecent(aNewPorts, into: list)
        XCTAssertEqual(list.map(\.host), ["a", "b"])
        XCTAssertEqual(list.first?.mediaPort, 9100)

        for i in 0..<10 {
            list = AppConnection.pushingRecent(target("h\(i)", UInt16(100 + i)), into: list)
        }
        XCTAssertEqual(list.count, AppConnection.recentTargetsLimit, "capped")
        XCTAssertEqual(list.first?.host, "h9")
    }

    func testRecentTargetsRoundTripThroughDefaultsAndSkipFailures() async throws {
        let suiteName = "slopdesk-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // The domain AND the file, at process exit: emptying alone leaves a plist in
        // ~/Library/Preferences, and removing one mid-process lets cfprefsd write it back.
        SettingsKey.removeSuiteAtExit(named: suiteName)

        // A FAILED connect must not enter the MRU. The pool is real and the dial is real; loopback
        // port 1 refuses it, rather than an injected fake throwing on its behalf.
        let failing = ConnectionRegistry(connectTimeout: .milliseconds(50))
        let c = AppConnection(registry: failing, defaults: defaults)
        c.host = "127.0.0.1"
        c.port = "1"
        c.mediaPort = "9000"
        c.cursorPort = "9001"
        await c.connect()
        XCTAssertTrue(c.recentTargets.isEmpty, "failures never pollute the recents menu")

        // A persisted MRU loads back on the next AppConnection (simulated relaunch).
        let seeded = [target("studio", 7420), target("macbook", 7421)]
        try defaults.set(JSONEncoder().encode(seeded), forKey: "connection.recentTargets")
        let c2 = AppConnection(registry: failing, defaults: defaults)
        XCTAssertEqual(c2.recentTargets, seeded)

        // fillForm fills ALL FOUR fields from a pick.
        let pick = ConnectionTarget(host: "studio", port: 7420, mediaPort: 9100, cursorPort: 9101)
        c2.fillForm(from: pick)
        XCTAssertEqual(c2.host, "studio")
        XCTAssertEqual(c2.port, "7420")
        XCTAssertEqual(c2.mediaPort, "9100")
        XCTAssertEqual(c2.cursorPort, "9101")
    }
}
