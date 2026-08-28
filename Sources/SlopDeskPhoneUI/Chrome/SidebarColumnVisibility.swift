// SidebarColumnVisibility — the two-way map between the shared `chrome.sidebarCollapsed` flag and the
// phone shell's `NavigationSplitView` column visibility.
//
// It is a separate file from the root view so the mapping can be asserted on its own — by
// `Apps/ClientApp-iOS/Tests/SidebarAutoHideWiringTests`, which is the ONLY thing that reaches it: this
// file is `#if os(iOS)`, so `swift test` compiles none of it and `just check-ios-tests` is its whole
// coverage. The DECISION on the setter side (recording a manual
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
