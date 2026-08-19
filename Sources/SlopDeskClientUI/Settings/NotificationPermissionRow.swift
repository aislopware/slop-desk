// NotificationPermissionRow — the system-permission status row at the top of the Notification group.
//
// It is a settings ROW that edits no setting: what it shows is the state of an OS grant, which no key
// in the table can carry and no toggle here can change. That is why it is its own file rather than an
// arm of the Shell page's control switch — the page renders settings, and this renders a permission.
//
// The DOT is a decision and lives where decisions live: ``PermissionStatus/dot(forAuthorization:)``,
// pure and headlessly pinned (`PermissionStatusTests`). This view only queries
// `UNUserNotificationCenter` and renders the answer.

#if canImport(SwiftUI)
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit // UIApplication.openSettingsURLString — the notification-permission deep link.
#endif

/// The System Permission status row (`terminal-features__notifications.md`, at the TOP of the Notification
/// group): a coloured dot (green = allowed, amber = will-prompt / unknown, red = blocked) + an **Open System
/// Settings** deep-link. The dot DECISION is the pure, headless-pinned
/// ``PermissionStatus/dot(forAuthorization:)``; this view only queries
/// `UNUserNotificationCenter.current().getNotificationSettings` and renders it.
///
/// **iOS caveat (carryover / spec flag):** macOS deep-links to the Notifications pane
/// (`x-apple.systempreferences:com.apple.preference.notifications`); iOS CANNOT deep-link to the per-app OS
/// pane, so the button opens the app's OWN settings via `UIApplication.openSettingsURLString` — macOS
/// deep-link `#if os(macOS)`, iOS fallback `#if os(iOS)`. See docs/DECISIONS.md.
struct NotificationPermissionRow: View {
    /// The current dot — starts amber (unknown) until the async query resolves, never a false green.
    @State private var dot: PermissionStatus.Dot = .amber
    /// SwiftUI-native URL opener (replaces `NSWorkspace`/`UIApplication.open` for the deep-link below). The
    /// custom `x-apple.systempreferences:` scheme routes through LaunchServices exactly as `NSWorkspace.open` did.
    @Environment(\.openURL) private var openURL

    var body: some View {
        LabeledContent {
            Button("Open System Settings", action: openSystemSettings)
                .controlSize(.small)
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text("System Permission")
                    Text(dotSubtitle)
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await refresh() }
    }

    private var dotColor: Color {
        switch dot {
        case .green: SettingsInk.ok
        case .amber: SettingsInk.warn
        case .red: SettingsInk.err
        }
    }

    private var dotSubtitle: String {
        switch dot {
        case .green: "Notifications are allowed for slopdesk."
        case .amber: "Notification permission has not been granted yet."
        case .red: "Notifications are blocked — enable them in System Settings."
        }
    }

    /// Query `UNUserNotificationCenter` and map the authorization status through the pure dot decision. Never
    /// instantiated in a test (`PermissionStatusTests` pins the pure mapping) — `current()` traps without a
    /// bundle, the same hang/crash-safety boundary as the video sessions. The `rawValue` Int is extracted
    /// INSIDE the `await` so the non-`Sendable` `UNNotificationSettings` never crosses the actor hop (only the
    /// `Int` does — Swift 6 region isolation).
    private func refresh() async {
        let raw = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus.rawValue
        dot = PermissionStatus.dot(forAuthorization: raw)
    }

    private func openSystemSettings() {
        // SwiftUI-native `openURL` (was `NSWorkspace`/`UIApplication.open`). The macOS custom scheme routes via
        // LaunchServices; on iOS `UIApplication.openSettingsURLString` is still the URL SOURCE (no SwiftUI
        // equivalent) — only the open ACTION is now `openURL`.
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            openURL(url)
        }
        #elseif os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
        #endif
    }
}
#endif
