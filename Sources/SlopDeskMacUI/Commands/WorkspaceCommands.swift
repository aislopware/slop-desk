// WorkspaceCommands — the macOS MENU BAR, built once at launch as an `NSMenu`.
//
// It lived in the draining floor until it had no reason to: a menu bar is macOS's, it names no view
// from that target (only `WorkspaceBindingRegistry`), and the whole-file `#if os(macOS)` it wore was
// the tell. Here the gate is the TARGET, so the file has none — docs/56 §3.
//
// A thin, DISCOVERABILITY-ONLY menu that renders `WorkspaceBindingRegistry.groupedForDisplay` as four
// top-level menus (Panes / Tabs / Focus / View) so the workspace actions are visible in the macOS menu
// bar. Every row dispatches through the SAME single source of truth
// (`WorkspaceBindingRegistry.route`) the keyboard dispatcher uses.
//
// THE load-bearing rule: NO KEY EQUIVALENT ON ANY WORKSPACE ROW. The app-level `NSEvent` `.keyDown`
// monitor (`WorkspaceKeyDispatcher`) OWNS chord dispatch — including the multi-key tmux/zellij prefix
// that a key equivalent cannot express. A menu shortcut would (a) DOUBLE-FIRE alongside the monitor
// for a single-chord binding, and (b) SWALLOW a prefix sequence's follow-up key before the terminal
// first responder (libghostty) sees it — both wrong. AppKit resolves key equivalents BEFORE the
// responder chain and before an application-scoped monitor sees the event, so this is not a
// preference. The glyph still SHOWS on each row (appended to the title as text, never as
// `keyEquivalent`) so the menu stays a faithful cheat sheet without binding the chord. See the
// `WorkspaceKeyDispatcher` header + docs/DECISIONS.md (menu-bar entry) for the full rationale.
//
// ⚠️ IT WAS A SwiftUI `Commands` BODY, AND THE PORT MADE IT BIGGER FOR A REASON THAT IS NOT STYLE. A
// SwiftUI `App` supplies the standard App / File / Edit / Window / Help menus itself and `.commands`
// only AMENDS them — which is why the old file's body was four `CommandMenu`s and two
// `CommandGroup(replacing:)`s and nothing else. This process has no `NSApplicationMain`, no
// MainMenu.nib and no `NSPrincipalClass`, so `NSApp.mainMenu` starts EMPTY: the standard menus are
// this file's now. Two of them are load-bearing rather than decorative:
//
//   * **Edit**, because ⌘X/⌘C/⌘V/⌘A in an `NSTextField` are not built into the field — they are
//     `cut:`/`copy:`/`paste:`/`selectAll:` key equivalents on the Edit menu, resolved against the
//     first responder. Without it the palette's query field and the Connect sheet's form take no
//     paste at all. These ARE key equivalents, and they do not violate the rule above: the rule is
//     about the WORKSPACE's chords, and ⌘V has never been one.
//   * **App ▸ Quit (⌘Q)**, because `terminate:` is likewise a menu key equivalent — and ⌘Q is what
//     the whole quit-drain in ``SlopDeskMacApp/applicationShouldTerminate(_:)`` is parked behind.
//
// The two `CommandGroup(replacing:)`s came across as absences rather than code:
//   * `.newItem` was replaced with NOTHING because the product is a documented SINGLE-window model —
//     the whole app wiring (`store` / `keyDispatcher` / `windowBox` / the close gate) is app-wide
//     singleton state, so a second workspace window over the SAME store would leave chords dying in
//     whichever window was not captured last. There is simply no New Window item below.
//   * `.appSettings` was replaced with "Open Configuration…" (⌘,), which is built into the App menu
//     here. It opens `config.toml`: there is no settings window to raise, and the file IS the
//     settings surface (docs/58 — there is NO settings GUI).

import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The macOS menu bar for the workspace, and the pure lookups its live half is validated through.
///
/// A caseless enum: it was a `struct … : Commands` because a SwiftUI scene needed a value to attach,
/// and every member it had was either a stored closure (now a parameter of ``perform(id:store:…)``)
/// or a static table.
@MainActor
enum WorkspaceCommands {
    // MARK: The bar

    /// Build the whole menu bar. `target` receives every action this file does not hand to the
    /// responder chain — see ``SlopDeskMacApp/performWorkspaceAction(_:)``,
    /// ``SlopDeskMacApp/openConfiguration(_:)`` and ``SlopDeskMacApp/closeWorkspaceWindow(_:)``.
    ///
    /// Built ONCE. Nothing here is rebuilt when the workspace changes: the two rows whose appearance
    /// is live (the ✓ on Pin Window, the greying of the pane actions) are resolved by AppKit's own
    /// ``NSMenuItem`` validation each time a menu opens — see ``checkmark(id:chrome:)`` and
    /// ``isEnabled(id:activePaneID:)`` — which costs nothing while the menu is closed. The SwiftUI
    /// original re-evaluated its whole `Commands` body on any observed store change to answer the
    /// same two questions.
    static func mainMenu(target: AnyObject) -> NSMenu {
        let bar = NSMenu()
        bar.addItem(appMenuItem(target: target))
        bar.addItem(editMenuItem())
        // One top-level menu per display category, in the registry's display order — the workspace's
        // own action verbs, after the standard menus. Unlike the SwiftUI original this is a real
        // loop: `CommandsBuilder` had no `ForEach` (it is a `View` builder concept), so the fan-out
        // had to be unrolled over `allCases` by hand. `NSMenu` has no such restriction, so adding a
        // category to the registry now lights up a menu with no line here.
        for category in WorkspaceAction.Category.allCases {
            bar.addItem(categoryMenuItem(category, target: target))
        }
        bar.addItem(windowMenuItem(target: target))
        return bar
    }

    /// The APP menu — the one whose title AppKit ignores (it always draws the process name in bold).
    private static func appMenuItem(target: AnyObject) -> NSMenuItem {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About \(name)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())
        // ⌘, is the one shortcut declared for a non-standard action, and it is the APP MENU's rather
        // than the workspace's — which is why it does not fall under this file's no-key-equivalent
        // rule. `.appSettings` was the group AppKit reserves for it in SwiftUI; here it is simply
        // where every Mac user looks.
        let configuration = NSMenuItem(
            title: "Open Configuration…",
            action: #selector(SlopDeskMacApp.openConfiguration(_:)),
            keyEquivalent: ",",
        )
        configuration.target = target
        menu.addItem(configuration)
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide \(name)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h",
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())
        // ⌘Q — the chord the entire quit drain hangs off. `terminate:` reaches `NSApp`, which asks its
        // delegate, which is ``SlopDeskMacApp``.
        menu.addItem(
            withTitle: "Quit \(name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
        )
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// The EDIT menu — see this file's header: these key equivalents are what make ⌘C/⌘V work in
    /// every text field in the app, and they are the responder chain's, not the workspace's.
    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a",
        )
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// One top-level menu for a display category, its rows pulled from ``WorkspaceBindingRegistry``'s
    /// ``WorkspaceBindingRegistry/groupedForDisplay`` (the single source the cheat sheet + palette also
    /// read). A category with no bindings yields an EMPTY menu — harmless, and a future epic that adds
    /// the first binding to a now-empty section lights it up with no further wiring here.
    private static func categoryMenuItem(
        _ category: WorkspaceAction.Category, target: AnyObject,
    ) -> NSMenuItem {
        let menu = NSMenu(title: category.rawValue)
        for binding in rowsByCategory[category] ?? [] {
            menu.addItem(row(for: binding, target: target))
        }
        let item = NSMenuItem(title: category.rawValue, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// One menu row. The collapsed ⌘1…⌘9 "Select Pane" representative expands into a real submenu (the
    /// registry comment promises the menu "builds its own Select Pane submenu"); every other binding is
    /// a plain key-equivalent-LESS item that routes its action and shows its glyph in its title.
    ///
    /// The binding's ID rides in `representedObject`, which is what makes the action ONE selector
    /// rather than a closure per row: an `NSMenuItem` carries a target/action pair, not a captured
    /// closure, and a per-row closure would need an object to own it — the exact retain-cycle shape
    /// (menu → closure → delegate → menu) docs/62 §4 warns about for target/action. A `String` in
    /// `representedObject` owns nothing.
    private static func row(for binding: WorkspaceBinding, target: AnyObject) -> NSMenuItem {
        if binding.id == WorkspaceBindingRegistry.selectPaneRepresentative.id {
            let submenu = NSMenu(title: "Select Pane")
            for pane in WorkspaceBindingRegistry.selectPaneBindings {
                submenu.addItem(row(for: pane, target: target))
            }
            let item = NSMenuItem(title: "Select Pane", action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }
        let item = NSMenuItem(
            title: title(for: binding),
            action: #selector(SlopDeskMacApp.performWorkspaceAction(_:)),
            // ⚠️ ALWAYS EMPTY — the whole point of this file. See the header.
            keyEquivalent: "",
        )
        item.target = target
        item.representedObject = binding.id
        return item
    }

    /// The WINDOW menu. Minimize and Zoom go to the responder chain like any Mac app's; Close Window
    /// is the workspace's own actuator, because a key SATELLITE must close itself rather than the
    /// hidden main window (see ``SlopDeskMacApp/closeWorkspaceWindow(_:)``).
    ///
    /// ⚠️ NO "New Window", and see the header: the single-window model is the product's, and the old
    /// scene said the same thing by replacing `.newItem` with an empty group.
    private static func windowMenuItem(target: AnyObject) -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m",
        )
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // ⌘⇧W's MENU TWIN, and deliberately without the key equivalent: the chord itself is the
        // NSEvent monitor's (`keyDispatcher.setCloseWindow`), like every other workspace chord.
        let close = NSMenuItem(
            title: "Close Window",
            action: #selector(SlopDeskMacApp.closeWorkspaceWindow(_:)),
            keyEquivalent: "",
        )
        close.target = target
        menu.addItem(close)
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    // MARK: The live half

    /// Dispatch the row identified by `id` through the shared registry routing.
    ///
    /// ⚠️ THE ROUTE CALL IS UNCHANGED, argument for argument — this is the deleted `actionButton`'s
    /// body with the binding looked up from an id instead of captured. The menu is a second ENTRY to
    /// the one dispatcher, never a second dispatcher, and that has not moved.
    static func perform(
        id: String,
        store: WorkspaceStore,
        togglePalette: (() -> Void)? = nil,
        toggleCheatSheet: (() -> Void)? = nil,
        toggleFind: (() -> Void)? = nil,
        togglePeekReply: (() -> Void)? = nil,
        toggleSidebar: (() -> Void)? = nil,
        toggleCodeSidebar: (() -> Void)? = nil,
        toggleGlobalSearch: (() -> Void)? = nil,
        toggleJumpTo: (() -> Void)? = nil,
        openQuickly: (() -> Void)? = nil,
        togglePinWindow: (() -> Void)? = nil,
        closeWindow: (() -> Void)? = nil,
    ) {
        guard let binding = bindingsByID[id] else { return }
        WorkspaceBindingRegistry.route(
            binding.action,
            to: store,
            togglePalette: togglePalette,
            toggleCheatSheet: toggleCheatSheet,
            toggleFind: toggleFind,
            togglePeekReply: togglePeekReply,
            toggleSidebar: toggleSidebar,
            toggleCodeSidebar: toggleCodeSidebar,
            toggleGlobalSearch: toggleGlobalSearch,
            toggleJumpTo: toggleJumpTo,
            openQuickly: openQuickly,
            togglePinWindow: togglePinWindow,
            closeWindow: closeWindow,
        )
    }

    /// Whether the row may be picked: grey it out when its action needs an active pane and there is
    /// none. Mirrors the palette / cheat-sheet enablement, and it is the `.disabled(binding.action
    /// .requiresActivePane && activePaneID == nil)` the two SwiftUI row builders both carried.
    static func isEnabled(id: String, activePaneID: PaneID?) -> Bool {
        guard let binding = bindingsByID[id] else { return true }
        return !(binding.action.requiresActivePane && activePaneID == nil)
    }

    /// Whether the row draws a ✓. Exactly one does: View ▸ Pin Window, which is a CHECKABLE toggle
    /// tracking the live `chrome.pinned`.
    ///
    /// ⚠️ IT COST A `Toggle` AND A `Binding` IN SwiftUI, and both were scaffolding around this one
    /// boolean: a `Button` cannot show menu state, so the row had to become a `Toggle` whose `set:`
    /// discarded its argument and called `togglePinWindow` anyway. An `NSMenuItem` has a `state`, so
    /// the row is the same kind of row as every other one and this function is the whole difference.
    static func checkmark(id: String, chrome: WorkspaceChromeState) -> Bool {
        id == pinWindowID && chrome.pinned
    }

    /// The Pin Window binding's id — the one row with live state. Spelled once here rather than at
    /// each of the two sites that ask about it.
    private static let pinWindowID = "view.pinWindow"

    // MARK: - The tables, read once

    /// Each display category's rows, in the registry's order.
    ///
    /// ``groupedForDisplay`` rebuilds the whole grouped table on every read (four `filter` passes over
    /// the 76-row array, plus the appended select-pane representative), and the SwiftUI original read
    /// it once per category per body pass — four times, on any observed store change. The bar is built
    /// once now, so this table's job has narrowed to "read the registry once at launch"; it stays a
    /// `static let` because it is also what ``bindingsByID`` is derived from.
    private static let rowsByCategory: [WorkspaceAction.Category: [WorkspaceBinding]] = Dictionary(
        uniqueKeysWithValues: WorkspaceBindingRegistry.groupedForDisplay.map { ($0.category, $0.bindings) },
    )

    /// Every displayable binding by id — what a row's `representedObject` is resolved through, for
    /// both the dispatch and the two validation questions.
    private static let bindingsByID: [String: WorkspaceBinding] = Dictionary(
        (WorkspaceBindingRegistry.groupedForDisplay.flatMap(\.bindings)
            + WorkspaceBindingRegistry.selectPaneBindings).map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first },
    )

    /// Every menu row's rendered title — the binding's own words with its default chord's glyph
    /// appended — by binding id.
    ///
    /// The glyph is a crossing, and `WorkspaceBindingRegistry.glyph(for:)` pays a linear scan of
    /// `allBindings` (an array it rebuilds per call) to find the binding before it renders one. That
    /// ran per menu ROW per body pass: ~54 chord-bearing rows plus the nine ⌘1…⌘9 submenu rows the
    /// Select Pane menu draws, so 54–110 crossings and thousands of element comparisons on every
    /// re-evaluation.
    ///
    /// Measured with `swiftc -O` against the shipped `SlopDeskFFI.xcframework`: the glyph door and its
    /// marshalling are 254 ns, and the `binding(for:)` lookup in front of it is **1.43 µs** — the
    /// array rebuild, not the boundary. So a menu-bar body pass was spending **~90–190 µs** rendering
    /// titles that had not changed since launch. ⚠️ THE MEASUREMENT IS KEPT THOUGH THE HOT LOOP IS
    /// GONE: an `NSMenu` built once pays the whole cost exactly once, so this table is no longer
    /// saving anything at runtime — it is saving the NEXT person from putting the crossing back in a
    /// place that runs often, which is what the numbers are here to say.
    ///
    /// It is a `let` because the answer cannot change: `WorkspaceBindingRegistry.bindings` is itself
    /// a `static let`, and `glyph(for:)` renders the DEFAULT chord — a user override lives in
    /// `WorkspaceBindingOverrides`, which this menu has never consulted (the glyph here is a
    /// discoverability hint, not the chord that fires; the `NSEvent` dispatcher owns that, per the
    /// file header).
    private static let titlesByID: [String: String] = {
        let rows = WorkspaceBindingRegistry.groupedForDisplay.flatMap(\.bindings)
            + WorkspaceBindingRegistry.selectPaneBindings
        return Dictionary(rows.map { binding in
            guard let glyph = WorkspaceBindingRegistry.glyph(for: binding.action) else {
                return (binding.id, binding.title)
            }
            return (binding.id, "\(binding.title)  \(glyph)")
        }, uniquingKeysWith: { first, _ in first })
    }()

    /// The row title, with the chord glyph appended as a plain-text hint when the binding has one. We
    /// do NOT set `keyEquivalent`, so the glyph would otherwise be invisible — appending it keeps the
    /// menu a faithful cheat sheet (e.g. "Split Right  ⌘D") without binding the key.
    ///
    /// Read out of ``titlesByID``; falls back to the bare title, which is what a binding with no chord
    /// reads as anyway.
    private static func title(for binding: WorkspaceBinding) -> String {
        titlesByID[binding.id] ?? binding.title
    }
}
