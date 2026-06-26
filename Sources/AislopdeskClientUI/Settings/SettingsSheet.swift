// SettingsSheet — the iOS settings host (E7 WI-5, ES-E7-5 / N13).
//
// iOS has no `Settings` scene (⌘, opens a separate, system-chromed window only on macOS), so the client's
// settings surface on iOS is an in-app SHEET, presented from the `WorkspaceRootView` toolbar gear. The
// macOS two-column navigator (`SettingsView`'s search pill + icon/label rows + content pane) does not map to
// compact width, so this wraps the
// SAME per-section structs in a `NavigationStack` + `List`-of-sections (the standard iOS Settings idiom):
// each section is a `NavigationLink` row that pushes its `SettingsSectionContent` body.
//
// SECTION SET: the iOS list shows only the CROSS-PLATFORM sections (`SettingsSection.isMacOSOnly` filter) —
// today that drops **Keybindings**, whose chord CAPTURE is a macOS `NSEvent` monitor with no iOS UI. The
// Advanced section IS shown, but its macOS-host-only ROWS (the raw `AISLOPDESK_*` editor + the Video host
// flags) are gated inside `AdvancedSettingsTab` with `#if os(macOS)`, so the iOS Advanced page shows the
// pure-SwiftUI All-Settings list + Workspace import/export only.
//
// The single live `PreferencesStore` is handed in by `WorkspaceRootView` (read there from
// `\.preferencesStore`); the live `WorkspaceStore` rides the `\.workspaceStore` environment slot (injected
// at the sheet root in `WorkspaceRootView`) so the Advanced → Workspace export/import works on iOS too.
//
// Otty.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if os(iOS) && canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// The iOS settings sheet: a `NavigationStack` over a `List` of the cross-platform sections, each pushing
/// the shared ``SettingsSectionContent`` body. Presented modally from `WorkspaceRootView.iosToolbar`.
struct SettingsSheet: View {
    /// The single live preferences owner (handed in by `WorkspaceRootView`, which reads it from
    /// `\.preferencesStore`). Held as a plain reference: the leaf section structs re-wrap it as `@Bindable`,
    /// and the `@Observable` store re-renders whichever leaf reads a changed field.
    let store: PreferencesStore

    @Environment(\.dismiss) private var dismiss

    /// A local selected-section state ONLY to satisfy the All-Settings ✎ jump binding. On the compact iOS
    /// list a jump cannot repoint a `TabView` (there is none) — the cross-section jump/highlight is deferred
    /// (recorded as a nice-to-have in WI-3), so on iOS setting this is a harmless no-op.
    @State private var selectedSection: SettingsSection = .general

    init(store: PreferencesStore) {
        self.store = store
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(SettingsSection.allCases.filter { !$0.isMacOSOnly }) { section in
                    NavigationLink {
                        SettingsSectionContent(
                            section: section, store: store, selectedSection: $selectedSection,
                        )
                        .navigationTitle(section.title)
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Otty.State.accent)
        .preferredColorScheme(Otty.colorScheme)
    }
}
#endif
