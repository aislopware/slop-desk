// SimulatorSidebarModelTests — the panel's state machine, with no server and no socket.
//
// Both seams the model was built around are exercised here: ``SimulatorControlling`` stands in for
// the HTTP half, and the stream factory for the websocket. Nothing in this file constructs an
// `NWConnection` or a display layer — the hang-safety rule.

#if os(macOS)
import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskClientUI

// MARK: - Doubles

/// A scripted control plane. A lifecycle call mutates what the NEXT list says, because the model
/// reads the state back rather than assuming it — without that, the read-back assertions below would
/// prove nothing.
private final class FakeControl: SimulatorControlling, @unchecked Sendable {
    var devices: [SimulatorDevice] = []
    var failure: Error?
    private(set) var booted: [String] = []
    private(set) var shutDown: [String] = []
    private(set) var listCalls = 0

    // Sync witnesses legally satisfy the protocol's `async` requirements — the repo's fake idiom,
    // and what keeps the strict `async_without_await` rule off bodies that have nothing to await.
    func devices(host _: String, port _: UInt16) throws -> [SimulatorDevice] {
        listCalls += 1
        if let failure { throw failure }
        return devices
    }

    func boot(host _: String, port _: UInt16, udid: String) throws {
        if let failure { throw failure }
        booted.append(udid)
        mark(udid, isBooted: true)
    }

    func shutdown(host _: String, port _: UInt16, udid: String) throws {
        if let failure { throw failure }
        shutDown.append(udid)
        mark(udid, isBooted: false)
    }

    private func mark(_ udid: String, isBooted: Bool) {
        guard let index = devices.firstIndex(where: { $0.udid == udid }) else { return }
        devices[index].isBooted = isBooted
        devices[index].state = isBooted ? "Booted" : "Shutdown"
    }

    // MARK: The device-control half

    /// What the panel asked the device to do, in order — one log for every route that only SETS, so a
    /// test can assert the wire value rather than the fact that a call happened.
    private(set) var orientations: [String] = []
    private(set) var statusBars: [[String: String]] = []
    private(set) var files: [(name: String, bytes: Int)] = []
    private(set) var screenshots = 0
    /// Answered by ``chrome``. Nil is the "this model has no description" case the panel must survive.
    var chromeResult: SimulatorChrome?
    /// Answered by ``screenshot`` — JPEG bytes in the real thing, arbitrary here.
    var screenshotResult = Data()

    func chrome(host _: String, port _: UInt16, udid _: String) throws -> SimulatorChrome {
        if let failure { throw failure }
        guard let chromeResult else { throw SimulatorControlError.malformedResponse }
        return chromeResult
    }

    func resource(host _: String, port _: UInt16, reference _: String) throws -> Data {
        if let failure { throw failure }
        return Data()
    }

    func setOrientation(host _: String, port _: UInt16, udid _: String, value: String) throws {
        if let failure { throw failure }
        orientations.append(value)
    }

    func screenshot(host _: String, port _: UInt16, udid _: String) throws -> Data {
        if let failure { throw failure }
        screenshots += 1
        return screenshotResult
    }

    func setStatusBar(
        host _: String, port _: UInt16, udid _: String, overrides: [String: String],
    ) throws {
        if let failure { throw failure }
        statusBars.append(overrides)
    }

    func sendFile(
        host _: String, port _: UInt16, udid _: String, name: String, contents: Data,
    ) throws {
        if let failure { throw failure }
        files.append((name, contents.count))
    }
}

@MainActor
private final class FakeStream: SimulatorStreaming {
    /// The model's own event handler, kept so a test can play the server's part.
    let sink: (SimulatorStreamEvent) -> Void
    private(set) var connectedTo: (host: String, port: UInt16, udid: String)?
    private(set) var disconnects = 0
    private(set) var sent: [SimulatorInputEnvelope] = []

    init(sink: @escaping (SimulatorStreamEvent) -> Void) {
        self.sink = sink
    }

    func connect(host: String, port: UInt16, udid: String) {
        connectedTo = (host, port, udid)
    }

    func disconnect() { disconnects += 1 }

    func send(_ envelope: SimulatorInputEnvelope) { sent.append(envelope) }
}

// MARK: - Tests

@MainActor
final class SimulatorSidebarModelTests: XCTestCase {
    private let host = "10.0.0.2"
    private let port: UInt16 = 51234

    private func device(_ udid: String, booted: Bool = false) -> SimulatorDevice {
        SimulatorDevice(
            udid: udid, name: "iPhone \(udid)", runtime: "iOS 26.0",
            state: booted ? "Booted" : "Shutdown", isBooted: booted,
        )
    }

    /// A model already at `.ready`, plus a peek at the most recently built stream.
    private func readyModel(_ control: FakeControl) async -> (SimulatorSidebarModel, () -> FakeStream?) {
        var latest: FakeStream?
        let model = SimulatorSidebarModel(control: control) { sink in
            let stream = FakeStream(sink: sink)
            latest = stream
            return stream
        }
        await model.poll(host: { [host] in host }, ensure: { [port] in .init(state: .ready, port: port) })
        return (model, { latest })
    }

    private func model(_ control: FakeControl = FakeControl()) -> SimulatorSidebarModel {
        SimulatorSidebarModel(control: control) { FakeStream(sink: $0) }
    }

    // MARK: The phase machine

    func testNoEndpointIsOfflineNotUnavailable() {
        // A host too old for verb 21, or no connected pane channel, answers nothing. That is "come
        // back later", NOT "baguette is missing" — the install hint would name a problem the user
        // does not have.
        XCTAssertEqual(SimulatorSidebarModel.phase(for: nil, host: "h"), .offline)
    }

    func testTheThreeServerStatesMapStraightThrough() {
        XCTAssertEqual(
            SimulatorSidebarModel.phase(for: .init(state: .starting, port: 0), host: "h"), .starting,
        )
        XCTAssertEqual(
            SimulatorSidebarModel.phase(for: .init(state: .unavailable, port: 0), host: "h"), .unavailable,
        )
        XCTAssertEqual(
            SimulatorSidebarModel.phase(for: .init(state: .ready, port: 7), host: "h"),
            .ready(host: "h", port: 7),
        )
    }

    func testAReadyEndpointWithNothingToDialDegradesToOffline() {
        // Degrading rather than trapping: the ensure loop keeps running, and the panel recovers on
        // its own once the connection names a host.
        XCTAssertEqual(
            SimulatorSidebarModel.phase(for: .init(state: .ready, port: 8080), host: nil), .offline,
        )
        XCTAssertEqual(
            SimulatorSidebarModel.phase(for: .init(state: .ready, port: 8080), host: ""), .offline,
        )
        XCTAssertEqual(
            SimulatorSidebarModel.phase(for: .init(state: .ready, port: 0), host: "h"), .offline,
        )
    }

    func testPollReturnsOnReadyAndReadsTheHostPerRound() async {
        // The host is read per round on purpose: a reconnect can retarget the connection mid-loop,
        // and baking the first answer in would leave the panel dialling the previous machine.
        var answers = ["stale", "current"]
        var rounds = 0
        let model = model()
        await model.poll(
            host: { answers.isEmpty ? nil : answers.removeFirst() },
            ensure: {
                rounds += 1
                return .init(state: rounds == 1 ? .starting : .ready, port: 900)
            },
            interval: .zero,
        )
        XCTAssertEqual(model.phase, .ready(host: "current", port: 900))
        XCTAssertEqual(rounds, 2)
    }

    func testPollKeepsGoingPastUnavailable() async {
        // `brew install baguette` mid-session is picked up without restarting anything.
        var rounds = 0
        let model = model()
        await model.poll(
            host: { "h" },
            ensure: {
                rounds += 1
                return .init(state: rounds == 1 ? .unavailable : .ready, port: 7000)
            },
            interval: .zero,
        )
        XCTAssertEqual(model.phase, .ready(host: "h", port: 7000))
    }

    func testPollStopsOnCancellation() async {
        // A never-ready server must not outlive the surface: the column's `.task` cancels on unmount,
        // and the loop has to notice — otherwise leaving the tab keeps the host polled forever.
        let model = model()
        let task = Task { @MainActor in
            await model.poll(
                host: { "h" }, ensure: { .init(state: .starting, port: 0) }, interval: .milliseconds(1),
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await task.value
        XCTAssertEqual(model.phase, .starting)
    }

    func testReloadBumpsTheGenerationTheColumnKeysOn() {
        let model = model()
        XCTAssertEqual(model.generation, 0)
        model.requestReload()
        // The column's `.task` is keyed on this, so a bump is what restarts the ensure loop and
        // respawns a server that died.
        XCTAssertEqual(model.generation, 1)
    }

    // MARK: The device list

    func testRefreshIsANoOpUntilTheServerIsReady() async {
        // Nothing to ask before there is an address; asking anyway would spend a round trip against
        // a port the panel has not been told about.
        let control = FakeControl()
        await model(control).refreshDevices()
        XCTAssertEqual(control.listCalls, 0)
    }

    func testAFailedListLeavesTheLastKnownDevicesInPlace() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true)]
        let (model, _) = await readyModel(control)
        await model.refreshDevices()
        XCTAssertEqual(model.devices.count, 1)

        control.failure = SimulatorControlError.status(503)
        await model.refreshDevices()
        // The devices survive; only the notice is new. Blanking the list on one failed poll would
        // make a flaky link look like a device set that vanished.
        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(model.failure, "The simulator server answered 503.")
    }

    func testASuccessfulListClearsAStaleFailure() async {
        let control = FakeControl()
        control.failure = SimulatorControlError.malformedResponse
        let (model, _) = await readyModel(control)
        await model.refreshDevices()
        XCTAssertNotNil(model.failure)

        control.failure = nil
        control.devices = [device("A")]
        await model.refreshDevices()
        XCTAssertNil(model.failure)
    }

    // MARK: Lifecycle

    func testBootReadsTheStateBackRatherThanAssumingIt() async {
        let control = FakeControl()
        control.devices = [device("A")]
        let (model, _) = await readyModel(control)
        await model.boot("A")
        XCTAssertEqual(control.booted, ["A"])
        // The request succeeding means the server ACCEPTED it, not that the device reached the
        // state. The list that follows is the truth, and it is what the row renders.
        XCTAssertEqual(model.devices.first?.isBooted, true)
        XCTAssertTrue(model.pending.isEmpty)
    }

    func testAFailedBootSurfacesAndLeavesNothingPending() async {
        let control = FakeControl()
        control.devices = [device("A")]
        control.failure = SimulatorControlError.status(409)
        let (model, _) = await readyModel(control)
        await model.boot("A")
        XCTAssertEqual(model.failure, "The simulator server answered 409.")
        // A stuck pending flag would leave the row spinning with no way back.
        XCTAssertTrue(model.pending.isEmpty)
    }

    func testShuttingDownTheStreamedDeviceDropsTheStreamFirst() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true)]
        let (model, stream) = await readyModel(control)
        model.select("A")
        XCTAssertNotNil(stream()?.connectedTo)

        await model.shutdown("A")
        // Order matters: holding the socket open across the shutdown leaves the panel decoding a
        // stream the server is about to kill, and the frozen final frame reads as a hang.
        XCTAssertNil(model.selection)
        XCTAssertEqual(stream()?.disconnects, 1)
        XCTAssertEqual(control.shutDown, ["A"])
    }

    // MARK: Selection and the stream

    func testSelectingDialsTheServersAddressForThatDevice() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        XCTAssertEqual(stream()?.connectedTo?.host, host)
        XCTAssertEqual(stream()?.connectedTo?.port, port)
        XCTAssertEqual(stream()?.connectedTo?.udid, "A")
    }

    func testSelectingBeforeTheServerIsReadyOpensNothing() {
        // The list cannot be populated in this phase, so this only happens through a stale view —
        // and dialling a port the panel does not have would be a connection to nowhere.
        var built = 0
        let model = SimulatorSidebarModel(control: FakeControl()) { sink in
            built += 1
            return FakeStream(sink: sink)
        }
        model.select("A")
        XCTAssertEqual(built, 0)
    }

    func testReselectingTheSameDeviceDoesNotRestartAHealthyStream() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let first = stream()
        model.select("A")
        // Idempotent, because a re-render must not cost a reconnect and a fresh keyframe wait.
        XCTAssertIdentical(first, stream())
        XCTAssertEqual(first?.disconnects, 0)
    }

    func testSwitchingDevicesTearsTheOldSocketDown() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let first = stream()
        model.select("B")
        XCTAssertEqual(first?.disconnects, 1)
        XCTAssertEqual(stream()?.connectedTo?.udid, "B")
        XCTAssertNotIdentical(first, stream())
    }

    func testADeviceThatDisappearsFromTheListIsDeselected() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true)]
        let (model, stream) = await readyModel(control)
        await model.refreshDevices()
        model.select("A")

        control.devices = []
        await model.refreshDevices()
        // A deleted device (or a device-set switch) cannot stay selected: the stream is already dead
        // and the panel would show its last frame forever.
        XCTAssertNil(model.selection)
        XCTAssertEqual(stream()?.disconnects, 1)
    }

    func testAnEventFromATornDownStreamCannotPaintOverTheCurrentOne() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let stale = stream()
        model.select("B")

        stale?.sink(.text("device A is gone"))
        // The late event belongs to a device nobody is looking at; delivering it would put another
        // device's error over the live one.
        XCTAssertNil(model.failure)

        stream()?.sink(.text("device B refuses to stream"))
        XCTAssertEqual(model.failure, "device B refuses to stream")
    }

    func testFramesAdvanceTheSequenceEvenWhenTheBytesRepeat() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let unit = Data([0, 0, 0, 1, 0x65])
        stream()?.sink(.message(.accessUnit(unit, isKeyframe: true)))
        let first = model.frame.sequence
        stream()?.sink(.message(.accessUnit(unit, isKeyframe: true)))
        // SwiftUI coalesces equal values, and two identical delta frames are ordinary on a static
        // screen — without the counter the second one would never reach the layer.
        XCTAssertGreaterThan(model.frame.sequence, first)
        XCTAssertEqual(model.frame.latest, .accessUnit(unit, isKeyframe: true))
    }

    func testAMalformedConfigurationRecordIsDroppedRatherThanRendered() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let before = model.frame.sequence
        stream()?.sink(.message(.configuration(Data([0x01, 0x02]))))
        // Untrusted input: validate then drop. A half-parsed avcC would build a format description
        // that fails every decode after it.
        XCTAssertEqual(model.frame.sequence, before)
    }

    func testGoingBackToTheListDropsTheSocketAndTheFrame() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        stream()?.sink(.message(.jpeg(Data([0xFF, 0xD8]))))
        model.select(nil)
        XCTAssertNil(model.selection)
        XCTAssertEqual(stream()?.disconnects, 1)
        // Cleared, not left showing: the next selection must not open on the previous device's frame.
        XCTAssertEqual(model.frame.latest, .none)
    }

    func testInputGoesNowhereWithNothingSelected() async {
        let (model, stream) = await readyModel(FakeControl())
        model.send(.button("home"))
        XCTAssertNil(stream())

        model.select("A")
        model.send(.button("home"))
        XCTAssertEqual(stream()?.sent.count, 1)
    }

    // MARK: Device controls

    func testRotatingWalksTheCycleAndSendsTheServersOwnSpelling() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        await model.rotate(.right)
        await model.rotate(.right)
        await model.rotate(.left)
        XCTAssertEqual(control.orientations, ["landscape-right", "portrait-upside-down", "landscape-right"])
        XCTAssertEqual(model.orientation, .landscapeRight)
    }

    func testAFailedRotationLeavesTheRememberedAngleWhereItWas() async {
        // The angle is what the NEXT rotation is relative to. Advancing it on a call the server
        // refused would have every later rotation off by a quarter turn.
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        control.failure = SimulatorControlError.status(500)
        await model.rotate(.right)
        XCTAssertEqual(model.orientation, .portrait)
        XCTAssertEqual(model.failure, "The simulator server answered 500.")
    }

    func testRotationIsRefusedWithNothingSelected() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        await model.rotate(.right)
        XCTAssertTrue(control.orientations.isEmpty)
    }

    func testTheStatusBarToggleSendsThePresetThenTheClear() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        await model.toggleStatusBarOverride()
        XCTAssertTrue(model.isStatusBarOverridden)
        XCTAssertEqual(control.statusBars.first?["time"], "9:41")

        await model.toggleStatusBarOverride()
        XCTAssertFalse(model.isStatusBarOverridden)
        // Empty is how the client spells "clear"; the client turns that into the server's own flag.
        XCTAssertEqual(control.statusBars.last, [:])
    }

    func testAFailedStatusBarCallDoesNotFlipTheTogglesPosition() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        control.failure = SimulatorControlError.status(500)
        await model.toggleStatusBarOverride()
        XCTAssertFalse(model.isStatusBarOverridden)
    }

    func testBothDeviceSettingsResetWhenTheSelectionMoves() async {
        // Each is a claim about the PREVIOUS device. Carried over, the new screen would rotate from
        // the wrong angle and show the wrong toggle position.
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        await model.rotate(.right)
        await model.toggleStatusBarOverride()

        model.select("B")
        XCTAssertEqual(model.orientation, .portrait)
        XCTAssertFalse(model.isStatusBarOverridden)
    }

    func testAnUndecodableScreenshotIsReportedRatherThanSilentlyDropped() async {
        // The fake answers bytes that are not an image, which is what a server problem looks like
        // from here — and a capture that quietly does nothing is the worst version of that.
        let control = FakeControl()
        control.screenshotResult = Data([0x00, 0x01])
        let (model, _) = await readyModel(control)
        model.select("A")
        await model.copyScreenshot()
        XCTAssertEqual(control.screenshots, 1)
        XCTAssertEqual(model.failure, "The screenshot could not be read.")
        XCTAssertNil(model.notice)
    }

    func testADroppedFileIsSentUnderItsOwnNameAndConfirmed() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        await model.send(file: URL(fileURLWithPath: "/tmp/Demo.app"), contents: Data([1, 2, 3]))
        XCTAssertEqual(control.files.map(\.name), ["Demo.app"])
        XCTAssertEqual(control.files.first?.bytes, 3)
        XCTAssertEqual(model.notice, "Sent Demo.app")
        XCTAssertNil(model.failure)
    }

    func testAFileGoesNowhereWithNothingSelected() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        await model.send(file: URL(fileURLWithPath: "/tmp/Demo.app"), contents: Data([1]))
        XCTAssertTrue(control.files.isEmpty)
    }

    func testAFailedSendReportsAndClearsTheInFlightFlag() async {
        let control = FakeControl()
        control.failure = SimulatorControlError.status(415)
        let (model, _) = await readyModel(control)
        model.select("A")
        await model.send(file: URL(fileURLWithPath: "/tmp/Demo.app"), contents: Data([1]))
        XCTAssertEqual(model.failure, "The simulator server answered 415.")
        // Left set, the drop target would claim an upload is running forever.
        XCTAssertFalse(model.isSendingFile)
    }

    func testAViewRaisedFailureClearsAPendingConfirmation() async {
        // A file the sandbox will not let the view read never reaches the client, so the VIEW has to
        // be able to say so. Both share one banner slot: a "Sent Demo.app" left standing under
        // "Could not read Demo.app" would claim success and failure for the same drop.
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        await model.send(file: URL(fileURLWithPath: "/tmp/Demo.app"), contents: Data([1]))
        XCTAssertEqual(model.notice, "Sent Demo.app")
        model.report("Could not read Demo.app.")
        XCTAssertEqual(model.failure, "Could not read Demo.app.")
        XCTAssertNil(model.notice)
    }

    // MARK: Notices

    func testTheFailureCopyNamesWhatWentWrong() {
        XCTAssertEqual(
            SimulatorSidebarModel.describe(SimulatorControlError.noEndpoint),
            "No simulator server address.",
        )
        XCTAssertEqual(
            SimulatorSidebarModel.describe(SimulatorControlError.status(404)),
            "The simulator server answered 404.",
        )
        XCTAssertEqual(
            SimulatorSidebarModel.describe(SimulatorControlError.malformedResponse),
            "The simulator server sent something unexpected.",
        )
    }
}
#endif
