import Foundation
import CoreGraphics

// MARK: - Geometric focus resolution

/// Resolves focus movement against the **solved rects the user actually sees** (docs/22 §1.3,
/// §2.1) — never against abstract tree position. Because it consumes the same ``SolvedLayout``
/// the layout renders, "move focus left" always lands on the pane that is visually to the left,
/// even in deeply / unevenly nested trees. Pure and free of SwiftUI; this is where tmux-style
/// navigation fidelity is pinned (docs/22 §8 `FocusResolverTests`).
public enum FocusResolver {
    /// The pane adjacent to `pane` in direction `dir`, resolved geometrically — or `nil` when
    /// there is none (an edge, or `pane`/the layout is empty).
    ///
    /// - `.left/.right/.up/.down`: pick the nearest candidate strictly on the requested side,
    ///   preferring the one whose **cross-axis span overlaps** the source the most, then the one
    ///   closest along the movement axis. This two-key tie-break is what makes navigation feel
    ///   right when neighbours are unevenly sized (you cross into the pane you are "pointing at",
    ///   not merely the geometrically closest centroid).
    /// - `.next/.previous`: delegates to ``cycle(_:from:forward:)`` over the layout's leaves
    ///   (frame order is not defined for cycling; callers that need pre-order cycling should pass
    ///   the tree's `allLeafIDs()` to `cycle` directly — the directional API resolves `.next` /
    ///   `.previous` as a convenience using the available frames sorted by reading order).
    public static func neighbor(of pane: PaneID, _ dir: FocusDirection, in solved: SolvedLayout) -> PaneID? {
        guard let source = solved.frames[pane] else { return nil }

        switch dir {
        case .next, .previous:
            // Reading-order (top-to-bottom, then left-to-right) cycle over the solved frames.
            let ordered = solved.frames
                .sorted { lhs, rhs in
                    if abs(lhs.value.minY - rhs.value.minY) > 0.5 { return lhs.value.minY < rhs.value.minY }
                    return lhs.value.minX < rhs.value.minX
                }
                .map(\.key)
            return cycle(ordered, from: pane, forward: dir == .next)

        case .left, .right, .up, .down:
            return directionalNeighbor(of: pane, source: source, dir: dir, in: solved)
        }
    }

    /// Cycles through `leaves` from `from`, wrapping at the ends. `.next/.previous` (⌘] / ⌘[, and
    /// the compact swipe) map here. Returns `from` itself if it is the only leaf, or `nil` if
    /// `from` is not in `leaves` / the list is empty.
    public static func cycle(_ leaves: [PaneID], from: PaneID, forward: Bool) -> PaneID? {
        guard !leaves.isEmpty, let i = leaves.firstIndex(of: from) else { return nil }
        let count = leaves.count
        let next = forward ? (i + 1) % count : (i - 1 + count) % count
        return leaves[next]
    }

    // MARK: - Directional pick

    private static func directionalNeighbor(
        of pane: PaneID,
        source: CGRect,
        dir: FocusDirection,
        in solved: SolvedLayout
    ) -> PaneID? {
        var best: (id: PaneID, overlap: CGFloat, distance: CGFloat)?

        for (id, rect) in solved.frames where id != pane {
            guard isOnRequestedSide(candidate: rect, source: source, dir: dir) else { continue }

            let overlap = crossAxisOverlap(candidate: rect, source: source, dir: dir)
            // Candidates that share NO cross-axis span are not "in line" with the source — skip
            // them so e.g. moving right from a top pane doesn't jump to a bottom-right pane that
            // is technically further right but vertically disjoint.
            guard overlap > 0 else { continue }

            let distance = axialDistance(candidate: rect, source: source, dir: dir)

            if let current = best {
                // Prefer more cross-axis overlap; break ties by the smaller axial distance.
                if overlap > current.overlap + 0.5 ||
                    (abs(overlap - current.overlap) <= 0.5 && distance < current.distance) {
                    best = (id, overlap, distance)
                }
            } else {
                best = (id, overlap, distance)
            }
        }
        return best?.id
    }

    /// Whether `candidate` lies strictly on the requested side of `source` (compared by the
    /// leading edge in that direction, so an adjacent pane counts even if rects abut exactly).
    private static func isOnRequestedSide(candidate: CGRect, source: CGRect, dir: FocusDirection) -> Bool {
        switch dir {
        case .left:  return candidate.midX < source.minX + 0.5
        case .right: return candidate.midX > source.maxX - 0.5
        case .up:    return candidate.midY < source.minY + 0.5
        case .down:  return candidate.midY > source.maxY - 0.5
        case .next, .previous: return false
        }
    }

    /// Length of the overlap of `candidate` and `source` along the axis *perpendicular* to the
    /// movement direction (horizontal move → vertical overlap, and vice versa).
    private static func crossAxisOverlap(candidate: CGRect, source: CGRect, dir: FocusDirection) -> CGFloat {
        switch dir {
        case .left, .right:
            // Movement is horizontal → cross axis is vertical (y).
            let lo = max(candidate.minY, source.minY)
            let hi = min(candidate.maxY, source.maxY)
            return max(hi - lo, 0)
        case .up, .down:
            // Movement is vertical → cross axis is horizontal (x).
            let lo = max(candidate.minX, source.minX)
            let hi = min(candidate.maxX, source.maxX)
            return max(hi - lo, 0)
        case .next, .previous:
            return 0
        }
    }

    /// Distance from `source` to `candidate` along the movement axis (gap between facing edges,
    /// clamped at 0 for abutting/overlapping rects).
    private static func axialDistance(candidate: CGRect, source: CGRect, dir: FocusDirection) -> CGFloat {
        switch dir {
        case .left:  return max(source.minX - candidate.maxX, 0)
        case .right: return max(candidate.minX - source.maxX, 0)
        case .up:    return max(source.minY - candidate.maxY, 0)
        case .down:  return max(candidate.minY - source.maxY, 0)
        case .next, .previous: return .greatestFiniteMagnitude
        }
    }
}
