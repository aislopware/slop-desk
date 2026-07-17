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
    /// History-state gating (`SLOPDESK_SWIPE_NAV_HISTORY`, default ON; `=0` skips the AX
    /// Back/Forward read entirely — every push ships `historyKnown=false` and the client fails
    /// open to the pre-gate behavior).
    public static let historyGate = EnvConfig.boolDefaultOn("SLOPDESK_SWIPE_NAV_HISTORY")

    /// Whether a qualifying swipe aimed at `bundleID` would be translated right now — the
    /// single eligibility rule both the fire path and the status push apply.
    public static func eligible(bundleID: String?) -> Bool {
        enabled && SwipeNavPolicy.isNavigable(bundleID: bundleID, extraApps: extraApps)
    }

    /// The status message describing this operating point for one target app. `history` is
    /// the target's AX Back/Forward availability, nil when unknown (fail open — doc 20 §9.6).
    public static func status(bundleID: String?, history: NavHistoryFlags?) -> SwipeNavStatusMessage {
        message(eligible: eligible(bundleID: bundleID), history: history)
    }

    /// An ineligible push zeroes the history bits: the client ignores them behind a dark chip,
    /// and a canonical all-zero tail keeps "ineligible" byte-identical regardless of what the
    /// AX read happened to say.
    private static func message(eligible: Bool, history: NavHistoryFlags?) -> SwipeNavStatusMessage {
        SwipeNavStatusMessage(
            eligible: eligible,
            slowTier: slowTier,
            fireTravel: UInt16(fireTravel), // clamped [20, 500] — always fits
            canGoBack: eligible && (history?.canGoBack ?? false),
            canGoForward: eligible && (history?.canGoForward ?? false),
            historyKnown: eligible && history != nil,
        )
    }

    /// WINDOW-scoped eligibility (pid > 0 sessions): the pane's app must be navigable AND
    /// actually frontmost. The fire path gates the chord on live focus (a HID-tap post lands
    /// in the OS key-focus holder — ``InputInjector/fireSwipeNav`` suppresses + raises on a
    /// mismatch), so the chip must go dark on the same condition or the affordance LIES: a
    /// committed chip + haptic for a fire the host silently swallows. Bundle-id equality is
    /// the same-app proxy the push has (the kicker fans out a bundle id, not a pid); the
    /// ≤ 2 s heartbeat staleness matches the display-session eligibility path.
    public static func eligibleWindowTarget(paneBundleID: String?, frontmostBundleID: String?) -> Bool {
        guard let paneBundleID, let frontmostBundleID else { return false }
        return eligible(bundleID: paneBundleID) && frontmostBundleID == paneBundleID
    }

    /// The status message for one WINDOW-scoped session (see ``eligibleWindowTarget``). The
    /// history flags come from the FRONTMOST app's AX read — eligibility requires pane ==
    /// frontmost, so whenever they matter they describe the pane's own app.
    public static func windowStatus(
        paneBundleID: String?, frontmostBundleID: String?, history: NavHistoryFlags?,
    ) -> SwipeNavStatusMessage {
        message(
            eligible: eligibleWindowTarget(paneBundleID: paneBundleID, frontmostBundleID: frontmostBundleID),
            history: history,
        )
    }
}

/// One AX read of a target app's history availability (``HostNavHistory``): can ⌘[ / ⌘]
/// navigate right now? Ungated (pure value) so the config mapping stays testable everywhere;
/// only the reader that PRODUCES it is macOS-only.
public struct NavHistoryFlags: Equatable, Sendable {
    public var canGoBack: Bool
    public var canGoForward: Bool

    public init(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}
