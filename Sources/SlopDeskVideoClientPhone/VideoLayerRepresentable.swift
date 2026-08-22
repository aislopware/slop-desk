// VideoLayerRepresentable — the `UIViewRepresentable` that mounts the Metal surface into
// SwiftUI (docs/56 §3, the video carve).
//
// The before/after-`activate` split of the sink publishes is the same one the Mac's `build()` makes,
// and for the same reasons, which are restated at each site rather than cross-referenced: the first
// decoded frame, the first host cadence announcement, the first ~2 Hz stats aggregate, a stall on
// the very first monitor tick and an immediate `helloAck(accepted: false)` must each find their sink
// already set.
#if os(iOS)
import SlopDeskVideoClient
import SwiftUI
import UIKit

/// `UIViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on iOS.
struct VideoLayerView: UIViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls?
    // Signature parity with the macOS representable (the shared `VideoWindowView.body` passes it).
    // The smart-zoom ⌘0 gate is a TRACKPAD `smartMagnify` translation; a phone has no two-finger
    // double-tap on a trackpad to gate, so this stays unread here.
    var targetAppName: String = ""
    /// Whether this is the workspace's focused pane. The phone forwards pointer input from ANY pane the
    /// finger lands on — exactly like the Mac's `mouseDown`, which is never `isActive`-gated (only HOVER
    /// is, and there is no hover here). What this drives is the KEYBOARD: the surface claims/releases
    /// first responder with the focus flip, so a hardware keyboard types into the focused pane.
    var isActive: Bool = true
    /// READ-ONLY INPUT GATE, and it is live now: `false` ⇒ this surface forwards NEITHER touch-derived
    /// pointer traffic NOR keycodes, and the seam withholds the host-affecting injector sinks. Set on
    /// every render, exactly like the macOS half.
    var inputEnabled: Bool = true
    // Signature parity with the macOS representable. Background-pointer interaction is "keep taking
    // pointer input while the window is NOT key", and iOS has no key-window state (nor a second window a
    // pane can be popped into) — the phone reads it as nothing, so it is accepted + ignored here.
    var backgroundPointer: Bool = false
    var onActivate: () -> Void = {}
    // Signature parity. ⌥-scroll-to-pan-the-canvas is a trackpad route; the phone's canvas is navigated
    // by its own gestures outside this surface, so the seam binds an empty closure and nothing calls it.
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    var onResizeInjectorReady: ((((Double, Double) -> Void)?) -> Void)?
    var onViewportInjectorReady: ((((UInt8) -> Void)?) -> Void)?
    var onInputReleaseReady: (((() -> Void)?) -> Void)?
    var onWindowGeometryReady: ((Double, Double, Double, Double) -> Void)?
    var onStreamCadenceReady: ((Int) -> Void)?
    var onStreamBitrateReady: ((Int) -> Void)?
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int, Double, Double, Double) -> Void)?
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    var onAudioInjectorReady: ((((Bool) -> Void)?) -> Void)?
    var onPrivacyInjectorReady: ((((Bool) -> Void)?) -> Void)?
    var onStreamStallChanged: ((Bool) -> Void)?
    var onSessionRejected: (() -> Void)?

    func makeUIView(context _: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView(frame: .zero)
        view.controls = controls
        view.isActive = isActive
        view.inputEnabled = inputEnabled
        view.onActivate = onActivate
        view.onStreamNativeSize = onStreamNativeSize // before activate — nil-ness picks snap vs host-follow
        // BEFORE activate, for the same reasons the macOS `build()` gives: the first decoded frame, the
        // first host cadence announcement, the first ~2 Hz stats aggregate, a stall detected on the very
        // first monitor tick and an immediate `helloAck(accepted: false)` must each find their sink set.
        view.onWindowGeometryReady = onWindowGeometryReady
        view.onStreamCadenceReady = onStreamCadenceReady
        view.onStreamBitrateReady = onStreamBitrateReady
        view.onNetworkStatsReady = onNetworkStatsReady
        view.onStreamStallReady = onStreamStallChanged
        view.onSessionRejectedReady = onSessionRejected
        view.activate(connection: connection)
        // AFTER activate — `pipeline.*` no-ops until the session is up, so publishing now is safe, and
        // the model's `didSet` re-asserts (audio / lock / stream overrides) need a live sink to push into.
        view.onKeyInjectorReady = onKeyInjectorReady
        view.publishKeyInjector()
        view.onResizeInjectorReady = onResizeInjectorReady
        view.publishResizeInjector()
        view.onViewportInjectorReady = onViewportInjectorReady
        view.publishViewportInjector()
        view.onInputReleaseReady = onInputReleaseReady
        view.publishInputReleaseInjector()
        view.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
        view.publishStreamSettingsInjector()
        view.onAudioInjectorReady = onAudioInjectorReady
        view.publishAudioInjector()
        view.onPrivacyInjectorReady = onPrivacyInjectorReady
        view.publishPrivacyInjector()
        return view
    }

    func updateUIView(_ uiView: MetalLayerBackedView, context _: Context) {
        uiView.controls = controls
        uiView.isActive = isActive
        // READ-ONLY INPUT GATE: on a FLIP, re-publish every sink the seam withholds while read-only, so
        // locking a live pane withdraws them and unlocking restores them with no view rebuild — the
        // macOS `apply(to:)` branch, transposed. The viewport sink is NOT in it (pure client compositor
        // ops), which is why the pane's fit/zoom/lock stay live on a locked phone pane.
        let inputGateFlipped = uiView.inputEnabled != inputEnabled
        uiView.inputEnabled = inputEnabled
        uiView.onActivate = onActivate
        uiView.onStreamNativeSize = onStreamNativeSize
        uiView.onViewportInjectorReady = onViewportInjectorReady
        uiView.onWindowGeometryReady = onWindowGeometryReady
        uiView.onStreamCadenceReady = onStreamCadenceReady
        uiView.onStreamBitrateReady = onStreamBitrateReady
        uiView.onNetworkStatsReady = onNetworkStatsReady
        uiView.onStreamStallReady = onStreamStallChanged
        uiView.onSessionRejectedReady = onSessionRejected
        uiView.activate(connection: connection)
        if inputGateFlipped {
            uiView.onKeyInjectorReady = onKeyInjectorReady
            uiView.publishKeyInjector()
            uiView.onResizeInjectorReady = onResizeInjectorReady
            uiView.publishResizeInjector()
            uiView.onInputReleaseReady = onInputReleaseReady
            uiView.publishInputReleaseInjector()
            uiView.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
            uiView.publishStreamSettingsInjector()
            uiView.onAudioInjectorReady = onAudioInjectorReady
            uiView.publishAudioInjector()
            uiView.onPrivacyInjectorReady = onPrivacyInjectorReady
            uiView.publishPrivacyInjector()
        }
    }

    static func dismantleUIView(_ uiView: MetalLayerBackedView, coordinator _: ()) {
        uiView.deactivate()
    }
}
#endif
