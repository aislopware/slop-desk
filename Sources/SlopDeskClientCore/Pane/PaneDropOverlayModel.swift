// PaneDropOverlayModel — the per-pane drag state a drop overlay renders from.
//
// Split out of `PaneDropReceiver` when the client's presentation logic left the view target
// (docs/56). The DELEGATE is framework-shaped — SwiftUI's `DropDelegate` on a Mac, a
// `UIDropInteractionDelegate` on a phone — but what it drives is not: a classified payload, the zone
// under the cursor, and the generation counter that makes a late classify unable to strand the
// overlay. That last one is a race guard, and a race guard written twice is a race guard that is
// right once.

import Observation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The per-pane drag state the overlay renders from and the receiver mutates: the classified payload of the
/// in-flight drag (`nil` when nothing supported is hovering) + the zone the cursor is currently over.
/// `@MainActor @Observable` so the overlay re-renders as the cursor moves between
/// zones; held per-pane by the pane container each shell mounts (``SlopDeskMacUI/MacPaneContainer`` /
/// ``SlopDeskPhoneUI/PaneContainerView``), keyed by `PaneID`.
@MainActor
@Observable
package final class PaneDropOverlayModel {
    package init() {}

    /// The classified content of the drag hovering THIS pane, or `nil` when no supported drag is over it.
    /// Drives ``isActive`` (overlay visibility) and ``allowedZones`` (which blobs can light up).
    package var content: DroppedContent?

    /// The zone the cursor is over RIGHT NOW — only ever an *allowed* zone (the receiver refuses to set a
    /// disabled one), or `nil` when the cursor is in a gap between zones. The overlay saturates this one.
    package var activeZone: DropZone?

    /// Monotonically-increasing token stamped on each new drag entry (`beginClassification`) and bumped on
    /// every `reset()` (drop committed / cursor left). The async pasteboard classify captures the value live
    /// at `dropEntered`; if a `reset()` bumped it before the classify resolves, the late write is recognised
    /// as STALE and dropped (``applyClassified(_:generation:)``). Without this guard a slow `.url`/`.text`
    /// provider load — or a fast enter→exit — would re-set `content` AFTER the overlay was cleared, flipping
    /// ``isActive`` back to `true` and stranding the full-pane overlay faded-in with no drag present (the
    /// post-reset async-race class — cf. the present-storm / identity-churn lessons).
    package private(set) var generation: Int = 0

    /// Whether the overlay should be shown — a supported drag is hovering this pane.
    package var isActive: Bool { content != nil }

    /// The zones the current content can act on (the others render muted + non-targetable). Derived from the
    /// pure policy table so the overlay gating can never drift from ``DropActionResolver/resolve(zone:content:)``.
    package var allowedZones: Set<DropZone> {
        guard let content else { return [] }
        return DropActionResolver.allowedZones(for: content)
    }

    /// Begin a new classification cycle: bump ``generation`` and hand the new current value back for the
    /// caller's async `Task` to capture. Only a classify whose captured generation still equals the live
    /// ``generation`` may write ``content`` (see ``applyClassified(_:generation:)``).
    package func beginClassification() -> Int {
        generation &+= 1
        return generation
    }

    /// Apply a freshly-classified `content` IFF the stamping `generation` is still current — the post-reset
    /// async-race guard. The `dropEntered` classify `Task` captures the generation from
    /// ``beginClassification()`` and calls this on completion; if a `reset()` bumped the generation meanwhile
    /// (the drag committed or left the pane), the write is DROPPED so a late classify can never re-activate
    /// the overlay after it was cleared.
    package func applyClassified(_ content: DroppedContent?, generation: Int) {
        guard generation == self.generation else { return }
        self.content = content
    }

    /// Clear the drag state (drop finished / cursor left the pane) so the overlay fades out. Bumps
    /// ``generation`` so any classify still in flight is invalidated (a late resolve can't strand the overlay).
    package func reset() {
        content = nil
        activeZone = nil
        generation &+= 1
    }
}
