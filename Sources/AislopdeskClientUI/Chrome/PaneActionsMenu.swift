// PaneActionsMenu — the native toolbar menu for the ACTIVE pane (working directory / split / move /
// close), replacing the old custom titlebar's centred title-⋯ popover (`SlateTitlebar.TitleMenuButton`,
// deleted in the native-chrome migration). A stock SwiftUI `Menu` in the unified toolbar: system styling,
// system materials, zero custom chrome. The window TITLE itself is `.navigationTitle` now — this menu
// carries only the actions.
//
// NOTE: the rows deliberately carry NO `.keyboardShortcut` — the app-level `WorkspaceKeyDispatcher`
// NSEvent monitor is the single chord owner (⌘D/⌘⇧D/⌘W/…); a SwiftUI shortcut here would double-fire.

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit // NSPasteboard for "Copy Path"
import SFSafeSymbols
import SwiftUI

struct PaneActionsMenu: View {
    let store: WorkspaceStore

    /// The active tab's active pane id — the target of every action; `nil` disables the menu.
    private var activePane: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    private var cwd: String? {
        guard let id = activePane else { return nil }
        return store.tree.activeSession?.specs[id]?.lastKnownCwd
    }

    var body: some View {
        Menu {
            Section("Working Directory") {
                if let cwd {
                    Text(cwd)
                    Button("Copy Path") { copyPath(cwd) }
                } else {
                    Text("~")
                }
            }
            Section {
                Button("Split Right") { split(.horizontal) }
                Button("Split Down") { split(.vertical) }
                Button("Move Pane Left") { store.swapActivePaneInDirection(.left) }
                Button("Move Pane Right") { store.swapActivePaneInDirection(.right) }
            }
            Section {
                Button("Close Pane", role: .destructive) { close() }
            }
        } label: {
            Label("Pane Actions", systemSymbol: .ellipsisCircle)
        }
        .disabled(activePane == nil)
        .help("Pane actions (split / move / close)")
    }

    private func split(_ axis: SplitAxis) {
        // A split MINTS a pane → create an in-pane CHOOSER pane, focused. Defer one runloop tick so the
        // menu's dismissal doesn't race the split's reconcile + focus (same discipline as the old popover).
        DispatchQueue.main.async { store.openChooserPane(.split(axis: axis)) }
    }

    private func close() {
        guard let id = activePane else { return }
        store.requestClosePaneTree(id)
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
#endif
