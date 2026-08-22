// MacVideoLayerRepresentable — the `NSViewRepresentable` that mounts the Metal surface into SwiftUI,
// plus the env-gated view-layer probe (docs/56 §3, the video carve).
//
// `build()` and `apply(to:)` are deliberately callable WITHOUT a SwiftUI `Context`, because
// `MacVideoSurfaceHost` mounts the same view into an AppKit canvas and drives it through exactly these
// two methods. Mount-time wiring and per-render wiring are each written once; the alternative is an
// AppKit half that re-derives which sinks are published before `activate` and which after, and is
// right by luck until someone adds the next sink.

import AppKit
import Foundation
import SlopDeskVideoClient
import SwiftUI

/// Env-gated (`SLOPDESK_VIDEO_DEBUG`) stderr diagnostics for the remote-GUI VIEW layer (scroll routing +
/// isActive delivery) — the BUG-2 ground-truth probe: logging both distinguishes a stale/sticky
/// `isActive` value from a downstream scroll-routing problem.
func videoViewDbg(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("SlopDesk[video.client.view]: \(message())\n".utf8))
}

/// `NSViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on macOS.
struct MacVideoLayerView: NSViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: MacVideoPaneControls?
    /// The bound remote app's display name (empty = desktop pane / unknown) — the smart-zoom
    /// ⌘0 gate's input (``PinchZeroPolicy``).
    var targetAppName: String = ""
    var isActive: Bool = true
    /// READ-ONLY INPUT GATE: `false` ⇒ the backing view forwards no pointer/scroll/keycode to the
    /// host (gated `isActive && inputEnabled`) and withholds the paste-as-keystrokes sink. Set on every render.
    var inputEnabled: Bool = true
    /// BACKGROUND POINTER (satellite windows): pointer interaction while the window is NOT key —
    /// see ``BackgroundPointerPolicy``. Set on every render.
    var backgroundPointer: Bool = false
    var onActivate: () -> Void = {}
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
    var onSystemKeyInjectorReady: ((((UInt16, UInt64, Bool) -> Void)?) -> Void)?
    var onStreamStallChanged: ((Bool) -> Void)?
    var onSessionRejected: (() -> Void)?

    func makeNSView(context _: Context) -> MacMetalLayerBackedView { build() }

    func updateNSView(_ nsView: MacMetalLayerBackedView, context _: Context) { apply(to: nsView) }

    static func dismantleNSView(_ nsView: MacMetalLayerBackedView, coordinator _: ()) {
        nsView.deactivate()
    }

    /// The `makeNSView` body, callable WITHOUT a SwiftUI `Context` (neither this nor ``apply(to:)`` ever
    /// read one). ``MacVideoSurfaceHost`` mounts the same view into an AppKit canvas and drives it through
    /// these two methods, so the mount-time wiring and the per-render wiring are each written once — the
    /// alternative is an AppKit half that re-derives which sinks are published before `activate` and which
    /// after, and is right by luck until someone adds the next sink.
    func build() -> MacMetalLayerBackedView {
        let view = MacMetalLayerBackedView()
        view.controls = controls
        view.targetAppName = targetAppName
        view.isActive = isActive
        view.inputEnabled = inputEnabled
        view.backgroundPointer = backgroundPointer
        view.onActivate = onActivate
        view.onCanvasScroll = onCanvasScroll
        view.onStreamNativeSize = onStreamNativeSize // before activate — its nil-ness picks snap vs host-follow
        // HOST-WINDOW RESIZE: before activate so the first decoded-points / displayMax callback can publish
        // the window geometry (current + max) straight to the model.
        view.onWindowGeometryReady = onWindowGeometryReady
        // CONNECTION STATS: before activate so the first host cadence announcement reaches the model's FPS row.
        view.onStreamCadenceReady = onStreamCadenceReady
        view.onStreamBitrateReady = onStreamBitrateReady
        // NETWORK-STATS MIRROR: before activate so the first ~2 Hz aggregate reaches the model.
        view.onNetworkStatsReady = onNetworkStatsReady
        // STALL SCRIM: before activate so a stall detected on the very first monitor tick reaches the model.
        view.onStreamStallReady = onStreamStallChanged
        // TERMINAL REFUSAL: before activate so a helloAck(accepted:false) landing immediately reaches the model.
        view.onSessionRejectedReady = onSessionRejected
        view.activate(connection: connection)
        // PASTE AS KEYSTROKES: publish a key-injection sink routed to THIS view's pipeline (`pipeline.key`
        // no-ops until the session is up, so publishing now is safe). Cleared on `deactivate`.
        view.onKeyInjectorReady = onKeyInjectorReady
        view.publishKeyInjector()
        // RESIZE GRIP: publish a resize-drive sink routed to THIS view's pipeline (the session's
        // resize guard no-ops until streaming, so publishing now is safe). Cleared on `deactivate`.
        view.onResizeInjectorReady = onResizeInjectorReady
        view.publishResizeInjector()
        // VIEWPORT CONTROLS: publish the client zoom / pan-lock command sink (pure compositor ops on THIS
        // view — no host round-trip). NOT read-only-gated, so it is never withdrawn on a lock flip. Cleared
        // on `deactivate`.
        view.onViewportInjectorReady = onViewportInjectorReady
        view.publishViewportInjector()
        // RELEASE STUCK INPUT (C5): publish the manual escape-hatch release sink (the seam binds nil while
        // read-only, like the key sink). Cleared on `deactivate`.
        view.onInputReleaseReady = onInputReleaseReady
        view.publishInputReleaseInjector()
        // STREAM SETTINGS: publish the fps-cap / bitrate-ceiling drive (the session's streaming guard
        // makes a pre-stream request safe — it is stored and sent at handshake). Host-affecting, so the
        // seam binds nil while read-only, like the resize sink. Cleared on `deactivate`.
        view.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
        view.publishStreamSettingsInjector()
        // HOST AUDIO: publish the enable/disable drive (the session stores the wish and re-sends it at
        // every handshake, so a pre-stream request is safe). Host-affecting, so the seam binds nil
        // while read-only, like the stream-settings sink.
        view.onAudioInjectorReady = onAudioInjectorReady
        view.publishAudioInjector()
        // PRIVACY BLANK: publish the enable/disable drive (stored + re-sent at handshake). Host-
        // affecting, so the seam binds nil while read-only, like the audio sink.
        view.onPrivacyInjectorReady = onPrivacyInjectorReady
        view.publishPrivacyInjector()
        // SYSTEM-KEY INJECTOR: publish the programmatic key drive (same wire path as local keyDown/keyUp;
        // `pipeline.key` no-ops until the session is up). Host input — seam binds nil while read-only.
        view.onSystemKeyInjectorReady = onSystemKeyInjectorReady
        view.publishSystemKeyInjector()
        // BUG-2 probe: a recreate (makeNSView) on focus change — vs an in-place updateNSView — would reset
        // isActive to its `true` default mid-stream; logging it distinguishes "stale Bool" from "recreate".
        videoViewDbg("makeNSView (CREATED) isActive=\(isActive)")
        return view
    }

    /// The `updateNSView` body, callable without a `Context` — see ``build()``.
    func apply(to nsView: MacMetalLayerBackedView) {
        nsView.controls = controls
        nsView.targetAppName = targetAppName
        if nsView.isActive != isActive { videoViewDbg("updateNSView isActive \(nsView.isActive)→\(isActive)") }
        nsView.isActive = isActive
        // READ-ONLY INPUT GATE: apply the current gate every render. On a FLIP, re-publish the
        // paste-as-keystrokes sink so the seam's `onKeyInjectorReady` (which binds a nil sink while read-only)
        // re-evaluates — locking a live pane withholds the sink, unlocking restores it, with no view rebuild.
        let inputGateFlipped = nsView.inputEnabled != inputEnabled
        nsView.inputEnabled = inputEnabled
        nsView.backgroundPointer = backgroundPointer
        nsView.onActivate = onActivate
        nsView.onCanvasScroll = onCanvasScroll
        nsView.onStreamNativeSize = onStreamNativeSize
        // VIEWPORT CONTROLS: keep the bind closure current (the model persists per pane, so the published
        // sink stays valid — no re-publish needed; it is not read-only-gated).
        nsView.onViewportInjectorReady = onViewportInjectorReady
        // HOST-WINDOW RESIZE: keep the geometry push current (model persists per pane).
        nsView.onWindowGeometryReady = onWindowGeometryReady
        // CONNECTION STATS: keep the cadence + bitrate pushes current (model persists per pane).
        nsView.onStreamCadenceReady = onStreamCadenceReady
        nsView.onStreamBitrateReady = onStreamBitrateReady
        // NETWORK-STATS MIRROR: keep the ~2 Hz aggregate push current (model persists per pane).
        nsView.onNetworkStatsReady = onNetworkStatsReady
        // STALL SCRIM: keep the stall push current (model persists per pane).
        nsView.onStreamStallReady = onStreamStallChanged
        // TERMINAL REFUSAL: keep the rejection push current (model persists per pane).
        nsView.onSessionRejectedReady = onSessionRejected
        nsView.activate(connection: connection)
        if inputGateFlipped {
            nsView.onKeyInjectorReady = onKeyInjectorReady
            nsView.publishKeyInjector()
            // RESIZE GRIP: the seam binds a nil resize sink while read-only (like the key sink), so a
            // read-only flip must re-publish to withdraw / restore the grip's drive.
            nsView.onResizeInjectorReady = onResizeInjectorReady
            nsView.publishResizeInjector()
            // RELEASE STUCK INPUT (C5): read-only-gated like the key sink — a flip re-evaluates the seam's
            // nil-binding so a locked pane withdraws the escape hatch and an unlock restores it.
            nsView.onInputReleaseReady = onInputReleaseReady
            nsView.publishInputReleaseInjector()
            // STREAM SETTINGS + AUDIO + SYSTEM KEYS: read-only-gated like the resize/key sinks — a flip
            // re-evaluates the seam's nil-binding (lock withholds, unlock restores).
            nsView.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
            nsView.publishStreamSettingsInjector()
            nsView.onAudioInjectorReady = onAudioInjectorReady
            nsView.publishAudioInjector()
            nsView.onPrivacyInjectorReady = onPrivacyInjectorReady
            nsView.publishPrivacyInjector()
            nsView.onSystemKeyInjectorReady = onSystemKeyInjectorReady
            nsView.publishSystemKeyInjector()
        }
    }
}
