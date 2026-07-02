// DetailsPanelState — the small @Observable model that owns the right-hand Details panel's SELECTED TAB
// (E9/WI-7). Sibling of `WorkspaceChromeState`.
//
// The Details-tab selection was a private `@State` inside `InspectorColumn`, so it could not be driven from
// outside the view — but the app exposes bindable `Details: *` jump commands (ES-E9-5) that switch the
// tab. Hoisting the selection into this shared `@Observable` lets `WorkspaceRootView` install a
// `selectDetailsTab` closure that writes `selected` (and reveals the panel) when a command routes through
// `WorkspaceBindingRegistry.route`, while `InspectorColumn` reads `selected` to render the active tab — one
// instance shared by both inspector mounts (the macOS split item + the iOS detail column).
//
// `selected` defaults to `.info` (the resting Details tab) and is the cross-module `DetailsPanelTab`, the
// SAME vocabulary the `selectDetailsTab(_:)` action carries — so there is ONE source of truth for "which tab".

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import Foundation

@MainActor
@Observable
final class DetailsPanelState {
    /// The currently-selected Details / inspector tab (Info | Files). Written by the
    /// segmented header click AND by the `Details: *` jump commands (via the root view's installed
    /// `selectDetailsTab` closure); read by `InspectorColumn` to render the active tab.
    var selected: DetailsPanelTab = .info
}
#endif
