import Foundation

// MARK: - DetailsPanelTab (the cross-module Details-panel tab vocabulary)

/// The two tabs of the right-hand Details / inspector panel: Info | Files.
///
/// This is the shared vocabulary the COMMAND layer (``WorkspaceAction/selectDetailsTab(_:)`` + its
/// `Details: *` registry bindings) and the VIEW layer (the client UI's segmented Details header + the
/// `@Observable` selection state) both speak — `AislopdeskWorkspaceCore` cannot see the client UI's
/// view-local tab enum, so the tab identity is hoisted here (E9/WI-7, ES-E9-5). A pure value enum (no
/// SwiftUI / view import) so the `selectDetailsTab` routing is fully unit-testable with no view.
///
/// The old standalone Outline tab was MERGED into the Info tab's Commands section (its per-row jump +
/// relative timestamps now live on the Commands navigator rows) — one command list instead of two. The
/// old standalone Git tab was likewise MERGED into Info: the Info tab shows a one-row git summary
/// (branch + change count) and the full status/diff view opens as a popup — the changed-file list is
/// unbounded, so it gets a window, not a sidebar tab.
///
/// The `String` raw values double as the stable on-the-wire-free tab ids the view reads, and the
/// `CaseIterable` order is the canonical tab order (Info first, then Files).
public enum DetailsPanelTab: String, CaseIterable, Sendable {
    case info
    case files
}
