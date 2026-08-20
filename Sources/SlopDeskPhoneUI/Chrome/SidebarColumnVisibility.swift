// SidebarColumnVisibility — the two-way map between the shared `chrome.sidebarCollapsed` flag and the
// phone shell's `NavigationSplitView` column visibility.
//
// It reads as iOS-only and it is not: `NavigationSplitViewVisibility` exists on macOS too, so keeping
// this pair OUT of the iOS-gated root view is what keeps the mapping inside the macOS `swift test`
// gate rather than only inside the iOS compile. The DECISION on the setter side (recording a manual
// override so the auto-hide policy stops fighting a swipe) is
// ``WorkspaceChromePolicy/applySidebarCollapsed(_:chrome:)``; what lives here is the two-column
// shell's own reading of a visibility value.

#if os(iOS)
import SlopDeskClientCore
import SwiftUI

@MainActor
enum SidebarColumnVisibility {
    /// Pure map from the shared `sidebarCollapsed` flag to the column visibility: collapsed →
    /// `.detailOnly` (a TWO-column shell now the inspector is removed, so "everything but the sidebar" is
    /// the detail alone), revealed → `.all`.
    static func visibility(sidebarCollapsed: Bool) -> NavigationSplitViewVisibility {
        sidebarCollapsed ? .detailOnly : .all
    }

    /// The setter side: `.detailOnly` is the only "sidebar hidden" value, since `.doubleColumn` shows BOTH
    /// columns of a two-column split. A genuine swipe is recorded as a manual override; the binding echo
    /// SwiftUI fires when the getter-derived value is written back unchanged is not (the policy's own `!=`
    /// guard).
    static func apply(_ visibility: NavigationSplitViewVisibility, chrome: WorkspaceChromeState) {
        WorkspaceChromePolicy.applySidebarCollapsed(visibility == .detailOnly, chrome: chrome)
    }
}
#endif
