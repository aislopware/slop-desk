// SettingsSheet — the iOS settings host.
//
// iOS has no `Settings` scene (⌘, opens a separate, system-chromed window only on macOS), so the client's
// settings surface on iOS is an in-app SHEET, presented from the phone root's toolbar gear. The
// macOS two-column navigator (`SettingsView`'s search pill + icon/label rows + content pane) does not map to
// compact width, so this wraps the
// SAME per-section structs in a `NavigationStack` + `List`-of-sections (the standard iOS Settings idiom):
// each section is a `NavigationLink` row that pushes its `SettingsSectionContent` body.
//
// SECTION SET: the iOS list shows only the CROSS-PLATFORM sections (`SettingsSection.isMacOSOnly` filter) —
// today that drops **Keybindings**, whose chord CAPTURE is a macOS `NSEvent` monitor with no iOS UI. The
// Advanced section IS shown, but its macOS-host-only ROWS (the raw `SLOPDESK_*` editor + the Video host
// flags) are gated inside `AdvancedSettingsTab` with `#if os(macOS)`, so the iOS Advanced page shows the
// pure-SwiftUI All-Settings list only.
//
// The single live `PreferencesStore` is handed in by `WorkspaceRootView` (read there from
// `\.preferencesStore`).
//
// The app-owned `AgentHooksController` is THREADED in here and injected
// onto the section content via `.agentHooksController(_:)`, mirroring the macOS `SlopDeskSettingsScene`.
// Without it the Agents card was permanently `.disconnected` and the entire Agent-Behaviour toggle block was
// greyed out on iOS (the controller's `@Environment` resolved nil). The app-owned `WorkspaceStore` rides the
// same seam (`.workspaceStore(_:)`) for the DEVICE-LOCAL rows — General → Shared Focus, whose default is OFF
// on exactly this platform, so an un-injected sheet would strand a phone unable to opt in.
//
// CROSS-PLATFORM COMPILE: although this is only ever PRESENTED on iOS, the struct compiles on every platform
// (the lone iOS-only modifier `.navigationBarTitleDisplayMode` is abstracted behind `inlineNavTitle()`) so
// the iOS settings host is unit-testable on the headless macOS `swift test` host — iOS view code otherwise
// rots silently (CLAUDE.md). It is referenced only from the iOS-only `WorkspaceRootView`.
//
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The iOS settings sheet: a `NavigationStack` over a `List` of the cross-platform sections, each pushing
/// the shared ``SettingsSectionContent`` body. Presented modally from `WorkspaceRootView.iosToolbar`.
struct SettingsSheet: View {
    /// The single live preferences owner (handed in by `WorkspaceRootView`, which reads it from
    /// `\.preferencesStore`). Held as a plain reference: the leaf section structs re-wrap it as `@Bindable`,
    /// and the `@Observable` store re-renders whichever leaf reads a changed field.
    let store: PreferencesStore

    /// The app-owned Agents install-hooks controller, threaded from `SlopDeskClientApp` (held as
    /// `@State` on every platform) so the iOS Agents card's Install/Uninstall/Status round-trips AND the
    /// gated Agent-Behaviour toggles are LIVE — mirrors the macOS `SlopDeskSettingsScene` injection. `nil`
    /// (a preview / no scene) → the card renders the disabled "Connect a session" state rather than crashing.
    let agentHooks: AgentHooksController?

    /// The app-owned ``WorkspaceStore``, threaded from `WorkspaceRootView` so the DEVICE-LOCAL preference
    /// rows (General → Shared Focus, docs/45 §7.3) reach the value they edit. A sheet does not inherit the
    /// presenter's custom environment values, so this must be handed in explicitly — the same reason
    /// `agentHooks` is. `nil` (a preview) → those rows render the platform default, disabled.
    let workspace: WorkspaceStore?

    @Environment(\.dismiss) private var dismiss

    /// A local selected-section state ONLY to satisfy the All-Settings ✎ jump binding. On the compact iOS
    /// list a jump cannot repoint a `TabView` (there is none) — the cross-section jump/highlight is deferred
    /// (a known follow-up), so on iOS setting this is a harmless no-op.
    @State private var selectedSection: SettingsSection = .general

    init(
        store: PreferencesStore,
        agentHooks: AgentHooksController? = nil,
        workspace: WorkspaceStore? = nil,
    ) {
        self.store = store
        self.agentHooks = agentHooks
        self.workspace = workspace
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(SettingsSection.allCases.filter { !$0.isMacOSOnly }) { section in
                    NavigationLink {
                        SettingsSectionContent(
                            section: section, store: store, selectedSection: $selectedSection,
                        )
                        // Thread the app-owned controller into the pushed section so the Agents card +
                        // behaviour toggles resolve a live `@Environment(\.agentHooksController)` on iOS too.
                        .agentHooksController(agentHooks)
                        // Same reason: the device-local rows edit `WorkspaceStore`, not `PreferencesStore`.
                        .workspaceStore(workspace)
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
        // Native settings sheet → SYSTEM accent AND system appearance: the tint is reset (dropping the
        // inherited theme accent) and NO `preferredColorScheme` is pinned, so a stock `Form` of stock
        // controls renders exactly as iOS Settings does. The terminal theme is the workspace's subject,
        // not this sheet's — see `SettingsInk`.
        .tint(nil)
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
