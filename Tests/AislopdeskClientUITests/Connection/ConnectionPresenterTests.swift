import AislopdeskClient
import AislopdeskTransport
import XCTest
@testable import AislopdeskClientUI

/// Pins ``ConnectionPresenter`` (raw transport payloads → actionable copy) and the gate's recent-hosts
/// MRU on ``AppConnection``:
///
/// - ``ConnectionPresenter/friendlyFailure(_:)`` maps the known POSIX/NW payload shapes to messages
///   that say what to DO; unknown payloads pass through verbatim.
/// - ``ConnectionPresenter/headline(for:)`` distinguishes a first "Connecting…" from the campaign's
///   "Reconnecting — attempt N of 20"; ``rawDetail(for:)`` is non-nil only when the mapping rewrote.
/// - ``AppConnection/pushingRecent(_:into:limit:)`` dedupes by host:port (ports are settings, not
///   identity), fronts the newest, caps the list; failures never enter the MRU; the MRU round-trips
///   through an injected scratch `UserDefaults` suite.
@MainActor
final class ConnectionPresenterTests: XCTestCase {
    // MARK: - Reconnect cap is a single source of truth

    func testReconnectCapMirrorsTheOneConstant() {
        // The displayed "attempt N of M" cap and the per-pane transport campaign length must be the SAME
        // number, or the UI lies (it once showed "of 20" while the per-pane campaign ran to 30).
        XCTAssertEqual(
            ConnectionPresenter.maxReconnectAttempts,
            ReconnectManager.maxReconnectAttempts,
            "ConnectionPresenter must mirror ReconnectManager's give-up ceiling",
        )
    }

    // MARK: - friendlyFailure mapping

    func testFriendlyFailureMapsKnownPayloads() {
        XCTAssertTrue(ConnectionPresenter
            .friendlyFailure("POSIXErrorCode(rawValue: 61): Connection refused")
            .contains("aislopdesk-hostd"))
        XCTAssertTrue(ConnectionPresenter
            .friendlyFailure("No route to host")
            .contains("network or VPN"))
        XCTAssertTrue(ConnectionPresenter
            .friendlyFailure("timedOut(\"dial tcp: i/o timeout\")")
            .contains("didn't answer"))
        XCTAssertTrue(ConnectionPresenter
            .friendlyFailure("Network is down")
            .contains("Wi-Fi"))
        XCTAssertTrue(ConnectionPresenter
            .friendlyFailure("dns resolution failed: NoSuchRecord")
            .contains("host name"))
        XCTAssertTrue(ConnectionPresenter
            .friendlyFailure("Connection reset by peer")
            .contains("Restart aislopdesk-hostd"))
        // Handshake / version mismatch (AislopdeskTransportError.handshakeFailed's errorDescription).
        XCTAssertTrue(ConnectionPresenter
            .friendlyFailure("Handshake failed — is this an aislopdesk host?")
            .contains("versions match"))
        // A clean mid-session drop (receiveFailed → "Connection lost") and EOF/closed/pipe variants.
        XCTAssertTrue(ConnectionPresenter.friendlyFailure("Connection lost").contains("dropped"))
        XCTAssertTrue(ConnectionPresenter.friendlyFailure("read: EOF").contains("dropped"))
        XCTAssertTrue(ConnectionPresenter.friendlyFailure("Broken pipe").contains("dropped"))
        // A bare transport "Connection failed" is enriched with what to check.
        XCTAssertTrue(ConnectionPresenter.friendlyFailure("Connection failed").contains("aislopdesk-hostd"))
    }

    func testFriendlyFailurePassesUnknownPayloadsThrough() {
        let raw = "some exotic failure we cannot improve"
        XCTAssertEqual(ConnectionPresenter.friendlyFailure(raw), raw)
    }

    // MARK: - headline / rawDetail / shortLabel

    func testHeadlineDistinguishesConnectingFromReconnectCampaign() {
        XCTAssertEqual(ConnectionPresenter.headline(for: .connecting), "Connecting…")
        XCTAssertEqual(
            ConnectionPresenter.headline(for: .reconnecting(attempt: 3, nextRetry: nil)),
            "Reconnecting — attempt 3 of \(ConnectionPresenter.maxReconnectAttempts)",
        )
        XCTAssertEqual(
            ConnectionPresenter.headline(for: .reconnecting(attempt: 0, nextRetry: nil)),
            "Reconnecting…",
        )
    }

    func testRawDetailOnlyWhenMappingRewrote() {
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
    }

    func testShortLabelCompactsCampaignAndFailure() {
        XCTAssertEqual(
            ConnectionPresenter.shortLabel(for: .reconnecting(attempt: 7, nextRetry: nil)),
            "reconnecting 7/\(ConnectionPresenter.maxReconnectAttempts)",
        )
        XCTAssertEqual(
            ConnectionPresenter.shortLabel(for: .failed("huge raw NWError dump")),
            "failed",
            "the toolbar label never dumps a raw payload",
        )
        XCTAssertEqual(ConnectionPresenter.shortLabel(for: .connected), "connected")
    }

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
        let suiteName = "aislopdesk-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A FAILED connect (throwing registry) must not enter the MRU.
        let failing = ConnectionRegistry { _, _ in throw AislopdeskTransportError.timedOut("test") }
        let c = AppConnection(registry: failing, defaults: defaults)
        c.host = "10.0.0.9"
        c.port = "7420"
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
