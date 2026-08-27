import CSlopDeskFFI
import SlopDeskVideoProtocol

/// The host process's swipe-nav operating point — ONE parse of the `SLOPDESK_SWIPE_NAV*`
/// env family, shared by the ``InputInjector`` (which fires ⌘[/⌘]) and the
/// ``SwipeNavStatusMessage`` push (which tells the client's peel-feedback mirror what the
/// host will actually do). Two parses could drift and make the feedback lie.
///
/// A face over `rust/slopdesk-ffi`'s `swipe_nav_config`, and the one place in the repo that
/// owns the handle: this namespace is process-lifetime and never copied, which is what makes a
/// handle the right shape here where the input ledger and the scroll accumulator cross by value
/// (`docs/55` §4b). The allowlist EXTENSION — a set of bundle ids — is why no fold of scalars
/// could carry it. Nothing frees it; the parse outlives every caller by construction.
public enum SwipeNavHostConfig {
    /// The parsed operating point. Every value crosses as its raw bytes with NULL meaning UNSET,
    /// so the whole default family — including which knobs default ON — is spelled once, over
    /// there. The reads go through ``EnvConfig`` (ProcessInfo → settings overlay) so a GUI
    /// setting drives them identically to an exported variable.
    /// `nonisolated(unsafe)` because the pointer is written once, by the first reader, and every
    /// door behind it only READS the parse — there is no mutable state on either side of the
    /// boundary to race over, and nothing ever frees it.
    private nonisolated(unsafe) static let handle: OpaquePointer? = {
        let values = [
            EnvConfig.string("SLOPDESK_SWIPE_NAV"), EnvConfig.string("SLOPDESK_SWIPE_NAV_APPS"),
            EnvConfig.string("SLOPDESK_SWIPE_NAV_TRAVEL"), EnvConfig.string("SLOPDESK_SWIPE_NAV_SLOW"),
            EnvConfig.string("SLOPDESK_SWIPE_NAV_HISTORY"),
        ]
        return withSettings(values) { slots in
            slopdesk_swipe_nav_config_parse(
                slots[0].base, slots[0].count, slots[1].base, slots[1].count,
                slots[2].base, slots[2].count, slots[3].base, slots[3].count,
                slots[4].base, slots[4].count,
            )
        }
    }()

    /// SWIPE-BACK TRANSLATION master switch (`SLOPDESK_SWIPE_NAV`, default ON; `=0` off). Read
    /// only where the fire path exits before it has a target app — ``eligible(bundleID:)``
    /// already carries it everywhere else.
    public static var enabled: Bool { slopdesk_swipe_nav_config_enabled(handle) }
    /// Lift-fire travel threshold in points (`SLOPDESK_SWIPE_NAV_TRAVEL`, default 80, clamped
    /// [20, 500]) — scales the recogniser's whole threshold family.
    public static var fireTravel: Double { slopdesk_swipe_nav_config_fire_travel(handle) }
    /// Slow-tier acceptance (`SLOPDESK_SWIPE_NAV_SLOW`, default ON; `=0` restores the v2
    /// flick-only duration gate).
    public static var slowTier: Bool { slopdesk_swipe_nav_config_slow_tier(handle) }
    /// History-state gating (`SLOPDESK_SWIPE_NAV_HISTORY`, default ON; `=0` skips the AX
    /// Back/Forward read entirely — every push ships `historyKnown=false` and the client fails
    /// open to the pre-gate behavior).
    public static var historyGate: Bool { slopdesk_swipe_nav_config_history_gate(handle) }

    /// Whether a qualifying swipe aimed at `bundleID` would be translated right now — the
    /// single eligibility rule both the fire path and the status push apply.
    public static func eligible(bundleID: String?) -> Bool {
        withSettings([bundleID]) { slots in
            slopdesk_swipe_nav_config_eligible(handle, slots[0].base, slots[0].count)
        }
    }

    /// The status message describing this operating point for one target app. `history` is
    /// the target's AX Back/Forward availability, nil when unknown (fail open — doc 20 §9.6).
    /// The ineligible push's canonical all-zero tail is the door's rule, not this face's.
    public static func status(bundleID: String?, history: NavHistoryFlags?) -> SwipeNavStatusMessage {
        let flat = withSettings([bundleID]) { slots in
            slopdesk_swipe_nav_config_status(
                handle, slots[0].base, slots[0].count, history != nil,
                history?.canGoBack ?? false, history?.canGoForward ?? false,
            )
        }
        return SwipeNavStatusMessage(wire: flat)
    }

    /// WINDOW-scoped eligibility (pid > 0 sessions): the pane's app must be navigable AND
    /// actually frontmost. The fire path gates the chord on live focus (a HID-tap post lands
    /// in the OS key-focus holder — `fire_swipe_nav` in `rust/slopdesk-ffi/src/injector.rs`
    /// suppresses + raises on a mismatch), so the chip must go dark on the same condition or
    /// the affordance LIES: a
    /// committed chip + haptic for a fire the host silently swallows. Bundle-id equality is
    /// the same-app proxy the push has (the kicker fans out a bundle id, not a pid); the
    /// ≤ 2 s heartbeat staleness matches the display-session eligibility path.
    public static func eligibleWindowTarget(paneBundleID: String?, frontmostBundleID: String?) -> Bool {
        withSettings([paneBundleID, frontmostBundleID]) { slots in
            slopdesk_swipe_nav_config_window_eligible(
                handle, slots[0].base, slots[0].count, slots[1].base, slots[1].count,
            )
        }
    }

    /// The status message for one WINDOW-scoped session (see ``eligibleWindowTarget``). The
    /// history flags come from the FRONTMOST app's AX read — eligibility requires pane ==
    /// frontmost, so whenever they matter they describe the pane's own app.
    public static func windowStatus(
        paneBundleID: String?, frontmostBundleID: String?, history: NavHistoryFlags?,
    ) -> SwipeNavStatusMessage {
        let flat = withSettings([paneBundleID, frontmostBundleID]) { slots in
            slopdesk_swipe_nav_config_window_status(
                handle, slots[0].base, slots[0].count, slots[1].base, slots[1].count,
                history != nil, history?.canGoBack ?? false, history?.canGoForward ?? false,
            )
        }
        return SwipeNavStatusMessage(wire: flat)
    }

    /// One lent string as the door reads it: a NULL base means ABSENT, which is not the same as
    /// a present empty string.
    private struct Lent {
        var base: UnsafePointer<UInt8>?
        var count: Int
    }

    /// Lends every value's UTF-8 bytes for the duration of one call, nil staying NULL. Recursive
    /// so the buffers nest — each one is alive until the innermost body returns. The terminator
    /// keeps every present value's storage non-empty, because an empty `Array`'s base address is
    /// NULL and NULL is how the door spells ABSENT: `SLOPDESK_SWIPE_NAV=` must stay a value.
    private static func withSettings<T>(_ values: [String?], _ body: ([Lent]) -> T) -> T {
        let bytes = values.map { $0.map { Array($0.utf8) + [0] } }
        var lent = [Lent]()
        lent.reserveCapacity(values.count)
        func step(_ index: Int) -> T {
            guard index < bytes.count else { return body(lent) }
            guard let value = bytes[index] else {
                lent.append(Lent(base: nil, count: 0))
                return step(index + 1)
            }
            return value.withUnsafeBufferPointer { buffer in
                lent.append(Lent(base: buffer.baseAddress, count: buffer.count - 1))
                return step(index + 1)
            }
        }
        return step(0)
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
