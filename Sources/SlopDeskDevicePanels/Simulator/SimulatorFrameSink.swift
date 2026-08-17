// SimulatorFrameSink — the video path from the socket to the display layer, with SwiftUI taken out
// of it.
//
// The panel used to publish each access unit as `@Observable` state that an `NSViewRepresentable`
// read back in `updateNSView`. That is a legitimate shape for a value that changes when the user does
// something; it is the wrong one for a video stream, and the numbers say why. MEASURED 2026-08-04
// against a live `baguette serve`: a device under a continuous drag emits **69.5 frames per second**
// (p50 gap 12.1 ms), and a device sitting still still emits ~13. Every one of those frames was
// invalidating the whole stage — header, toolbar, bezel artwork, and the console's up-to-600 rows —
// seventy times a second, on the same main thread that has to dispatch the mouse events the user is
// making at that exact moment. The frames were not the point of that work; the panel around them was
// being rebuilt as a side effect of them arriving.
//
// So frames no longer travel as state. The model holds one of these, the mounted screen view
// registers itself with it, and each access unit goes straight to the display layer. What stays
// observable is what the PANEL actually renders differently: whether video has arrived at all, and
// what size it turned out to be. Both change a handful of times per stream instead of seventy times
// per second.
//
// REPLAY, and why it is not optional. The view mounts asynchronously — SwiftUI builds it a beat after
// the model opens the socket, and `.id(model.selection)` tears it down and builds a fresh one on every
// device switch. The parameter sets and the last keyframe arrive in that gap. Without a replay the
// layer would sit black until the server's next IDR, which on a quiet device is SECONDS away
// (measured: one IDR in an 8-second idle window). So this holds exactly what a decoder needs to start
// — the avcC record and the most recent keyframe — and hands them over on attach. Delta frames are
// deliberately NOT held: they are only meaningful against a reference frame the new layer never had.
//
// Hang-safety: this file touches no network and builds no decoder. It is the seam BETWEEN the model
// and the display layer, which is what lets a test drive frame delivery without either.

#if os(macOS)
import Foundation

/// What a mounted screen view can do with a frame. A protocol rather than the concrete view so the
/// delivery order — replay first, then live frames — is testable without an `AVSampleBufferDisplayLayer`.
@MainActor
package protocol SimulatorFrameRenderer: AnyObject {
    func apply(configuration: SimulatorWireProtocol.AVCConfiguration)
    func enqueue(accessUnit: Data, isKeyframe: Bool)
    func showSeed(_ jpeg: Data)
    func reset()
}

@MainActor
package final class SimulatorFrameSink {
    /// The mounted view, weakly: SwiftUI owns its lifetime, and a sink outliving a torn-down stage
    /// must not keep a display layer alive.
    private weak var renderer: SimulatorFrameRenderer?

    /// The two messages a cold decoder needs, kept for whoever mounts next. The seed is kept as well
    /// so a stream that has not produced a keyframe yet still shows the still the server sent.
    private var configuration: SimulatorWireProtocol.AVCConfiguration?
    private var keyframe: Data?
    private var seed: Data?

    /// Called from the view's `makeNSView`. Replays what the stream has already said, in the order a
    /// decoder needs it: parameter sets, then the still, then the keyframe on top of it.
    package func attach(_ renderer: SimulatorFrameRenderer) {
        self.renderer = renderer
        if let configuration { renderer.apply(configuration: configuration) }
        if let seed { renderer.showSeed(seed) }
        if let keyframe { renderer.enqueue(accessUnit: keyframe, isKeyframe: true) }
    }

    package func deliver(configuration: SimulatorWireProtocol.AVCConfiguration) {
        self.configuration = configuration
        // A new parameter set invalidates the held keyframe — it was encoded against the old one.
        keyframe = nil
        renderer?.apply(configuration: configuration)
    }

    package func deliver(accessUnit: Data, isKeyframe: Bool) {
        if isKeyframe { keyframe = accessUnit }
        renderer?.enqueue(accessUnit: accessUnit, isKeyframe: isKeyframe)
    }

    package func deliver(seed jpeg: Data) {
        seed = jpeg
        renderer?.showSeed(jpeg)
    }

    /// A disconnect or a retry, where the SAME surface stays mounted. Drops the replay as well as the
    /// picture: the next stream's frames must not decode against this one's parameter sets.
    package func reset() {
        discard()
        renderer?.reset()
    }

    /// A device SWITCH, where the surface itself is being replaced (the stage keys its screen on the
    /// selection, so the next device mounts a new layer that this sink has nothing to replay into).
    /// Same forgetting, minus the flush — and the flush is the whole difference: the outgoing view
    /// lives on for the length of the navigation transition, and blanking its layer would spend that
    /// transition fading out a device with its screen switched off.
    package func discard() {
        configuration = nil
        keyframe = nil
        seed = nil
    }
}
#endif
