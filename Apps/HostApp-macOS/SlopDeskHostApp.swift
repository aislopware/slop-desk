import AppKit
import SwiftUI

/// The `@main` entry for the SlopDesk macOS HOST menu-bar app (issue #5, research §C / §C1).
///
/// A friendly menu-bar front-end over the existing headless host daemon. It runs the SAME
/// terminal ``SlopDeskHost/HostServer`` the `slopdesk-hostd` CLI runs, but IN-PROCESS on a background
/// task with a Start/Stop toggle — so a user no longer needs a terminal + CLI knowledge just to
/// stand up the server. The C1 TCC permission checklist (Screen Recording + Accessibility) is
/// included here too, ready for the later GUI-video host wiring (which is NOT wired in this MVP).
///
/// `LSUIElement` (set in Info.plist) makes this a pure agent app: no Dock icon, no default
/// window — the entire UI is the menu-bar status item + its popover.
@main
struct SlopDeskHostApp: App {
    /// Owns the single ``HostController`` (see its doc) so it exists from launch — Quit must be
    /// able to drain a running host even if the popover (and its own controller wiring) was never
    /// opened this run.
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate

    /// The desired listen port, persisted via `@AppStorage`. Default 7779 (the issue's
    /// requested default; the CLI's own default is 7420, but the app just passes whatever the
    /// user sets to `HostServer(port:)`).
    @AppStorage("slopdesk.host.port") private var port: Int = 7779

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(controller: appDelegate.controller, port: $port)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        // `.window` (a real popover) rather than `.menu`: the content has a text field, status
        // dots, and multiple buttons — none of which work in a plain NSMenu (research §C4).
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar status item's icon: ``HostController/menuBarSymbol`` (the daemon-state glyph),
/// overridden by a distinct warning glyph whenever any required TCC permission is missing
/// (research §C1). The menu bar renders SF Symbols as monochrome templates, so the affordance is a
/// SYMBOL SWAP, not a color tint — fighting template rendering with `.foregroundStyle` would just
/// be flattened back to the template color at menu-bar scale (legible-or-absent).
private struct MenuBarIcon: View {
    @Bindable var controller: HostController

    /// Forces a re-check of `TCC.anyPermissionMissing` on a light timer. A grant/revoke in System
    /// Settings does not touch any `@Observable` state this view already depends on, so without a
    /// timer the icon would never notice a mid-session permission change (mirrors the popover's
    /// own `tccTimer` in `MenuContentView`).
    @State private var tccRefreshTick = 0
    private let tccTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Image(systemName: symbol)
            .onReceive(tccTimer) { _ in tccRefreshTick &+= 1 }
            .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        _ = tccRefreshTick // read so this computed property re-runs when the timer bumps it
        // A failed daemon is the more specific/urgent signal and already gets its own glyph —
        // don't let a stale permission checklist mask a listener that just died. The permission
        // glyph is lock-flavored so it can't be mistaken for the failed-daemon triangle at
        // menu-bar size (filled vs unfilled reads as the same glyph in 16pt template mono).
        if case .failed = controller.state { return controller.menuBarSymbol }
        if TCC.anyPermissionMissing { return "lock.trianglebadge.exclamationmark" }
        return controller.menuBarSymbol
    }

    /// VoiceOver mirrors the glyph's state — the visual swap alone is silent to it.
    private var accessibilityText: String {
        _ = tccRefreshTick
        if case .failed = controller.state { return "SlopDesk Host — daemon failed" }
        if TCC.anyPermissionMissing { return "SlopDesk Host — permission missing" }
        return "SlopDesk Host"
    }
}

/// App delegate whose only job is making Quit graceful: it intercepts termination to await
/// `HostController.stop()` (SIGTERM-with-grace to every live session, journal flush, listener
/// close) before the process actually exits, instead of `NSApplication.terminate` yanking the
/// process out from under connected clients. Also owns the single `HostController` instance, so
/// it is guaranteed to exist at Quit time regardless of whether the popover was ever opened.
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    let controller = HostController()

    /// Deadline for the graceful drain — generous for HostServer's SIGTERM-with-grace-then-force
    /// per-session teardown, but bounded so a wedged `stop()` can never hang Quit (and therefore a
    /// system shutdown/logout waiting on this app) forever.
    private static let gracefulStopTimeout: Duration = .seconds(5)

    /// Races the graceful drain against the timeout — whichever finishes first replies to AppKit.
    /// `latch` guards against both firing: a second `reply(toApplicationShouldTerminate:)` on an
    /// already-completed termination is undefined.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        let latch = QuitReplyLatch()
        Task { @MainActor in
            await controller.stop()
            if latch.tryFire() { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.gracefulStopTimeout)
            if latch.tryFire() { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

/// One-shot guard so the graceful-stop and timeout races above can never both reply.
@MainActor
private final class QuitReplyLatch {
    private var fired = false
    func tryFire() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}
