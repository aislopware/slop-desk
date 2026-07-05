import Foundation
import SlopDeskProtocol

// MARK: - NotificationPolicy (E14/K9 — the PURE "should this notification be delivered" decision)

/// The **Notify While Foreground** tri-state (`notification-while-foreground`) — how a system
/// notification banner behaves while slopdesk is the FRONTMOST app. macOS otherwise suppresses banners
/// for the foreground app; this overrides that policy. The rendered picker shows
/// the long human label for ``tabUnfocused``.
public enum NotifyWhileForeground: String, CaseIterable, Sendable, Equatable {
    /// Default — let the system suppress the banner while the app is frontmost.
    case off
    /// Always show the banner, even when the app is frontmost.
    case always
    /// Show the banner only when the notification's SOURCE tab is NOT the active one
    /// (`tab-unfocused`). The picker renders this as "Only when source tab is unfocused".
    case tabUnfocused = "tab-unfocused"

    /// The human-readable picker label. The picker renders the long form for ``tabUnfocused``
    /// ("Only when source tab is unfocused") rather than the raw enum token.
    public var displayLabel: String {
        switch self {
        case .off: "Off"
        case .always: "Always"
        case .tabUnfocused: "Only when source tab is unfocused"
        }
    }
}

/// The notification-bearing events the policy gates. Each maps to exactly ONE per-event toggle (so a key
/// is never double-gated); the foreground tri-state then decides whether the banner shows while frontmost.
public enum NotificationEvent: Sendable, Equatable {
    /// An explicit child-requested OSC 9 / OSC 777 / OSC 99 notification. Gated by the master
    /// "Allow App Notifications" (`appNotificationsEnabled`) — the shell-app notification switch.
    case explicitOSC
    /// A command finished (OSC 133;D). `exit == nil` / `0` is a clean finish (gated by Notify on Finish);
    /// a non-zero exit is an error (gated by Notify on Error Exit).
    case commandFinish(exit: Int32?)
    /// An `slopdesk watch`-wrapped command finished. The SOURCE (the watch command emitting the finish
    /// edge) is E20 territory; the toggle + policy ship now and parse-only is wired (see DECISIONS.md).
    case watchFinish
    /// A code agent (Claude Code only — see the E14 scope exclusion) finished its task and went idle.
    case agentTaskComplete
    /// A code agent is awaiting approval / input.
    case agentAwaitInput

    /// Classify an EXPLICIT child notification (the host's `.notification(title:body:)` — OSC 9 / 777 / 99) into
    /// the gating event + the user-visible title. An `slopdesk watch` finish banner carries the private
    /// ``WatchNotificationMarker/title`` sentinel in its title; it routes to ``watchFinish`` (gated by the
    /// dedicated "Notify on Watch Finish" toggle) with the sentinel STRIPPED, so the banner shows just the
    /// message. Any other notification rides ``explicitOSC`` (the master "Allow App Notifications" switch),
    /// unchanged. Pure — the single source of the watch-vs-generic routing decision, exercised by the app's
    /// `onPaneNotification` dispatch and pinned by `NotificationPolicyTests`.
    public static func classifyExplicit(
        title: String, body _: String,
    ) -> (event: Self, displayTitle: String) {
        if title == WatchNotificationMarker.title {
            return (.watchFinish, "")
        }
        return (.explicitOSC, title)
    }
}

/// The resolved per-event notification toggles + the foreground policy — the headless inputs to
/// ``NotificationPolicy/shouldDeliver(event:appActive:sourcePaneFocused:settings:)``. The default values are
/// the shipped notification defaults, so `NotificationSettings()` is the shipped baseline (and a
/// test can pin those defaults). The live values are resolved from ``SettingsKey/notificationSettings``.
public struct NotificationSettings: Sendable, Equatable {
    /// "Allow App Notifications" — the master switch for explicit OSC 9 / 777 / 99 notifications (default ON).
    public var appNotificationsEnabled: Bool
    /// "Notify on Command Finish" — fire when a command exits 0 (default OFF).
    public var notifyOnFinish: Bool
    /// "Notify on Error Exit" — fire when a command exits non-zero (default ON).
    public var notifyOnError: Bool
    /// "Notify on Watch Finish" — fire when an `slopdesk watch`-wrapped command finishes (default ON).
    public var notifyOnWatchFinish: Bool
    /// "Notify While Foreground" — banner behaviour while the app is frontmost (default ``NotifyWhileForeground/off``).
    public var notifyWhileForeground: NotifyWhileForeground
    /// "Code Agent — Notify When Task Completes" (default ON).
    public var agentNotifyTaskComplete: Bool
    /// "Code Agent — Notify When Awaiting Input" (default ON).
    public var agentNotifyAwaitInput: Bool

    public init(
        appNotificationsEnabled: Bool = true,
        notifyOnFinish: Bool = false,
        notifyOnError: Bool = true,
        notifyOnWatchFinish: Bool = true,
        notifyWhileForeground: NotifyWhileForeground = .off,
        agentNotifyTaskComplete: Bool = true,
        agentNotifyAwaitInput: Bool = true,
    ) {
        self.appNotificationsEnabled = appNotificationsEnabled
        self.notifyOnFinish = notifyOnFinish
        self.notifyOnError = notifyOnError
        self.notifyOnWatchFinish = notifyOnWatchFinish
        self.notifyWhileForeground = notifyWhileForeground
        self.agentNotifyTaskComplete = agentNotifyTaskComplete
        self.agentNotifyAwaitInput = agentNotifyAwaitInput
    }
}

/// The PURE decision "should this notification be delivered as a system banner". Headless + `UN`-free so the
/// whole truth table is unit-tested without `UNUserNotificationCenter` (the macOS poster
/// ``CommandCompletionNotifier`` is the thin actuator that calls this). Two stages, both must pass:
///  1. the per-event toggle (``eventEnabled(_:settings:)``) — each event has exactly one toggle;
///  2. the Notify-While-Foreground gate (``foregroundGate(appActive:sourcePaneFocused:policy:)``) — only
///     relevant while the app is frontmost; when the app is backgrounded the OS shows the banner normally,
///     so the gate is a pass-through.
///
/// This is the carryover "the foreground gate must ACTUALLY gate" requirement, made a pure function.
public enum NotificationPolicy {
    /// Whether `event` is delivered given the live focus/app-active state and the resolved `settings`.
    public static func shouldDeliver(
        event: NotificationEvent,
        appActive: Bool,
        sourcePaneFocused: Bool,
        settings: NotificationSettings,
    ) -> Bool {
        guard eventEnabled(event, settings: settings) else { return false }
        return foregroundGate(
            appActive: appActive, sourcePaneFocused: sourcePaneFocused, policy: settings.notifyWhileForeground,
        )
    }

    /// Stage 1 — the per-event toggle. Each event maps to exactly one toggle (no double-gating): explicit
    /// OSC rides the master "Allow App Notifications", a command finish splits on exit (Finish vs Error),
    /// watch/agent each ride their own toggle.
    static func eventEnabled(_ event: NotificationEvent, settings: NotificationSettings) -> Bool {
        switch event {
        case .explicitOSC:
            settings.appNotificationsEnabled
        case let .commandFinish(exit):
            // `exit == nil` (a completion carrying no code) is treated as a clean exit 0, matching the
            // BackgroundCompletionPolicy badge convention.
            (exit ?? 0) == 0 ? settings.notifyOnFinish : settings.notifyOnError
        case .watchFinish:
            settings.notifyOnWatchFinish
        case .agentTaskComplete:
            settings.agentNotifyTaskComplete
        case .agentAwaitInput:
            settings.agentNotifyAwaitInput
        }
    }

    /// Stage 2 — the Notify-While-Foreground gate. When the app is NOT active the OS shows the banner
    /// normally, so this is always a pass. While the app IS active the tri-state decides: `.off` suppresses,
    /// `.always` shows, `.tabUnfocused` shows only when the source pane is not the focused one.
    static func foregroundGate(
        appActive: Bool, sourcePaneFocused: Bool, policy: NotifyWhileForeground,
    ) -> Bool {
        guard appActive else { return true }
        switch policy {
        case .off: return false
        case .always: return true
        case .tabUnfocused: return !sourcePaneFocused
        }
    }
}
