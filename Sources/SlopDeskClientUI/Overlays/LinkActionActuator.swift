// LinkActionActuator — the ONE thin platform dispatch behind a resolved `LinkAction` PLUS the per-row Actions
// popover action table, shared by the Jump-To / Open-Quickly "Current" rows — and, later, the File/Folder
// rows — so a single actuation home exists and no parallel switch can drift.
//
// The INTENT mapping stays in the pure `LinkActionPolicy` / `TerminalContextMenu` (which kind offers which
// items; gesture/menu-item → `LinkAction`); this actuator is the thin macOS/iOS dispatch only, mirroring the
// renderer's `performLinkAction` and the leaf `TerminalLeafView`:
//   - **Copy** (`copyPathClient`) → the CLIENT pasteboard.
//   - **Reveal / Open** (`revealHost` / `openHost`) → the pane model's host RPC seams (`onRequestRevealHostPath`
//     / `onRequestOpenHostPath`, metadata verbs 10 / 9) — a no-op when no live model backs it.
//   - **Change Directory Here** (`changeDirectoryPTY`) → **verbatim UTF-8** `cd <quoted>` (parent-if-file)
//     down the pane PTY via `LinkActionPolicy.changeDirectoryCommandLine` — NEVER `SendKeysParser` (cd is
//     verbatim; memory: re-run/cd is verbatim UTF-8).
//   - **URL** (`openURLClient`) → opened on the CLIENT (`NSWorkspace`/`UIApplication`).
//
// Scope note (the Jump-To set only): a command-BLOCK row here offers Jump-to + Copy (the Outline row menu).
// A verbatim Re-Run of a captured block is NOT added by this actuator — it already lives on the store
// (`WorkspaceStore` → `BlockReRunEncoder`); the Open-Quickly command rows reuse THAT path, never a parallel
// encoder.
//
// `@MainActor` because every sink it touches (`WorkspaceStore.jumpToNavigatorBlockInActivePane`,
// `TerminalViewModel.sendInput` / its host callbacks, the platform pasteboard) is main-actor work. Shared by
// `JumpToView` and `OpenQuicklyView`.

import Foundation
import SlopDeskWorkspaceCore
#if canImport(AppKit)
import AppKit // NSPasteboard (Copy) + NSWorkspace (open URL) — client-side
#elseif canImport(UIKit)
import UIKit // UIPasteboard (Copy) + UIApplication (open URL) — client-side
#endif

@MainActor
enum LinkActionActuator {
    /// One row in the per-item Actions popover (⌘K / right-click): a label, an SF Symbol, and the closure that
    /// firing it runs. The view renders these; selecting one runs `run()` and closes the panel.
    struct RowAction {
        let title: String
        let symbol: String
        let run: () -> Void
    }

    /// The per-row action set for a Jump-To `item`: for a LINK, the kind-appropriate link items
    /// (`TerminalContextMenu.linkItems`) each resolved through the pure `LinkActionPolicy` and actuated below;
    /// for a command/prompt BLOCK, Jump-to (scrollback re-anchor) + Copy (the command text), mirroring the
    /// Outline row menu. `model` is the focused pane's terminal model (`nil` ⇒ open/reveal/cd are no-ops).
    static func rowActions(for item: JumpToItem, store: WorkspaceStore, model: TerminalViewModel?) -> [RowAction] {
        switch item.act {
        case let .link(link):
            TerminalContextMenu.linkItems(for: link.kind).map { linkItem in
                RowAction(title: linkItem.title(for: link.kind), symbol: linkItem.symbol) {
                    actuate(LinkActionPolicy.action(for: linkItem, link: link), model: model)
                }
            }
        case let .block(index):
            [
                RowAction(title: "Jump to", symbol: "arrow.right.to.line") {
                    store.jumpToNavigatorBlockInActivePane(index: index)
                },
                RowAction(title: "Copy", symbol: "doc.on.doc") {
                    copyToPasteboard(item.title)
                    model?.noteClipboardCopy(item.title)
                },
            ]
        }
    }

    /// Actuate a resolved `LinkAction` — the thin platform dispatch behind the pure `LinkActionPolicy`,
    /// mirroring the renderer's `performLinkAction`: copy → client pasteboard; cd → **verbatim UTF-8**
    /// `cd <quoted>` (parent-if-file) down the pane PTY (never `SendKeysParser`); open/reveal → the host RPC
    /// callbacks on the model (verbs 9 / 10); URL → client open. A no-op when no live `model` backs an
    /// open/reveal/cd.
    static func actuate(_ action: LinkAction, model: TerminalViewModel?) {
        switch action {
        case .nothing:
            return
        case let .copyPathClient(text):
            copyToPasteboard(text)
            model?.noteClipboardCopy(text)
        case let .changeDirectoryPTY(path):
            model?.sendInput(Data(LinkActionPolicy.changeDirectoryCommandLine(path).utf8))
        case let .openURLClient(urlString):
            openURLString(urlString)
        case let .openHost(path):
            model?.onRequestOpenHostPath?(path)
        case let .revealHost(path):
            model?.onRequestRevealHostPath?(path)
        }
    }

    /// Copy text to the platform pasteboard (the Outline / context-menu "Copy" idiom). A no-op for empty text.
    static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        ClientPasteboard.write(text)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// Open a URL string on the CLIENT (a URL / IP is host-agnostic). A no-op for an unparseable string.
    private static func openURLString(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}
