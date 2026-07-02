// OverlayEnvironment — a SwiftUI environment slot carrying the single ``OverlayCoordinator`` down to deep
// views (per-pane toast emitters / overlay hooks) without threading it through every intermediate view.
// The root injects it once; `nil` is the safe default (hooks degrade to a no-op in tests/previews).

import SwiftUI

extension EnvironmentValues {
    /// The single overlay coordinator (palette / settings / toasts). `nil` outside the app scene root.
    @Entry var overlayCoordinator: OverlayCoordinator?
}

extension View {
    /// Inject the live ``OverlayCoordinator`` into the environment (called once at the scene root).
    func overlayCoordinator(_ coordinator: OverlayCoordinator?) -> some View {
        environment(\.overlayCoordinator, coordinator)
    }
}
