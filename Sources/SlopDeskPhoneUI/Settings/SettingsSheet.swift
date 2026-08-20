// SettingsSheet — the iOS settings host.
//
// iOS has no `Settings` scene to hang a preferences window on, so the client's settings surface is an
// in-app SHEET, presented from the phone root's toolbar gear. A two-column navigator — a search pill over
// icon/label rows beside a content pane, which is what `SlopDeskMacUI` draws — does not map to compact
// width, so this is a `NavigationStack` + `List`-of-sections instead (the standard iOS Settings idiom):
// each section is a `NavigationLink` row that pushes its ``SettingsSectionContent`` body.
//
// THE STACK IS A VALUE (`path`), and that is what makes the All-Settings ✎ jump work rather than merely draw. The
// Mac routes its ✎ into `MacSettingsNavigator.select`: it repoints the source list and swaps the page, and that is
// ALL it does — no highlight, flash or scroll-to on the row that was jumped for (the landed-on page scrolls to its
// own top), so there is no highlight to match here either. What the phone owes is the JUMP, and on a stack a jump is
// a push: the rows link by VALUE and `selectedSection`'s setter appends to the same path, so one
// `navigationDestination` says what a section looks like whichever way the reader arrived at it.
//
// SECTION SET: EVERY section, the same eight the Mac's navigator lists. Keybindings used to be dropped
// here — its chord recorder was said to need an `NSEvent` monitor — and it is not dropped any more, because
// the phone records with `KeybindingCaptureHost` off the same Rust tables (docs/56 increment 30). What still
// differs by half is the GROUPS inside a page (the raw `SLOPDESK_*` editor, the Video host flags), and those
// are gated by the layout table's `Platform` as data, so the All-Settings index still reaches every setting.
//
// The single live `PreferencesStore` is handed in by `WorkspaceRootView` (read there from
// `\.preferencesStore`).
//
// The app-owned `AgentHooksController` is THREADED in here and injected onto the section content via
// `.agentHooksController(_:)`. Without it the Agents card was permanently `.disconnected` and the entire
// Agent-Behaviour toggle block was greyed out (the controller's `@Environment` resolved nil). The app-owned
// `WorkspaceStore` rides the same seam (`.workspaceStore(_:)`) for the DEVICE-LOCAL rows — General → Shared
// Focus, whose default is OFF on exactly this platform, so an un-injected sheet would strand a phone unable
// to opt in.
//
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if os(iOS)
import SlopDeskClientCore // SettingsSection (docs/56: descended in batch 2)
import SlopDeskWorkspaceCore
import SwiftUI

/// The iOS settings sheet: a `NavigationStack` over a `List` of the shared section taxonomy, each row
/// pushing its ``SettingsSectionContent`` body. Presented modally from `WorkspaceRootView`'s toolbar.
struct SettingsSheet: View {
    /// The single live preferences owner (handed in by `WorkspaceRootView`, which reads it from
    /// `\.preferencesStore`). Held as a plain reference: the leaf section structs re-wrap it as `@Bindable`,
    /// and the `@Observable` store re-renders whichever leaf reads a changed field.
    let store: PreferencesStore

    /// The app-owned Agents install-hooks controller, threaded from the composition root (`SlopDeskPhoneApp`
    /// holds it) through `WorkspaceRootView`, so the Agents card's Install/Uninstall/Status round-trips AND
    /// the gated Agent-Behaviour toggles are LIVE. `nil` (a preview / no scene) → the card renders the
    /// disabled "Connect a session" state rather than crashing.
    let agentHooks: AgentHooksController?

    /// The app-owned ``WorkspaceStore``, threaded from `WorkspaceRootView` so the DEVICE-LOCAL preference
    /// rows (General → Shared Focus, docs/45 §7.3) reach the value they edit. A sheet does not inherit the
    /// presenter's custom environment values, so this must be handed in explicitly — the same reason
    /// `agentHooks` is. `nil` (a preview) → those rows render the platform default, disabled.
    let workspace: WorkspaceStore?

    @Environment(\.dismiss) private var dismiss

    /// THE STACK, as a value — so a row tap and an All-Settings ✎ jump reach a page the same way,
    /// through one push, rather than one of them going through a `NavigationLink` the other cannot
    /// spell. Held as a typed `[SettingsSection]` and not a `NavigationPath`: this stack has exactly
    /// one kind of destination in it, and the erased path would only make the jump re-decode what it
    /// already knows.
    @State private var path: [SettingsSection] = []

    /// The All-Settings ✎ jump, as the `Binding<SettingsSection>` the section bodies already take.
    /// WRITING it navigates — that is the whole point, and it used to be a no-op into a `@State` no
    /// one read, which left a drawn control inert.
    ///
    /// It APPENDS where the Mac's navigator REPOINTS (`MacSettingsNavigator.select`, which swaps the
    /// page under a source list that has no history to keep). That is the layout differing, not the
    /// feature: the index the ✎ was pressed in is itself a pushed page here, so replacing the stack
    /// would answer "take me to the setting that owns this" by also throwing away the reader's place
    /// in the list of every setting. Back returns them to it. The guard is for the one case that
    /// would stack a page on itself — a jump to the page already on top is a jump already arrived.
    ///
    /// READING it answers with the page currently on top, which is what "the selected section" means
    /// in a stack; the root list selects nothing, so it falls back to the first page.
    private var selectedSection: Binding<SettingsSection> {
        Binding(
            get: { path.last ?? .general },
            set: { section in
                guard path.last != section else { return }
                path.append(section)
            },
        )
    }

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
        NavigationStack(path: $path) {
            List {
                ForEach(SettingsSection.ordered) { section in
                    // A VALUE link, not a destination one: the tap and the ✎ jump then arrive by the
                    // same push, and there is one place — `navigationDestination` — that says what a
                    // section looks like.
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
            .navigationDestination(for: SettingsSection.self) { section in
                SettingsSectionContent(
                    section: section, store: store, selectedSection: selectedSection,
                )
                // Thread the app-owned controller into the pushed section so the Agents card +
                // behaviour toggles resolve a live `@Environment(\.agentHooksController)`.
                .agentHooksController(agentHooks)
                // Same reason: the device-local rows edit `WorkspaceStore`, not `PreferencesStore`.
                .workspaceStore(workspace)
                .navigationTitle(section.title)
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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
#endif
