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
