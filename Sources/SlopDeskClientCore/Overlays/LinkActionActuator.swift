// LinkActionActuator — the ONE thin platform dispatch behind a resolved `LinkAction` PLUS the per-row Actions
// popover action table, shared by the Jump-To / Open-Quickly "Current" rows — and, later, the File/Folder
// rows — so a single actuation home exists and no parallel switch can drift.
//
// The INTENT mapping stays in the pure `LinkActionPolicy` / `TerminalContextMenu` (which kind offers which
// items; gesture/menu-item → `LinkAction`); this actuator is the thin macOS/iOS dispatch only, and it is now
// the ONLY one — the renderer's `performLinkAction` mirrored it until the phone needed the same dispatch and
// the choice was a third copy or this one raised to `public`:
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

// `public`, not `package`, and only for ``actuate(_:model:)``: the terminal renderer used to be the fork's
// embedder, compiled by the Xcode app targets and by no `Package.swift` target, so it sat OUTSIDE this
// package where `package` is invisible — which is the whole reason its macOS half carried a
// `performLinkAction` of its own, a second spelling of the switch below that this file's header already
// described itself as mirroring. That copy is gone; both platforms' renderers dispatch through here, so a
// link copied from the terminal lights the `COPIED · N` chip (`noteClipboardCopy`) and writes through
// `ClientPasteboard` like every other copy in the app, which the AppKit copy of the switch did neither of.
//
// The ACCESS LEVEL outlived its reason and is kept on purpose: docs/68 moved the renderer into
// `Sources/SlopDeskTerminal/`, so `package` would now reach it, but narrowing this is a change to who may
// actuate a link and belongs in a change about link actuation. Everything else here stays `package` — the
// Jump-To / Open-Quickly row table has no reader outside the package and must not grow one.
// `@preconcurrency` rides the `@MainActor` for the same reason it does on ``TerminalViewModel``: a PUBLIC
// main-actor declaration is a source break for a Swift 5 client.
@preconcurrency
@MainActor
public enum LinkActionActuator {
    /// One row in the per-item Actions popover (⌘K / right-click): a label, an SF Symbol, and the closure that
    /// firing it runs. The view renders these; selecting one runs `run()` and closes the panel.
    package struct RowAction {
        package let title: String
        package let symbol: String
        package let run: () -> Void

        package init(title: String, symbol: String, run: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.run = run
        }
    }

    /// The per-row action set for a Jump-To `item`: for a LINK, the kind-appropriate link items
    /// (`TerminalContextMenu.linkItems`) each resolved through the pure `LinkActionPolicy` and actuated below;
    /// for a command/prompt BLOCK, Jump-to (scrollback re-anchor) + Copy (the command text), mirroring the
    /// Outline row menu. `model` is the focused pane's terminal model (`nil` ⇒ open/reveal/cd are no-ops).
    package static func rowActions(
        for item: JumpToItem,
        store: WorkspaceStore,
        model: TerminalViewModel?,
    ) -> [RowAction] {
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

    /// Actuate a resolved `LinkAction` — THE thin platform dispatch behind the pure `LinkActionPolicy`,
    /// run by the Jump-To / Open-Quickly rows and by both halves of the terminal renderer's link gestures
    /// and context menus: copy → client pasteboard; cd → **verbatim UTF-8**
    /// `cd <quoted>` (parent-if-file) down the pane PTY (never `SendKeysParser`); open/reveal → the host RPC
    /// callbacks on the model (verbs 9 / 10); URL → client open. A no-op when no live `model` backs an
    /// open/reveal/cd.
    public static func actuate(_ action: LinkAction, model: TerminalViewModel?) {
        switch action {
        case .nothing:
            return
        case let .copyPathClient(text):
            copyToPasteboard(text)
            model?.noteClipboardCopy(text)
        case let .changeDirectoryPTY(path):
            model?.sendInput(Data(LinkActionPolicy.changeDirectoryCommandLine(path).utf8))
        case let .openURLClient(urlString):
            ExternalOpen.url(urlString)
        case let .openCodeHost(target):
            model?.onRequestOpenCodeHostPath?(target)
        case let .openHost(path):
            model?.onRequestOpenHostPath?(path)
        case let .revealHost(path):
            model?.onRequestRevealHostPath?(path)
        }
    }

    /// Copy text to the platform pasteboard (the Outline / context-menu "Copy" idiom). A no-op for empty text.
    package static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        ClientPasteboard.write(text)
    }
}
