import Foundation

/// The PURE decision policy for "should a finished command raise a desktop notification".
///
/// Split out from the platform-specific poster so the threshold rule is unit-tested WITHOUT
/// touching `UNUserNotificationCenter` (which needs an app bundle + entitlements + an auth
/// prompt). The threshold is a single named constant so the "~10s" requirement lives in one
/// place. `#if`-unguarded so it compiles + tests on every platform.
public enum CommandNotificationPolicy {
    /// Commands shorter than this never notify — only LONG-running commands are worth a
    /// desktop alert (matches the iTerm2/Warp "command finished" default of ~10 seconds).
    /// A quick `ls` (milliseconds) is far below this and stays silent.
    public static let longRunningThresholdMS: UInt32 = 10000

    /// The pure decision: notify iff the host-measured C→D duration is at least the threshold.
    /// `>=` so a command that took exactly the threshold notifies (and `sleep 12` clearly does).
    public static func shouldNotify(durationMS: UInt32) -> Bool {
        durationMS >= longRunningThresholdMS
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
/// notification's focus gate (the B3 gate). UN-free + clock-free so it is unit-tested without touching
/// `UNUserNotificationCenter` (matching ``CommandNotificationPolicy``). The threshold is reused from
/// ``CommandNotificationPolicy/longRunningThresholdMS`` so "long" means one thing everywhere.
///
/// The two surfaces differ deliberately:
///  - **badge**: shows on an UNFOCUSED pane. A FAILURE badges immediately (even a quick failing `make`
///    is worth surfacing on a backgrounded pane); a SUCCESS badges only when it was LONG, so a quick
///    background `ls`/`cd` does not litter the sidebar.
///  - **shouldNotify**: the B3 focus gate — a desktop notification fires only for an UNFOCUSED, LONG
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
        guard !isPaneFocused else { return nil }
        if (exitCode ?? 0) != 0 { return .failure }
        return durationMS >= longThresholdMS ? .success : nil
    }

    /// The B3 focus gate for the long-command desktop notification: notify ONLY when the pane is
    /// UNFOCUSED, the command was LONG (≥ `longThresholdMS`), and notifications are enabled. A foreground
    /// long command (you watched it run) never notifies; a disabled toggle never notifies.
    public static func shouldNotify(
        durationMS: UInt32,
        isPaneFocused: Bool,
        enabled: Bool,
        longThresholdMS: UInt32,
    ) -> Bool {
        guard enabled, !isPaneFocused else { return false }
        return durationMS >= longThresholdMS
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
        let pane = paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = explicitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return (explicit, body)
        }
        if !pane.isEmpty {
            return (pane, body)
        }
        // No title anywhere: promote the body so the alert is never blank.
        return (body, "")
    }
}

/// The PURE `userInfo` builder for a long-command notification — split out so the "click reveals the
/// originating pane" wiring is unit-tested without instantiating `UNUserNotificationCenter`. When a
/// `paneIDKey` is present it embeds it under ``PaneNotificationRouter/paneIDUserInfoKey`` (so a click
/// routes through the existing reveal path); a `nil` key yields an empty `userInfo` (no reveal target).
///
/// `#if`-unguarded (a pure `[String: String]` derivation) so it compiles + tests on every platform; the
/// key string is duplicated here as a `String` literal-free reference only on macOS where the router
/// type exists, so the helper takes the key as a parameter to stay portable.
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
    public let capacity: Double
    public let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: TimeInterval

    public init(capacity: Double = 5, refillPerSecond: Double = 0.5, now: TimeInterval) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        tokens = capacity
        lastRefill = now
    }

    /// Refills by elapsed time then consumes a token if one is available. Returns whether the
    /// notification is allowed (a burst beyond `capacity` is dropped until tokens refill).
    public mutating func allow(now: TimeInterval) -> Bool {
        tokens = min(capacity, tokens + max(0, now - lastRefill) * refillPerSecond)
        lastRefill = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

#if os(macOS)
import UserNotifications

/// Posts a LOCAL macOS notification when a LONG-running command completes (OSC 133;D with a
/// duration ≥ ``CommandNotificationPolicy/longRunningThresholdMS``). Best-effort, lazy-auth:
///
/// - **Lazy authorization:** `requestAuthorization` is called on the FIRST long-command
///   completion, not at launch, so a user who never runs a long command is never prompted.
/// - **Best-effort:** if authorization is denied or unavailable we simply do nothing — the
///   in-app running indicator (the PRIMARY deliverable) is unaffected.
/// - **macOS-only:** the whole type is `#if os(macOS)` and its sole call site is guarded too,
///   so iOS still builds. (`UNUserNotificationCenter` exists on iOS, but this deliverable is
///   scoped to the macOS workspace; dropping the guard later makes it portable.)
///
/// `@MainActor final class` because it caches authorization state across calls and is invoked
/// from the `@MainActor` ``ConnectionViewModel`` events loop. (A class — not a struct — so the
/// authorization cache mutated from the async `requestAuthorization` callback survives.)
@MainActor
final class CommandCompletionNotifier {
    /// Cached authorization result so we do not re-`requestAuthorization` on every long command
    /// (the OS only prompts once, but caching avoids the repeated round-trip and lets a denied
    /// user fall straight through). `nil` until the first request resolves.
    private var granted: Bool?

    /// Anti-flood limiter for EXPLICIT (OSC 9/777) notifications — a hostile remote process could
    /// otherwise post unboundedly. ~5 burst, then ~1 per 2s. (The long-command path is naturally
    /// rate-limited by the ~10s threshold, so it is not gated.)
    private var explicitLimiter = NotificationRateLimiter(now: ProcessInfo.processInfo.systemUptime)

    init() {}

    /// Posts a "command finished" notification IFF `durationMS` clears the long-running threshold. A
    /// no-op for quick commands. The B3 focus gate (unfocused + enabled) is applied UPSTREAM in
    /// ``WorkspaceStore`` so the store's focus state drives it; this poster keeps only the threshold
    /// floor as a defence-in-depth guard. `paneIDKey` (the originating pane's id string) is embedded in
    /// the notification's `userInfo` so a click reveals that pane via ``PaneNotificationRouter`` — `nil`
    /// ⇒ no reveal target (e.g. an unresolved pane).
    func notifyIfLong(paneTitle: String, exitCode: Int32?, durationMS: UInt32, paneIDKey: String? = nil) {
        guard CommandNotificationPolicy.shouldNotify(durationMS: durationMS) else { return }

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

    /// Builds + adds the notification request — a no-op unless authorization was granted. Embeds
    /// `paneIDKey` in `userInfo` (via the pure ``LongCommandNotificationUserInfo``) so a click reveals
    /// the originating pane.
    private func post(paneTitle: String, exitCode: Int32?, durationMS: UInt32, paneIDKey: String?) {
        guard granted == true else { return }
        let content = UNMutableNotificationContent()
        content.title = paneTitle.isEmpty ? "Command finished" : paneTitle
        let secs = Int((Double(durationMS) / 1000).rounded())
        content.body = "command finished (exit \(exitCode.map(String.init) ?? "?"), \(secs)s)"
        content.userInfo = LongCommandNotificationUserInfo.make(
            paneIDUserInfoKey: PaneNotificationRouter.paneIDUserInfoKey, paneIDKey: paneIDKey,
        )
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Posts an EXPLICIT (OSC 9 / OSC 777) child-requested notification, carrying `paneIDKey` in
    /// `userInfo` so a click can focus the originating pane (see ``PaneNotificationRouter``). Lazy-auth
    /// + best-effort like the long-command path; resolves the title fallback via the pure
    /// ``ExplicitNotificationContent``.
    func notifyExplicit(paneIDKey: String, paneTitle: String, title: String, body: String) {
        // Anti-flood: drop a notification that exceeds the burst/refill budget (a hostile process must
        // not be able to bury the user under alerts). Checked BEFORE auth so a flood can't even trigger
        // the first auth prompt repeatedly.
        guard explicitLimiter.allow(now: ProcessInfo.processInfo.systemUptime) else { return }
        let resolved = ExplicitNotificationContent.resolve(paneTitle: paneTitle, explicitTitle: title, body: body)
        if granted != nil {
            postExplicit(paneIDKey: paneIDKey, title: resolved.title, body: resolved.body)
        } else {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                Task { @MainActor [weak self] in
                    self?.granted = ok
                    self?.postExplicit(paneIDKey: paneIDKey, title: resolved.title, body: resolved.body)
                }
            }
        }
    }

    /// Adds the explicit-notification request — a no-op unless authorization was granted.
    private func postExplicit(paneIDKey: String, title: String, body: String) {
        guard granted == true else { return }
        let content = UNMutableNotificationContent()
        // The title/body originate from untrusted PTY output (OSC 9/777); mask any secret before it is
        // archived in Notification Center (a banner outlives the command). Gated as an opt-out.
        let redact = SettingsKey.redactSecretsEnabled
        content.title = redact ? SecretRedactor.redact(title) : title
        content.body = redact ? SecretRedactor.redact(body) : body
        content.userInfo = [PaneNotificationRouter.paneIDUserInfoKey: paneIDKey]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// Routes a clicked notification (its `userInfo` pane-id) to a reveal closure the app wires to the
/// store (focus + centre the originating pane). The app installs it as the
/// `UNUserNotificationCenterDelegate` at launch; the key + parsing live here so they are one source
/// of truth shared with ``CommandCompletionNotifier``.
@preconcurrency
@MainActor
public final class PaneNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// The `userInfo` key carrying the originating pane's id string. `nonisolated` so the
    /// `nonisolated` delegate methods (and the poster) can read it without a main-actor hop.
    public nonisolated static let paneIDUserInfoKey = "aislopdesk.paneID"

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
#endif
