// SharedFocusSetting's binding + environment slot — the two things the pure derivations cannot be
// without SwiftUI itself.
//
// The flag belongs to `WorkspaceStore`, not to `PreferencesStore`, so the Settings surface reaches it the
// way the Agents card reaches `AgentHooksController`: an `@Entry` environment slot injected at the
// settings ROOT (the AppKit window's hosting root on macOS, `SettingsSheet` on iOS — a sheet does not
// inherit the presenter's custom environment values).
//
// docs/56: ``SharedFocusSetting``'s `isFollowing(_:)` / `isConfigurable(_:)` / `valueText(_:)` /
// `catalogKey` name no view framework and descended to
// `SlopDeskClientCore/Settings/SharedFocusSetting.swift` in batch 2 of the draining-floor split. What
// stayed is `binding(_:)` — a `Binding<Bool>` is SwiftUI's, not a decision — and the environment slot,
// which is SwiftUI by construction (`@Entry`, `EnvironmentValues`). Both are declared as an `extension`
// on the same-named enum, so every call site still spells `SharedFocusSetting.binding(...)` without
// caring which target answers it.

#if canImport(SwiftUI)
import SlopDeskClientCore // SharedFocusSetting's pure half
import SlopDeskWorkspaceCore
import SwiftUI

extension SharedFocusSetting {
    /// The row's binding. Writes go through ``WorkspaceStore/setFollowSessionFocus(_:)`` — the ONE edit
    /// path, so the "resuming follow drops the device-local overlay" rule can never be routed around.
    /// With no store the write is inert.
    @MainActor
    static func binding(_ store: WorkspaceStore?) -> Binding<Bool> {
        Binding(
            get: { isFollowing(store) },
            set: { store?.setFollowSessionFocus($0) },
        )
    }
}

// MARK: - The settings-root environment slot

extension EnvironmentValues {
    /// The single app-owned ``WorkspaceStore``, injected at the settings root so the device-local
    /// preference rows (docs/45 §7.3) reach the value they edit. `nil` outside the app scene (previews) →
    /// those rows render the platform default, disabled, rather than crashing.
    @Entry var workspaceStore: WorkspaceStore?
}

package extension View {
    /// Inject the app-owned ``WorkspaceStore`` into the environment (called at the settings root —
    /// the SwiftUI scene's, and the AppKit window's hosting root, which is the same root twice).
    func workspaceStore(_ store: WorkspaceStore?) -> some View {
        environment(\.workspaceStore, store)
    }
}
#endif
