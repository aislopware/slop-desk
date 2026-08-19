// SharedFocusSetting — the Settings row that decides whether THIS device follows the shared focus.
//
// `DevicePreferences.followSessionFocus` (docs/45 §8.2) is DEVICE-LOCAL, persisted in
// `device-prefs.json` and platform-defaulted (ON macOS / OFF iOS). It decides whether local navigation
// stages a `focusTab` / `focusPane` INTENT — moving every following client — or only this device's own
// `WorkspaceStore.DeviceFocus` overlay. A phone glancing at a build log must not drag a Studio's screen
// with it; a desk expects the host's focus to lead.
//
// The flag belongs to `WorkspaceStore`, not to `PreferencesStore`, so the Settings surface reaches it the
// way the Agents card reaches `AgentHooksController`: an `@Entry` environment slot injected at the
// settings ROOT (the AppKit window's hosting root on macOS, `SettingsSheet` on iOS — a sheet does not
// inherit the presenter's custom environment values).
//
// A `nil` store is a preview or an un-injected host. The row then states the PLATFORM DEFAULT and
// disables itself: never a made-up state, never a write that lands nowhere — the same honest-fallback
// rule `AgentSettingsCard` follows for a nil controller.
//
// Every derivation here is a pure function of an optional store, so `SharedFocusSettingTests` pins the
// whole wiring — including the `device-prefs.json` round trip — with NO view.

#if canImport(SwiftUI)
import SlopDeskClientCore // SettingsIndexPresentation — the one spelling of the readout
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - The pure derivations behind the row

/// The shared-focus row's state, derived from the (optional) injected ``WorkspaceStore``.
enum SharedFocusSetting {
    /// The config-style name the searchable All-Settings list files this row under — the catalog's own
    /// constant, so the advertised row and the control it jumps to can never name different things.
    static let catalogKey = AllSettingsCatalog.followSessionFocusKey

    /// Whether this device follows the shared focus. With no store, the platform default — that IS what a
    /// fresh device would use, and it is the only honest answer when nothing is backing the row.
    ///
    /// `@MainActor` because ``WorkspaceStore`` is: it also makes the ``binding(_:)`` closures below inherit
    /// main-actor isolation, which is what lets a `Binding` reach the store synchronously.
    @MainActor
    static func isFollowing(_ store: WorkspaceStore?) -> Bool {
        store?.devicePreferences.followSessionFocus ?? DevicePreferences.platformDefaultFollowSessionFocus
    }

    /// Whether the row can be edited. A nil store ⇒ greyed, because `setFollowSessionFocus(_:)` has no
    /// owner to reach.
    static func isConfigurable(_ store: WorkspaceStore?) -> Bool { store != nil }

    /// The readout the All-Settings list shows beside its ✎ jump.
    ///
    /// Forwards to ``SettingsIndexPresentation/followSessionFocusText(_:)`` since increment 49, so the two
    /// index renderers and this row cannot end up disagreeing about one word.
    @MainActor
    static func valueText(_ store: WorkspaceStore?) -> String {
        SettingsIndexPresentation.followSessionFocusText(store)
    }

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
