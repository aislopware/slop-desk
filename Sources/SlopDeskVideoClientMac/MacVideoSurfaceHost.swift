// MacVideoSurfaceHost — the AppKit mount of one remote-GUI pane (docs/56 stage F risk 2, and docs/56
// §3 for the carve that gave it its own file).
//
// NO PHONE TWIN, and that is not a gap: the phone's own `SlopDeskVideoClientPhone` mount is UIKit start
// to finish, so it needs no analogue of this file — there was never a second framework's canvas asking
// for a bare `UIView` here to widen a seam toward.
//
// SwiftUI removal (this campaign): `VideoWindowFactory` used to carry TWO registrations — `shared`
// returning an `AnyView` (built by wrapping THIS module's `MacVideoWindowView`, a SwiftUI `View`, since
// neither UI target could name that type directly) and `nativeShared` returning this class, built from
// the SAME `MacVideoWindowView` value so the two mounts could not drift. `VideoWindowFactory` now has
// one slot (``VideoWindowSeam.swift``, `SlopDeskWorkspaceCore`), because there is only one mount left to
// register: this class, built from ``MacVideoPaneSpec`` (`MacVideoWindowView`'s non-SwiftUI successor).
// "ONE BUILDER, TWO REGISTRATIONS" — the property the old doc comment here protected — is moot with one
// registration: there is nothing left for a second copy of the spec to drift FROM.

import AppKit
import SlopDeskVideoClient

// MARK: - The AppKit mount of the video pixel seam (docs/56 stage F, risk 2)

/// The AppKit mount of one remote-GUI pane: hosts the `MacMetalLayerBackedView` ``MacVideoLayerView``
/// builds, added straight into an AppKit canvas — no hosting view between it and the canvas, and (since
/// the swipe-peel chip below stopped being SwiftUI) none anywhere else in this class either.
///
/// WHY there is no hosting view at all now: `MacMetalLayerBackedView` is ALREADY an `NSView`, so nothing
/// between it and the canvas ever did real work except claim a hit-test region a `CAMetalLayer` surface
/// that forwards pointer traffic to a remote desktop cannot afford to lose. The swipe-peel chip used to
/// be the one exception — a ~120-line SwiftUI drawing hosted through `NSHostingView` (`nil` from its
/// `hitTest` to stay provably transparent) — and is now ``MacSwipePeelOverlayView``, a plain `NSView`
/// that answers the same `hitTest` question directly instead of needing a second object to answer it on
/// its behalf.
///
/// Conforms to `SlopDeskWorkspaceCore.RemoteSurfaceHosting` RETROACTIVELY, from the app target — this
/// module never imports `SlopDeskWorkspaceCore` (the seam exists for exactly that reason), so the three
/// members below are spelled to match that protocol and the conformance is declared where both are
/// visible, like `WindowFeedChannel: @retroactive HostWindowFeedLink`.
public final class MacVideoSurfaceHost: NSView {
    /// The Metal-backed pane view. Owned as a subview; it owns the decode pipeline for its lifetime.
    private let surface: MacMetalLayerBackedView
    /// The control bridge, owned here for this host's lifetime. The Metal view publishes the swipe-peel
    /// state onto it; the chip overlay is wired to react (see ``init(_:)``).
    private let controls: MacVideoPaneControls
    /// The mount-time binding, kept so ``setPaneGates(isActive:inputEnabled:backgroundPointer:)`` can
    /// re-run ``MacVideoLayerView/apply(to:)`` — the only per-render pass this pane gets now that there
    /// is no SwiftUI render loop to run it automatically.
    private var binding: MacVideoLayerView

    /// Builds the AppKit mount from a ``MacVideoPaneSpec`` — the app target's one video builder, fed
    /// straight to `VideoWindowFactory.shared`'s one registration (see the file header).
    public init(_ pane: MacVideoPaneSpec) {
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

        let chip = MacSwipePeelOverlayView(frame: bounds)
        chip.autoresizingMask = [.width, .height]
        addSubview(chip)
        // Wires the chip to the control bridge's swipe-peel state — see
        // ``MacVideoPaneControls/onSwipePeelChanged``, fired on every `controls.swipePeel` change.
        // `[weak chip]` — the closure lives on `controls`, which this host also owns, so nothing here
        // would break without it, but a callback that outlives its target is the shape of a leak this
        // file does not want to normalize.
        controls.onSwipePeelChanged = { [weak chip] state in chip?.apply(state) }
        // Accessibility rides the container, not the Metal view: the pixels have no structure to expose.
        setAccessibilityLabel("Remote GUI window: \(pane.title)")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// `RemoteSurfaceHosting`: the view the canvas adds. It is this container (the Metal view and the
    /// chip are its subviews and are never handed out separately).
    public var surfaceView: NSView { self }

    /// `RemoteSurfaceHosting`: pushes the three gates that change at runtime and re-runs
    /// ``MacVideoLayerView/apply(to:)`` — an AppKit canvas has no render pass to do this automatically
    /// the way SwiftUI's `updateNSView` used to, so a caller must ask for it explicitly on every gate
    /// change. Runs through the SAME `apply(to:)` as every other gate push, including its read-only-flip
    /// branch, which is the only thing that withdraws and restores the host-affecting injector sinks.
    public func setPaneGates(isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool) {
        binding.isActive = isActive
        binding.inputEnabled = inputEnabled
        binding.backgroundPointer = backgroundPointer
        binding.apply(to: surface)
    }

    /// `RemoteSurfaceHosting`: tears the client session down. Removing this view from its superview
    /// is NOT enough — the session owns two UDP sockets, a VideoToolbox decoder and a display link.
    public func detachSurface() { surface.deactivate() }
}
