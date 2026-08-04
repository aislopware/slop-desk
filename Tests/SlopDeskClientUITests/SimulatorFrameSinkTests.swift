// The video path with SwiftUI taken out of it. The interesting behaviour is REPLAY: the view mounts
// a beat after the socket opens and is rebuilt on every device switch, so whatever a cold decoder
// needs has to be waiting for it. Without that, a panel opened onto a quiet device sits black until
// the server's next keyframe — measured 2026-08-04 as one per eight-second idle window.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

/// Records what a mounted screen view would have been asked to do. Standing in for the real view is
/// the whole point: an `AVSampleBufferDisplayLayer` may not be built in a unit test.
@MainActor
final class FakeRenderer: SimulatorFrameRenderer {
    private(set) var calls: [String] = []

    func apply(configuration _: SimulatorWireProtocol.AVCConfiguration) { calls.append("config") }
    func enqueue(accessUnit _: Data, isKeyframe: Bool) {
        calls.append(isKeyframe ? "enqueue(key)" : "enqueue(delta)")
    }

    func showSeed(_: Data) { calls.append("seed") }
    func reset() { calls.append("reset") }
}

@MainActor
final class SimulatorFrameSinkTests: XCTestCase {
    private let configuration = SimulatorFrameSinkTests.record([0x67, 0x64])

    /// An avcC value object — no bytes are parsed here, so any well-formed one will do.
    private static func record(_ sps: [UInt8]) -> SimulatorWireProtocol.AVCConfiguration {
        SimulatorWireProtocol.AVCConfiguration(
            parameterSets: [Data(sps), Data([0x68, 0xEE])], nalUnitHeaderLength: 4,
            profile: 0x64, levelIndication: 0x33,
        )
    }

    func testAViewMountingLateIsHandedWhatADecoderNeedsToStart() {
        let sink = SimulatorFrameSink()
        sink.deliver(configuration: configuration)
        sink.deliver(seed: Data([0xFF, 0xD8]))
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.deliver(accessUnit: Data([0x41]), isKeyframe: false)

        let renderer = FakeRenderer()
        sink.attach(renderer)
        // Parameter sets first, then the still, then the keyframe on top of it. The delta is NOT
        // replayed: it is only meaningful against a reference frame this layer never had.
        XCTAssertEqual(renderer.calls, ["config", "seed", "enqueue(key)"])
    }

    func testFramesAfterAttachGoStraightThrough() {
        let sink = SimulatorFrameSink()
        let renderer = FakeRenderer()
        sink.attach(renderer)
        sink.deliver(configuration: configuration)
        sink.deliver(accessUnit: Data([0x41]), isKeyframe: false)
        XCTAssertEqual(renderer.calls, ["config", "enqueue(delta)"])
    }

    func testNewParameterSetsInvalidateTheHeldKeyframe() {
        // A keyframe encoded against the old parameter sets would decode into garbage under the new
        // ones — replaying it would look like a corrupt stream rather than an empty one.
        let sink = SimulatorFrameSink()
        sink.deliver(configuration: configuration)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        sink.deliver(configuration: Self.record([0x67, 0x00]))
        let renderer = FakeRenderer()
        sink.attach(renderer)
        XCTAssertEqual(renderer.calls, ["config"])
    }

    func testResetClearsTheReplayAsWellAsThePicture() {
        // A device switch. The next stream's frames must not decode against this one's parameter
        // sets, and the next mount must not open on the previous device's screen.
        let sink = SimulatorFrameSink()
        sink.deliver(configuration: configuration)
        sink.deliver(accessUnit: Data([0x65]), isKeyframe: true)
        let first = FakeRenderer()
        sink.attach(first)
        sink.reset()
        XCTAssertEqual(first.calls.last, "reset")

        let second = FakeRenderer()
        sink.attach(second)
        XCTAssertTrue(second.calls.isEmpty)
    }

    func testTheSinkDoesNotHoldTheViewAlive() throws {
        // SwiftUI owns the view's lifetime; a sink outliving a torn-down stage must not keep a
        // display layer — and its decompression session — alive behind it.
        let sink = SimulatorFrameSink()
        var renderer: FakeRenderer? = FakeRenderer()
        weak var observed = renderer
        try sink.attach(XCTUnwrap(renderer))
        renderer = nil
        XCTAssertNil(observed)
        // And a frame arriving afterwards is simply dropped rather than trapping.
        sink.deliver(accessUnit: Data([0x41]), isKeyframe: false)
    }
}
#endif
