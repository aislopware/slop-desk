import SwiftUI

/// The `@main` entry for the Aislopdesk macOS HOST menu-bar app (issue #5, research §C / §C1).
///
/// A friendly menu-bar front-end over the existing headless host daemon. It runs the SAME
/// terminal ``AislopdeskHost/HostServer`` the `aislopdesk-hostd` CLI runs, but IN-PROCESS on a background
/// task with a Start/Stop toggle — so a user no longer needs a terminal + CLI knowledge just to
/// stand up the server. The C1 TCC permission checklist (Screen Recording + Accessibility) is
/// included here too, ready for the later GUI-video host wiring (which is NOT wired in this MVP).
///
/// `LSUIElement` (set in Info.plist) makes this a pure agent app: no Dock icon, no default
/// window — the entire UI is the menu-bar status item + its popover.
@main
struct AislopdeskHostApp: App {
    @State private var controller = HostController()

    /// The desired listen port, persisted via `@AppStorage`. Default 7779 (the issue's
    /// requested default; the CLI's own default is 7420, but the app just passes whatever the
    /// user sets to `HostServer(port:)`).
    @AppStorage("aislopdesk.host.port") private var port: Int = 7779

    var body: some Scene {
        MenuBarExtra("Aislopdesk Host", systemImage: controller.menuBarSymbol) {
            MenuContentView(controller: controller, port: $port)
        }
        // `.window` (a real popover) rather than `.menu`: the content has a text field, status
        // dots, and multiple buttons — none of which work in a plain NSMenu (research §C4).
        .menuBarExtraStyle(.window)
    }
}
