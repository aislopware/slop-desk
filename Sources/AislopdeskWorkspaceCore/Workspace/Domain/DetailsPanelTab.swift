import Foundation

// MARK: - DetailsPanelTab (the cross-module Details-panel tab vocabulary)

/// The three tabs of the right-hand Details / inspector panel: Info | Git | Files.
///
/// This is the shared vocabulary the COMMAND layer (``WorkspaceAction/selectDetailsTab(_:)`` + its
/// `Details: *` registry bindings) and the VIEW layer (the client UI's segmented Details header + the
/// `@Observable` selection state) both speak — `AislopdeskWorkspaceCore` cannot see the client UI's
/// view-local tab enum, so the tab identity is hoisted here (E9/WI-7, ES-E9-5). A pure value enum (no
/// SwiftUI / view import) so the `selectDetailsTab` routing is fully unit-testable with no view.
///
/// The old standalone Outline tab was MERGED into the Info tab's Commands section (its per-row jump +
/// relative timestamps now live on the Commands navigator rows) — one command list instead of two.
///
/// The `String` raw values double as the stable on-the-wire-free tab ids the view reads, and the
/// `CaseIterable` order is the canonical tab order (Info first, then Git / Files).
public enum DetailsPanelTab: String, CaseIterable, Sendable {
    case info
    case git
    case files
}
