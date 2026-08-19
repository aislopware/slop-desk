// CodeSidebarWebView — mounting the pooled workbench, and (on the Mac) the webview subclass that
// holds the responder seam.
//
// The MOUNT is a clipping container rather than the webview itself, on both platforms, and for a
// reason that has nothing to do with either: SwiftUI destroys a representable's product on
// structural identity changes, and the whole point of ``CodeSidebarWebViewPool`` is that the
// workbench outlives the column's re-renders and project switches. The container is disposable; what
// it holds is not.
//
// The SUBCLASS is macOS-only, and it is the entire reason the two halves differ. On the Mac the
// embedded VS Code and the focused terminal are two first responders duelling over one window, so
// every claim goes through ``CodeSidebarFocusPolicy`` at the responder seam and every reserved chord
// is refused there. iOS has no such duel — no app-level event monitor, no menu bar — so the phone
// mounts a plain `WKWebView` and there is nothing to guard.
//
// WHAT THE SUBCLASS OWNS IS THE SEAM, NEVER THE BOOKKEEPING. The three moments the responder chain
// hands it — a claim, a resign, a refusal that strands the keyboard — are reported to
// ``CodeSidebarKeyboard``, which is `MacCodeSidebarKeyboard` one target up (docs/56 §3: the duel is
// AppKit window machinery and belongs in the Mac's own target). It is reached through the pool
// because the pool is what both of them can see; this file names no target above it.

import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import WebKit

#if os(macOS)
import AppKit

/// The pooled webview class: applies ``CodeSidebarFocusPolicy`` at the responder seam, so the
/// embedded VS Code can never STEAL the keyboard — it can only be handed it by a click (or the
/// pool's own remount RESTORE, which is app-directed, never page-directed).
final class CodeSidebarWKWebView: WKWebView, CodeSidebarKeyboardPage {
    /// The pool key this webview serves — the focus-restore bookkeeping is keyed by it.
    let projectRoot: String

    /// Armed (scoped) by ``claimKeyboardForRestore()`` — the ONE non-click path
    /// `becomeFirstResponder` honors. App-directed: only the pool's remount restore sets it; a
    /// page-level `focus()` can never reach it.
    private var programmaticRestoreArmed = false

    init(projectRoot: String, frame: CGRect, configuration: WKWebViewConfiguration) {
        self.projectRoot = projectRoot
        super.init(frame: frame, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The same policy for every AppKit path that ASKS before moving the keyboard — the key-view
    /// loop, initial-first-responder assignment, window restoration. `NSWindow.makeFirstResponder`
    /// itself never consults this (it resigns the current responder first and asks
    /// `becomeFirstResponder` second — measured, not assumed; see the orphan repair there), so
    /// this cannot be the only gate, but the asking paths should get the honest answer too.
    override var acceptsFirstResponder: Bool {
        guard let app = NSApp as NSApplication? else { return false }
        return programmaticRestoreArmed
            || CodeSidebarFocusPolicy.shouldAcceptFocus(
                eventType: app.currentEvent?.type,
                clickWasInsideWebView: app.currentEvent.map(eventLandsInside) ?? false,
            )
    }

    override func becomeFirstResponder() -> Bool {
        // `NSApp` is nil in a headless test process — optional access, never the implicit unwrap.
        guard let app = NSApp as NSApplication? else { return false }
        guard programmaticRestoreArmed
            || CodeSidebarFocusPolicy.shouldAcceptFocus(
                eventType: app.currentEvent?.type,
                clickWasInsideWebView: app.currentEvent.map(eventLandsInside) ?? false,
            )
        else {
            // The refusal arrives MID-`makeFirstResponder`: the page pulled native focus
            // (`WebPageProxy::MakeFirstResponder` — the workbench does it while booting), and
            // AppKit had the current responder RESIGN before asking here, so returning false
            // strands first responder on the window — every key dead until the next click
            // (user-reported 2026-08-04: opening the app with the panel expanded showed cursors
            // blinking in both the terminal and the editor, with the keyboard in neither). Hand
            // the keyboard straight back to the responder it was lifted from. The duel owns both
            // halves of that repair — the remembered owner and the one-hop defer that lets the
            // surrounding `makeFirstResponder` finish first — because both are about the WINDOW,
            // which is the Mac's subject and not this file's.
            CodeSidebarWebViewPool.shared.keyboard?.repairOrphanedFocus(after: self)
            return false
        }
        let became = super.becomeFirstResponder()
        if became {
            CodeSidebarKeyboardState.shared.set(true)
            CodeSidebarWebViewPool.shared.keyboard?.noteKeyboardClaimed(projectRoot: projectRoot)
        }
        return became
    }

    /// The pool's remount hand-back (``CodeSidebarFocusPolicy/shouldRestoreOnRemount(claimedTab:activeTab:)``).
    func claimKeyboardForRestore() {
        guard let window else { return }
        programmaticRestoreArmed = true
        defer { programmaticRestoreArmed = false }
        window.makeFirstResponder(self)
    }

    /// Anything that takes the keyboard back (a terminal click, an overlay, the panel collapsing
    /// and unparenting this view) resigns through here — the observable flag tracks it so the
    /// workspace's focused pane re-lights the moment the keyboard actually returns. The resign's
    /// CAUSE is classified one runloop later, once the swap (if any) has finished unparenting:
    /// off-window ⇒ a warm-swap unmount (the tab stays a panel tab), still-in-window ⇒ a genuine
    /// keyboard move by gesture (that tab's region is the terminal again — see
    /// ``CodeSidebarFocusPolicy/memoryAfterResign(_:resigningTab:stillInWindow:)``).
    ///
    /// The tab is read NOW, not in the deferred hop: a click on another tab's row moves the keyboard
    /// on mouse-down and switches the tab after, so the hop would name the wrong tab. That is why
    /// ``CodeSidebarKeyboard/noteResign(of:)`` is called synchronously and defers on its own side —
    /// the deadline belongs to whoever reads the tab, and this file no longer knows what a tab is.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            CodeSidebarKeyboardState.shared.set(false)
            CodeSidebarWebViewPool.shared.keyboard?.noteResign(of: self)
        }
        return resigned
    }

    /// Make the PAGE agree that it does not have the keyboard.
    ///
    /// The workbench decides where its caret blinks from its own DOM focus, and it re-focuses the
    /// editor on its own schedule — a remount, a layout change, an editor opening. Those pulls are
    /// refused at the native seam (only a click hands the panel the keyboard), but refusing the
    /// NATIVE claim does not undo the PAGE's: `document.activeElement` is the editor, VS Code has
    /// seen its `focus` event, and it blinks a caret next to the terminal's — two live cursors, and
    /// the keys going to the terminal (user-reported 2026-08-10). WebKit is no help here: a view
    /// that loses first responder by being UNPARENTED never delivers the page its blur.
    ///
    /// So the correction is driven from this side too: replay the missing blur through the page's
    /// own focus-truth hook, which no-ops the moment `document.hasFocus()` is honestly true. The
    /// hook self-installs at document start (``CodeSidebarPageDressing/focusTruthScript()``); the
    /// `&&` guard makes this inert on a page that has not run it yet.
    func syncFocusTruth() {
        evaluateJavaScript(CodeSidebarPageDressing.focusTruthSyncCall)
    }

    /// Whether `event`'s location falls inside THIS webview — same window, point within bounds.
    private func eventLandsInside(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Refuse the app-reserved chords (``CodeSidebarFocusPolicy/isReservedAppChord(modifiers:key:)``)
    /// so they continue up to the main menu — WebKit's own implementation forwards ⌘-chords to the
    /// page and returns `true`, which is how a focused editor swallowed ⌘Q whole. The standard
    /// clipboard chords are CLAIMED here instead and driven through WebKit's native editing actions
    /// (``CodeSidebarFocusPolicy/editingCommand(modifiers:key:)`` — the Edit-menu contract a browser
    /// gives VS Code web, which this app's shortcut-less menus never provided): the DOM
    /// copy/paste/cut runs against whatever has focus in the page, and the clipboard bridge sees
    /// the copies. First-responder-gated like the terminal's claim, so a focused find bar / native
    /// field never loses its own ⌘C/⌘V to the panel. Nothing else may be added to that set — the
    /// workbench binds the rest itself and a claim here silently outranks it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased()
        if CodeSidebarFocusPolicy.isReservedAppChord(modifiers: event.modifierFlags, key: key) {
            return false
        }
        if event.type == .keyDown, window?.firstResponder === self,
           let command = CodeSidebarFocusPolicy.editingCommand(modifiers: event.modifierFlags, key: key)
        {
            // WKWebView implements the standard editing IBActions (they back the Edit menu in every
            // WebKit browser) without declaring them publicly — selector dispatch is the seam. The
            // `responds` guard keeps a hypothetical WebKit that dropped one on the `super` path
            // instead of silently eating the chord.
            let action: Selector =
                switch command {
                case .copy: #selector(NSText.copy(_:))
                case .paste: #selector(NSText.paste(_:))
                case .cut: #selector(NSText.cut(_:))
                }
            if responds(to: action) {
                perform(action, with: nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The webview's mount that DECAPITATES the web title bar. The workbench force-shows its title
/// bar while the activity bar sits at "top" (seed v12 — the band must host the relocated
/// accounts/manage actions), and the grid positions every part with inline absolute geometry, so
/// a CSS `display: none` leaves a dead gap instead of reflowing. The clip is the clean cut: the
/// webview is laid out TALLER than the container by exactly the title-bar height and shifted up,
/// so the band renders above the clip line — the workbench still believes in it, the user never
/// sees it (user-directed 2026-08-03). Hit-testing is bounds-guarded: without it the overhang
/// would sit under the panel's strip and eat its clicks.
final class CodeSidebarClippedContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// Mounts the pooled webview for one project inside a clipping container view. A container (not
/// the webview itself) because the pooled NSView must survive this representable's teardown —
/// SwiftUI destroys `makeNSView`'s product on structural identity changes, and the whole point of
/// the pool is that the workbench outlives the column's re-renders and project switches.
struct CodeSidebarWebView: NSViewRepresentable {
    let projectRoot: String
    let url: URL

    /// The web workbench title bar's laid-out height at zoom 1 (30px on Code 1.131). The webview
    /// overhangs the container by this much; see ``CodeSidebarClippedContainer``. Coupled to seed
    /// v12's `activityBar.location: "top"` — a seed that stops forcing the title bar should retire
    /// this to 0.
    ///
    /// It is NOT a CSS constant to grep: the workbench grid positions its parts with inline
    /// geometry, so the honest measurement is the laid-out box —
    /// `document.querySelector('#workbench\\.parts\\.titlebar').getBoundingClientRect().height`
    /// against a real workbench. It went 35 → 30 across Code 1.112 → 1.131; re-measure on every
    /// code-server bump, because being wrong here clips the editor tab row instead.
    static let clippedTitleBarHeight: CGFloat = 30

    private var topOverhang: CGFloat { Self.clippedTitleBarHeight }

    func makeNSView(context _: Context) -> NSView {
        let container = CodeSidebarClippedContainer()
        container.wantsLayer = true
        container.clipsToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = CodeSidebarWebViewPool.shared.webView(for: projectRoot, url: url)
        // Re-apply the theme backdrop on every update: the pooled webview outlives a theme
        // switch, and the creation-time snapshot would otherwise flash the OLD theme's tone on
        // scroll bounce (an appearance flip re-runs this via the colorScheme environment change).
        webView.underPageBackgroundColor = SlateNativeColor(slateHex: Slate.theme.groundHexValue)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor, constant: -topOverhang),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // A (re)mount may owe the keyboard back — the warm-swap focus restore (a first-ever mount
        // has no restore armed; the call is then a no-op).
        CodeSidebarWebViewPool.shared.noteRemount(projectRoot: projectRoot)
    }
}

#elseif os(iOS)
import UIKit

/// The webview's mount that DECAPITATES the web title bar — the phone's half of
/// ``CodeSidebarClippedContainer``. Same clip, same reason: the workbench force-shows its title bar
/// while the activity bar sits at "top" (seed v12), and the grid positions every part with inline
/// absolute geometry, so a CSS `display: none` leaves a dead gap instead of reflowing. The webview is
/// laid out TALLER than the container by exactly the title-bar height and shifted up.
///
/// No hit-test override here. The Mac's exists because the overhang would otherwise sit under the
/// panel's AppKit strip and eat its clicks; `clipsToBounds` already stops UIKit delivering touches
/// outside the container's bounds.
final class CodeSidebarClippedContainer: UIView {}

/// Mounts the pooled webview for one project inside a clipping container view — see the header for
/// why the container and not the webview is what SwiftUI owns.
struct CodeSidebarWebView: UIViewRepresentable {
    let projectRoot: String
    let url: URL

    /// The web workbench title bar's laid-out height at zoom 1 — one number, measured once, shared
    /// with the AppKit half's ``CodeSidebarWebView/clippedTitleBarHeight``. It is NOT a CSS constant
    /// to grep: the workbench grid positions its parts with inline geometry, so the honest
    /// measurement is the laid-out box. Re-measure on every code-server bump, because being wrong
    /// here clips the editor tab row instead.
    static let clippedTitleBarHeight: CGFloat = 30

    private var topOverhang: CGFloat { Self.clippedTitleBarHeight }

    func makeUIView(context _: Context) -> UIView {
        let container = CodeSidebarClippedContainer()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context _: Context) {
        let webView = CodeSidebarWebViewPool.shared.webView(for: projectRoot, url: url)
        // Re-apply the theme backdrop on every update, for the reason the AppKit half records: the
        // pooled webview outlives a theme switch, and the creation-time snapshot would otherwise
        // flash the OLD theme's tone on scroll bounce.
        webView.underPageBackgroundColor = SlateNativeColor(slateHex: Slate.theme.groundHexValue)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor, constant: -topOverhang),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        CodeSidebarWebViewPool.shared.noteRemount(projectRoot: projectRoot)
    }
}
#endif
