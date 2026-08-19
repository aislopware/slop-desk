// MacCodeSidebarKeyboard — the duel between an embedded VS Code and a focused terminal over one
// window's keyboard, and the only place it is fought.
//
// THE DEFECT IT EXISTS TO PREVENT is two live cursors. A workspace tab has a terminal and it may have
// the code panel, both of them AppKit first responders in one `NSWindow`, and the workbench pulls
// native focus on its own schedule (a boot, a file open, a layout change). Left alone that produces a
// window where the terminal draws a solid caret, the editor blinks one beside it, and the keystrokes
// go to whichever of them AppKit last handed first responder — which is the bug this whole cluster
// was written around (user-reported 2026-08-03 and again 2026-08-10). Every rule about who should
// have the keyboard is pure and lives in `CodeSidebarFocusPolicy`; this file is the ACTUATOR, and it
// is the half that is unavoidably AppKit: key windows, responder chains, `makeFirstResponder`.
//
// IT LIVES HERE BECAUSE THAT IS WHAT IT IS. It used to be the bottom two hundred lines of
// `CodeSidebarWebViewPool`, walled off behind `#if os(macOS)` — and a platform gate inside a shared
// file means the file is in the wrong target (docs/56 §3). The pool's subject is projects and their
// warm pages, which is one law on both platforms; this is window machinery, which is one platform's
// and no law at all on the other. The phone installs no duel, and the pool's `keyboard` seam stays
// nil there rather than compiling to an empty branch.
//
// IT REACHES THE POOL, NEVER THE PAGE'S CLASS. `CodeSidebarWKWebView` is the responder seam and
// `check-supervisor.sh` keeps its name inside the two files that own it, so everything below speaks
// ``CodeSidebarPooledPage`` — the webview plus the three things a page can be asked to do.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // the pool and its keyboard seam — the duel is fought over its warm pages
import SlopDeskWorkspaceModel // TabID — the focus region is per TAB, which is the whole point
import WebKit

/// The Mac's keyboard duel. A process singleton because its subject is a process singleton: there is
/// one key window, one responder chain and one pool.
@MainActor
final class MacCodeSidebarKeyboard {
    /// Built on first touch, and building it is what ARMS the window observers below. That used to
    /// happen on the first touch of `CodeSidebarWebViewPool.shared`; it now happens at app
    /// composition, which is strictly earlier and therefore strictly safer — an observer that is
    /// armed before there is a window to observe simply has nothing to do yet.
    static let shared = MacCodeSidebarKeyboard()

    /// The workspace's ACTIVE TAB — wired once by the app layer, because neither this nor the pool
    /// can see the store. The `nil` default (headless tests, pre-wiring renders) simply never
    /// restores, which is the honest answer when nobody has said what tab it is.
    var activeTabID: @MainActor () -> TabID? = { nil }

    /// THE PER-TAB FOCUS REGION — every workspace tab whose keyboard belongs to the code panel,
    /// mapped to the project workbench it belongs to. A tab absent from here reads its terminal.
    /// Written at the responder seam (claim / resign) and honoured on every tab switch and remount;
    /// see ``CodeSidebarFocusPolicy/shouldRestoreOnRemount(memory:activeTab:projectRoot:)``.
    private var sidebarFocusMemory: [TabID: String] = [:]

    /// The last first responder that was a real view OUTSIDE every pooled webview — the repair target
    /// when a refused page focus pull strands the keyboard on the window (see
    /// ``repairOrphanedFocus(after:)``). Tracked from `NSWindow.didUpdate` because AppKit offers no
    /// first-responder-change notification; weak, and re-validated against the live window at repair
    /// time, so a torn-down view can never be revived by the repair.
    private(set) weak var lastKeyboardOwner: NSView?

    /// Held for their lifetime, which is the process's — there is no teardown edge for a duel.
    private var keyWindowObservers: [NSObjectProtocol] = []

    private init() {
        // The responder overrides keep `CodeSidebarKeyboardState` honest WITHIN one window, but a
        // key-window change moves the keyboard without any responder transition (the webview stays
        // its window's first responder while a satellite pane window is key). Re-derive on both
        // edges so the flag always answers for the window that actually receives keys — but only
        // while SOME window of ours is key: app deactivation is not an intra-app keyboard move
        // (`CodeSidebarFocusPolicy.keyboardOwnership` — the ⌘⇥ round-trip fix).
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    CodeSidebarKeyboardState.shared.set(CodeSidebarFocusPolicy.keyboardOwnership(
                        previous: CodeSidebarKeyboardState.shared.ownsKeyboard,
                        hasKeyWindow: (NSApp as NSApplication?)?.keyWindow != nil,
                        webViewHoldsFirstResponder: Self.shared.holdsFirstResponder(),
                    ))
                }
            })
        }
        // The rightful-owner tracker behind the orphan repair. `didUpdate` fires on every window
        // update pass — the guards are cheap and the write is a weak-pointer store.
        keyWindowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main,
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                Self.shared.noteWindowUpdate(window)
            }
        })
        // The last line of the init on purpose: the pool must never see a half-built duel, and
        // nothing above touches the pool.
        CodeSidebarWebViewPool.shared.keyboard = self
    }
}

// MARK: - The pool's side of the seam

extension MacCodeSidebarKeyboard: CodeSidebarKeyboard {
    /// A project whose tab is still owed the keyboard must survive eviction, or the debt dies with
    /// the page and the user lands in a terminal they never aimed at.
    var projectRootsOwedKeyboard: Set<String> { Set(sidebarFocusMemory.values) }

    /// The Mac's half of a remount. When the tab being remounted into is a PANEL tab reading THIS
    /// project (``CodeSidebarFocusPolicy/shouldRestoreOnRemount(memory:activeTab:projectRoot:)``),
    /// the keyboard is handed back; otherwise the page is told it does not have the keyboard, because
    /// the workbench autofocuses its editor on the remount and would blink a caret beside the
    /// terminal's.
    func noteRemount(projectRoot: String) {
        guard CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: sidebarFocusMemory, activeTab: activeTabID(), projectRoot: projectRoot,
        ) else {
            CodeSidebarWebViewPool.shared.page(for: projectRoot)?.syncFocusTruth()
            return
        }
        claimWhenMounted(projectRoot: projectRoot)
    }

    /// A page took the keyboard (click or restore) — the tab it happened in is a PANEL tab from now
    /// on, reading this project's workbench.
    func noteKeyboardClaimed(projectRoot: String) {
        guard let tab = activeTabID() else { return }
        sidebarFocusMemory[tab] = projectRoot
    }

    /// The one-hop-deferred verdict on a page resign —
    /// ``CodeSidebarFocusPolicy/memoryAfterResign(_:resigningTab:stillInWindow:)`` decides whether
    /// the tab stops being a panel tab.
    ///
    /// The TAB is read here, synchronously, and the WINDOW test is read in the hop, and the split is
    /// load-bearing in both directions. A click on another tab's row moves the keyboard on mouse-down
    /// and switches the tab after, so reading the tab late would name the tab being arrived at rather
    /// than the one being left; and a warm-swap unmount has not finished unparenting yet when the
    /// resign fires, so reading the window early would call every swap a user gesture.
    func noteResign(of page: CodeSidebarPooledPage) {
        let resigningTab = activeTabID()
        DispatchQueue.main.async { [weak page] in
            MainActor.assumeIsolated {
                guard let page else { return }
                let keyboard = Self.shared
                keyboard.sidebarFocusMemory = CodeSidebarFocusPolicy.memoryAfterResign(
                    keyboard.sidebarFocusMemory,
                    resigningTab: resigningTab,
                    stillInWindow: page.window != nil,
                )
                // The page keeps rendering a caret unless it is TOLD the keyboard left.
                page.syncFocusTruth()
            }
        }
    }

    /// The page refused a focus pull mid-`makeFirstResponder`: AppKit had the current responder
    /// RESIGN before asking, so the refusal strands first responder on the WINDOW and every key is
    /// dead until the next click. Hand the keyboard straight back to the responder it was lifted
    /// from, one hop later so the surrounding `makeFirstResponder` finishes first.
    ///
    /// The `firstResponder === window` guard keeps the repair out of every legitimate move (a real
    /// taker means no orphan), and the owner is re-validated against the SAME window, so a remembered
    /// view that has since moved or died can never be handed anything.
    func repairOrphanedFocus(after page: CodeSidebarPooledPage) {
        DispatchQueue.main.async { [weak page] in
            MainActor.assumeIsolated {
                guard let window = page?.window, window.firstResponder === window,
                      let owner = Self.shared.lastKeyboardOwner, owner.window === window
                else { return }
                window.makeFirstResponder(owner)
            }
        }
    }
}

// MARK: - The workspace's side of the seam

extension MacCodeSidebarKeyboard {
    /// The workspace switched tabs — honour the arriving tab's focus region
    /// (``CodeSidebarFocusPolicy/tabSwitchFocus(incoming:memory:editorHoldsKeyboard:)``).
    ///
    /// `liveTabs` prunes the memory of tabs that have since closed: nothing here can see the store,
    /// and a `TabID` nobody can reach again would otherwise sit in the map for the session's life.
    func noteActiveTabChanged(to tab: TabID?, liveTabs: Set<TabID>) {
        sidebarFocusMemory = sidebarFocusMemory.filter { liveTabs.contains($0.key) }
        switch CodeSidebarFocusPolicy.tabSwitchFocus(
            incoming: tab, memory: sidebarFocusMemory, editorHoldsKeyboard: holdsFirstResponder(),
        ) {
        case let .claimEditor(projectRoot):
            claimWhenMounted(projectRoot: projectRoot)
        case .yieldToWorkspace:
            yieldKeyboardToWorkspace()
        case .leaveAlone:
            break
        }
    }

    /// The workspace moved its focus to a PANE inside the tab already on screen (a split's new leaf,
    /// ⌘-arrow, a rail row, a palette landing) — the tab reads its terminal again, and the keyboard
    /// has to follow.
    ///
    /// Without this the move was silently swallowed whenever the panel held the keyboard: the pane
    /// tree gates every pane's rendered focus on ``CodeSidebarKeyboardState/ownsKeyboard`` (so the
    /// terminal never re-lights and never claims first responder), and no workspace path asks the
    /// page to resign. A fresh split then arrived with no keyboard, no focus corner and a hollow
    /// cursor, and only a CLICK into it — which forces first responder the hard way — put things
    /// right, which is what made it read as intermittent (user-reported 2026-08-10).
    func noteWorkspacePaneFocused(tab: TabID?) {
        if let tab { sidebarFocusMemory.removeValue(forKey: tab) }
        guard holdsFirstResponder() else { return }
        yieldKeyboardToWorkspace()
    }

    /// Actuates ``CodeSidebarFocusPolicy/focusToggle(webViewHoldsKeyboard:hasMountedWebView:panelCollapsed:)``.
    /// `reveal` shows the panel when it is collapsed; the claim is then deferred until the page has
    /// actually been mounted by the resulting SwiftUI pass (two hops, the same settling the warm-swap
    /// restore uses). Returns nothing — every outcome is best-effort chrome.
    func toggleFocus(panelCollapsed: Bool, reveal: @MainActor () -> Void) {
        switch CodeSidebarFocusPolicy.focusToggle(
            webViewHoldsKeyboard: holdsFirstResponder(),
            hasMountedWebView: CodeSidebarWebViewPool.shared.mountedPage() != nil,
            panelCollapsed: panelCollapsed,
        ) {
        case .handBack:
            guard let owner = lastKeyboardOwner, let window = owner.window else { return }
            window.makeFirstResponder(owner)
        case .claimEditor:
            CodeSidebarWebViewPool.shared.mountedPage()?.claimKeyboardForRestore()
        case .revealThenClaim:
            reveal()
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        CodeSidebarWebViewPool.shared.mountedPage()?.claimKeyboardForRestore()
                    }
                }
            }
        case .none:
            break
        }
    }

    /// Whether the key window's first responder sits inside ANY pooled page — the
    /// `WorkspaceKeyDispatcher`'s webview-yield predicate (while true, the embedded VS Code owns the
    /// keyboard). Checked per keystroke against the live responder.
    func holdsFirstResponder() -> Bool {
        // `NSApp` is an IMPLICITLY-unwrapped global that is genuinely nil in a headless test process —
        // touch it optionally or the default dispatcher predicate traps every dispatcher unit test.
        guard let app = NSApp as NSApplication?,
              let responder = app.keyWindow?.firstResponder as? NSView
        else { return false }
        return isInsidePooledWebView(responder)
    }
}

// MARK: - Actuation

extension MacCodeSidebarKeyboard {
    /// Hand the keyboard to `projectRoot`'s workbench once the pass that asked for it has mounted it
    /// — deferred TWO runloop hops so it lands after the focused terminal's own deferred one-hop
    /// claim (the transition claim scheduled by the same render), settling the race in the editor's
    /// favour exactly once. Re-checked on arrival against BOTH the live memory and what is actually
    /// on screen, so a tab switch the user has already moved on from claims nothing.
    private func claimWhenMounted(projectRoot: String) {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let keyboard = Self.shared
                    guard let page = CodeSidebarWebViewPool.shared.mountedPage(),
                          page.projectRoot == projectRoot,
                          CodeSidebarFocusPolicy.shouldRestoreOnRemount(
                              memory: keyboard.sidebarFocusMemory,
                              activeTab: keyboard.activeTabID(),
                              projectRoot: projectRoot,
                          )
                    else { return }
                    page.claimKeyboardForRestore()
                }
            }
        }
    }

    /// Give the keyboard back to the workspace: drop the ownership flag, which re-lights the active
    /// tab's focused pane and — through the terminal's focus-gated responder claim — has it take
    /// first responder, which is what actually resigns the page.
    ///
    /// The flag leads the responder move by a hop on purpose (nothing here can reach into the pane
    /// tree to name a view), so it is re-checked afterwards: when nothing claimed — the tab's focused
    /// pane is a video surface, or there is no pane at all — the editor really does still have the
    /// keyboard and the flag must say so, or the workspace would draw a live cursor for a pane the
    /// keys are not going to.
    private func yieldKeyboardToWorkspace() {
        CodeSidebarKeyboardState.shared.set(false)
        // Long enough for the SwiftUI pass and the pane's own deferred `makeFirstResponder` — this
        // is a repair, and being late costs nothing while being early would undo the hand-back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                guard Self.shared.holdsFirstResponder() else { return }
                CodeSidebarKeyboardState.shared.set(true)
            }
        }
    }

    /// Remember the current first responder as the keyboard's rightful owner when
    /// ``CodeSidebarFocusPolicy/isTrackableKeyboardOwner(responderIsView:responderIsWindow:responderInsidePooledWebView:)``
    /// says it qualifies (a real view, not the window's orphan stand-in, not a pooled page).
    private func noteWindowUpdate(_ window: NSWindow?) {
        guard let window, window.isKeyWindow else { return }
        let responder = window.firstResponder
        let view = responder as? NSView
        guard CodeSidebarFocusPolicy.isTrackableKeyboardOwner(
            responderIsView: view != nil,
            responderIsWindow: responder === window,
            responderInsidePooledWebView: view.map(isInsidePooledWebView) ?? false,
        ), let view else { return }
        lastKeyboardOwner = view
    }

    /// Whether `view` is (inside) any pooled page — WebKit's actual first responder is an internal
    /// content subview, hence the descendant walk rather than an identity check.
    private func isInsidePooledWebView(_ view: NSView) -> Bool {
        CodeSidebarWebViewPool.shared.pooledWebViews().contains {
            view === $0 || view.isDescendant(of: $0)
        }
    }
}

// MARK: - The pool's Mac-facing questions

/// The five things the Mac's shell asks the pool about the keyboard, forwarded to the duel that
/// actually knows. They stay spelled on the POOL rather than on ``MacCodeSidebarKeyboard`` because
/// the pool is the object every caller already holds — the dispatcher's yield predicate, the root's
/// focus-region wiring, the ⌥⌘R chord — and moving the state should not move every call site.
///
/// ⚠️ SETTING `activeTabID` IS ALSO WHAT BRINGS THE DUEL UP, and that is a design point rather than a
/// side effect. ``MacCodeSidebarKeyboard/shared`` is lazy, the app composes this one line at launch
/// (`SlopDeskMacApp`), and it is the EARLIEST Mac-side touch of the pool there is — which matters,
/// because the window observers have to be armed before the first key-window change or
/// `CodeSidebarKeyboardState` starts answering for the wrong window. Every other entry point below
/// arms it too, so no single call site is load-bearing; this one is merely first.
///
/// `@MainActor` is spelled out rather than inherited: the pool carries it, but this is the first
/// extension of a `SlopDeskClientUI` type from this target, and an isolation that is stated is one
/// nobody has to re-derive from another module's declaration.
@MainActor
package extension CodeSidebarWebViewPool {
    /// The workspace's active tab, wired once by the app layer — see
    /// ``MacCodeSidebarKeyboard/activeTabID``.
    static var activeTabID: @MainActor () -> TabID? {
        get { MacCodeSidebarKeyboard.shared.activeTabID }
        set { MacCodeSidebarKeyboard.shared.activeTabID = newValue }
    }

    /// `true` while the embedded workbench owns the keyboard — the `WorkspaceKeyDispatcher`'s
    /// per-keystroke yield predicate. See ``MacCodeSidebarKeyboard/holdsFirstResponder()``.
    func holdsFirstResponder() -> Bool {
        MacCodeSidebarKeyboard.shared.holdsFirstResponder()
    }

    /// The workspace switched tabs — see ``MacCodeSidebarKeyboard/noteActiveTabChanged(to:liveTabs:)``.
    func noteActiveTabChanged(to tab: TabID?, liveTabs: Set<TabID>) {
        MacCodeSidebarKeyboard.shared.noteActiveTabChanged(to: tab, liveTabs: liveTabs)
    }

    /// The workspace named a PANE inside the tab already on screen — see
    /// ``MacCodeSidebarKeyboard/noteWorkspacePaneFocused(tab:)``.
    func noteWorkspacePaneFocused(tab: TabID?) {
        MacCodeSidebarKeyboard.shared.noteWorkspacePaneFocused(tab: tab)
    }

    /// ⌥⌘R, both directions — see ``MacCodeSidebarKeyboard/toggleFocus(panelCollapsed:reveal:)``.
    func toggleKeyboardFocus(panelCollapsed: Bool, reveal: @MainActor () -> Void) {
        MacCodeSidebarKeyboard.shared.toggleFocus(panelCollapsed: panelCollapsed, reveal: reveal)
    }
}
