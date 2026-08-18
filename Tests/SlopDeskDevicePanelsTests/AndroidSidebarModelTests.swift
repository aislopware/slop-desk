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
@testable import SlopDeskDevicePanels

@MainActor
final class AndroidSidebarPhaseTests: XCTestCase {
    /// Only a reached bridge has somewhere to dial, and the socket reads that address from the phase
    /// rather than from a second field that could disagree with it. The phase machine itself is
    /// `DevicePanelRulesTests` — it is the simulator panel's too.
    func testOnlyAReadyPhaseYieldsAnAddress() {
        XCTAssertNil(AndroidSidebarModel.address(of: .starting))
        XCTAssertNil(AndroidSidebarModel.address(of: .unavailable))
        let address = AndroidSidebarModel.address(of: .ready(host: "h", port: 1))
        XCTAssertEqual(address?.host, "h")
        XCTAssertEqual(address?.port, 1)
    }

    /// A row the way `adb devices -l` leaves one. `isRunning` — the flag the shared wait verdict
    /// reads, pinned by `AndroidDeviceTests` — is `serial != nil && state == "device"`, so `offline`
    /// is a boot in progress rather than a failure.
    private func device(state: String, serial: String? = "emulator-5554") -> AndroidDevice {
        AndroidDevice(
            key: "avd:Pixel_API36", name: "Pixel API36", serial: serial, avdName: "Pixel_API36",
            state: state, isEmulator: true,
        )
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
