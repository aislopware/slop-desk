// NotificationPermissionRow — the system-permission status row at the top of the Notification group.
//
// It is a settings ROW that edits no setting: what it shows is the state of an OS grant, which no key
// in the table can carry and no toggle here can change. That is why it is its own file rather than an
// arm of the Shell page's control switch — the page renders settings, and this renders a permission.
//
// The DOT is a decision and lives where decisions live: ``PermissionStatus/dot(forAuthorization:)``,
// pure and headlessly pinned (`PermissionStatusTests`). Since increment 49 the WORDS around it live one
// floor down too, in ``SettingsPermissionRow`` — there are two renderers now
// (``SlopDeskMacUI/MacNotificationPermissionRow``) and a sentence about an OS grant reads the same on
// both. This view queries `UNUserNotificationCenter` and arranges the answer; it decides nothing.

#if os(iOS)
import SlopDeskClientCore // SettingsPermissionRow — the words this row is not allowed to re-type
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI
import UIKit // UIApplication.openSettingsURLString — the notification-permission deep link.
import UserNotifications

/// The System Permission status row (`terminal-features__notifications.md`, at the TOP of the Notification
/// group): a coloured dot (green = allowed, amber = will-prompt / unknown, red = blocked) + an **Open System
/// Settings** deep-link. The dot DECISION is the pure, headless-pinned
/// ``PermissionStatus/dot(forAuthorization:)``; this view only queries
/// `UNUserNotificationCenter.current().getNotificationSettings` and renders it.
///
/// **Caveat (carryover / spec flag):** iOS CANNOT deep-link to the per-app Notifications pane, so the
/// button lands one level out, on the app's OWN settings page (`UIApplication.openSettingsURLString`),
/// and the user taps Notifications there. See docs/DECISIONS.md.
struct NotificationPermissionRow: View {
    /// The current dot — starts amber (unknown) until the async query resolves, never a false green.
    @State private var dot: PermissionStatus.Dot = .amber
    /// SwiftUI-native URL opener — `openURL` rather than `UIApplication.open` for the deep-link below, so
    /// the row asks the environment to open a URL instead of reaching for the shared application.
    @Environment(\.openURL) private var openURL

    var body: some View {
        LabeledContent {
            Button(SettingsPermissionRow.buttonTitle, action: openSystemSettings)
                .controlSize(.small)
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text(SettingsPermissionRow.title)
                    Text(SettingsPermissionRow.subtitle(dot))
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await refresh() }
    }

    private var dotColor: Color { SettingsInk.of(SettingsPermissionRow.ink(dot)) }

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
        // `UIApplication.openSettingsURLString` is still the URL SOURCE (SwiftUI has no equivalent) — only
        // the open ACTION is `openURL`.
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
#endif
