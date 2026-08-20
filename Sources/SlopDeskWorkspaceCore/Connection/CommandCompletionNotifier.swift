import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel
import UserNotifications

/// The PURE decision policy for "should a finished command raise a desktop notification".
///
/// Split out from the platform-specific poster so the threshold rule is unit-tested WITHOUT
/// touching `UNUserNotificationCenter` (which needs an app bundle + entitlements + an auth
/// prompt). The threshold is a single named constant so the "~10s" requirement lives in one
/// place. `#if`-unguarded so it compiles + tests on every platform.
public enum CommandNotificationPolicy {
    /// Commands shorter than this never notify — only LONG-running commands are worth a
    /// desktop alert (matches the iTerm2/Warp "command finished" default of ~10 seconds).
    /// A quick `ls` (milliseconds) is far below this and stays silent. Asked for rather than
    /// transcribed, so "long" cannot come to mean two things.
    public static var longRunningThresholdMS: UInt32 { slopdesk_ws_notify_long_threshold_ms() }

    /// Notify iff the host-measured C→D duration is at least the threshold. `>=`, so a command that
    /// took exactly the threshold notifies (and `sleep 12` clearly does).
    public static func shouldNotify(durationMS: UInt32) -> Bool {
        slopdesk_ws_notify_is_long_running(durationMS)
    }
}

/// A small completion badge a BACKGROUND pane carries until you look at it: a green ✓ for a clean exit,
/// a red ✗ for a failure. Pure value, `Sendable` so it crosses the store/view boundary freely.
public enum PaneCompletionBadge: Equatable, Sendable {
    /// The command exited 0 (or with no exit code) — a clean finish. ✓ green.
    case success
    /// The command exited non-zero — it failed. ✗ red.
    case failure
}

/// The PURE decision shared by BOTH the background-pane completion badge AND the long-command
/// notification's focus gate. UN-free + clock-free so it is unit-tested without touching
/// `UNUserNotificationCenter` (matching ``CommandNotificationPolicy``). The threshold is reused from
/// ``CommandNotificationPolicy/longRunningThresholdMS`` so "long" means one thing everywhere.
///
/// The two surfaces differ deliberately:
///  - **badge**: shows on an UNFOCUSED pane. A FAILURE badges immediately (even a quick failing `make`
///    is worth surfacing on a backgrounded pane); a SUCCESS badges only when it was LONG, so a quick
///    background `ls`/`cd` does not litter the sidebar.
///  - **shouldNotify**: the focus gate — a desktop notification fires only for an UNFOCUSED, LONG
///    command while notifications are enabled (a foreground long command must not spam).
public enum BackgroundCompletionPolicy {
    /// The completion badge for a finished command, or `nil` for "no badge":
    ///  - FOCUSED pane → always `nil` (you are already watching it; nothing to remember).
    ///  - failure (`(exitCode ?? 0) != 0`) → `.failure` (regardless of duration).
    ///  - success that ran ≥ `longThresholdMS` → `.success`.
    ///  - a SHORT background success → `nil` (no `ls`/`cd` noise).
    /// `exitCode == nil` is treated as a clean exit 0 (a completion with no carried code).
    public static func badge(
        exitCode: Int32?,
        durationMS: UInt32,
        isPaneFocused: Bool,
        longThresholdMS: UInt32,
    ) -> PaneCompletionBadge? {
        switch slopdesk_ws_notify_badge(
            exitCode ?? 0, exitCode != nil, durationMS, isPaneFocused, longThresholdMS,
        ) {
        case 1: .success
        case 2: .failure
        default: nil
        }
    }

    /// The focus gate for the long-command desktop notification: notify ONLY when the pane is
    /// UNFOCUSED, the command was LONG (≥ `longThresholdMS`), and notifications are enabled. A foreground
    /// long command (you watched it run) never notifies; a disabled toggle never notifies.
    public static func shouldNotify(
        durationMS: UInt32,
        isPaneFocused: Bool,
        enabled: Bool,
        longThresholdMS: UInt32,
    ) -> Bool {
        slopdesk_ws_notify_should_notify_completion(
            durationMS, isPaneFocused, enabled, longThresholdMS,
        )
    }
}

/// The PURE content policy for an EXPLICIT (OSC 9 / OSC 777) child-requested notification — the
/// title-fallback rule, split out so it is unit-tested without `UNUserNotificationCenter`.
public enum ExplicitNotificationContent {
    /// Resolves the displayed `(title, body)` for an explicit notification:
    /// - OSC 777 carries its own title → use it.
    /// - OSC 9 carries only a body (`explicitTitle == ""`) → the pane title is the title and the OSC
    ///   body is the body; if the pane has no title either, the body becomes the title (so the alert
    ///   is never blank) and the body line is dropped.
    public static func resolve(
        paneTitle: String,
        explicitTitle: String,
        body: String,
    ) -> (title: String, body: String) {
        var pane = paneTitle
        var explicit = explicitTitle
        var body = body
        var split = 0
        // The two strings come back as one run; `split` says where the title ends, so a title
        // carrying any byte a separator could use is still read back whole.
        let answer = wsAnswerBytes { out, cap in
            pane.withUTF8 { paneText in
                explicit.withUTF8 { explicitText in
                    body.withUTF8 { bodyText in
                        slopdesk_ws_notify_explicit_content(
                            paneText.baseAddress, paneText.count,
                            explicitText.baseAddress, explicitText.count,
                            bodyText.baseAddress, bodyText.count,
                            out, cap, &split,
                        )
                    }
                }
            }
        }
        guard split <= answer.count else { return ("", "") }
        return (
            String(bytes: answer[..<split], encoding: .utf8) ?? "",
            String(bytes: answer[split...], encoding: .utf8) ?? "",
        )
    }
}

/// The PURE `userInfo` builder for a long-command notification — split out so the "click reveals the
/// originating pane" wiring is unit-tested without instantiating `UNUserNotificationCenter`. When a
/// `paneIDKey` is present it embeds it under ``PaneNotificationRouter/paneIDUserInfoKey`` (so a click
/// routes through the existing reveal path); a `nil` key yields an empty `userInfo` (no reveal target).
///
/// A pure `[String: String]` derivation, so it compiles + tests on every platform. It takes the key as a
/// PARAMETER rather than reading ``PaneNotificationRouter/paneIDUserInfoKey`` itself — the router used to
/// be macOS-only and the helper had to survive without it. The router is portable now, but the parameter
/// stays: it is what lets the helper be tested with no reference to a `UN*` type at all.
public enum LongCommandNotificationUserInfo {
    /// `[paneIDUserInfoKey: paneIDKey]` when a key is supplied, else `[:]`.
    public static func make(paneIDUserInfoKey: String, paneIDKey: String?) -> [String: String] {
        guard let paneIDKey else { return [:] }
        return [paneIDUserInfoKey: paneIDKey]
    }
}

/// A pure token-bucket rate limiter — bounds how many explicit (OSC 9/777) notifications a single
/// remote shell can post, so a hostile or buggy process cannot flood the user's Notification Center.
/// `capacity` tokens are available immediately; they refill at `refillPerSecond`. Each allowed
/// notification consumes one. Deterministic (caller passes a monotonic `now`), so it is unit-tested
/// with no clock.
public struct NotificationRateLimiter: Sendable {
    /// The bucket itself, which is the whole state — it crosses by value in both directions, so
    /// there is no handle to own and nothing to free.
    private var bucket: SlopDeskWsNotifyRateLimiter

    public var capacity: Double { bucket.capacity }
    public var refillPerSecond: Double { bucket.refill_per_second }

    public init(capacity: Double = 5, refillPerSecond: Double = 0.5, now: TimeInterval) {
        bucket = SlopDeskWsNotifyRateLimiter(
            capacity: capacity, refill_per_second: refillPerSecond, tokens: capacity,
            last_refill: now,
        )
    }

    /// Refills by elapsed time then consumes a token if one is available. Returns whether the
    /// notification is allowed (a burst beyond `capacity` is dropped until tokens refill).
    public mutating func allow(now: TimeInterval) -> Bool {
        slopdesk_ws_notify_rate_limit_allow(&bucket, now)
    }
}

/// Posts a LOCAL notification when a LONG-running command completes (OSC 133;D with a
/// duration ≥ ``CommandNotificationPolicy/longRunningThresholdMS``). Best-effort, lazy-auth:
///
/// - **Lazy authorization:** `requestAuthorization` is called on the FIRST long-command
///   completion, not at launch, so a user who never runs a long command is never prompted.
/// - **Best-effort:** if authorization is denied or unavailable we simply do nothing — the
///   in-app running indicator (the PRIMARY deliverable) is unaffected.
/// - **BOTH triples.** `UserNotifications` is one framework with one API on macOS and iOS, so this is
///   one poster, not a pair of them. It was `#if os(macOS)` until the UI split, on the reasoning that
///   the deliverable was "the macOS workspace" — which shipped a phone that renders the whole
///   Notifications settings group over nothing. The binding rule is that the two apps differ in LAYOUT,
///   so the poster is portable and each platform entry point installs it into the composition's sinks.
///   What is genuinely per-platform is the ACTUATION either side of it, and both of those are already
///   injected seams rather than gates: ``bounceDock`` (a Dock tile is a Mac object; the phone leaves it
///   at its `{}` default) and the sound (see `sound:` below).
///
/// `@MainActor final class` because it caches authorization state across calls and is invoked
/// from the `@MainActor` ``ConnectionViewModel`` events loop. (A class — not a struct — so the
/// authorization cache mutated from the async `requestAuthorization` callback survives.)
@preconcurrency
@MainActor
public final class CommandCompletionNotifier {
    /// Cached authorization result so we do not re-`requestAuthorization` on every long command
    /// (the OS only prompts once, but caching avoids the repeated round-trip and lets a denied
    /// user fall straight through). `nil` until the first request resolves.
    private var granted: Bool?

    /// Anti-flood limiter for EXPLICIT (OSC 9/777) notifications — a hostile remote process could
    /// otherwise post unboundedly. ~5 burst, then ~1 per 2s. (The long-command path is naturally
    /// rate-limited by the ~10s threshold, so it is not gated.)
    private var explicitLimiter = NotificationRateLimiter(now: ProcessInfo.processInfo.systemUptime)

    /// The dock-bounce seam: called when a notification is DELIVERED while the app is not
    /// active. The bounce rides the notification OSCs, NOT the bell — so it fires on every delivered
    /// banner. The Mac wires this to `NSApp.requestUserAttention(.informationalRequest)` (gated by the
    /// "Bounce Dock Icon" toggle); the default is a no-op so tests never bounce — and so the phone,
    /// which has no Dock tile to bounce, binds nothing rather than being read past an `#if`.
    public var bounceDock: () -> Void = {}

    public init() {}

    /// Posts a "command finished" notification IFF the ``NotificationPolicy`` allows it (Notify on Finish
    /// for a clean exit / Notify on Error Exit for a non-zero exit, then the Notify-While-Foreground tri-state
    /// with the store-supplied `appActive` + `sourcePaneVisible`). There is no long-running floor here —
    /// the per-command gate is applied UPSTREAM in ``WorkspaceStore/handleCommandCompleted`` (the same policy,
    /// per-command + any duration), so a SHORT failing command notifies. This poster re-applies the policy as the
    /// foreground-gate actuator (defence-in-depth, agreeing with the store). `paneIDKey` (the
    /// originating pane's id string) is embedded in the notification's `userInfo` so a click reveals that
    /// pane via ``PaneNotificationRouter`` — `nil` ⇒ no reveal target (e.g. an unresolved pane).
    public func notifyIfLong(
        paneTitle: String,
        exitCode: Int32?,
        durationMS: UInt32,
        paneIDKey: String? = nil,
        appActive: Bool,
        sourcePaneVisible: Bool,
        settings: NotificationSettings,
    ) {
        // There is no ~10s long-running floor here — the per-command gate lives UPSTREAM in the
        // store (``WorkspaceStore/handleCommandCompleted``), which routes finish/error through the SAME pure
        // ``NotificationPolicy`` per-command (any duration). Re-imposing a floor here would silently drop the
        // short failing `make` the store just authorised. The poster re-applies the policy as the foreground-gate
        // actuator (defence-in-depth — agreeing with the store), then auth + post.
        // The per-event toggle (Notify on Finish / Error) + the Notify-While-Foreground gate.
        // A clean exit is `notifyOnFinish` (default OFF — so a clean long command does not post a banner);
        // a non-zero exit is `notifyOnError` (default ON).
        guard NotificationPolicy.shouldDeliver(
            event: .commandFinish(exit: exitCode),
            appActive: appActive, sourcePaneVisible: sourcePaneVisible, settings: settings,
        ) else { return }
        bounceDockIfBackgrounded(appActive: appActive)

        if granted != nil {
            // Already resolved — post (or no-op if denied) without re-prompting.
            post(paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS, paneIDKey: paneIDKey)
        } else {
            // Lazy authorization on the first long command. The completion handler is nonisolated
            // (Network/UN callback queue); hop back to the main actor carrying only Sendable values
            // (the Bool + the notification's primitive fields) so there is no cross-actor capture
            // of self until we are back on the main actor.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                Task { @MainActor [weak self] in
                    self?.granted = ok
                    self?.post(paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS, paneIDKey: paneIDKey)
                }
            }
        }
    }

    /// Fires the dock-bounce seam iff the app is NOT active (a delivered banner the user can't see in
    /// the foreground earns a bounce). A no-op while the app is active or if the app leaves ``bounceDock`` unwired.
    private func bounceDockIfBackgrounded(appActive: Bool) {
        if !appActive { bounceDock() }
    }

    /// Builds + adds the notification request — a no-op unless authorization was granted. Embeds
    /// `paneIDKey` in `userInfo` (via the pure ``LongCommandNotificationUserInfo``) so a click reveals
    /// the originating pane.
    private func post(paneTitle: String, exitCode: Int32?, durationMS: UInt32, paneIDKey: String?) {
        guard granted == true else { return }
        let content = UNMutableNotificationContent()
        // `paneTitle` is the live OSC 0/2 pane title — untrusted, remote/PTY-settable text (often the running
        // command line, e.g. `mysql -pSECRET`). Mask any secret before it is archived in Notification Center
        // (a banner outlives the command), mirroring `postExplicit`. Gated as an opt-out. The body below is a
        // fixed exit-code + duration template (no untrusted text), so it carries no secret.
        let redact = SettingsKey.redactSecretsEnabled
        content.title = paneTitle.isEmpty ? "Command finished" : (redact ? SecretRedactor.redact(paneTitle) : paneTitle)
        let secs = Int((Double(durationMS) / 1000).rounded())
        content.body = "command finished (exit \(exitCode.map(String.init) ?? "?"), \(secs)s)"
        content.userInfo = LongCommandNotificationUserInfo.make(
            paneIDUserInfoKey: PaneNotificationRouter.paneIDUserInfoKey, paneIDKey: paneIDKey,
        )
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Posts an EXPLICIT (OSC 9 / 777 / 99) child-requested notification — OR a Claude agent edge (the
    /// `event` distinguishes them) — carrying `paneIDKey` in `userInfo` so a click can focus the originating
    /// pane (see ``PaneNotificationRouter``). Gated by the ``NotificationPolicy`` (the per-event toggle
    /// + the Notify-While-Foreground tri-state) with the store-supplied `appActive` + `sourcePaneVisible`,
    /// then the anti-flood limiter. Lazy-auth + best-effort like the long-command path; resolves the title
    /// fallback via the pure ``ExplicitNotificationContent``.
    ///
    /// `sound` is the ``AgentSoundPolicy`` VERDICT, not a second policy: nil = stay silent (the toggle is
    /// off), non-nil = ring. There is ONE decision and TWO presenters — the Mac plays the edge's own
    /// `NSSound` at its binding site and passes nil here; the phone has no ambient audio path of its own,
    /// so it hands the verdict to the banner and this poster attaches the sound to the request. See
    /// ``bannerSound(for:)`` for why the phone's cue is the system default rather than Submarine/Glass.
    public func notifyExplicit(
        event: NotificationEvent,
        paneIDKey: String,
        paneTitle: String,
        title: String,
        body: String,
        appActive: Bool,
        sourcePaneVisible: Bool,
        settings: NotificationSettings,
        sound: AgentSound? = nil,
    ) {
        // The per-event toggle (explicit OSC rides "Allow App Notifications"; an agent edge rides its
        // own toggle) + the Notify-While-Foreground gate. Checked FIRST so a suppressed notification neither
        // consumes a rate-limit token nor triggers the auth prompt.
        guard NotificationPolicy.shouldDeliver(
            event: event, appActive: appActive, sourcePaneVisible: sourcePaneVisible, settings: settings,
        ) else { return }
        // Anti-flood: drop a notification that exceeds the burst/refill budget (a hostile process must
        // not be able to bury the user under alerts). Checked BEFORE auth so a flood can't even trigger
        // the first auth prompt repeatedly.
        guard explicitLimiter.allow(now: ProcessInfo.processInfo.systemUptime) else { return }
        bounceDockIfBackgrounded(appActive: appActive)
        let resolved = ExplicitNotificationContent.resolve(paneTitle: paneTitle, explicitTitle: title, body: body)
        if granted != nil {
            postExplicit(paneIDKey: paneIDKey, title: resolved.title, body: resolved.body, sound: sound)
        } else {
            // `AgentSound` (a `String` enum) crosses into the `@Sendable` auth callback; a
            // `UNNotificationSound` — an `NSObject` — could not, which is the other half of why the
            // VERDICT travels and the sound object is built at the post site.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                Task { @MainActor [weak self] in
                    self?.granted = ok
                    self?.postExplicit(
                        paneIDKey: paneIDKey, title: resolved.title, body: resolved.body, sound: sound,
                    )
                }
            }
        }
    }

    /// Adds the explicit-notification request — a no-op unless authorization was granted.
    private func postExplicit(paneIDKey: String, title: String, body: String, sound: AgentSound?) {
        guard granted == true else { return }
        let content = UNMutableNotificationContent()
        // The title/body originate from untrusted PTY output (OSC 9/777); mask any secret before it is
        // archived in Notification Center (a banner outlives the command). Gated as an opt-out.
        let redact = SettingsKey.redactSecretsEnabled
        content.title = redact ? SecretRedactor.redact(title) : title
        content.body = redact ? SecretRedactor.redact(body) : body
        content.userInfo = [PaneNotificationRouter.paneIDUserInfoKey: paneIDKey]
        content.sound = sound.map(Self.bannerSound)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// The banner-attached cue for an ``AgentSound`` verdict: the SYSTEM DEFAULT alert, both edges.
    ///
    /// `AgentSound`'s two rawValues (`Submarine`, `Glass`) name files in macOS's `/System/Library/Sounds`,
    /// which iOS does not ship and `UNNotificationSound(named:)` resolves against the app BUNDLE — so
    /// naming them here would post a banner that silently falls back to the default anyway, while reading
    /// as if the phone had the Mac's two-tone vocabulary. It does not, and bundling two audio files to
    /// invent one is a second sound world, not the one this seam exists to avoid. What survives the trip
    /// is the part the toggles control — ring or stay silent — decided once by ``AgentSoundPolicy``.
    private static func bannerSound(for _: AgentSound) -> UNNotificationSound { .default }
}

/// Routes a clicked notification (its `userInfo` pane-id) to a reveal closure the app wires to the
/// store (focus + centre the originating pane). EACH app installs it as the
/// `UNUserNotificationCenterDelegate` at launch — one router, two entry points — and the key + parsing
/// live here so they are one source of truth shared with ``CommandCompletionNotifier``.
@preconcurrency
@MainActor
public final class PaneNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// The `userInfo` key carrying the originating pane's id string. `nonisolated` so the
    /// `nonisolated` delegate methods (and the poster) can read it without a main-actor hop.
    public nonisolated static let paneIDUserInfoKey = "slopdesk.paneID"

    /// Called with the clicked notification's pane-id string. The app sets this to
    /// `store.revealPane(byIDString:)`.
    public var onReveal: ((String) -> Void)?

    override public init() { super.init() }

    /// Show the banner even while the app is foreground (otherwise an explicit notification fired while
    /// the user is looking at a different pane would be silently dropped). `nonisolated` to satisfy the
    /// delegate conformance; it touches no main-actor state.
    public nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: (UNNotificationPresentationOptions) -> Void,
    ) {
        completionHandler([.banner, .sound])
    }

    /// A click on the notification → reveal the originating pane (hops to the main actor for the store).
    public nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: () -> Void,
    ) {
        let key = response.notification.request.content.userInfo[Self.paneIDUserInfoKey] as? String
        Task { @MainActor [weak self] in
            if let key { self?.onReveal?(key) }
        }
        completionHandler()
    }
}
