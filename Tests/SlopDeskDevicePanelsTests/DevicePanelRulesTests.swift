// DevicePanelRulesTests — the crossing for the decisions BOTH device panels make.
//
// The rules are `slopdesk_devicepanel`'s and pinned there; what these check is the door and the
// marshalling around it — that a `String?` host reaches the rule as an address or as nothing, that
// each kind byte comes back as the case it names, and that the backoff a phase carries is the one
// the loop sleeps on. They were two byte-identical copies of the same assertions, one per panel,
// which is exactly what a shared rule with a shared test replaces.

#if os(macOS)
import SlopDeskProtocol
import XCTest
@testable import SlopDeskDevicePanels

final class DevicePanelRulesTests: XCTestCase {
    private func endpoint(_ state: MetadataCodec.ServiceState, port: UInt16) -> MetadataCodec
        .ServiceEndpoint
    {
        MetadataCodec.ServiceEndpoint(state: state, port: port)
    }

    // MARK: The phase machine

    func testAReadyEndpointBecomesAnAddress() {
        XCTAssertEqual(
            DevicePanelRules.phase(for: endpoint(.ready, port: 7421), host: "10.0.0.2"),
            .ready(host: "10.0.0.2", port: 7421),
        )
    }

    func testNoAnswerAtAllIsOfflineAndKeepsPolling() {
        // No connected pane channel, or a host too old to know the verb. That is "come back later",
        // NOT "the tool is missing" — the install hint would name a problem nobody has.
        XCTAssertEqual(DevicePanelRules.phase(for: nil, host: "h"), .offline)
    }

    func testTheTwoWaitingStatesMapStraightThrough() {
        XCTAssertEqual(
            DevicePanelRules.phase(for: endpoint(.starting, port: 0), host: "h"), .starting,
        )
        XCTAssertEqual(
            DevicePanelRules.phase(for: endpoint(.unavailable, port: 0), host: "h"), .unavailable,
        )
    }

    func testAReadyEndpointWithNoUsableAddressDegradesRatherThanTraps() {
        // Both halves of an address are needed and neither is guaranteed: a ready state with port
        // zero is a host that answered before it bound, and a nil (or empty) host is a client
        // between connections. Degrading keeps the ensure loop running, so the panel recovers on its
        // own once there is something to dial.
        XCTAssertEqual(DevicePanelRules.phase(for: endpoint(.ready, port: 0), host: "h"), .offline)
        XCTAssertEqual(
            DevicePanelRules.phase(for: endpoint(.ready, port: 7421), host: nil), .offline,
        )
        XCTAssertEqual(DevicePanelRules.phase(for: endpoint(.ready, port: 7421), host: ""), .offline)
    }

    func testAnUnknownFutureStateKeepsPollingRatherThanClaimingTheToolIsMissing() {
        // The forward-tolerant carry, and it is the WIRE's rule rather than a second copy here: a
        // state byte this build cannot interpret must never render the install hint it cannot
        // justify.
        XCTAssertEqual(
            DevicePanelRules.phase(for: MetadataCodec.ServiceEndpoint(stateByte: 99, port: 0), host: "h"),
            .starting,
        )
    }

    func testTheLoopStopsOnReadyAndBacksOffOnTheOperatorPhases() {
        // Zero ends the loop that was looking for the service. One is the base cadence, for a boot
        // that is seconds away. Four is for the two phases that only change when someone installs
        // something or reconnects — asking four times as often would not make that happen sooner.
        XCTAssertEqual(DevicePanelRules.pollBackoff(.ready(host: "h", port: 1)), 0)
        XCTAssertEqual(DevicePanelRules.pollBackoff(.starting), 1)
        XCTAssertEqual(DevicePanelRules.pollBackoff(.offline), 4)
        XCTAssertEqual(DevicePanelRules.pollBackoff(.unavailable), 4)
    }

    // MARK: The wait's verdict

    /// The decision that turned a boot from a dead end into a wait. Measured 2026-08-07 against a
    /// cold boot: the mirror is refused for the first ~21 s, can stall ~15 s more the moment the
    /// device turns running, and succeeds cleanly after that — so silence while the device is not
    /// (yet) running means "again shortly", not "broken".
    func testABootingDeviceIsWaitedOnNotFailed() {
        XCTAssertEqual(DevicePanelRules.streamVerdict(isRunning: false, withinGrace: true), .wait)
    }

    func testAReadyDeviceIsConnectedTheMomentItTurnsUp() {
        XCTAssertEqual(DevicePanelRules.streamVerdict(isRunning: true, withinGrace: true), .connect)
    }

    func testPatienceRunsOutInTheRightWords() {
        // A running device with no video is the stall message with the retry button; a device that
        // never came up is its own sentence. Both only AFTER the grace window.
        XCTAssertEqual(DevicePanelRules.streamVerdict(isRunning: true, withinGrace: false), .stalled)
        XCTAssertEqual(
            DevicePanelRules.streamVerdict(isRunning: false, withinGrace: false), .neverReady,
        )
    }

    func testADeviceThatLeftTheListIsGoneWhateverThePatience() {
        XCTAssertEqual(DevicePanelRules.streamVerdict(isRunning: nil, withinGrace: true), .gone)
        XCTAssertEqual(DevicePanelRules.streamVerdict(isRunning: nil, withinGrace: false), .gone)
    }

    // MARK: The per-frame gate

    /// Only the FIRST frame is news, and this is the whole reason it is a function.
    ///
    /// `@Observable` notifies on assignment rather than on change, so a handler that writes
    /// `hasVideo = true` per access unit invalidates every view reading it at the frame rate — the
    /// stage rebuilding header, toolbar, device body and drawer on the main actor between the
    /// pointer events the user is making. It is the cost each panel's frame sink exists to keep out
    /// of the video path, leaking back in through one assignment.
    func testOnlyTheFirstFrameOfAStreamIsWorthTelling() {
        XCTAssertTrue(DevicePanelRules.videoArrivalIsNews(hasVideo: false, isAwaitingStream: true))
        XCTAssertFalse(DevicePanelRules.videoArrivalIsNews(hasVideo: true, isAwaitingStream: false))
    }

    func testARetryMakesTheNextFrameNewsAgain() {
        // A retry re-arms the wait, and the veil it raises has to come back down.
        XCTAssertTrue(DevicePanelRules.videoArrivalIsNews(hasVideo: true, isAwaitingStream: true))
        // A stream with neither video nor a wait outstanding is one the panel gave up on; its late
        // frame still ends the failure state.
        XCTAssertTrue(DevicePanelRules.videoArrivalIsNews(hasVideo: false, isAwaitingStream: false))
    }
}
#endif
