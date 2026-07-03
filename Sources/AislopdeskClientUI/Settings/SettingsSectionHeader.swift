// SettingsSectionHeader (Batch-5 UI fidelity) — the signature in-page Settings SECTION-header treatment.
//
// Settings section labels (`MOUSE` / `SECURE INPUT` in `mouse-option.png`, `NOTIFICATION` /
// `TAB BADGE` in `notification-setting.png`, `ALL SETTINGS` in `all-settings.png`) render as UPPERCASE,
// letter-TRACKED, secondary-gray small-caps headers — NOT macOS's default Title-Case dark `Section(_:)`
// header. Earlier code used the native `Section("Title")` initializer, which renders Title-Case bold
// dark on macOS grouped Forms (e.g. "Selection", "Copy & Paste"). This helper consolidates every grouped
// settings section onto ONE shared header style that matches both the design-spec screenshots AND this app's
// own command-palette section headers (`PaletteView.sectionHeader` — the same uppercase/tracked/muted
// treatment, styled with native system semantics since the native-chrome migration), so the Settings
// form and the palette no longer diverge. Call sites swap `Section("X") {` → `slateFormSection("X") {`; the
// content closure is unchanged, so no layout in the section body moves.

#if canImport(SwiftUI)
import SwiftUI

/// Pure, testable transform for the section-header label — UPPERCASE. Extracted so the casing is pinned
/// by `SettingsSectionHeaderTests` and can't silently regress to macOS's Title-Case default if the render
/// helper is refactored.
enum SlateSettingsSectionHeader {
    static func label(_ title: String) -> String { title.uppercased() }
}

/// A grouped-`Form` section whose header carries the UPPERCASE / tracked / muted treatment (native
/// `.caption` semibold · system `.tertiary` — the Slate token layer is retired here, native-chrome
/// migration 2026-07-03), instead of macOS's default Title-Case dark header.
/// Drop-in for `Section(_ title:content:)`: the trailing `content` closure is identical, so swapping the
/// initializer name restyles the header without touching the section body. `@MainActor` matches its SwiftUI
/// call sites (every one is a view body).
@MainActor
func slateFormSection(
    _ title: String,
    @ViewBuilder content: () -> some View,
) -> some View {
    Section {
        content()
    } header: {
        Text(SlateSettingsSectionHeader.label(title))
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}
#endif
