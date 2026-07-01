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
// E13 (ES-E13-1/ES-E13-2 iOS halves): the app-owned `AgentHooksController` is THREADED in here and injected
// onto the section content via `.agentHooksController(_:)`, mirroring the macOS `AislopdeskSettingsScene`.
// Without it the Agents card was permanently `.disconnected` and the entire Agent-Behaviour toggle block was
// greyed out on iOS (the controller's `@Environment` resolved nil).
//
// CROSS-PLATFORM COMPILE: although this is only ever PRESENTED on iOS, the struct compiles on every platform
// (the lone iOS-only modifier `.navigationBarTitleDisplayMode` is abstracted behind `inlineNavTitle()`) so
// the iOS settings host is unit-testable on the headless macOS `swift test` host — iOS view code otherwise
// rots silently (CLAUDE.md). It is referenced only inside `WorkspaceRootView`'s `#if os(iOS)` branch.
//
// Slate.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// The iOS settings sheet: a `NavigationStack` over a `List` of the cross-platform sections, each pushing
/// the shared ``SettingsSectionContent`` body. Presented modally from `WorkspaceRootView.iosToolbar`.
struct SettingsSheet: View {
    /// The single live preferences owner (handed in by `WorkspaceRootView`, which reads it from
    /// `\.preferencesStore`). Held as a plain reference: the leaf section structs re-wrap it as `@Bindable`,
    /// and the `@Observable` store re-renders whichever leaf reads a changed field.
    let store: PreferencesStore

    /// E13: the app-owned Agents install-hooks controller, threaded from `AislopdeskClientApp` (held as
    /// `@State` on every platform) so the iOS Agents card's Install/Uninstall/Status round-trips AND the
    /// gated Agent-Behaviour toggles are LIVE — mirrors the macOS `AislopdeskSettingsScene` injection. `nil`
    /// (a preview / no scene) → the card renders the disabled "Connect a session" state rather than crashing.
    let agentHooks: AgentHooksController?

    @Environment(\.dismiss) private var dismiss

    /// A local selected-section state ONLY to satisfy the All-Settings ✎ jump binding. On the compact iOS
    /// list a jump cannot repoint a `TabView` (there is none) — the cross-section jump/highlight is deferred
    /// (recorded as a nice-to-have in WI-3), so on iOS setting this is a harmless no-op.
    @State private var selectedSection: SettingsSection = .general

    init(store: PreferencesStore, agentHooks: AgentHooksController? = nil) {
        self.store = store
        self.agentHooks = agentHooks
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(SettingsSection.allCases.filter { !$0.isMacOSOnly }) { section in
                    NavigationLink {
                        SettingsSectionContent(
                            section: section, store: store, selectedSection: $selectedSection,
                        )
                        // E13: thread the app-owned controller into the pushed section so the Agents card +
                        // behaviour toggles resolve a live `@Environment(\.agentHooksController)` on iOS too.
                        .agentHooksController(agentHooks)
                        .navigationTitle(section.title)
                        .inlineNavTitle()
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
            .navigationTitle("Settings")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Native settings sheet → SYSTEM accent (reset the inherited theme tint) so its stock controls read as
        // native controls; appearance still tracks the theme via `preferredColorScheme`.
        .tint(nil)
        .preferredColorScheme(Slate.colorScheme)
    }
}

private extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` is iOS/tvOS/watchOS-only; a cross-platform no-op elsewhere so
    /// the settings sheet compiles (and unit-tests) on the macOS host even though it is only PRESENTED on iOS.
    @ViewBuilder
    func inlineNavTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
#endif
