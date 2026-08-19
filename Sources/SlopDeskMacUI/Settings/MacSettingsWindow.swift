// MacSettingsWindow — the Settings window, in AppKit.
//
// docs/56 stage D: `SlopDeskMacUI` may not carry an `#if os(...)`, and Settings was the largest
// surface still standing in the way. What unblocked it was not a rewrite technique — it was
// increment 19's move of the page's SHAPE into `slopdesk_workspace::settings_layout`, where a
// platform gate is a `Platform` field rather than a preprocessor directive. This window asks that
// table for `Half.mac` and draws what comes back; the phone asks the same table for `Half.phone`.
// Neither carries a gate, and neither spells a group header, a row label or an option list.
//
// WHAT THIS FILE OWNS is the chrome the stock `Settings` scene used to supply for free, and each
// piece is here because AppKit gives it plainly where SwiftUI gave it with a caveat:
//
//   * The SPLIT is an `NSSplitViewController` with a real `.sidebar` behavior, so the navigator gets
//     the system's source-list material without a `.toolbar(removing: .sidebarToggle)` to stop the
//     framework adding a collapse control that would leave no way back to a section.
//   * ESC is `cancelOperation(_:)` — the responder chain's own path — rather than a window-scoped
//     `NSEvent` monitor standing in for behaviour a `Settings` scene lacked. WHAT Esc means is
//     unchanged and still Rust's (`SettingsEscapePolicy`); only the monitor that asked it is gone.
//   * The window is a SINGLETON held by the controller, so ⌘, raises the one that is open instead of
//     relying on a scene's identity.
//
// The window pins NO appearance. System Settings follows the OS, so this does too; the terminal
// theme is what the terminal is drawn in, not what a preferences window is drawn in.

import AppKit
import SlopDeskClientCore
import SlopDeskVideoProtocol // InputModifiers — the wire's own modifier bits, which the policy reads
import SlopDeskWorkspaceCore

// MARK: - The window

/// The Settings window. `cancelOperation` reaches here from anywhere inside that did not handle Esc,
/// which is the responder chain doing what the SwiftUI scene needed a monitor for.
final class MacSettingsWindow: NSWindow {
    override func cancelOperation(_: Any?) {
        // WHAT Esc means here is `slopdesk_video::escape_monitor`'s, asked through
        // `SettingsEscapePolicy` — the modifier rule and the chord-recorder veto are decisions, and
        // they did not stop being decisions when the monitor that used to ask them went away.
        let event = NSApp.currentEvent
        let decision = SettingsEscapePolicy.decide(
            keyCode: event?.keyCode ?? 53,
            modifierMask: event.map { InputModifiers($0.modifierFlags).rawValue } ?? 0,
            isCapturingChord: SettingsChordCapture.shared.isCapturing,
        )
        guard decision == .closeWindow else { return }
        // End any field editing FIRST so an in-flight edit commits through its normal path rather than
        // dying with the window.
        endEditing(for: nil)
        performClose(nil)
    }
}

// MARK: - The controller

/// Opens and raises the one Settings window.
///
/// Held by the app rather than by a scene: a stock `Settings` scene is a SwiftUI construct, and the
/// point of stage D is that the Mac shell's windows are windows.
@preconcurrency
@MainActor
public final class MacSettingsWindowController: NSObject, NSWindowDelegate {
    private let store: PreferencesStore
    private let agentHooks: AgentHooksController?
    private let workspace: WorkspaceStore?

    /// The live window, or `nil` while none is open. Cleared in `windowWillClose(_:)` so the next ⌘,
    /// builds a fresh one rather than raising a window AppKit has already torn down.
    private var window: NSWindow?

    public init(
        store: PreferencesStore,
        agentHooks: AgentHooksController? = nil,
        workspace: WorkspaceStore? = nil,
    ) {
        self.store = store
        self.agentHooks = agentHooks
        self.workspace = workspace
    }

    /// ⌘, — show the window, or raise the one already up.
    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let split = MacSettingsSplitController(store: store, agentHooks: agentHooks, workspace: workspace)
        let created = MacSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        created.title = "Settings"
        created.contentViewController = split
        created.titlebarAppearsTransparent = false
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.setFrameAutosaveName("SlopDeskSettings")
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_: Notification) {
        window = nil
    }
}

// MARK: - The split

/// The navigator on the left, the selected section's page on the right.
///
/// `.sidebar` behavior is what gives the left column the system's source-list material and its
/// automatic minimum/maximum thickness; the right column is `.contentList` so it takes the remaining
/// width and holds a sensible floor of its own.
@MainActor
final class MacSettingsSplitController: NSSplitViewController {
    private let navigator: MacSettingsNavigatorController
    private let page: MacSettingsPageController

    init(store: PreferencesStore, agentHooks: AgentHooksController?, workspace: WorkspaceStore?) {
        navigator = MacSettingsNavigatorController()
        page = MacSettingsPageController(store: store, agentHooks: agentHooks, workspace: workspace)
        super.init(nibName: nil, bundle: nil)
        navigator.onSelect = { [weak self] section in self?.page.show(section) }
        // A ✎ in the All-Settings index names the page that owns the key. The page cannot show it
        // itself — the NAVIGATOR is what says which section is current, and a page that changed its
        // own content would leave the source list highlighting the one the reader left.
        page.onJump = { [weak self] section in self?.navigator.select(section) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebar = NSSplitViewItem(sidebarWithViewController: navigator)
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 320
        // A Settings window has a FIXED navigator, like System Settings: collapsing it would leave no
        // way to reach another section, so the collapse the sidebar behavior offers is refused here
        // rather than removed from a toolbar after the fact.
        sidebar.canCollapse = false
        addSplitViewItem(sidebar)

        let detail = NSSplitViewItem(viewController: page)
        detail.minimumThickness = 520
        addSplitViewItem(detail)

        navigator.select(SettingsCatalog.sections.first?.id ?? "")
    }
}
