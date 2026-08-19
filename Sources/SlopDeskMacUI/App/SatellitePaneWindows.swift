// SatellitePaneWindows — the macOS "detach pane into its own window" surface: the WINDOWS.
//
// A DETACHED pane (``WorkspaceStore/detachedPanes``) lives outside every tab's split tree but keeps its
// spec + live registry handle (reconcile counts detached ids as desired). This file materializes that
// state as real windows: ``SatelliteWindowsCoordinator`` diffs one plain-AppKit `NSWindowController` per
// detached pane into existence/away, each hosting the SAME leaf UI the split tree mounts — so the
// terminal ring-replays into a fresh surface and a video pane re-hellos, while the PTY / host session
// never dies. The content itself is still SwiftUI and comes over the ``SatellitePaneHost`` seam, the
// way the split shell's columns do.
//
// Deliberately PURE AppKit (never a second SwiftUI `WindowGroup`): the app's chord dispatcher /
// close-gate / pin actuator are single-window singletons keyed to the ONE workspace window captured via
// `.introspect(.window)` — a scene-created sibling would be re-captured and corrupt them. A plain
// `NSWindowController` is invisible to that machinery; ``SatellitePaneWindow`` is the marker class the
// few key-window-sensitive actuators (menu Close Window) check so they act on "the window I'm looking
// at" instead of the hidden main window.
//
// CLOSE = REATTACH, never destroy: `windowShouldClose` folds the pane back into its tab (origin tab when
// alive) and vetoes the AppKit close — the store mutation drops the pane from `detachedPanes`, and the
// coordinator's diff performs the one real window teardown.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // SatellitePaneHost — the hosted pane content, until the leaf UI is AppKit
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - SatellitePaneWindow (marker class)

/// The satellite `NSWindow` subclass — a MARKER: key-window-sensitive actuators (`overlayCoordinator
/// .closeWindow`, the menu Close Window item) test `NSApp.keyWindow is SatellitePaneWindow` to target
/// the satellite the user is looking at instead of the captured main workspace window.
final class SatellitePaneWindow: NSWindow {
    /// A BORDERLESS-engaged satellite must keep taking keys/main (AppKit defaults a `.borderless`
    /// styleMask to neither) — the desktop stream is useless without keyboard input. Harmless for
    /// the titled resting state (titled windows already say yes).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Routes the standard fullscreen verb (the View-menu item / ⌃⌘F / the green-button chord)
    /// through the controller first: a borderless-engaged window EXITS borderless, and a desktop
    /// window whose presentation setting is `.borderless` ENTERS it — native Spaces fullscreen
    /// remains the fallthrough for everything else.
    override func toggleFullScreen(_ sender: Any?) {
        if let controller = delegate as? SatellitePaneWindowController, controller.handleFullscreenVerb() {
            return
        }
        super.toggleFullScreen(sender)
    }
}

// MARK: - Per-pane window controller

/// One satellite window: a titled/closable/resizable `NSWindow` whose content is an `NSHostingView`
/// over ``SatellitePaneRootView``. Close (X / ⌘W via menu) REATTACHES — `windowShouldClose` runs the
/// store op and returns `false`; the coordinator's diff (observing ``WorkspaceStore/detachedPanes``)
/// then closes the window for real, keeping ONE teardown path for every exit (reattach, pane close,
/// session close).
@MainActor
final class SatellitePaneWindowController: NSWindowController, NSWindowDelegate {
    let paneID: PaneID
    private weak var store: WorkspaceStore?
    private let keyState = SatelliteWindowKeyState()
    /// `true` while the coordinator itself is closing the window (the pane already left
    /// `detachedPanes`) — `windowShouldClose` must let THAT close pass instead of re-running reattach.
    private var closingFromCoordinator = false

    // MARK: Borderless fullscreen (the dwell-gated Parallels model)

    /// Non-nil while BORDERLESS fullscreen is engaged: the window covers its screen with a
    /// `.borderless` mask, the local menu bar/Dock hide behind ``BorderlessDwellGate``, and this
    /// remembers everything needed to restore the titled resting state on exit.
    private struct BorderlessEngagement {
        var savedFrame: NSRect
        var savedStyleMask: NSWindow.StyleMask
        var gate = BorderlessDwellGate()
        var trackingArea: NSTrackingArea?
    }

    private var borderless: BorderlessEngagement?
    /// One-shot dwell completion for a MOTIONLESS pointer (mouse-moved events stop when the hand
    /// stops; the gate's deadline still has to fire).
    private var dwellTimer: Timer?

    init(
        store: WorkspaceStore, paneID: PaneID, title: String, paneDrag: PaneDragCoordinator?,
        overlay: OverlayCoordinator,
    ) {
        self.store = store
        self.paneID = paneID
        let window = SatellitePaneWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = title
        window.minSize = NSSize(width: 400, height: 300)
        // The workspace window must survive every satellite: an `NSWindowController`-owned window
        // released on close mid-diff double-frees; the coordinator owns the lifetime instead.
        window.isReleasedWhenClosed = false
        window.contentView = SatellitePaneHost.contentView(
            store: store, paneID: paneID, keyState: keyState, paneDrag: paneDrag, overlay: overlay,
        )
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Closes the window on the coordinator's behalf (the pane already left the detached set) —
    /// flagged so `windowShouldClose` passes it through instead of re-running reattach.
    func closeFromCoordinator() {
        closingFromCoordinator = true
        close()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_: NSWindow) -> Bool {
        if closingFromCoordinator { return true }
        // If the store is gone (teardown race) allow the close.
        guard let store else { return true }
        if store.tree.spec(for: paneID)?.kind == .desktop {
            // A DESKTOP satellite's close is a REAL close — the desktop never folds into a tab
            // (docs/DECISIONS.md 2026-07-22), so closing the window ends the stream session. No
            // confirmation surface: a video pane hosts no running child process to lose.
            store.closePaneTree(paneID)
        } else {
            // User-initiated close = REATTACH (non-destructive; the pane folds back into its tab).
            store.reattachPane(paneID)
        }
        // Veto the AppKit close either way — the store mutation drives the coordinator diff, which
        // closes via `closeFromCoordinator()` (the ONE real teardown path).
        return false
    }

    func windowDidBecomeKey(_: Notification) {
        keyState.isKey = true
        // Satellite focus truth (``WorkspaceStore/keySatellitePaneID``): a completion badge / desktop
        // notification for THIS pane must not fire while its window is the one the user is looking at.
        store?.noteSatelliteKey(paneID: paneID, isKey: true)
        // Borderless chrome-hiding is APP-WIDE state (`NSApp.presentationOptions`) — it may only
        // stand while this window is the key one, so it re-applies on every key gain…
        applyBorderlessPresentationOptions()
    }

    func windowDidResignKey(_: Notification) {
        keyState.isKey = false
        store?.noteSatelliteKey(paneID: paneID, isKey: false)
        // …and always releases on key loss (another window — even another satellite — must get the
        // normal menu bar back).
        if borderless != nil { NSApp.presentationOptions = [] }
    }

    func windowWillClose(_: Notification) {
        // A borderless window closing (⌘W ends the desktop session) must not strand the app-wide
        // chrome-hiding — release it and the dwell timer on the way out.
        if borderless != nil {
            NSApp.presentationOptions = []
            dwellTimer?.invalidate()
            dwellTimer = nil
        }
    }

    // FULLSCREEN AUTO-ARMS system-key capture (docs/DECISIONS.md 2026-07-22, the industry-converged
    // pattern): a fullscreen desktop window forwards ⌘Tab/⌘Space… to the host regardless of the
    // latched per-target immersive toggle; exiting returns to the latched value. Routed through the
    // handle seam — a graceful no-op for a terminal satellite.
    func windowDidEnterFullScreen(_: Notification) {
        store?.noteSatelliteFullscreen(paneID: paneID, isFullscreen: true)
    }

    func windowDidExitFullScreen(_: Notification) {
        store?.noteSatelliteFullscreen(paneID: paneID, isFullscreen: false)
    }

    // MARK: Borderless fullscreen engagement

    /// The fullscreen verb arrived (View menu / ⌃⌘F / green-button chord — routed by
    /// ``SatellitePaneWindow/toggleFullScreen(_:)``). Returns `true` when borderless handled it:
    /// engaged → exit; a desktop window whose presentation setting is `.borderless` → enter.
    /// `false` falls through to native Spaces fullscreen.
    func handleFullscreenVerb() -> Bool {
        if borderless != nil {
            disengageBorderless()
            return true
        }
        if store?.tree.spec(for: paneID)?.kind == .desktop,
           SettingsKey.desktopWindowPresentation == .borderless
        {
            engageBorderless()
            return true
        }
        return false
    }

    /// Covers the window's screen with a borderless mask, hides the local menu bar/Dock behind the
    /// dwell gate, and auto-arms immersive system-key capture (both fullscreen flavours are "the
    /// remote desktop owns this screen" — the docs/DECISIONS.md 2026-07-22 pattern). Idempotent.
    func engageBorderless() {
        guard borderless == nil, let window, let screen = window.screen ?? NSScreen.main else { return }
        var engagement = BorderlessEngagement(savedFrame: window.frame, savedStyleMask: window.styleMask)
        // Mouse-moved events feed the dwell gate; `.activeAlways` because the gate must also track
        // while a host app has focus inside the stream (the window stays key either way).
        if let content = window.contentView {
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self,
            )
            content.addTrackingArea(area)
            engagement.trackingArea = area
        }
        borderless = engagement
        window.styleMask = [.borderless]
        window.setFrame(screen.frame, display: true)
        window.isMovable = false // the cover IS the screen; a background-drag would tear it off it
        window.makeKeyAndOrderFront(nil)
        applyBorderlessPresentationOptions()
        store?.noteSatelliteFullscreen(paneID: paneID, isFullscreen: true)
    }

    /// Restores the titled resting window (saved frame + mask), releases the app-wide chrome
    /// hiding, and returns immersive capture to the latched per-target value. Idempotent.
    func disengageBorderless() {
        guard let engagement = borderless, let window else { return }
        dwellTimer?.invalidate()
        dwellTimer = nil
        if let area = engagement.trackingArea { window.contentView?.removeTrackingArea(area) }
        borderless = nil
        NSApp.presentationOptions = []
        window.styleMask = engagement.savedStyleMask
        window.setFrame(engagement.savedFrame, display: true)
        window.isMovable = true
        store?.noteSatelliteFullscreen(paneID: paneID, isFullscreen: false)
    }

    /// Tracking-area callback (this controller is the area's owner): feed the gate the pointer's
    /// distance from the screen's top edge, in points.
    override func mouseMoved(with _: NSEvent) {
        tickDwellGate()
    }

    /// One gate fold from the CURRENT global pointer position (mouse-moved event or dwell timer —
    /// both re-read `NSEvent.mouseLocation`, so a stale timer can never reveal for a pointer that
    /// already left the edge).
    private func tickDwellGate() {
        guard borderless != nil, let screen = window?.screen ?? NSScreen.main else { return }
        let yFromTop = screen.frame.maxY - NSEvent.mouseLocation.y
        let now = ProcessInfo.processInfo.systemUptime
        let before = borderless?.gate.phase
        borderless?.gate.update(pointerYFromTop: yFromTop, now: now)
        guard let engagement = borderless else { return }
        if engagement.gate.phase != before { applyBorderlessPresentationOptions() }
        // A motionless pointer emits no more moves — complete (or cancel) the dwell on a timer.
        dwellTimer?.invalidate()
        dwellTimer = nil
        if let deadline = engagement.gate.armingDeadline {
            let delay = Double.maximum(0.01, deadline - now)
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.tickDwellGate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            dwellTimer = timer
        }
    }

    /// Maps the gate phase onto the APP-WIDE presentation options — only while this window is key
    /// (the options are global; a background satellite must not hide another window's menu bar).
    /// Hidden ⇒ hard-hide (a top-edge touch reaches the REMOTE menu bar); revealed ⇒ auto-hide
    /// (macOS slides the local bar in for the already-dwelling pointer, and back out when it leaves).
    private func applyBorderlessPresentationOptions() {
        guard let engagement = borderless, window?.isKeyWindow == true else { return }
        NSApp.presentationOptions = engagement.gate.isRevealed
            ? [.autoHideMenuBar, .autoHideDock]
            : [.hideMenuBar, .hideDock]
    }
}

// MARK: - Coordinator (detachedPanes ⇄ NSWindows diff)

/// Diffs ``WorkspaceStore/detachedPanes`` into satellite windows: opens a controller per newly-detached
/// pane, closes the controller of any pane that left the set (reattached or closed). Driven by the
/// scene's `.onChange(of: store.detachedPanes)` (plus one initial sync) — the store stays headless; only
/// this app layer touches AppKit windows.
@MainActor
final class SatelliteWindowsCoordinator {
    private var controllers: [PaneID: SatellitePaneWindowController] = [:]
    /// Cascade origin so a burst of detaches doesn't stack windows exactly on top of each other.
    private var cascadeStep = 0

    /// Mirror of the app's automation gate (`SlopDeskClientApp.hasAutomationEnvironment`): an E2E
    /// run must never enter fullscreen (deterministic geometry for pixel checks).
    private static func hasAutomationEnvironment() -> Bool {
        let env = WorkspaceStore.automationInputs()
        return ["SLOPDESK_AUTOCONNECT_HOST", "SLOPDESK_VIDEO_AUTOCONNECT_HOST"]
            .contains { (env[$0]?.isEmpty == false) }
    }

    /// One sync pass. `overlay` is handed through to each window's hosted root, which is where the ONE
    /// environment key that subtree reads gets applied (``SatellitePaneHost/contentView(store:paneID:
    /// keyState:paneDrag:overlay:)``) — an `NSHostingView` root inherits NOTHING from the main scene, and
    /// the key is declared in the same target as the view that reads it, so the injection was moved to
    /// that side of the seam in increment 57a. What crosses here is a plain `SlopDeskClientCore` value.
    /// `paneDrag` (optional) wires the grab strip into each satellite AND supplies the tear-off drop
    /// point: a pane detached by DRAGGING it out of the main window opens under the cursor, not in the
    /// centre-cascade.
    func sync(
        _ detached: [DetachedPane], store: WorkspaceStore, paneDrag: PaneDragCoordinator? = nil,
        overlay: OverlayCoordinator,
    ) {
        let desired = Set(detached.map(\.pane))

        // Close windows whose pane reattached or closed for real.
        for (paneID, controller) in controllers where !desired.contains(paneID) {
            controllers.removeValue(forKey: paneID)
            controller.closeFromCoordinator()
        }

        // Open a window per newly-detached pane — at its recorded tear-off drop point when the detach
        // came from a drag, else cascaded off centre.
        for entry in detached where controllers[entry.pane] == nil {
            let spec = store.tree.spec(for: entry.pane)
            let isDesktop = spec?.kind == .desktop
            let title = spec?.title ?? "Detached Pane"
            let controller = SatellitePaneWindowController(
                store: store, paneID: entry.pane, title: title, paneDrag: paneDrag, overlay: overlay,
            )
            if let window = controller.window {
                if isDesktop {
                    // The desktop window is a primary surface, not a popped-out pane — open it
                    // roomy (the stream letterboxes inside) and centred.
                    window.setContentSize(NSSize(width: 1280, height: 800))
                    window.center()
                } else if let drop = paneDrag?.takePlacement(for: entry.pane) {
                    // Land the window's top edge just above the drop point (screen coords are
                    // bottom-left origin), roughly centred on the cursor — the pane appears to settle
                    // where the user let go. AppKit clamps the frame onto the screen if the drop was
                    // near an edge.
                    window.setFrameTopLeftPoint(NSPoint(
                        x: drop.x - window.frame.width / 2,
                        y: drop.y + 24,
                    ))
                } else {
                    cascadeStep = (cascadeStep + 1) % 8
                    let offset = CGFloat(cascadeStep) * 28
                    window.setFrameTopLeftPoint(NSPoint(
                        x: window.frame.minX + offset,
                        y: window.frame.maxY - offset,
                    ))
                }
            }
            controllers[entry.pane] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            // Default presentation (`desktopWindow.presentation`): a desktop window can open
            // STRAIGHT into native fullscreen (the Parsec model) or the dwell-gated borderless
            // cover (the Parallels model). Never under automation — an E2E run needs deterministic
            // window geometry (the window-size gate precedent).
            if isDesktop, !Self.hasAutomationEnvironment() {
                switch SettingsKey.desktopWindowPresentation {
                case .window: break
                case .fullscreen: controller.window?.toggleFullScreen(nil)
                case .borderless: controller.engageBorderless()
                }
            }
        }

        // Keep titles fresh on re-syncs (a rename / video rebind updates the spec title).
        for (paneID, controller) in controllers {
            if let title = store.tree.spec(for: paneID)?.title, controller.window?.title != title {
                controller.window?.title = title
            }
        }
    }

    /// Brings `paneID`'s satellite to the front (the ``WorkspaceStore/revealSatelliteWindow`` seam) —
    /// Reveal-style ingresses call this instead of minting a duplicate live stream when the pane is
    /// already detached. Returns `false` if no controller exists yet (e.g. this sync pass hasn't run).
    func reveal(_ paneID: PaneID) -> Bool {
        guard let controller = controllers[paneID] else { return false }
        controller.window?.makeKeyAndOrderFront(nil)
        return true
    }
}
