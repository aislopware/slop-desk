import Foundation
import SlopDeskVideoProtocol

/// The host process's swipe-nav operating point — ONE parse of the `SLOPDESK_SWIPE_NAV*`
/// env family, shared by the ``InputInjector`` (which fires ⌘[/⌘]) and the
/// ``SwipeNavStatusMessage`` push (which tells the client's peel-feedback mirror what the
/// host will actually do). Two parses could drift and make the feedback lie.
public enum SwipeNavHostConfig {
    /// SWIPE-BACK TRANSLATION master switch (`SLOPDESK_SWIPE_NAV`, default ON; `=0` off).
    public static let enabled = EnvConfig.boolDefaultOn("SLOPDESK_SWIPE_NAV")
    /// Extra bundle ids for the allowlist (`SLOPDESK_SWIPE_NAV_APPS`, comma-separated).
    public static let extraApps = SwipeNavPolicy.extraApps(from: EnvConfig.string("SLOPDESK_SWIPE_NAV_APPS"))
    /// Lift-fire travel threshold in points (`SLOPDESK_SWIPE_NAV_TRAVEL`, default 80, clamped
    /// [20, 500]) — scales the recogniser's whole threshold family.
    public static let fireTravel = SwipeNavPolicy.fireTravel(fromEnv: EnvConfig.string("SLOPDESK_SWIPE_NAV_TRAVEL"))
    /// Slow-tier acceptance (`SLOPDESK_SWIPE_NAV_SLOW`, default ON; `=0` restores the v2
    /// flick-only duration gate).
    public static let slowTier = EnvConfig.boolDefaultOn("SLOPDESK_SWIPE_NAV_SLOW")

    /// Whether a qualifying swipe aimed at `bundleID` would be translated right now — the
    /// single eligibility rule both the fire path and the status push apply.
    public static func eligible(bundleID: String?) -> Bool {
        enabled && SwipeNavPolicy.isNavigable(bundleID: bundleID, extraApps: extraApps)
    }

    /// The status message describing this operating point for one target app.
    public static func status(bundleID: String?) -> SwipeNavStatusMessage {
        SwipeNavStatusMessage(
            eligible: eligible(bundleID: bundleID),
            slowTier: slowTier,
            fireTravel: UInt16(fireTravel), // clamped [20, 500] — always fits
        )
    }
}
