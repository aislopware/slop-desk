import SwiftUI
import RworkClientUI
#if canImport(RworkVideoClient)
import RworkVideoClient
#endif

/// The `@main` entry for both Xcode app targets (ClientApp-macOS, ClientApp-iOS).
///
/// The whole scene lives in the `RworkClientUI` SwiftPM library (`RworkClientApp`); this
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
        // cross-platform `RworkClientUI` library cannot reference `GhosttyTerminalView`
        // (it would force linking `libghostty.xcframework` + the `CGhostty` clang module
        // into the headless `swift build`/tests), so the GUI app target injects it here.
        //
        // GATED on `#if canImport(CGhostty)`: the `CGhostty` module exists only once the
        // xcframework is built and added to this app target (see the wiring notes above +
        // docs/21-HANDOFF.md). Until then this block compiles to NOTHING and the seam
        // shows the gated `BuildStatusPlaceholderView` (libghostty-only policy — no
        // fallback VT renderer).
        #if canImport(CGhostty)
        TerminalRendererFactory.shared = { model in AnyView(GhosttyTerminalView(model: model)) }
        #endif

        // PATH 2 (GUI video path, doc 17 §3): register the production remote-GUI-window
        // view. The cross-platform `RworkClientUI` library cannot reference
        // `RworkVideoClient.VideoWindowView` directly (it would pull VideoToolbox + Metal
        // into the headless `swift build`/tests), so the GUI app target — which links
        // `RworkVideoClient` — injects it here at launch. With no registration the seam
        // shows the gated `RemoteWindowPlaceholderView`.
        #if canImport(RworkVideoClient)
        VideoWindowFactory.shared = { descriptor in
            // LIVE path when the descriptor carries a full endpoint (host + media/cursor
            // ports), entered via the Remote-window panel: build the VideoWindowConnection
            // and the orchestrator-backed VideoWindowView(title:connection:). Otherwise the
            // chrome-only initializer (no live decode) — the seam's preview/placeholder path.
            if descriptor.hasEndpoint {
                let connection = VideoWindowConnection(
                    host: descriptor.host,
                    mediaPort: descriptor.mediaPort,
                    cursorPort: descriptor.cursorPort,
                    windowID: descriptor.windowID
                )
                return AnyView(VideoWindowView(title: descriptor.title, connection: connection))
            }
            return AnyView(VideoWindowView(title: descriptor.title))
        }
        // UDP-mux (RWORK_VIDEO_MUX, default OFF): install the per-host shared-flow registry on the
        // video pipeline IFF the env flag is set. No-op when OFF, so the pipeline keeps the
        // byte-identical per-pane transport. Both ends must agree on the flag (the host's
        // `rwork-videohostd` reads the same `RWORK_VIDEO_MUX`); the 15↔19-byte wire is incompatible
        // across the boundary, so a mixed pair misframes → the host drops the unadmitted lane.
        MainActor.assumeIsolated { VideoMuxInstaller.installIfEnabled() }
        #endif

        RworkClientApp.main()
    }
}
