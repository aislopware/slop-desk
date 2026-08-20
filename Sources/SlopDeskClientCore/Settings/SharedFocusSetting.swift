// SharedFocusSetting — the pure derivations behind the Settings row that decides whether THIS device
// follows the shared focus.
//
// `DevicePreferences.followSessionFocus` (docs/45 §8.2) is DEVICE-LOCAL, persisted in
// `device-prefs.json` and platform-defaulted (ON macOS / OFF iOS). It decides whether local navigation
// stages a `focusTab` / `focusPane` INTENT — moving every following client — or only this device's own
// `WorkspaceStore.DeviceFocus` overlay. A phone glancing at a build log must not drag a Studio's screen
// with it; a desk expects the host's focus to lead.
//
// A `nil` store is a preview or an un-injected host. The row then states the PLATFORM DEFAULT and
// disables itself: never a made-up state, never a write that lands nowhere — the same honest-fallback
// rule `AgentSettingsCard` follows for a nil controller.
//
// Every derivation here is a pure function of an optional store, so `SharedFocusSettingTests` (split
// across `SlopDeskClientCoreTests` and the phone app's own bundle, docs/56) pins the whole wiring —
// including the `device-prefs.json` round trip — with NO view.
//
// docs/56: this is the half of the old shared `Settings/SharedFocusSetting.swift` that names
// no view framework — `WorkspaceStore` is `SlopDeskWorkspaceCore`'s, and `Bool`/`String` are not
// SwiftUI. It descended here in batch 2 of the draining-floor split. `binding(_:)` — which returns a
// SwiftUI `Binding<V>` — and the `@Entry` environment slot both need SwiftUI itself, so they stayed in
// `SlopDeskPhoneUI/Settings/SharedFocusSetting.swift`, which now carries only that half and reaches
// this one the same way any other call site does.

import SlopDeskWorkspaceCore

// MARK: - The pure derivations behind the row

/// The shared-focus row's state, derived from the (optional) injected ``WorkspaceStore``. `package`:
/// read from `SlopDeskPhoneUI` (the `binding(_:)` extension, and the settings pages) across the
/// module boundary, the way `SettingsCatalog` beside it is.
package enum SharedFocusSetting {
    /// The config-style name the searchable All-Settings list files this row under — the catalog's own
    /// constant, so the advertised row and the control it jumps to can never name different things.
    package static let catalogKey = AllSettingsCatalog.followSessionFocusKey

    /// Whether this device follows the shared focus. With no store, the platform default — that IS what a
    /// fresh device would use, and it is the only honest answer when nothing is backing the row.
    ///
    /// `@MainActor` because ``WorkspaceStore`` is: it also makes ``SlopDeskPhoneUI``'s `binding(_:)`
    /// closures inherit main-actor isolation, which is what lets a `Binding` reach the store synchronously.
    @MainActor
    package static func isFollowing(_ store: WorkspaceStore?) -> Bool {
        store?.devicePreferences.followSessionFocus ?? DevicePreferences.platformDefaultFollowSessionFocus
    }

    /// Whether the row can be edited. A nil store ⇒ greyed, because `setFollowSessionFocus(_:)` has no
    /// owner to reach.
    package static func isConfigurable(_ store: WorkspaceStore?) -> Bool { store != nil }

    /// The readout the All-Settings list shows beside its ✎ jump.
    ///
    /// Forwards to ``SettingsIndexPresentation/followSessionFocusText(_:)`` since increment 49, so the two
    /// index renderers and this row cannot end up disagreeing about one word.
    @MainActor
    package static func valueText(_ store: WorkspaceStore?) -> String {
        SettingsIndexPresentation.followSessionFocusText(store)
    }
}
