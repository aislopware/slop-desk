// ClientNotificationSinks — the composition's three OS-notification sinks, filled ONCE.
//
// ``ClientComposition`` publishes three seams and installs neither: `backgroundNoticeSink`,
// `longCommandSink` and `agentAttentionSink`. Both shells filled all three, in their own `App.init`,
// with the same `CommandCompletionNotifier` + `PaneNotificationRouter` pair and the same argument
// lists — two of the three character for character. That was a composition root written twice, which
// is what docs/56 §3 calls the failure mode the split exists to prevent, and the drift it had already
// produced is in this file's other half: the Mac's own comment still read "the phone installs NONE of
// them" long after the phone started installing all three.
//
// ⚠️ NOTHING HERE IS A PLATFORM GATE. `UserNotifications` is cross-platform and so is every type
// below; the two genuine per-shell facts are handed IN. The Dock bounce is one — there is no Dock
// tile on a phone, so it stays an unbound seam on the notifier rather than an `#if`. The other is
// where an agent CUE is spoken (``CueDelivery``), which is a speaker, not a second policy: the
// VERDICT is ``AgentSoundPolicy/sound(needsInput:sourcePaneFocused:soundTaskComplete:soundAwaitInput:)``'s
// on both, and neither shell may grow its own idea of when a cue rings.

import Defaults
import SlopDeskWorkspaceCore

/// Fills the composition's three notification seams over one notifier and one router.
@MainActor
package enum ClientNotificationSinks {
    /// Who speaks an agent cue on this platform.
    package enum CueDelivery {
        /// The BANNER carries it — the notification request's own `sound` field. One posting, one
        /// sound, and the system decides whether a silenced device hears it.
        case withTheBanner
        /// A SEPARATE sound the shell plays, and a silent banner beside it. The Mac's, because the
        /// cues are system sounds (`NSSound(named:)`) rather than anything bundled, and because a
        /// focused pane on another display should still ring while its banner is suppressed.
        case played(@MainActor (AgentSound) -> Void)
    }

    /// Installs all three sinks. `router` is handed in already delegated by the caller, which is the
    /// one step that has to happen where the shell can hold the strong reference the delegate seam
    /// does not take.
    ///
    /// Authorization is LAZY inside the poster: the first event that survives the toggles prompts, so
    /// a client that never sees one never asks.
    package static func install(
        on app: ClientComposition,
        notifier: CommandCompletionNotifier,
        cue: CueDelivery,
    ) {
        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) → an OS notification tagged with the pane id, so a
        // click reveals the pane (the router routes back). The toast half already fired inside the
        // composition, on both platforms; what is added here is the OS surface.
        app.backgroundNoticeSink = { notice in
            notifier.notifyExplicit(
                event: notice.event,
                paneIDKey: notice.paneIDKey, paneTitle: notice.paneTitle,
                title: notice.title, body: notice.body,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
            )
        }
        // Notify on Finish (clean exit, default OFF) / Notify on Error Exit (non-zero, default ON) +
        // the Notify-While-Foreground gate — the duration threshold is the notifier's own.
        app.longCommandSink = { notice in
            notifier.notifyIfLong(
                paneTitle: notice.paneTitle, exitCode: notice.exitCode, durationMS: notice.durationMS,
                paneIDKey: notice.paneIDKey,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
            )
        }
        app.agentAttentionSink = { notice in
            // The cue's VERDICT, once. `AgentSoundPolicy` does NOT gate on focus: the TOAST is
            // suppressed for a focused pane (a card over the event you are watching is spam) but the
            // cue still rings, because a focused pane is routinely one in a background window or on
            // another display.
            let verdict = AgentSoundPolicy.sound(
                needsInput: notice.needsInput,
                sourcePaneFocused: notice.sourcePaneFocused,
                soundTaskComplete: Defaults[.agentSoundTaskComplete],
                soundAwaitInput: Defaults[.agentSoundAwaitInput],
            )
            var banner: AgentSound?
            switch cue {
            case .withTheBanner:
                banner = verdict
            case let .played(play):
                if let verdict { play(verdict) }
            }
            // Agent edges ride their OWN per-event toggles — awaiting-input vs task-complete — NOT the
            // shell-app master switch, then the Notify-While-Foreground gate.
            notifier.notifyExplicit(
                event: notice.needsInput ? .agentAwaitInput : .agentTaskComplete,
                paneIDKey: notice.paneIDKey, paneTitle: notice.name,
                title: notice.name, body: notice.body,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
                sound: banner,
            )
        }
    }
}
