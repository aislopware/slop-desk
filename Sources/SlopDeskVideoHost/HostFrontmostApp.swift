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

    /// The pure frontmost rule over a front-to-back window list: the first fully-described
    /// window at normal level (layer 0) with any visible alpha wins. Records missing a field
    /// are skipped (validate-then-drop — a malformed record must never elect a frontmost app);
    /// overlay/panel levels (layer ≠ 0) and fully transparent windows never count.
    public static func frontmostOwnerPID(in windows: [WindowRecord]) -> pid_t? {
        for window in windows {
            guard let layer = window.layer, layer == 0,
                  let pid = window.ownerPID, pid > 0,
                  let alpha = window.alpha, alpha > 0 else { continue }
            return pid
        }
        return nil
    }

    /// The frontmost app's pid, fresh from the WindowServer. `nil` when the query fails or no
    /// normal-level window is on screen (login/lock screen, display asleep).
    public static func frontmostPID() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID,
        ) as? [[String: Any]] else { return nil }
        let records = list.map { info in
            WindowRecord(
                layer: info[kCGWindowLayer as String] as? Int,
                ownerPID: (info[kCGWindowOwnerPID as String] as? Int32).map { pid_t($0) },
                alpha: info[kCGWindowAlpha as String] as? Double,
            )
        }
        return frontmostOwnerPID(in: records)
    }

    /// The frontmost app's bundle identifier, fresh from the WindowServer. Falls back to the
    /// `NSWorkspace` snapshot only when the WindowServer query yields nothing at all — inside a
    /// GUI app that snapshot is live, and in the daemon a frozen answer still beats none for a
    /// best-effort affordance (the fire path re-checks at fire time either way).
    public static func bundleID() -> String? {
        if let pid = frontmostPID() {
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
#endif
