import SwiftUI
import RworkClientUI

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
        // #if canImport(CGhostty)
        //   TerminalRendererFactory.shared = { model in AnyView(GhosttyTerminalView(model: model)) }
        // #endif
        RworkClientApp.main()
    }
}
