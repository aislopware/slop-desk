// MacVideoSurfaceHost — the AppKit mount of one remote-GUI pane, for a canvas that is not SwiftUI
// (docs/56 stage F risk 2, and docs/56 §3 for the carve that gave it its own file).
//
// NO PHONE TWIN, and that is not a gap: `VideoWindowFactory.nativeShared` is macOS-only because the
// phone's canvas is SwiftUI all the way down and mounts through `AnyView`. There is no UIKit canvas
// asking for a bare `UIView` here.

import AppKit
import SlopDeskVideoClient
import SwiftUI

// MARK: - The native half of the video pixel seam (docs/56 stage F, risk 2)

/// The AppKit mount of one remote-GUI pane: the same `MacMetalLayerBackedView` ``MacVideoWindowView``
/// mounts, added straight into an AppKit canvas instead of through an `NSHostingView` over an `AnyView`.
///
/// WHY the seam widened rather than the canvas thickening: `MacMetalLayerBackedView` is ALREADY an `NSView`,
/// and `VideoWindowFactory.shared` only returns an `AnyView` because neither UI target may NAME that type.
/// A hosting view between the canvas and a `CAMetalLayer` buys nothing and costs a full-bleed hit-test
/// claim over a surface that forwards pointer traffic to a remote desktop.
///
/// ONE hosting view survives, and deliberately: the swipe-peel chip. It is a ~120-line SwiftUI drawing
/// that no AppKit caller has any reason to own a second copy of, it is `allowsHitTesting(false)` on the
/// SwiftUI side already, and ``PeelOverlayHostingView`` returns `nil` from `hitTest` so it claims nothing
/// here either. That is the whole distinction risk 2 draws: a hosting view that takes input over the pixel
/// surface is the bug; one that is provably transparent to it is a renderer.
///
/// Conforms to `SlopDeskWorkspaceCore.RemoteSurfaceHosting` RETROACTIVELY, from the app target — this
/// module never imports `SlopDeskWorkspaceCore` (the seam exists for exactly that reason), so the three
/// members below are spelled to match that protocol and the conformance is declared where both are
/// visible, like `WindowFeedChannel: @retroactive HostWindowFeedLink`.
public final class MacVideoSurfaceHost: NSView {
    /// The Metal-backed pane view. Owned as a subview; it owns the decode pipeline for its lifetime.
    private let surface: MacMetalLayerBackedView
    /// The control bridge, owned here for this host's lifetime — the AppKit twin of ``MacVideoWindowView``'s
    /// `@StateObject`. The Metal view publishes the swipe-peel state onto it; the chip overlay reads it.
    private let controls: MacVideoPaneControls
    /// The mount-time binding, kept so ``setPaneGates(isActive:inputEnabled:backgroundPointer:)`` can
    /// re-run the same `apply(to:)` the SwiftUI half re-runs on every render.
    private var binding: MacVideoLayerView

    /// Builds the AppKit mount from the SAME value the SwiftUI mount is built from, so the app target's
    /// two registrations cannot drift: whatever it hands `VideoWindowFactory.shared` it also hands here.
    public init(_ pane: MacVideoWindowView) {
        // Locals through phase 1: `self` is off limits until `super.init`, so the binding is built from a
        // local `controls` and the surface from the local binding, then both are stored.
        let controls = MacVideoPaneControls()
        let binding = MacVideoLayerView(
            connection: pane.connection,
            controls: controls,
            targetAppName: pane.targetAppName,
            isActive: pane.isActive,
            inputEnabled: pane.inputEnabled,
            backgroundPointer: pane.backgroundPointer,
            onActivate: pane.onActivate,
            onCanvasScroll: pane.onCanvasScroll,
            onStreamNativeSize: pane.onStreamNativeSize,
            onKeyInjectorReady: pane.onKeyInjectorReady,
            onResizeInjectorReady: pane.onResizeInjectorReady,
            onViewportInjectorReady: pane.onViewportInjectorReady,
            onInputReleaseReady: pane.onInputReleaseReady,
            onWindowGeometryReady: pane.onWindowGeometryReady,
            onStreamCadenceReady: pane.onStreamCadenceReady,
            onStreamBitrateReady: pane.onStreamBitrateReady,
            onNetworkStatsReady: pane.onNetworkStatsReady,
            onStreamSettingsInjectorReady: pane.onStreamSettingsInjectorReady,
            onAudioInjectorReady: pane.onAudioInjectorReady,
            onPrivacyInjectorReady: pane.onPrivacyInjectorReady,
            onSystemKeyInjectorReady: pane.onSystemKeyInjectorReady,
            onStreamStallChanged: pane.onStreamStallChanged,
            onSessionRejected: pane.onSessionRejected,
        )
        self.controls = controls
        self.binding = binding
        surface = binding.build()
        super.init(frame: .zero)
        surface.autoresizingMask = [.width, .height]
        surface.frame = bounds
        addSubview(surface)

        let chip = PeelOverlayHostingView(rootView: MacSwipePeelOverlay(controls: controls))
        chip.autoresizingMask = [.width, .height]
        chip.frame = bounds
        // The hosting view must not paint a background over the video: `NSHostingView` is otherwise
        // transparent, but an opaque backing would composite a grey plate over every decoded frame.
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(chip)
        // Accessibility rides the container, not the Metal view: the pixels have no structure to expose.
        setAccessibilityLabel("Remote GUI window: \(pane.title)")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// `RemoteSurfaceHosting`: the view the canvas adds. It is this container (the Metal view and the
    /// chip are its subviews and are never handed out separately).
    public var surfaceView: NSView { self }

    /// `RemoteSurfaceHosting`: the AppKit twin of `updateNSView`. SwiftUI re-runs the whole binding on
    /// every render; an AppKit canvas has no such pass, so the three gates that actually change at runtime
    /// are pushed explicitly and then run through the SAME `apply(to:)` — including its read-only-flip
    /// branch, which is the only thing that withdraws and restores the host-affecting injector sinks.
    public func setPaneGates(isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool) {
        binding.isActive = isActive
        binding.inputEnabled = inputEnabled
        binding.backgroundPointer = backgroundPointer
        binding.apply(to: surface)
    }

    /// `RemoteSurfaceHosting`: the AppKit twin of `dismantleNSView`. Removing this view from its superview
    /// is NOT enough — the session owns two UDP sockets, a VideoToolbox decoder and a display link.
    public func detachSurface() { surface.deactivate() }
}

/// An `NSHostingView` that is transparent to the hit-test, so the swipe-peel chip floating over the video
/// surface cannot swallow a click the remote desktop is owed. `allowsHitTesting(false)` inside the SwiftUI
/// content is not enough on its own: the HOSTING view is an ordinary `NSView` in the AppKit responder
/// chain, and it is the one the canvas's `hitTest` walks.
final class PeelOverlayHostingView: NSHostingView<MacSwipePeelOverlay> {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}
