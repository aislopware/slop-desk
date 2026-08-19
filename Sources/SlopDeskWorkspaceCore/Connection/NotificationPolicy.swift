import CSlopDeskFFI
import SlopDeskProtocol

// MARK: - NotificationPolicy (the face over "should this notification be delivered")

/// The **Notify While Foreground** tri-state (`notification-while-foreground`) — how a system
/// notification banner behaves while slopdesk is the FRONTMOST app. macOS otherwise suppresses banners
/// for the foreground app; this overrides that policy. The rendered picker shows
/// the long human label for ``tabUnfocused``.
public enum NotifyWhileForeground: String, CaseIterable, Sendable, Equatable {
    /// Default — let the system suppress the banner while the app is frontmost.
    case off
    /// Always show the banner, even when the app is frontmost.
    case always
    /// Show the banner only when the notification's SOURCE pane is NOT visible — its tab is not
    /// the active one (any split of the active tab is on screen, so it counts as visible)
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

    /// The CASE index — the crate's `ForegroundPolicy` order. A byte the crate does not recognise
    /// reads as `off`, so a disagreement costs a banner rather than producing one.
    var ffiByte: UInt8 {
        switch self {
        case .off: 0
        case .always: 1
        case .tabUnfocused: 2
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
    /// An `slopdesk watch`-wrapped command finished. Detecting the SOURCE (the watch command emitting the
    /// finish edge) is out of scope here; the toggle + policy ship now and parse-only is wired (see DECISIONS.md).
    case watchFinish
    /// A code agent (Claude Code only) finished its task and went idle.
    case agentTaskComplete
    /// A code agent is awaiting approval / input.
    case agentAwaitInput

    /// The flat `(case index, exit)` the crate reads — the crate's `Event` order.
    var ffi: SlopDeskWsNotifyEvent {
        switch self {
        case .explicitOSC:
            SlopDeskWsNotifyEvent(kind: 0, exit: 0, exit_present: false)
        case let .commandFinish(exit):
            SlopDeskWsNotifyEvent(kind: 1, exit: exit ?? 0, exit_present: exit != nil)
        case .watchFinish:
            SlopDeskWsNotifyEvent(kind: 2, exit: 0, exit_present: false)
        case .agentTaskComplete:
            SlopDeskWsNotifyEvent(kind: 3, exit: 0, exit_present: false)
        case .agentAwaitInput:
            SlopDeskWsNotifyEvent(kind: 4, exit: 0, exit_present: false)
        }
    }

    /// Classify an EXPLICIT child notification (the host's `.notification(title:body:)` — OSC 9 / 777 / 99) into
    /// the gating event + the user-visible title. An `slopdesk watch` finish banner carries the private
    /// ``WatchNotificationMarker/title`` sentinel in its title; it routes to ``watchFinish`` (gated by the
    /// dedicated "Notify on Watch Finish" toggle) with the sentinel STRIPPED, so the banner shows just the
    /// message. Any other notification rides ``explicitOSC`` (the master "Allow App Notifications" switch),
    /// unchanged.
    ///
    /// The sentinel is `rust/slopdesk-wire`'s, and so is the reading of it: this is the parse-back of the
    /// builder that put it there, which is why the two sit in one crate rather than agreeing by hand.
    public static func classifyExplicit(
        title: String, body _: String,
    ) -> (event: Self, displayTitle: String) {
        var title = title
        let isWatch = title.withUTF8 { text in
            slopdesk_watch_notification_is_marked(text.baseAddress, text.count)
        }
        return isWatch ? (.watchFinish, "") : (.explicitOSC, title)
    }
}

/// The resolved per-event notification toggles + the foreground policy — the headless inputs to
/// ``NotificationPolicy/shouldDeliver(event:appActive:sourcePaneVisible:settings:)``. The default values are
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

    var ffi: SlopDeskWsNotifySettings {
        SlopDeskWsNotifySettings(
            app_notifications_enabled: appNotificationsEnabled,
            notify_on_finish: notifyOnFinish,
            notify_on_error: notifyOnError,
            notify_on_watch_finish: notifyOnWatchFinish,
            foreground: notifyWhileForeground.ffiByte,
            agent_notify_task_complete: agentNotifyTaskComplete,
            agent_notify_await_input: agentNotifyAwaitInput,
        )
    }
}

/// The decision "should this notification be delivered as a system banner". The rule is
/// `slopdesk_workspace::notify`, which states the two stages and why the second one is a
/// pass-through whenever the app is backgrounded; this is the call.
///
/// The macOS poster ``CommandCompletionNotifier`` is the thin actuator that asks it.
public enum NotificationPolicy {
    /// Whether `event` is delivered given the live focus/app-active state and the resolved `settings`.
    /// `sourcePaneVisible` = the user can SEE the source pane right now — it sits in the active
    /// session's ACTIVE tab (any split, not just the focused leaf) while the app is active, or its
    /// satellite window is key. Visibility, not leaf focus, is the gate input: a split pane you are
    /// watching work needs no banner even though your cursor is in its sibling.
    public static func shouldDeliver(
        event: NotificationEvent,
        appActive: Bool,
        sourcePaneVisible: Bool,
        settings: NotificationSettings,
    ) -> Bool {
        slopdesk_ws_notify_should_deliver(event.ffi, appActive, sourcePaneVisible, settings.ffi)
    }
}
