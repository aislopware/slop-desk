// CodeSidebarPage — minting one pooled workbench page, and (on the Mac) the webview subclass that
// holds the responder seam.
//
// A PAGE IS NOT A VIEW, which is why this file is here and not one floor up. `WKWebView` IS the
// platform's view class, so a page has AppKit and UIKit in it by construction — but nothing in this
// file lays anything out, reads a design token or names a `some View`. What the UI target keeps is
// the MOUNT: a clipping container and one representable per half, which is where SwiftUI's structural
// identity and the pool's warm pages meet (docs/56 increment 45).
//
// The SUBCLASS is macOS-only, and it is the entire reason the two halves differ. On the Mac the
// embedded VS Code and the focused terminal are two first responders duelling over one window, so
// every claim goes through ``CodeSidebarFocusPolicy`` at the responder seam and every reserved chord
// is refused there. iOS has no such duel — no app-level event monitor, no menu bar — so the phone
// mints a plain `WKWebView` and there is nothing to guard.
//
// WHAT THE SUBCLASS OWNS IS THE SEAM, NEVER THE BOOKKEEPING. The three moments the responder chain
// hands it — a claim, a resign, a refusal that strands the keyboard — are reported to
// ``CodeSidebarKeyboard``, which is `MacCodeSidebarKeyboard` two targets up (docs/56 §3: the duel is
// AppKit window machinery and belongs in the Mac's own target). It is reached through the pool
// because the pool is what both of them can see; this file names no target above it.
//
// THE MINT IS HERE AND THE POOL IS BESIDE IT, WITH THE GATE ON THIS SIDE OF THE WALL. Building a page
// is two decisions with two spellings and one meaning, while ``CodeSidebarWebViewPool``'s subject is
// projects and their warm pages — a law with no platform in it at all. A `#if` in the middle of that
// law is a file wearing two coats (docs/56 §3), so the pool builds the CONFIGURATION (the faces, the
// five user scripts, the clipboard bridge — every one of them platform-blind) and asks for a dressed
// page whose class it never learns.
//
// The two decisions are stated ONCE, here, because each half below only spells them:
//   • THE CLASS. The Mac's page is a SUBCLASS because it has the responder seam above to guard; the
//     phone's is a plain `WKWebView` because there is no second first responder to duel with.
//   • THE BASE CANVAS. WebKit's own is WHITE until the page's first paint — with a multi-second
//     workbench boot that is a visible flash between the dark chrome and the dark editor. On the Mac
//     there is no public API for it and the long-standing KVC key makes the canvas transparent;
//     UIKit exposes the same thing honestly, through the view's own opacity. Chrome POLARITY rides
//     along with it, because the two are one appearance: the workbench is a sunken panel on the
//     ground, not an island (ONE ISLAND law 1), so it wears the chrome's LIGHT appearance and the
//     seeded colour customizations paint it in the ground tone.
//
// THE GROUND TONE IS NOT MINTED HERE, and that is what let this file descend. It used to be — one
// `underPageBackgroundColor` from `Slate.theme` at creation. ⚠️ THE REASON GIVEN FOR THAT BEING A
// BLOCKER WAS FALSE: this header said "`SlopDeskSlate` DEPENDS on this target and an import back up
// is a cycle", and it is the reverse — `Package.swift:475` puts `SlopDeskSlate` inside
// `SlopDeskClientCore`'s dependencies, `Package.swift:537-549` shows Slate depending on nothing here,
// and `Pane/GuiLeafChromeLayout.swift` reads `Slate.theme`'s neighbour `Slate.Metric` from this
// target today. So the descent was never gated on a cycle. What it WAS gated on is the real
// argument and stands on its own: both mounts already re-apply that colour on the very update that
// creates the page, and
// they must, because a pooled page outlives a theme switch and a creation-time snapshot would flash
// the old tone on a scroll bounce. One writer, in the target that has the tokens.

import WebKit

/// Builds one project's pooled page from the configuration ``CodeSidebarWebViewPool`` assembled —
/// the only part of a warm page that is not one law on both platforms. Each half below declares its
/// own `page(projectRoot:configuration:)`; what the two of them share is stated here, once.
@MainActor
enum CodeSidebarPageMint {
    /// The tail of every mint, OUTSIDE the file's gate because it is one spelling for both platforms
    /// and a decision written twice is a decision that drifts. Nothing above it reads the line back,
    /// so it runs after the per-platform dressing rather than inside it.
    private static func finish(_ page: WKWebView) -> WKWebView {
        // Right-click → Inspect Element on the embedded workbench (Safari Web Inspector) — the only
        // window into a misbehaving code-server page.
        page.isInspectable = true
        return page
    }
}

#if os(macOS)
import AppKit

extension CodeSidebarPageMint {
    /// The Mac's spelling of the header's two decisions: the responder-seam subclass below, and the
    /// KVC key that is the only reach WebKit gives an embedder for its white base canvas — with the
    /// chrome's light appearance, which is the same decision seen from the front. `configuration`
    /// arrives FINISHED — a configuration is copied at construction, so a handler or user script
    /// added after this call reaches no page at all.
    static func page(projectRoot: String, configuration: WKWebViewConfiguration) -> WKWebView {
        let webView: WKWebView = CodeSidebarWKWebView(
            projectRoot: projectRoot, frame: .zero, configuration: configuration,
        )
        webView.appearance = NSAppearance(named: .aqua)
        webView.setValue(false, forKey: "drawsBackground")
        return finish(webView)
    }
}

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

#elseif os(iOS)
import UIKit

extension CodeSidebarPageMint {
    /// The phone's spelling of the header's two decisions. A PLAIN `WKWebView` — there is no
    /// responder duel here to need a seam — and the base canvas is killed through the view's own
    /// opacity, which is the honest API the Mac has to reach for a KVC key to get. Both the view AND
    /// its scroll view: UIKit hosts the page inside the scroll view, so its own background would
    /// paint straight back through the transparency `isOpaque` just made. The project root is
    /// DROPPED here — only the Mac's subclass carries one, and the label stays so the pool's call
    /// site has no gate in it either. `configuration` arrives FINISHED, for the reason the Mac's
    /// half records.
    static func page(projectRoot _: String, configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.overrideUserInterfaceStyle = .light
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return finish(webView)
    }
}
#endif
