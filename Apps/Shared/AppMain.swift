import SwiftUI
import AislopdeskClientUI
#if canImport(AislopdeskVideoClient)
import AislopdeskVideoClient
#endif

/// The `@main` entry for both Xcode app targets (ClientApp-macOS, ClientApp-iOS).
///
/// The whole scene lives in the `AislopdeskClientUI` SwiftPM library (`AislopdeskClientApp`); this
/// shell only attaches `@main` and, when the libghostty xcframework is present, registers the
/// production terminal renderer with ``TerminalRendererFactory``. Until the xcframework is
/// built, no factory is registered and the BUILD-STATUS placeholder shows (libghostty-only
/// policy — there is NO fallback VT renderer).
///
/// ## Wiring the production renderer (once the xcframework exists)
/// 1. Build it: `ThirdParty/ghostty/build-libghostty.sh` → `libghostty.xcframework`.
/// 2. Add the xcframework to this app target (project.yml `dependencies:` / Xcode "Frameworks").
/// 3. Add `ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift` +
///    the `CGhostty` module map to this target's sources/headers.
/// 4. Add a `GhosttyTerminalView: TerminalRenderingView` (a `UIViewRepresentable` /
///    `NSViewRepresentable` hosting a Metal view that owns a `GhosttySurface`, attaching it to
///    `model.surface` and feeding `model`'s output).
/// 5. Register it in `init()` below:
///        TerminalRendererFactory.shared = { model in AnyView(GhosttyTerminalView(model: model)) }
@main
struct ClientAppMain {
    static func main() {
        // PATH 1 (terminal, libghostty-only): register the production renderer. The
        // cross-platform `AislopdeskClientUI` library cannot reference `GhosttyTerminalView`
        // (it would force linking `libghostty.xcframework` + the `CGhostty` clang module
        // into the headless `swift build`/tests), so the GUI app target injects it here.
        //
        // GATED on `#if canImport(CGhostty)`: the `CGhostty` module exists only once the
        // xcframework is built and added to this app target (see the wiring notes above +
        // docs/21-HANDOFF.md). Until then this block compiles to NOTHING and the seam
        // shows the gated `BuildStatusPlaceholderView` (libghostty-only policy — no
        // fallback VT renderer).
        #if canImport(CGhostty)
        TerminalRendererFactory.shared = { model, isFocused in
            AnyView(GhosttyTerminalView(model: model, isFocused: isFocused))
        }
        #endif

        // PATH 2 (GUI video path, doc 17 §3): register the production remote-GUI-window
        // view. The cross-platform `AislopdeskClientUI` library cannot reference
        // `AislopdeskVideoClient.VideoWindowView` directly (it would pull VideoToolbox + Metal
        // into the headless `swift build`/tests), so the GUI app target — which links
        // `AislopdeskVideoClient` — injects it here at launch. With no registration the seam
        // shows the gated `RemoteWindowPlaceholderView`.
        #if canImport(AislopdeskVideoClient)
        VideoWindowFactory.shared = { descriptor, paneContext in
            // LIVE path when the descriptor carries a full endpoint (host + media/cursor
            // ports), entered via the Remote-window panel: build the VideoWindowConnection
            // and the orchestrator-backed VideoWindowView(title:connection:). Otherwise the
            // chrome-only initializer (no live decode) — the seam's preview/placeholder path.
            //
            // `paneContext` (active state + activate/canvas-scroll callbacks) is destructured into
            // primitives here — `AislopdeskVideoClient` cannot import `AislopdeskClientUI` (the seam exists
            // for exactly that reason), so the context type stays on the `AislopdeskClientUI` side and
            // only its Bool + closures cross into `VideoWindowView`.
            if descriptor.hasEndpoint {
                let connection = VideoWindowConnection(
                    host: descriptor.host,
                    mediaPort: descriptor.mediaPort,
                    cursorPort: descriptor.cursorPort,
                    windowID: descriptor.windowID
                )
                return AnyView(VideoWindowView(
                    title: descriptor.title, connection: connection,
                    isActive: paneContext.isActive,
                    onActivate: paneContext.onActivate,
                    onCanvasScroll: paneContext.onCanvasScroll,
                    onStreamNativeSize: paneContext.onStreamNativeSize,
                    onKeyInjectorReady: paneContext.onKeyInjectorReady))
            }
            return AnyView(VideoWindowView(title: descriptor.title))
        }
        // UDP-mux: install the per-host shared-flow registry on the video pipeline. Panes targeting the
        // same host share ONE UDP flow (one flow per host, N panes); the host's `aislopdesk-videohostd`
        // speaks the matching 19-byte channelID-prefixed wire — the only video wire there is now.
        MainActor.assumeIsolated { VideoMuxInstaller.install() }

        // Remote-window PICKER discovery seam (docs/31): inject the host-window query so the
        // cross-platform UI lists windows instead of making the user type a CGWindowID. Maps the
        // video-protocol `WindowSummary` → the UI's `RemoteWindowSummary`. `nil` (no video module) ⇒ the
        // picker falls back to manual entry.
        MainActor.assumeIsolated {
            RemoteWindowDiscovery.shared = { host, mediaPort, cursorPort in
                let windows = await VideoWindowDiscovery.discoverWindows(
                    host: host, mediaPort: mediaPort, cursorPort: cursorPort
                )
                return windows.map {
                    RemoteWindowSummary(windowID: $0.windowID, appName: $0.appName, title: $0.title,
                                        width: $0.width, height: $0.height)
                }
            }
        }

        // System-dialog poll seam (the "show system popups in their own pane" feature): inject the
        // host system-dialog query so the cross-platform `SystemDialogMonitor` can auto-spawn dialog
        // panes WITHOUT importing the gated video module. Maps the protocol's `SystemDialogSummary` →
        // the UI's `SystemDialogInfo`. `nil` (no video module) ⇒ the monitor is inert.
        MainActor.assumeIsolated {
            SystemDialogDiscovery.shared = { host, mediaPort, cursorPort in
                let dialogs = await VideoWindowDiscovery.discoverSystemDialogs(
                    host: host, mediaPort: mediaPort, cursorPort: cursorPort
                )
                return dialogs.map {
                    SystemDialogInfo(windowID: $0.windowID, owner: $0.owner, title: $0.title,
                                     width: $0.width, height: $0.height, isSecure: $0.isSecure)
                }
            }
        }
        #endif

        AislopdeskClientApp.main()
    }
}
