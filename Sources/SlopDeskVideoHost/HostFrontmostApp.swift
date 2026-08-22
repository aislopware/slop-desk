#if os(macOS)
import AppKit
import CSlopDeskFFI

/// The daemon-safe "which app is frontmost on this host" read.
///
/// The election is `rust/slopdesk-apple-cgwindow` + `slopdesk-video`'s `window_list`, reached
/// through ``slopdesk_cgwindow_frontmost_pid``; only the pid → bundle-id resolution is left here,
/// because that one call is `NSRunningApplication`'s and nothing else's.
///
/// `NSWorkspace.shared.frontmostApplication` is deliberately NOT used, for either half. It is a
/// per-process SNAPSHOT: it populates on the first access and then updates only via AppKit
/// run-loop machinery this daemon never pumps — so every later read returns the first-access app
/// forever (probe-verified: with Chrome frontmost, a daemon launched from Terminal read
/// `com.apple.Terminal` on every call, on and off the main thread, while a side-by-side window-list
/// scan tracked Chrome→Finder→Chrome flips live). That freeze made the swipe-nav status push report
/// `eligible=false` for the daemon's whole life, and left the fire path's allowlist check correct
/// only by luck of first-access ordering.
public enum HostFrontmostApp {
    /// The frontmost app's pid, fresh from the WindowServer. `nil` when the query fails or no
    /// normal-level window is on screen (login/lock screen, display asleep).
    public static func frontmostPID() -> pid_t? {
        let pid = slopdesk_cgwindow_frontmost_pid()
        return pid > 0 ? pid_t(pid) : nil
    }

    /// The frontmost app's bundle identifier. `nil` when no normal-level window is on screen at all
    /// — deliberately with NO `NSWorkspace` fallback, since the no-window case is precisely where a
    /// frozen snapshot would fire. `nil` flows into `SwipeNavHostConfig.eligible`'s nil ⇒ false at
    /// every caller, so both the status push and the fire path fail CLOSED (chip dark, no chord)
    /// instead of fail-frozen.
    public static func bundleID() -> String? {
        guard let pid = frontmostPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Pid + bundle id from ONE WindowServer query — for callers that need both (the swipe-nav
    /// status kicker resolves the bundle for eligibility and feeds the pid to the AX history read).
    /// Same fail-closed nil semantics as ``bundleID()``.
    public static func frontmost() -> (pid: pid_t, bundleID: String?)? {
        guard let pid = frontmostPID() else { return nil }
        return (pid, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }
}
#endif
