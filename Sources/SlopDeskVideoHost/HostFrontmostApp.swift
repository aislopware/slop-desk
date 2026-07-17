#if os(macOS)
import AppKit
import CoreGraphics

/// The daemon-safe "which app is frontmost on this host" read.
///
/// `NSWorkspace.shared.frontmostApplication` is a per-process SNAPSHOT: it populates on the
/// first access and then updates only via AppKit run-loop machinery this daemon never pumps —
/// so every later read returns the first-access app forever (probe-verified: with Chrome
/// frontmost, a daemon launched from Terminal read `com.apple.Terminal` on every call, on and
/// off the main thread, while a side-by-side `CGWindowListCopyWindowInfo` scan tracked
/// Chrome→Finder→Chrome flips live). That freeze made the swipe-nav status push report
/// `eligible=false` for the daemon's whole life, and left the fire path's allowlist check
/// correct only by luck of first-access ordering.
///
/// This helper queries the WindowServer directly instead — fresh on every call, no run loop
/// needed, covered by the TCC the capture daemon already holds. The frontmost app is the owner
/// of the first normal-level (layer 0), visible window in the front-to-back on-screen list;
/// the pure scan is separated (`frontmostOwnerPID(in:)`) so the z-order/layer/alpha rules stay
/// unit-testable without a WindowServer connection.
public enum HostFrontmostApp {
    /// One on-screen window's routing-relevant fields, decoded from a
    /// `CGWindowListCopyWindowInfo` record (nil fields = record was missing/malformed them).
    public struct WindowRecord {
        public var layer: Int?
        public var ownerPID: pid_t?
        public var alpha: Double?

        public init(layer: Int?, ownerPID: pid_t?, alpha: Double?) {
            self.layer = layer
            self.ownerPID = ownerPID
            self.alpha = alpha
        }
    }

    /// The pure per-record frontmost rule: a fully-described window at normal level (layer 0)
    /// with any visible alpha elects its owner. Records missing a field never elect
    /// (validate-then-drop — a malformed record must never elect a frontmost app);
    /// overlay/panel levels (layer ≠ 0) and fully transparent windows never count.
    public static func electedOwnerPID(of window: WindowRecord) -> pid_t? {
        guard let layer = window.layer, layer == 0,
              let pid = window.ownerPID, pid > 0,
              let alpha = window.alpha, alpha > 0 else { return nil }
        return pid
    }

    /// The frontmost rule over a front-to-back window list: the first electing record wins.
    public static func frontmostOwnerPID(in windows: [WindowRecord]) -> pid_t? {
        for window in windows {
            if let pid = electedOwnerPID(of: window) { return pid }
        }
        return nil
    }

    /// The frontmost app's pid, fresh from the WindowServer. `nil` when the query fails or no
    /// normal-level window is on screen (login/lock screen, display asleep).
    ///
    /// Decodes records ONE at a time and stops at the first elected pid — the swipe-nav kicker
    /// calls this at 4 Hz for the daemon's whole life, and the frontmost window sits at the
    /// head of the front-to-back list past a handful of overlay layers, so deep-bridging every
    /// on-screen window's full record each tick paid a per-tick cost that scaled with how many
    /// windows the desktop had open (profile: ~30% of the query's samples were the bridge).
    public static func frontmostPID() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID,
        ) else { return nil }
        // The NS views are toll-free wrappers over the CF list — bridging to [[String: Any]]
        // would deep-copy every record and defeat the early stop.
        // swiftlint:disable:next legacy_objc_type
        for case let info as NSDictionary in list as NSArray {
            let record = WindowRecord(
                layer: info[kCGWindowLayer] as? Int,
                ownerPID: (info[kCGWindowOwnerPID] as? Int32).map { pid_t($0) },
                alpha: info[kCGWindowAlpha] as? Double,
            )
            if let pid = electedOwnerPID(of: record) { return pid }
        }
        return nil
    }

    /// The frontmost app's bundle identifier, fresh from the WindowServer. `nil` when no
    /// normal-level window is on screen at all (bare desktop, login/lock transitions, display
    /// asleep) — deliberately NO `NSWorkspace` fallback: in this daemon that snapshot is FROZEN
    /// at first access (the very bug this type exists to fix), and the no-window case is
    /// precisely where a fallback would fire. `nil` flows into `SwipeNavPolicy.isNavigable`'s
    /// nil ⇒ false at every caller, so both the status push and the fire path fail CLOSED
    /// (chip dark, no chord) instead of fail-frozen.
    public static func bundleID() -> String? {
        guard let pid = frontmostPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Pid + bundle id from ONE WindowServer query — for callers that need both (the swipe-nav
    /// status kicker resolves the bundle for eligibility and feeds the pid to the AX history
    /// read). Same fail-closed nil semantics as ``bundleID()``.
    public static func frontmost() -> (pid: pid_t, bundleID: String?)? {
        guard let pid = frontmostPID() else { return nil }
        return (pid, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }
}
#endif
