// SlateSettingsSectionHeader (Batch-5 UI fidelity) — the pure half of the in-page Settings SECTION-header
// treatment.
//
// Settings section labels (`MOUSE` / `SECURE INPUT` in `mouse-option.png`, `NOTIFICATION` /
// `TAB BADGE` in `notification-setting.png`, `ALL SETTINGS` in `all-settings.png`) render as UPPERCASE,
// letter-tracked, secondary-gray small-caps headers, and the one fact that transform must never regress
// is the casing itself — UPPERCASE, not the raw Title-Case title macOS's native `Section(_:)` header
// renders. That is a `String -> String` function, so it names no view framework, and it descended here
// from `SlopDeskClientUI` in batch 2 of the draining-floor split (`SettingsSectionHeaderTests` moved with
// it, to `SlopDeskClientCoreTests`).
//
// The DRAWING half — `slateFormSection`, the `Section` wrapper that applies the tracking, the weight and
// `SettingsInk.secondary` — needs `Text`/`Section`/`Color`, all of which are SwiftUI (and `SettingsInk`
// is a `Color` table, which the P6 rule keeps out of this target). It stayed behind, in
// `SlopDeskClientUI/Settings/SettingsSectionHeader.swift`, which now carries only that half and says so.
/// `package`: read from `SlopDeskClientUI/Settings/SettingsSectionHeader.swift`'s `slateFormSection`
/// across the module boundary.
package enum SlateSettingsSectionHeader {
    package static func label(_ title: String) -> String { title.uppercased() }
}
