// SettingsSectionHeader (Batch-5 UI fidelity) — the DRAWING half of the signature in-page Settings
// SECTION-header treatment.
//
// Earlier code used the native `Section("Title")` initializer, which renders Title-Case bold dark on
// macOS grouped Forms (e.g. "Selection", "Copy & Paste"). This helper consolidates every grouped
// settings section onto ONE shared header style that matches both the design-spec screenshots AND this app's
// own command-palette section headers (`PaletteView.sectionHeader` — the same three tokens), so the Settings
// form and the palette no longer diverge. Call sites swap `Section("X") {` → `slateFormSection("X") {`; the
// content closure is unchanged, so no layout in the section body moves.
//
// docs/56: the CASING transform itself — `title.uppercased()`, pinned as ``SlateSettingsSectionHeader`` —
// named no view framework and descended to `SlopDeskClientCore/Settings/SlateSettingsSectionHeader.swift`
// in batch 2 of the draining-floor split, along with its test. What is left here is the drawing: `Text`,
// `Section`, the tracking and `SettingsInk.secondary` (a `Color`, which is why this half cannot follow —
// the P6 rule keeps a `Color` at or above `SlopDeskSlate`).

#if os(iOS)
import SlopDeskClientCore // SlateSettingsSectionHeader.label(_:)
import SlopDeskSlate
import SwiftUI

/// A grouped-`Form` section whose header carries the UPPERCASE / tracked / secondary-gray treatment
/// (`SettingsType.sectionHeader` semibold · `SettingsInk.secondary`), instead of macOS's default Title-Case
/// dark header.
/// Drop-in for `Section(_ title:content:)`: the trailing `content` closure is identical, so swapping the
/// initializer name restyles the header without touching the section body.
func slateFormSection(
    _ title: String,
    @ViewBuilder content: () -> some View,
) -> some View {
    Section {
        content()
    } header: {
        Text(SlateSettingsSectionHeader.label(title))
            .font(SettingsType.sectionHeader.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(SettingsInk.secondary)
    }
}
#endif
