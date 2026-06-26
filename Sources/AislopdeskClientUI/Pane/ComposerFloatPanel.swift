// ComposerFloatPanel — the macOS "float panel" mode of the otty Composer (E12 / WI-6). Clicking the float
// button (② in `composer.png`) detaches the Composer into a Spotlight-style floating window that stays on
// top of every other window WITHOUT activating the app or claiming the menu bar (`composer-float.png`).
//
// The panel is a `.nonactivatingPanel` at `.floating` level with `becomesKeyOnlyIfNeeded` — the exact Cocoa
// recipe for "floats above other apps, takes keystrokes, never activates Aislopdesk" (spec
// `agents__composer.md` → "Mappings that are non-trivial"). It hosts an `NSHostingView` over the SAME durable
// ``ComposerModel`` as the in-pane mount, so `⌘↩` still injects into the ORIGIN pane's PTY; sending or closing
// docks it back (``ComposerModel/sendDraft()`` / ``cancel()`` clear ``ComposerModel/isFloating``, which drives
// `floatingComposer` to `nil` and closes the panel).
//
// Title: "Aislopdesk Composer — Claude Code" when the origin pane hosts an agent (`claudeStatus != .none`),
// else "Aislopdesk Composer" — no agent-name guessing (E12-carryovers).
//
// This is `#if os(macOS)`: it NEVER compiles into the iOS slice (iOS uses ``ComposerSheet``). It is compiled
// + code-reviewed only — an `NSPanel` needs a window server, so no test instantiates it (cf. the hang-safety
// rule; the testable composer logic is the headless ``ComposerModel`` / ``WorkspaceStore`` resolvers).

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit
import SwiftUI

// MARK: - The non-activating floating panel

/// The Spotlight-style floating `NSPanel` that hosts the detached Composer. `.nonactivatingPanel` +
/// `becomesKeyOnlyIfNeeded` + `level = .floating` is the otty "stays on top without activating the app"
/// behaviour; `canBecomeKey` is overridden so the hosted text field can still take keystrokes.
final class ComposerFloatPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
            // `.titled` + the three traffic-light buttons (`composer-float.png`); `.nonactivatingPanel` keeps
            // the owning app inactive while the panel floats + types.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        self.contentView = contentView
        isFloatingPanel = true
        level = .floating
        // Take keyboard focus only when the field actually needs it — so showing the panel does not steal
        // key from the frontmost app's window until the user (or the auto-focus) drives the field.
        becomesKeyOnlyIfNeeded = true
        // Stay up when the app deactivates (the user is reading docs in the browser, composing here).
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        // A compact Spotlight-ish footprint (the `composer-float.png` proportions — wider than tall).
        setContentSize(NSSize(width: 380, height: 180))
        minSize = NSSize(width: 320, height: 140)
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    /// A `.nonactivatingPanel` reports `canBecomeKey == false` by default — override so the hosted
    /// ``ComposerBar`` text field can still receive keystrokes (the panel becomes key WITHOUT activating the
    /// app, exactly the otty float behaviour).
    override var canBecomeKey: Bool { true }
}

// MARK: - The float content (the SAME composer, hosted in the panel)

/// The SwiftUI content hosted inside ``ComposerFloatPanel``: the Prompt-Queue chip strip + the
/// ``ComposerBar``, driving the SAME durable ``ComposerModel`` as the in-pane mount. Owns its own per-mount
/// ``ComposerLeafChrome`` (`@State`) — the float is OUTSIDE the pane subtree, so it can't borrow the leaf's.
/// The panel's native title bar carries the title, so there is no in-content title row here.
struct ComposerFloatContent: View {
    let composer: ComposerModel
    /// The growing field's line budget (the panel scrolls internally past it).
    var maxLines: Int = 8

    /// Per-mount chrome (queue-input mode is always the normal Composer here; the float button is not a
    /// queue affordance). Bumped once on appear so the field grabs focus when the panel shows.
    @State private var chrome = ComposerLeafChrome()

    var body: some View {
        VStack(spacing: 0) {
            PromptQueueStrip(composer: composer)
            ComposerBar(composer: composer, chrome: chrome, maxLines: maxLines)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NativePaneColor.terminalBackground)
        // Re-assert field focus each time the panel (re)appears for this content.
        .onAppear { chrome.focusToken &+= 1 }
    }
}

// MARK: - The SwiftUI driver (opens / closes the panel to match `store.floatingComposer`)

/// A zero-size `NSViewRepresentable` mounted as a `.background` of the workspace root. It reads
/// `store.floatingComposer` (passed in by the parent body so SwiftUI re-invokes `updateNSView` when the
/// `isFloating` toggle flips) and opens / closes the ``ComposerFloatPanel`` to match. The panel is a separate
/// window; this anchor view only ties the panel's lifetime to the scene and locates the host window for
/// initial placement.
struct ComposerFloatPanelHost: NSViewRepresentable {
    /// The float target resolved by the store (`nil` when no composer is floating). Computed in the parent
    /// body so reading `composer.isFloating` there registers SwiftUI observation that re-renders this view.
    let floating: ResolvedComposer?

    func makeNSView(context _: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(to: floating, anchor: nsView)
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Owns the live ``ComposerFloatPanel`` and drives it from the resolved float target. `@MainActor`
    /// because every AppKit window touch is main-thread.
    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: ComposerFloatPanel?
        /// The composer the panel currently hosts — so a user close (red button) can dock it back.
        private weak var hosted: ComposerModel?

        /// Open / update / close the panel to match `floating`.
        func sync(to floating: ResolvedComposer?, anchor: NSView) {
            guard let floating else { close()
                return
            }
            if panel == nil {
                open(floating, anchor: anchor)
            } else {
                // Already floating — keep the panel; just refresh the title (the agent may have started).
                panel?.title = Self.title(agentActive: floating.agentActive)
            }
            hosted = floating.composer
        }

        private func open(_ floating: ResolvedComposer, anchor: NSView) {
            let hosting = NSHostingView(rootView: ComposerFloatContent(composer: floating.composer))
            let panel = ComposerFloatPanel(contentView: hosting)
            panel.title = Self.title(agentActive: floating.agentActive)
            panel.delegate = self
            position(panel, near: anchor)
            // Key (so the field types) + front, WITHOUT activating the app (the `.nonactivatingPanel` mask).
            panel.makeKeyAndOrderFront(nil)
            self.panel = panel
        }

        /// Close the panel programmatically (the composer un-floated via dock-back / send / cancel). Clears
        /// the panel ref + detaches the delegate FIRST so the close does not re-enter `windowWillClose`.
        func close() {
            guard let panel else { return }
            self.panel = nil
            panel.delegate = nil
            panel.close()
        }

        /// The user clicked the panel's close button — dock the composer back into its pane (clear
        /// `isFloating`, which also drops `floatingComposer` to `nil` so a later `sync` is a no-op).
        func windowWillClose(_: Notification) {
            hosted?.isFloating = false
            panel = nil
        }

        /// Place the panel near the top-right of the host window (the `composer-float.png` position), or
        /// centred on screen when the host window is not yet resolvable.
        private func position(_ panel: ComposerFloatPanel, near anchor: NSView) {
            let size = panel.frame.size
            if let host = anchor.window {
                let hostFrame = host.frame
                let x = hostFrame.maxX - size.width - 24
                let y = hostFrame.maxY - size.height - 48
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                panel.center()
            }
        }

        /// "Aislopdesk Composer — Claude Code" when the origin pane hosts an agent, else "Aislopdesk
        /// Composer" (no agent-name guessing — E12-carryovers).
        private static func title(agentActive: Bool) -> String {
            agentActive ? "Aislopdesk Composer — Claude Code" : "Aislopdesk Composer"
        }
    }
}
#endif
