// AndroidSidebarModelTests — the panel's two pure decisions, plus the replay the video path turns on.
//
// Nothing here builds a socket or a display layer (hang-safety): the ensure loop's mapping and the
// frame sink are both value-shaped on purpose, and they are the two places a mistake is invisible
// until the panel is on a real host — a phase that renders the install hint for a host that merely
// has not finished starting, or a mirror that sits black because its keyframe arrived before the view
// did.

#if os(macOS)
import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class AndroidSidebarPhaseTests: XCTestCase {
    private func endpoint(_ state: MetadataCodec.ServiceState, port: UInt16) -> MetadataCodec
        .ServiceEndpoint
    {
        MetadataCodec.ServiceEndpoint(state: state, port: port)
    }

    func testAReadyEndpointBecomesAnAddress() {
        XCTAssertEqual(
            AndroidSidebarModel.phase(for: endpoint(.ready, port: 7421), host: "10.0.0.2"),
            .ready(host: "10.0.0.2", port: 7421),
        )
    }

    func testNoAnswerAtAllIsOfflineAndKeepsPolling() {
        // No connected pane channel, or a host too old to know the verb. The connection may come up.
        XCTAssertEqual(AndroidSidebarModel.phase(for: nil, host: "h"), .offline)
    }

    func testAStartingHostIsNotAnErrorSurface() {
        XCTAssertEqual(AndroidSidebarModel.phase(for: endpoint(.starting, port: 0), host: "h"), .starting)
    }

    func testOnlyAMissingAdbRendersTheInstallHint() {
        XCTAssertEqual(
            AndroidSidebarModel.phase(for: endpoint(.unavailable, port: 0), host: "h"), .unavailable,
        )
    }

    func testAReadyEndpointWithNoUsableAddressDegradesRatherThanTraps() {
        // Both halves of an address are needed and neither is guaranteed: a ready state with port
        // zero is a host that answered before it bound, and a nil host is a client between
        // connections.
        XCTAssertEqual(AndroidSidebarModel.phase(for: endpoint(.ready, port: 0), host: "h"), .offline)
        XCTAssertEqual(AndroidSidebarModel.phase(for: endpoint(.ready, port: 7421), host: nil), .offline)
        XCTAssertEqual(AndroidSidebarModel.phase(for: endpoint(.ready, port: 7421), host: ""), .offline)
    }

    func testAnUnknownFutureStateKeepsPollingRatherThanClaimingAdbIsMissing() {
        // The forward-tolerant carry: a state byte this build cannot interpret must never render the
        // install hint it cannot justify.
        let future = MetadataCodec.ServiceEndpoint(stateByte: 99, port: 0)
        XCTAssertEqual(AndroidSidebarModel.phase(for: future, host: "h"), .starting)
    }

    func testOnlyAReadyPhaseYieldsAnAddress() {
        XCTAssertNil(AndroidSidebarModel.address(of: .starting))
        XCTAssertNil(AndroidSidebarModel.address(of: .unavailable))
        let address = AndroidSidebarModel.address(of: .ready(host: "h", port: 1))
        XCTAssertEqual(address?.host, "h")
        XCTAssertEqual(address?.port, 1)
    }

    /// Only the FIRST frame is news, and this is the whole reason it is a function.
    ///
    /// `@Observable` notifies on assignment rather than on change, so a handler that writes
    /// `hasVideo = true` per access unit invalidates every view reading it at the frame rate — the
    /// stage rebuilding header, toolbar, device body and drawer on the main actor between the pointer
    /// events the user is making. It is the cost `AndroidFrameSink` exists to keep out of the video
    /// path, leaking back in through one assignment.
    func testOnlyTheFirstFrameOfAStreamIsWorthTelling() {
        XCTAssertTrue(
            AndroidSidebarModel.videoArrivalIsNews(hasVideo: false, isAwaitingStream: true),
        )
        XCTAssertFalse(
            AndroidSidebarModel.videoArrivalIsNews(hasVideo: true, isAwaitingStream: false),
        )
    }

    func testARetryMakesTheNextFrameNewsAgain() {
        // `retry()` re-arms the wait, and the veil it raises has to come back down.
        XCTAssertTrue(
            AndroidSidebarModel.videoArrivalIsNews(hasVideo: true, isAwaitingStream: true),
        )
        // A stream that has neither video nor a wait outstanding is one the panel gave up on; its
        // late frame still ends the failure state.
        XCTAssertTrue(
            AndroidSidebarModel.videoArrivalIsNews(hasVideo: false, isAwaitingStream: false),
        )
    }

    // MARK: The wait's verdict

    /// The decision that turned a boot from a dead end into a wait. Measured 2026-08-07 against a
    /// cold boot: `open` is refused for the first ~21 s, can stall ~15 s more the moment `adb` says
    /// `device`, and succeeds cleanly after that — so silence while the device is not (yet) running
    /// means "again shortly", not "broken".
    private func device(state: String, serial: String? = "emulator-5554") -> AndroidDevice {
        AndroidDevice(
            key: "avd:Pixel_API36", name: "Pixel API36", serial: serial, avdName: "Pixel_API36",
            state: state, isEmulator: true,
        )
    }

    func testABootingDeviceIsWaitedOnNotFailed() {
        XCTAssertEqual(
            AndroidSidebarModel.verdict(for: device(state: "offline"), withinGrace: true), .wait,
        )
        // Freshly booted, no serial yet — same wait.
        XCTAssertEqual(
            AndroidSidebarModel.verdict(for: device(state: "offline", serial: nil), withinGrace: true),
            .wait,
        )
    }

    func testAReadyDeviceIsConnectedTheMomentItTurnsUp() {
        XCTAssertEqual(
            AndroidSidebarModel.verdict(for: device(state: "device"), withinGrace: true), .connect,
        )
    }

    func testPatienceRunsOutInTheRightWords() {
        // A running device with no video is the stall message with the retry button; a device that
        // never came up is its own sentence. Both only AFTER the grace window.
        XCTAssertEqual(
            AndroidSidebarModel.verdict(for: device(state: "device"), withinGrace: false), .stalled,
        )
        XCTAssertEqual(
            AndroidSidebarModel.verdict(for: device(state: "offline"), withinGrace: false),
            .neverReady,
        )
    }

    func testADeviceThatLeftTheListIsGoneWhateverThePatience() {
        XCTAssertEqual(AndroidSidebarModel.verdict(for: nil, withinGrace: true), .gone)
        XCTAssertEqual(AndroidSidebarModel.verdict(for: nil, withinGrace: false), .gone)
    }

    // MARK: The lifecycle spinner's hold

    /// What `pending` waits for after a play press. Both lifecycle verbs are fire-and-forget on the
    /// host (`emulator` is spawned; `adb emu kill` merely asks), so "the host accepted it" is not a
    /// state change — these two predicates are. A spinner that resolves any earlier re-arms the
    /// button mid-flight: a second boot press then hits the AVD lock, and a second stop press sits
    /// on a card that looks healthy and is not.
    func testABootHoldsItsSpinnerUntilTheSerialFoldsIn() {
        let key = "avd:Pixel_API36"
        // Accepted but not yet surfaced: the AVD row still has no transport.
        XCTAssertFalse(
            AndroidSidebarModel.bootIsVisible([device(state: "offline", serial: nil)], key: key),
        )
        // A list glitch that drops the row entirely is still not visibility.
        XCTAssertFalse(AndroidSidebarModel.bootIsVisible([], key: key))
        // The fold: same row, now carrying the booted serial — state is irrelevant, `offline`
        // IS the boot in progress.
        XCTAssertTrue(
            AndroidSidebarModel.bootIsVisible([device(state: "offline")], key: key),
        )
    }

    func testAShutdownHoldsItsSpinnerUntilTheSerialIsGone() {
        let serial = "emulator-5554"
        // Still dying: the serial is listed, however the row is keyed and whatever adb calls it.
        XCTAssertFalse(
            AndroidSidebarModel.shutdownIsVisible([device(state: "offline")], serial: serial),
        )
        // Landed: the AVD row remains — merely no longer running — and that is the resolved state.
        XCTAssertTrue(
            AndroidSidebarModel.shutdownIsVisible(
                [device(state: "offline", serial: nil)], serial: serial,
            ),
        )
        XCTAssertTrue(AndroidSidebarModel.shutdownIsVisible([], serial: serial))
    }
}

// MARK: - The video path

@MainActor
final class AndroidFrameSinkTests: XCTestCase {
    /// A renderer that records rather than decodes. No `VTDecompressionSession`, no display layer.
    private final class Recorder: AndroidFrameRenderer {
        var applied: [[Data]] = []
        var enqueued: [(Data, Bool)] = []
        var resets = 0

        func apply(parameterSets: [Data], codec _: AndroidVideoCodec) { applied.append(parameterSets) }
        func enqueue(accessUnit: Data, isKeyframe: Bool) { enqueued.append((accessUnit, isKeyframe)) }
        func reset() { resets += 1 }
    }

    func testAViewThatMountsLateStillGetsAPicture() {
        // The reason the sink exists. `scrcpy` sends its parameter sets and ONE keyframe at the head
        // of the stream and then, on a quiet screen, nothing at all — measured idle floor 547 B/s
        // with a single keyframe for a whole session. Without the replay the panel sits black until
        // the user happens to touch something.
        let sink = AndroidFrameSink()
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.deliver(accessUnit: Data([0x41]), isKeyframe: false)

        let recorder = Recorder()
        sink.attach(recorder)
        XCTAssertEqual(recorder.applied, [[Data([0x67])]])
        // The keyframe and only the keyframe: a delta frame replayed against a decoder that never
        // saw its reference is noise.
        XCTAssertEqual(recorder.enqueued.count, 1)
        XCTAssertEqual(recorder.enqueued.first?.0, Data([0x65]))
    }

    func testNewParameterSetsInvalidateTheHeldKeyframe() {
        // It was encoded against the old ones — replaying it after a rotation would hand the decoder
        // a frame its format description cannot describe.
        let sink = AndroidFrameSink()
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.deliver(parameterSets: [Data([0x67, 0x01])], codec: .h264)

        let recorder = Recorder()
        sink.attach(recorder)
        XCTAssertEqual(recorder.applied, [[Data([0x67, 0x01])]])
        XCTAssertTrue(recorder.enqueued.isEmpty)
    }

    func testAMountedViewIsFedDirectly() {
        let sink = AndroidFrameSink()
        let recorder = Recorder()
        sink.attach(recorder)
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x41]), isKeyframe: false)
        XCTAssertEqual(recorder.applied.count, 1)
        XCTAssertEqual(recorder.enqueued.count, 1)
        XCTAssertEqual(recorder.enqueued.first?.1, false)
    }

    func testAResetFlushesTheSurfaceThatStaysMounted() {
        // A disconnect or a retry: the same view is still on screen and has to be blanked.
        let sink = AndroidFrameSink()
        let recorder = Recorder()
        sink.attach(recorder)
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.reset()
        XCTAssertEqual(recorder.resets, 1)

        let next = Recorder()
        sink.attach(next)
        XCTAssertTrue(next.applied.isEmpty)
        XCTAssertTrue(next.enqueued.isEmpty)
    }

    func testADeviceSwitchForgetsWithoutBlankingTheOutgoingView() {
        // The outgoing view lives on for the length of the navigation transition, and flushing its
        // layer would spend that transition fading out a device with its screen switched off. That
        // trap cost the simulator panel a debugging round.
        let sink = AndroidFrameSink()
        let recorder = Recorder()
        sink.attach(recorder)
        sink.deliver(parameterSets: [Data([0x67])], codec: .h264)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.discard()
        XCTAssertEqual(recorder.resets, 0)

        let next = Recorder()
        sink.attach(next)
        XCTAssertTrue(next.applied.isEmpty)
    }
}
#endif
