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
    public static let longRunningThresholdMS: UInt32 = 10_000

    /// The pure decision: notify iff the host-measured C→D duration is at least the threshold.
    /// `>=` so a command that took exactly the threshold notifies (and `sleep 12` clearly does).
    public static func shouldNotify(durationMS: UInt32) -> Bool {
        durationMS >= longRunningThresholdMS
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

    init() {}

    /// Posts a "command finished" notification IFF `durationMS` clears the long-running
    /// threshold. A no-op for quick commands. TODO(B3): gate on the app/pane being UNFOCUSED so
    /// a foreground long command does not spam — left off for now so WF11 acceptance (which
    /// expects the notification with the window up) can observe it.
    func notifyIfLong(paneTitle: String, exitCode: Int32?, durationMS: UInt32) {
        guard CommandNotificationPolicy.shouldNotify(durationMS: durationMS) else { return }

        if granted != nil {
            // Already resolved — post (or no-op if denied) without re-prompting.
            post(paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS)
        } else {
            // Lazy authorization on the first long command. The completion handler is nonisolated
            // (Network/UN callback queue); hop back to the main actor carrying only Sendable values
            // (the Bool + the notification's primitive fields) so there is no cross-actor capture
            // of self until we are back on the main actor.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                Task { @MainActor [weak self] in
                    self?.granted = ok
                    self?.post(paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS)
                }
            }
        }
    }

    /// Builds + adds the notification request — a no-op unless authorization was granted.
    private func post(paneTitle: String, exitCode: Int32?, durationMS: UInt32) {
        guard granted == true else { return }
        let content = UNMutableNotificationContent()
        content.title = paneTitle.isEmpty ? "Command finished" : paneTitle
        let secs = Int((Double(durationMS) / 1000).rounded())
        content.body = "command finished (exit \(exitCode.map(String.init) ?? "?"), \(secs)s)"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
#endif
