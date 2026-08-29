// SimulatorSidebarModelTests — the panel's state machine, with no server and no socket.
//
// Both seams the model was built around are exercised here: ``SimulatorControlling`` stands in for
// the HTTP half, and the stream factory for the websocket. Nothing in this file constructs an
// `NWConnection` or a display layer — the hang-safety rule.

#if os(macOS)
import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskDevicePanels

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
    private(set) var statusBars: [Bool] = []
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

    /// Which device each capture was asked for, in order — the stage takes the open one and the list
    /// names one that is not open, so "which" is the whole of what separates the two call sites.
    private(set) var screenshotUdids: [String] = []

    func screenshot(host _: String, port _: UInt16, udid: String) throws -> Data {
        if let failure { throw failure }
        screenshots += 1
        screenshotUdids.append(udid)
        return screenshotResult
    }

    /// The card's capture. Counted separately from ``screenshot`` because the two have opposite
    /// budgets and the model must not confuse them — a card polling the full-resolution route would
    /// cost thirty-five times the bytes.
    private(set) var thumbnails: [String] = []

    func thumbnail(host _: String, port _: UInt16, udid: String) throws -> Data {
        if let failure { throw failure }
        thumbnails.append(udid)
        return screenshotResult
    }

    func setStatusBar(host _: String, port _: UInt16, udid _: String, demo: Bool) throws {
        if let failure { throw failure }
        statusBars.append(demo)
    }

    func sendFile(
        host _: String, port _: UInt16, udid _: String, name: String, contents: Data,
    ) throws {
        if let failure { throw failure }
        files.append((name, contents.count))
    }

    /// Every position the panel asked for, `nil` standing for the DELETE that restores live values —
    /// so a test can tell a clear from a pin to the origin, which is the one pair the route's two
    /// methods make easy to confuse.
    private(set) var locations: [SimulatorCoordinate?] = []

    func setLocation(
        host _: String, port _: UInt16, udid _: String, coordinate: SimulatorCoordinate?,
    ) throws {
        if let failure { throw failure }
        locations.append(coordinate)
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

/// The console's socket, same shape and for the same reason: the model's console lifecycle is a
/// subscribe/unsubscribe machine, and testing it against a real one would open a websocket and spawn
/// a `log stream` child on the host.
@MainActor
private final class FakeLogStream: SimulatorLogStreaming {
    let sink: (SimulatorLogEvent) -> Void
    private(set) var connections: [(host: String, port: UInt16, udid: String, level: SimulatorLogLevel)] = []
    private(set) var disconnects = 0

    init(sink: @escaping (SimulatorLogEvent) -> Void) {
        self.sink = sink
    }

    func connect(host: String, port: UInt16, udid: String, level: SimulatorLogLevel) {
        connections.append((host, port, udid, level))
    }

    func disconnect() { disconnects += 1 }
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

    /// A model already at `.ready`, plus a peek at the most recently built stream. The first-frame
    /// deadline defaults to something no test can reach by accident, so only the tests that are ABOUT
    /// the deadline pay for waiting on it.
    private func readyModel(
        _ control: FakeControl, deadline: Duration = .seconds(600),
    ) async -> (SimulatorSidebarModel, () -> FakeStream?) {
        var latest: FakeStream?
        let model = SimulatorSidebarModel(
            control: control,
            makeStream: { sink in
                let stream = FakeStream(sink: sink)
                latest = stream
                return stream
            },
            firstFrameDeadline: deadline,
        )
        await model.poll(host: { [host] in host }, ensure: { [port] in .init(state: .ready, port: port) })
        return (model, { latest })
    }

    private func model(_ control: FakeControl = FakeControl()) -> SimulatorSidebarModel {
        SimulatorSidebarModel(control: control) { FakeStream(sink: $0) }
    }

    /// A ready model plus a peek at every console socket it has built, in order. The list rather than
    /// the latest, because "did opening the console at a new level build a SECOND socket" is exactly
    /// what the re-subscribe tests are about.
    private func consoleModel(
        _ control: FakeControl = FakeControl(),
    ) async -> (SimulatorSidebarModel, () -> [FakeLogStream]) {
        var built: [FakeLogStream] = []
        let model = SimulatorSidebarModel(
            control: control,
            makeStream: { FakeStream(sink: $0) },
            makeLogStream: { sink in
                let stream = FakeLogStream(sink: sink)
                built.append(stream)
                return stream
            },
        )
        await model.poll(host: { [host] in host }, ensure: { [port] in .init(state: .ready, port: port) })
        return (model, { built })
    }

    // MARK: The ensure loop

    //
    // The phase machine it drives is `DevicePanelRulesTests` — one ensure round's endpoint means the
    // same thing here as it does on the Android panel, and this file used to hold a second copy of
    // those assertions. What is still pinned here is the LOOP: what it reads per round, and when it
    // stops.

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

    // MARK: The stream that never starts

    /// ⚠️ THE SERVER DOES NOT SAY NO. Measured 2026-08-04 against the live server: opening the stream
    /// for a device that is NOT booted returns `101 Switching Protocols` and then sends nothing at
    /// all — no error text, no close frame, no bytes, indefinitely — while a booted device's first
    /// keyframe arrives in 0.09 s. So there is no event these doubles could deliver to represent the
    /// failure: the failure IS the absence, and every test below reproduces it by staying silent.
    ///
    /// Spin until the model has stopped waiting rather than sleeping a fixed span: the deadline is
    /// injected tiny, but it is still a scheduler hop plus the state read-back.
    private func awaitSettled(_ model: SimulatorSidebarModel) async {
        for _ in 0..<400 {
            if !model.isAwaitingStream { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testASilentSocketForADeviceThatIsGoneSaysSoAndGoesBackToTheList() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true)]
        let (model, stream) = await readyModel(control, deadline: .milliseconds(1))
        await model.refreshDevices()
        model.select("A")
        XCTAssertTrue(model.isAwaitingStream)

        // The reported bug: the row said Booted because this panel's list is up to four seconds
        // stale, and the device had been shut down elsewhere. Nothing arrives on the socket.
        control.devices = [device("A", booted: false)]
        await awaitSettled(model)

        // The read-back is what turns the hang into a sentence — and there is nothing to look at, so
        // the panel returns to the list rather than sitting on a rectangle that will stay empty.
        XCTAssertEqual(model.failure, "iPhone A is no longer running.")
        XCTAssertNil(model.selection)
        XCTAssertEqual(stream()?.disconnects, 1)
    }

    func testASilentSocketForADeviceStillRunningStaysOnTheDevice() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true)]
        let (model, stream) = await readyModel(control, deadline: .milliseconds(1))
        await model.refreshDevices()
        model.select("A")
        await awaitSettled(model)

        // Running but not encoding is the other cause, and it keeps the selection: the screen is the
        // thing being worked on, and the stage offers a retry in place.
        XCTAssertEqual(model.failure, "The device is running, but no video has arrived.")
        XCTAssertEqual(model.selection, "A")
        XCTAssertEqual(stream()?.disconnects, 0)
    }

    func testAKeyframeStandsTheDeadlineDown() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true)]
        let (model, stream) = await readyModel(control, deadline: .milliseconds(1))
        model.select("A")
        stream()?.sink(.message(.accessUnit(Data([0, 0, 0, 1, 0x65]), isKeyframe: true)))
        XCTAssertFalse(model.isAwaitingStream)

        try? await Task.sleep(for: .milliseconds(40))
        // Well past the deadline: a healthy stream must never be interrupted by the watchdog that
        // exists for the silent one.
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.selection, "A")
    }

    func testTheJpegSeedIsNotArrival() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true)]
        let (model, stream) = await readyModel(control, deadline: .milliseconds(1))
        await model.refreshDevices()
        model.select("A")
        stream()?.sink(.message(.jpeg(Data([0xFF, 0xD8]))))
        // The seed is the still the server sends while its encoder starts. Counting it as arrival
        // would let a stream that never encodes pass as live, wearing a screenshot as a disguise.
        XCTAssertTrue(model.isAwaitingStream)

        await awaitSettled(model)
        XCTAssertEqual(model.failure, "The device is running, but no video has arrived.")
    }

    func testAnErrorFromTheServerEndsTheWaitAndARetryReopensTheSocket() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let first = stream()
        first?.sink(.text("device A refuses to stream"))
        // The server's one out-loud channel. It carries its own explanation, so the wait is over.
        XCTAssertFalse(model.isAwaitingStream)

        model.retry()
        XCTAssertTrue(model.isAwaitingStream)
        XCTAssertNil(model.failure)
        // The device is still the subject: same selection, a fresh socket, the old one closed.
        XCTAssertEqual(model.selection, "A")
        XCTAssertEqual(first?.disconnects, 1)
        XCTAssertNotIdentical(first, stream())
        XCTAssertEqual(stream()?.connectedTo?.udid, "A")
    }

    func testSelectingASecondDeviceCancelsTheFirstsVerdict() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true), device("B", booted: true)]
        let (model, _) = await readyModel(control, deadline: .milliseconds(1))
        await model.refreshDevices()
        model.select("A")
        model.select("B")
        await awaitSettled(model)
        // B's own deadline may speak; A's must not — a verdict about the device nobody is looking at
        // would name the wrong device in the banner and could send the panel back to the list.
        XCTAssertEqual(model.failure, "The device is running, but no video has arrived.")
    }

    func testEveryFrameReachesTheRendererEvenWhenTheBytesRepeat() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let renderer = FakeRenderer()
        model.frames.attach(renderer)
        let unit = Data([0, 0, 0, 1, 0x65])
        stream()?.sink(.message(.accessUnit(unit, isKeyframe: true)))
        stream()?.sink(.message(.accessUnit(unit, isKeyframe: true)))
        // Two identical delta frames are ordinary on a static screen. They used to travel as
        // `@Observable` state, where equal values coalesce; a direct call cannot lose one.
        XCTAssertEqual(renderer.calls, ["enqueue(key)", "enqueue(key)"])
        XCTAssertTrue(model.hasVideo)
    }

    /// A config packet is a PROMISE, not a frame. The record travels to the renderer whole — the
    /// door is the only thing that reads an avcC layout now, and `DevicePanelVideoStream.configure`
    /// answers `false` for a malformed one — but the loading state must not end on the promise, or a
    /// record that will never render drops the indicator over a panel that stays black.
    func testAConfigurationRecordTravelsWholeButIsNotVideoOnItsOwn() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let renderer = FakeRenderer()
        model.frames.attach(renderer)
        stream()?.sink(.message(.configuration(Data([0x01, 0x02]))))
        XCTAssertEqual(renderer.calls, ["config"], "the record is the door's to judge, not this file's")
        XCTAssertFalse(model.hasVideo, "nothing decodable has arrived yet")
        // And the refusal itself, through the face the renderer would have used.
        XCTAssertEqual(
            DevicePanelVideoStream()?.configure(avcc: Data([0x01, 0x02])), false,
            "a two-byte record describes no stream",
        )
    }

    func testTheSeedIsShownButIsNotVideo() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        let renderer = FakeRenderer()
        model.frames.attach(renderer)
        stream()?.sink(.message(.jpeg(Data([0xFF, 0xD8]))))
        XCTAssertEqual(renderer.calls, ["seed"])
        // A still the server sends while its encoder starts is not a device anyone is driving.
        XCTAssertFalse(model.hasVideo)
    }

    func testGoingBackToTheListDropsTheSocketAndTheReplay() async {
        let (model, stream) = await readyModel(FakeControl())
        model.select("A")
        stream()?.sink(.message(.jpeg(Data([0xFF, 0xD8]))))
        let renderer = FakeRenderer()
        model.frames.attach(renderer)
        model.select(nil)
        XCTAssertNil(model.selection)
        XCTAssertEqual(stream()?.disconnects, 1)
        XCTAssertFalse(model.hasVideo)
        // The MOUNTED surface is left holding its picture — it is the OUTGOING view, it is about to
        // be discarded whole (the stage keys its screen on the selection), and it stays on screen for
        // the length of the back transition. Flushing it here spent that transition fading out a
        // device with its screen switched off.
        XCTAssertEqual(renderer.calls, ["seed"])
        // What must not survive is the REPLAY, which is the half that could reach the NEXT device:
        // whatever mounts after this opens on nothing at all.
        let next = FakeRenderer()
        model.frames.attach(next)
        XCTAssertTrue(next.calls.isEmpty)
    }

    // MARK: Parking

    /// A model with a peek at BOTH socket kinds — parking is about the pair, and the two standing
    /// helpers each expose only one.
    private func parkableModel() async -> (
        SimulatorSidebarModel, () -> [FakeStream], () -> [FakeLogStream],
    ) {
        var streams: [FakeStream] = []
        var logs: [FakeLogStream] = []
        let model = SimulatorSidebarModel(
            control: FakeControl(),
            makeStream: { sink in
                let stream = FakeStream(sink: sink)
                streams.append(stream)
                return stream
            },
            makeLogStream: { sink in
                let stream = FakeLogStream(sink: sink)
                logs.append(stream)
                return stream
            },
            firstFrameDeadline: .seconds(600),
        )
        await model.poll(host: { [host] in host }, ensure: { [port] in .init(state: .ready, port: port) })
        return (model, { streams }, { logs })
    }

    func testLeavingTheSurfaceDropsBothSocketsAndKeepsTheDevice() async {
        // The panel going off screen used to change nothing: the host kept encoding and both
        // websockets stayed up for a viewer that had left. See `park()` for the measurement.
        let (model, streams, logs) = await parkableModel()
        model.select("A")
        model.toggleConsole()
        XCTAssertEqual(streams().count, 1)
        XCTAssertEqual(logs().count, 1)

        model.park()
        XCTAssertEqual(streams().first?.disconnects, 1)
        XCTAssertEqual(logs().first?.disconnects, 1)
        // The DEVICE is untouched — parking is about sockets, not about what the panel is showing.
        XCTAssertEqual(model.selection, "A")
        XCTAssertTrue(model.isConsoleOpen)
    }

    func testComingBackReDialsTheSameDeviceAndItsLatchedConsole() async {
        let (model, streams, logs) = await parkableModel()
        model.select("A")
        model.toggleConsole()
        model.park()

        model.resume()
        XCTAssertEqual(streams().count, 2)
        XCTAssertEqual(streams().last?.connectedTo?.udid, "A")
        XCTAssertEqual(logs().count, 2, "a drawer left open comes back subscribed")
        XCTAssertTrue(model.isAwaitingStream, "and the first-frame deadline runs again")
    }

    func testResumingIsIdempotentAndNeedsADeviceToResume() async {
        let (model, streams, _) = await parkableModel()
        model.resume()
        XCTAssertTrue(streams().isEmpty, "nothing is selected — there is nothing to re-dial")

        model.select("A")
        XCTAssertEqual(streams().count, 1)
        // An appearance while the socket is live must not open a second one: SwiftUI is free to
        // send appear/disappear pairs a redraw apart, and two streams for one panel is the cost
        // parking exists to remove, doubled.
        model.resume()
        model.resume()
        XCTAssertEqual(streams().count, 1)
    }

    func testAKnownGoodAddressSurvivesTheSurfaceBeingRemounted() async {
        // The ensure loop restarts on every mount. Resetting to `.starting` unconditionally put
        // "Starting simulator server…" over the whole panel for a round-trip every time someone
        // stepped back into the tab — and it also stranded `resume()`, which needs the address.
        let (model, _, _) = await parkableModel()
        guard case .ready = model.phase else {
            XCTFail("the fixture is meant to be ready")
            return
        }
        let restart = Task {
            await model.poll(
                host: { [host] in host },
                ensure: {
                    try? await Task.sleep(for: .seconds(600))
                    return nil
                },
            )
        }
        await Task.yield()
        guard case let .ready(host, port) = model.phase else {
            restart.cancel()
            XCTFail("a restart must not blank an address that still works")
            return
        }
        XCTAssertEqual(host, self.host)
        XCTAssertEqual(port, self.port)
        restart.cancel()
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
        XCTAssertEqual(control.statusBars.first, true)

        await model.toggleStatusBarOverride()
        XCTAssertFalse(model.isStatusBarOverridden)
        // The toggle asks for the preset or for the clear; which BODY and which verb each is are
        // `slopdesk_devicepanel::sim_control`'s, so what the model owes is only the direction.
        XCTAssertEqual(control.statusBars.last, false)
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

    func testTheListCanCaptureADeviceItHasNotOpened() async {
        // A running device's screen is often worth a picture without being worth opening, and its card
        // is right there in the list. The stage keeps calling with no argument and still means "the
        // device that is open".
        //
        // The bytes are deliberately not an image, so this never reaches the real pasteboard: what is
        // being pinned is WHICH device the capture was asked for, and a test that clobbered the
        // machine's clipboard to prove it would be paying far too much for the last line.
        let control = FakeControl()
        control.screenshotResult = Data([0x00, 0x01])
        let (model, _) = await readyModel(control)
        XCTAssertNil(model.selection)
        await model.copyScreenshot(of: "B")
        XCTAssertEqual(control.screenshotUdids, ["B"])
    }

    func testACardsCaptureFailingIsSilentRatherThanANotification() async {
        // A card polls every two seconds, and a device that shut down between the last device list and
        // this request answers 500 (measured 2026-08-04, after a 2.1 s wait). Routed through `failure`
        // that would raise a notification card every two seconds about a device the list is already
        // about to stop drawing — which is exactly the alert-shaped noise this panel spent a round
        // removing.
        let control = FakeControl()
        control.failure = SimulatorControlError.status(500)
        let (model, _) = await readyModel(control)
        let data = await model.thumbnail(for: "A")
        XCTAssertNil(data)
        XCTAssertNil(model.failure)
        XCTAssertNil(model.notice)
    }

    func testShuttingEverythingDownTouchesOnlyWhatIsRunning() async {
        let control = FakeControl()
        control.devices = [device("A", booted: true), device("B"), device("C", booted: true)]
        let (model, _) = await readyModel(control)
        await model.refreshDevices()
        await model.shutdownAll()
        XCTAssertEqual(control.shutDown, ["A", "C"])
        XCTAssertTrue(model.devices.allSatisfy { !$0.isBooted })
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

    // MARK: Simulated location

    func testPinningSendsThePositionAndTheHeaderFollowsTheCallRatherThanTheClick() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        let park = SimulatorCoordinate(latitude: 37.334886, longitude: -122.008988)
        await model.pin(park)
        XCTAssertEqual(control.locations, [park])
        XCTAssertEqual(model.pinnedLocation, park)
        XCTAssertEqual(model.notice, "Location 37.334886, -122.008988")
    }

    func testClearingIsItsOwnCallAndItsOwnConfirmation() async {
        // `nil` is the DELETE, not a pin to the origin — and the readout has to go back to nothing,
        // since a header still naming a place is the panel claiming a position the device left.
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        let somewhere = SimulatorCoordinate(latitude: 1, longitude: 2)
        await model.pin(somewhere)
        await model.pin(nil)
        XCTAssertEqual(control.locations, [somewhere, nil])
        XCTAssertNil(model.pinnedLocation)
        XCTAssertEqual(model.notice, "Live location restored")
    }

    func testARefusedPinLeavesTheHeaderSayingWhatIsStillTrue() async {
        let control = FakeControl()
        control.failure = SimulatorControlError.status(400)
        let (model, _) = await readyModel(control)
        model.select("A")
        await model.pin(SimulatorCoordinate(latitude: 1, longitude: 2))
        XCTAssertNil(model.pinnedLocation)
        XCTAssertEqual(model.failure, "The simulator server answered 400.")
    }

    func testAPinGoesNowhereWithNothingSelected() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        await model.pin(SimulatorCoordinate(latitude: 1, longitude: 2))
        XCTAssertTrue(control.locations.isEmpty)
    }

    // MARK: The measured resolution

    func testTheResolutionIsWhatTheDecoderReportedAndZeroIsNotAReport() async {
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        XCTAssertNil(model.resolution)
        // A `.zero` would be the view asking before its format description exists; printing it would
        // put "0 × 0" in the header for as long as the stream takes to start.
        model.observed(resolution: .zero)
        XCTAssertNil(model.resolution)
        model.observed(resolution: CGSize(width: 1206, height: 2622))
        XCTAssertEqual(model.resolution, CGSize(width: 1206, height: 2622))
    }

    func testTheResolutionAndThePinBothBelongToTheDeviceThatWasSelected() async {
        // Both are claims about the previous device: carried over, the header would print one model's
        // pixel size and another's position under the new device's name.
        let control = FakeControl()
        let (model, _) = await readyModel(control)
        model.select("A")
        model.observed(resolution: CGSize(width: 1206, height: 2622))
        await model.pin(SimulatorCoordinate(latitude: 1, longitude: 2))

        model.select("B")
        XCTAssertNil(model.resolution)
        XCTAssertNil(model.pinnedLocation)
    }

    // MARK: The console

    func testOpeningTheConsoleSubscribesForTheSelectedDeviceAtTheChosenLevel() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        XCTAssertTrue(model.isConsoleOpen)
        XCTAssertEqual(streams().count, 1)
        let connection = streams().first?.connections.first
        XCTAssertEqual(connection?.host, host)
        XCTAssertEqual(connection?.port, port)
        XCTAssertEqual(connection?.udid, "A")
        XCTAssertEqual(connection?.level, .info)
    }

    func testClosingTheConsoleDropsTheSocketRatherThanJustHidingIt() async {
        // `log stream` is a child process on the host per subscriber, so a console nobody can see
        // must not stay subscribed.
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        model.toggleConsole()
        XCTAssertFalse(model.isConsoleOpen)
        XCTAssertEqual(streams().first?.disconnects, 1)
        XCTAssertFalse(model.isLogStarted)
    }

    func testChangingTheLevelReSubscribesAndKeepsTheRowsAlreadyCollected() async {
        // The server takes `--level` at subscribe time and cannot change it on a live socket. The
        // history stays: dropping the output someone just widened the level to explain would be the
        // wrong half to throw away.
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        streams()[0].sink(.lines(["2026-08-04 13:50:19.565 I p[1:2] first"]))
        XCTAssertEqual(model.logLines.count, 1)

        model.setLogLevel(.debug)
        XCTAssertEqual(streams().count, 2)
        XCTAssertEqual(streams()[0].disconnects, 1)
        XCTAssertEqual(streams()[1].connections.first?.level, .debug)
        XCTAssertEqual(model.logLines.count, 1)
        // The new socket has not reported its child yet, so the console says connecting rather than
        // claiming a stream that does not exist.
        XCTAssertFalse(model.isLogStarted)
    }

    func testSettingTheLevelWithTheConsoleClosedChangesNothingButTheLevel() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.setLogLevel(.fault)
        XCTAssertEqual(model.logLevel, .fault)
        XCTAssertTrue(streams().isEmpty)
    }

    func testTheStartedEnvelopeIsWhatSeparatesAQuietDeviceFromADeadConsole() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        XCTAssertFalse(model.isLogStarted)
        streams()[0].sink(.started)
        XCTAssertTrue(model.isLogStarted)
    }

    func testEveryLineOfABatchGetsItsOwnIdentitySoIdenticalRowsStayTwoRows() async {
        // A content-derived id would collapse a repeated line into one row, which is the opposite of
        // what a console is for: the repetition IS the signal.
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        streams()[0].sink(.lines(["same", "same"]))
        XCTAssertEqual(model.logLines.count, 2)
        XCTAssertNotEqual(model.logLines[0].id, model.logLines[1].id)
        XCTAssertEqual(model.logLines.map(\.message), ["same", "same"])
    }

    func testTheConsoleTrimsFromTheFrontAtCapacity() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        let overflow = SimulatorSidebarModel.logCapacity + 10
        streams()[0].sink(.lines((0..<overflow).map { "line \($0)" }))
        XCTAssertEqual(model.logLines.count, SimulatorSidebarModel.logCapacity)
        // The OLDEST go: a console that dropped the newest would stop updating under load, which is
        // exactly when anyone is watching it.
        XCTAssertEqual(model.logLines.first?.message, "line 10")
        XCTAssertEqual(model.logLines.last?.message, "line \(overflow - 1)")
    }

    func testAnEmptyBatchIsNotARow() async {
        // The server batches on a timer, so a tick with nothing to say arrives regularly.
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        streams()[0].sink(.lines([]))
        XCTAssertTrue(model.logLines.isEmpty)
    }

    func testAnEventFromThePreviousDevicesConsoleCannotPaintIntoThisOne() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        let stale = streams()[0]
        model.select("B")
        stale.sink(.lines(["from A"]))
        stale.sink(.started)
        XCTAssertTrue(model.logLines.isEmpty)
        XCTAssertFalse(model.isLogStarted)
    }

    func testTheDrawerStaysLatchedAcrossADeviceSwitchAndTheSocketFollowsIt() async {
        // Someone reading logs while stepping between two devices means to keep reading logs — but
        // the ROWS are the old device's and must not survive under the new device's name.
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        streams()[0].sink(.lines(["from A"]))

        model.select("B")
        XCTAssertTrue(model.isConsoleOpen)
        XCTAssertTrue(model.logLines.isEmpty)
        XCTAssertEqual(streams().count, 2)
        XCTAssertEqual(streams()[1].connections.first?.udid, "B")
    }

    func testGoingBackToTheListUnlatchesTheDrawerInsteadOfArmingItForTheNextDevice() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        model.select(nil)
        XCTAssertFalse(model.isConsoleOpen)
        XCTAssertEqual(streams()[0].disconnects, 1)
        XCTAssertEqual(streams().count, 1)
    }

    func testClearingEmptiesTheRowsWithoutTouchingTheSubscription() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        streams()[0].sink(.started)
        streams()[0].sink(.lines(["a"]))
        model.clearLog()
        XCTAssertTrue(model.logLines.isEmpty)
        XCTAssertTrue(model.isConsoleOpen)
        XCTAssertTrue(model.isLogStarted)
        XCTAssertEqual(streams()[0].disconnects, 0)
    }

    func testALogSocketThatDiesSaysSoAndStopsClaimingItStarted() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        streams()[0].sink(.started)
        streams()[0].sink(.ended(reason: "connection reset"))
        XCTAssertFalse(model.isLogStarted)
        XCTAssertEqual(model.failure, "connection reset")
    }

    func testACleanCloseIsNotAFailureBanner() async {
        let (model, streams) = await consoleModel()
        model.select("A")
        model.toggleConsole()
        streams()[0].sink(.ended(reason: nil))
        XCTAssertNil(model.failure)
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
