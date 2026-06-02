#if canImport(SwiftUI)
import SwiftUI

/// The Rwork client app scene, shared by both Xcode app targets (ClientApp-macOS,
/// ClientApp-iOS). The app targets reference this as their `@main` entry — see the
/// `project.yml`s under `Apps/`.
///
/// It wires the view-models once and hands them to ``ClientRootView``. Platform chrome is
/// branched with `#if os(macOS)` / `#if os(iOS)`:
/// - macOS: a `WindowGroup` plus the standard commands; the window is resizable.
/// - iOS: a `WindowGroup` and the app handles background/foreground via the scene phase to
///   drive the client `pause()`/`resume()` byte-exact-resume seam (doc 17 §2.5).
///
/// The terminal renderer is the gated seam: in the app target, register a
/// ``TerminalRendererFactory/shared`` factory that builds the libghostty
/// `GhosttyTerminalView` once the xcframework is present; until then the BUILD-STATUS
/// placeholder shows. The library compiles and runs without it.
public struct RworkClientApp: App {
    @State private var terminal = TerminalViewModel()
    @State private var connection: ConnectionViewModel
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        let terminal = TerminalViewModel()
        _terminal = State(initialValue: terminal)
        _connection = State(initialValue: ConnectionViewModel(terminal: terminal))
    }

    public var body: some Scene {
        WindowGroup {
            ClientRootView(connection: connection)
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }

    /// Drives the iOS lifecycle seam: background → `pause()` (host retains the tail),
    /// foreground → `resume()` (byte-exact). On macOS scene phase is informational only.
    private func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        switch phase {
        case .background:
            Task { await connection.pause() }
        case .active:
            Task { await connection.resume() }
        default:
            break
        }
        #endif
    }
}
#endif
