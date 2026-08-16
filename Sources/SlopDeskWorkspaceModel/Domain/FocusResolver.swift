import CSlopDeskFFI
import Foundation

// MARK: - Geometric focus resolution

/// Resolves focus movement against the **solved rects the user actually sees** (docs/22 §1.3,
/// §2.1) — never against abstract tree position. Because it consumes the same ``SolvedLayout``
/// the layout renders, "move focus left" always lands on the pane that is visually to the left,
/// even in deeply / unevenly nested trees.
///
/// The resolution itself is `rust/slopdesk-workspace`'s `focus` (docs/55). The two-key tie-break
/// that makes navigation feel right — most cross-axis overlap first, then nearest along the movement
/// axis — and the id tie-break under it are one rule, and the CLI's `pane focus` walks the same
/// frames. Two copies would mean `⌘⌥←` could land somewhere different depending on who asked.
public enum FocusResolver {
    /// The pane adjacent to `pane` in direction `dir`, resolved geometrically — or `nil` when
    /// there is none (an edge, or `pane`/the layout is empty).
    ///
    /// - `.left/.right/.up/.down`: the nearest candidate strictly on the requested side, preferring
    ///   the one whose **cross-axis span overlaps** the source the most. That is what makes you
    ///   cross into the pane you are "pointing at" rather than the closest centroid.
    /// - `.next/.previous`: cycles the layout's frames in reading order. Callers that need the
    ///   tree's pre-order should pass `allLeafIDs()` to ``cycle(_:from:forward:)`` directly.
    public static func neighbor(of pane: PaneID, _ dir: FocusDirection, in solved: SolvedLayout) -> PaneID? {
        // Sorted by id so the array the crate sees is the same array every call: the solver's own
        // ordering is total, but a dictionary's iteration order is not an input worth having.
        var frames = solved.frames
            .map { SlopDeskWsFrame(id: $0.key.ffi, rect: SlopDeskWsRect($0.value)) }
            .sorted { lhs, rhs in lhs.id.uuid.uuidString < rhs.id.uuid.uuidString }
        var answer = SlopDeskWsUuid(bytes: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let found = frames.withUnsafeMutableBufferPointer { buffer in
            slopdesk_ws_focus_neighbor(buffer.baseAddress, buffer.count, pane.ffi, dir.ffiByte, &answer)
        }
        return found ? PaneID(ffi: answer) : nil
    }

    /// Cycles through `leaves` from `from`, wrapping at either end. `nil` when `from` is not among
    /// them, which is the answer that keeps a stale focus from silently jumping to pane zero.
    public static func cycle(_ leaves: [PaneID], from: PaneID, forward: Bool) -> PaneID? {
        var ids = leaves.map(\.ffi)
        var answer = SlopDeskWsUuid(bytes: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let found = ids.withUnsafeMutableBufferPointer { buffer in
            slopdesk_ws_focus_cycle(buffer.baseAddress, buffer.count, from.ffi, forward, &answer)
        }
        return found ? PaneID(ffi: answer) : nil
    }
}
