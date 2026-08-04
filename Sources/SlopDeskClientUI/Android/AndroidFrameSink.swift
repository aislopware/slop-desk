// AndroidFrameSink — the video path from the socket to the display layer, with SwiftUI taken out of
// it.
//
// The same seam as ``SimulatorFrameSink`` and for the same measured reason: frames arrive far too
// often to travel as `@Observable` state, and publishing each one rebuilds the whole stage — header,
// toolbar, device body, log drawer — on the thread that has to dispatch the pointer events the user
// is making at that moment. Measured 2026-08-04 on this host's emulator: 25.3 frames/s under a
// continuous drag at 460×1024, and a burst rate higher still on a device with a hardware encoder.
//
// REPLAY is, if anything, MORE load-bearing here than on the simulator path. `scrcpy` sends its
// parameter sets and one IDR at the head of the stream and then, on a quiet screen, **nothing at
// all** — measured idle floor 547 B/s over twelve seconds, with a single keyframe for the whole
// session. A view that mounts a beat after the socket opens has therefore missed the only keyframe
// there will be, and without a replay it sits black until the user happens to touch something. So
// this holds exactly what a cold decoder needs — the parameter sets and the most recent keyframe —
// and hands them over on attach.
//
// (There is a second lever the simulator path did not have: `RESET_VIDEO` asks the device for a fresh
// keyframe on demand. ``AndroidSidebarModel`` uses it for a retry. It is not a substitute for the
// replay — it costs a round trip and a full intra frame, where the replay costs a dictionary read.)
//
// Hang-safety: this file touches no network and builds no decoder.

#if os(macOS)
import Foundation

/// What a mounted screen view can do with a frame.
@MainActor
protocol AndroidFrameRenderer: AnyObject {
    func apply(parameterSets: [Data], codec: AndroidVideoCodec)
    func enqueue(accessUnit: Data, isKeyframe: Bool)
    func reset()
}

@MainActor
final class AndroidFrameSink {
    /// The mounted view, weakly: SwiftUI owns its lifetime, and a sink outliving a torn-down stage
    /// must not keep a display layer alive.
    private weak var renderer: AndroidFrameRenderer?

    private var parameterSets: [Data] = []
    private var codec: AndroidVideoCodec = .h264
    private var keyframe: Data?

    /// Called from the view's `makeNSView`. Replays in the order a decoder needs it.
    func attach(_ renderer: AndroidFrameRenderer) {
        self.renderer = renderer
        if !parameterSets.isEmpty { renderer.apply(parameterSets: parameterSets, codec: codec) }
        if let keyframe { renderer.enqueue(accessUnit: keyframe, isKeyframe: true) }
    }

    func deliver(parameterSets sets: [Data], codec: AndroidVideoCodec) {
        parameterSets = sets
        self.codec = codec
        // New parameter sets invalidate the held keyframe — it was encoded against the old ones.
        keyframe = nil
        renderer?.apply(parameterSets: sets, codec: codec)
    }

    func deliver(accessUnit: Data, isKeyframe: Bool) {
        if isKeyframe { keyframe = accessUnit }
        renderer?.enqueue(accessUnit: accessUnit, isKeyframe: isKeyframe)
    }

    /// A disconnect or a retry, where the SAME surface stays mounted.
    func reset() {
        discard()
        renderer?.reset()
    }

    /// A device SWITCH, where the surface itself is being replaced. Same forgetting, minus the flush
    /// — the outgoing view lives on for the length of the navigation transition, and blanking its
    /// layer would spend that transition fading out a device with its screen switched off. That trap
    /// cost the simulator panel a debugging round; it is not being rebuilt here.
    func discard() {
        parameterSets = []
        keyframe = nil
    }
}
#endif
