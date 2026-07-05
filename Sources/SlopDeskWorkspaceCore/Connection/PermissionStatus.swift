import Foundation

// MARK: - PermissionStatus (E14/K11 — the PURE "what dot does the System Permission row show" decision)

/// The macOS/iOS notification-permission status row shown at the top of Settings → Shell →
/// Notification (`docs/ui-shell/spec/terminal-features__notifications.md`): a coloured dot (green = allowed,
/// amber = will-prompt / unknown, red = blocked) plus an **Open System Settings** button.
///
/// PURE + framework-free so the whole green/amber/red decision is unit-pinned WITHOUT importing
/// UserNotifications (the view layer queries `UNUserNotificationCenter.current().getNotificationSettings`
/// and feeds the raw `UNAuthorizationStatus.rawValue` Int through ``dot(forAuthorization:)``). Keeping the
/// mapping headless means `PermissionStatusTests` never instantiates `UNUserNotificationCenter` (which traps
/// without a bundle) — the hang/crash-safety discipline, same as the video sessions.
public enum PermissionStatus {
    /// The three dot colours the System Permission row renders.
    public enum Dot: String, Sendable, Equatable, CaseIterable {
        /// Notifications are authorised — the banner path works.
        case green
        /// Not yet determined (the OS will prompt on first request) or an unknown future status — the
        /// honest "we don't know yet / it may prompt" colour.
        case amber
        /// Notifications are denied/blocked — banners are suppressed until the user re-enables them in
        /// System Settings.
        case red
    }

    /// Map a `UNAuthorizationStatus` raw value to the dot the row shows. PURE — the caller passes
    /// `settings.authorizationStatus.rawValue` so this never imports UserNotifications.
    ///
    /// Apple's `UNAuthorizationStatus` raw values: `0` notDetermined, `1` denied, `2` authorized,
    /// `3` provisional, `4` ephemeral. Authorised / provisional / ephemeral all DELIVER notifications, so they
    /// are green (allowed); denied is red (blocked); notDetermined — and ANY unrecognised future value — is
    /// amber (will prompt / unknown), the conservative "not proven allowed" default rather than a false green.
    public static func dot(forAuthorization rawValue: Int) -> Dot {
        switch rawValue {
        case 2,
             3,
             4: .green // authorized / provisional / ephemeral — all deliver
        case 1: .red // denied
        default: .amber // 0 notDetermined + any unknown future value
        }
    }
}
