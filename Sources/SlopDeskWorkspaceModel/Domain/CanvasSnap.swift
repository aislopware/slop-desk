import CoreGraphics
import Foundation

// MARK: - CanvasSnap (pure smart-snap solver for canvas drags)

/// Pure smart-snapping for canvas move/resize drags: magnetic alignment against the OTHER panes'
/// edges/centres, standard-gutter adjacency (tiling next to a neighbour with the uniform 16pt gap),
/// the viewport edges/centre, and a background-grid quantum — resolved independently per axis, with
/// hysteresis (engage/release thresholds) and the active alignment guides returned for the view to
/// draw.
///
/// Free of SwiftUI by design (the `CanvasGeometry` discipline): the solver is a total function
/// `(proposed frame, targets, viewport, config, previous) → Resolution`, so every threshold /
/// priority / hysteresis rule is unit-tested with no view. The VIEW decides *when* to call it (live
/// drag preview + the single `.onEnded` commit, threading `previous` through so preview ≡ commit even
/// inside the hysteresis band) and *what* `others` means; the solver only does geometry.
///
/// ### Candidate classes and priority
/// Per axis, in tie-break priority order (``GuideKind``): **gutter** (own edge butts a neighbour with
/// the standard gap) > **edge** (own min/max ↔ other min/max, which includes flush butting) >
/// **center** (own mid ↔ other mid) > **viewportEdge** (own edges ↔ the 16pt-inset viewport edges,
/// own mid ↔ the viewport centre). Within an axis the smallest |delta| wins; near-ties (< 0.5pt)
/// break by class priority. The GRID is a *fallback only*: it is considered iff no pane/viewport
/// candidate engaged on that axis (the Figma rule — objects beat the grid), with its own (tighter)
/// thresholds.
///
/// ### Hysteresis (engage / release)
/// A candidate ENGAGES within ``Config/engage`` and, once held (carried via ``Resolution/stickX``/
/// `stickY` fed back as `previous`), persists until the raw position drifts past ``Config/release`` —
/// even if a nearer candidate appears mid-hold. The solver is otherwise a pure function of the RAW
/// proposed frame (zero drift: breakaway lands exactly under the pointer), and the asymmetry means a
/// pane sitting ON a guide cannot oscillate across it. Corrections are bounded by `release` per axis
/// by construction.
public enum CanvasSnap {
    // MARK: Config

    /// Tuning knobs, all in canvas points (1:1 with screen points — the camera is a pure translate).
    public struct Config: Sendable, Equatable {
        /// Magnetic range for pane/viewport candidates: engage at ≤ this …
        public var engage: CGFloat
        /// … and, once held, release only past this (engage < release ⇒ no boundary oscillation).
        public var release: CGFloat
        /// The standard gap used by gutter-adjacency candidates (== `Canvas.tidied` gutter == the
        /// group-box padding, so hand-snapped rows look exactly like Tidy output).
        public var gutter: CGFloat
        /// The grid snap quantum (the dot grid draws at 2× this, so every dot is an honest snap site).
        public var gridSpacing: CGFloat
        /// Grid engage/release — deliberately tighter than the pane thresholds (the grid is the
        /// weakest magnet).
        public var gridEngage: CGFloat
        public var gridRelease: CGFloat
        /// Master switch for pane/viewport candidates.
        public var snapsToPanes: Bool
        /// Master switch for the grid fallback.
        public var snapsToGrid: Bool

        public init(
            engage: CGFloat = 8,
            release: CGFloat = 12,
            gutter: CGFloat = 16,
            gridSpacing: CGFloat = 16,
            gridEngage: CGFloat = 6,
            gridRelease: CGFloat = 9,
            snapsToPanes: Bool = true,
            snapsToGrid: Bool = true,
        ) {
            self.engage = engage
            self.release = release
            self.gutter = gutter
            self.gridSpacing = gridSpacing
            self.gridEngage = gridEngage
            self.gridRelease = gridRelease
            self.snapsToPanes = snapsToPanes
            self.snapsToGrid = snapsToGrid
        }

        /// Everything off — the escape hatch for the "hold ⌘ to drag freely" modifier.
        public static let disabled = Self(snapsToPanes: false, snapsToGrid: false)
    }

    // MARK: Guides

    /// The candidate class that produced a guide — also the near-tie priority (lower raw = stronger)
    /// and the view's style cue (centers draw dashed, the Keynote distinction).
    public enum GuideKind: Int, Sendable, Equatable, Hashable, Comparable {
        case gutter = 0
        case edge
        case center
        case viewportEdge
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One alignment guide line the view draws while a pane-derived snap is ACTIVE: a 1-D position on
    /// the snapped axis plus the span (along the other axis) covering the dragged frame and every
    /// agreeing source. Canvas-space; the view converts to its local space.
    public struct Guide: Sendable, Equatable, Hashable {
        public enum Orientation: Sendable, Hashable {
            /// A vertical line (an X-axis snap) at `position == x`, spanning `start...end` in Y.
            case vertical
            /// A horizontal line (a Y-axis snap) at `position == y`, spanning `start...end` in X.
            case horizontal
        }

        public var orientation: Orientation
        public var position: CGFloat
        public var start: CGFloat
        public var end: CGFloat
        public var kind: GuideKind

        public init(orientation: Orientation, position: CGFloat, start: CGFloat, end: CGFloat, kind: GuideKind) {
            self.orientation = orientation
            self.position = position
            self.start = start
            self.end = end
            self.kind = kind
        }
    }

    // MARK: Hysteresis token

    /// The held snap of one axis: WHICH dragged edge is bound to WHAT target. Fed back into the next
    /// solve as `previous` so the hold survives until the release threshold.
    public struct Stick: Sendable, Equatable {
        /// The dragged value that landed on `target`.
        public enum OwnEdge: Sendable, Equatable, Hashable { case min, mid, max }
        public var ownEdge: OwnEdge
        public var target: CGFloat
        /// Grid sticks use the (tighter) grid release threshold and draw no guide.
        public var isGrid: Bool

        public init(ownEdge: OwnEdge, target: CGFloat, isGrid: Bool) {
            self.ownEdge = ownEdge
            self.target = target
            self.isGrid = isGrid
        }
    }

    // MARK: Resolution

    /// The solver output: the snapped frame, the guides to draw, and the per-axis hysteresis tokens
    /// to feed back as `previous` on the next solve. `frame == proposed` when nothing engaged.
    public struct Resolution: Sendable, Equatable {
        public var frame: CGRect
        public var guides: [Guide]
        public var stickX: Stick?
        public var stickY: Stick?

        public init(frame: CGRect, guides: [Guide] = [], stickX: Stick? = nil, stickY: Stick? = nil) {
            self.frame = frame
            self.guides = guides
            self.stickX = stickX
            self.stickY = stickY
        }
    }

    // MARK: Move

    /// Snaps a MOVE drag: `proposed` is the dragged pane's raw candidate frame (persisted frame +
    /// raw live translation — always derive from the RAW translation, never from a previous snapped
    /// frame, or the snap would drift). `others` are the sibling frames to magnetize against (the
    /// caller passes the viewport-near ones, excluding the dragged pane). `viewport` is the visible
    /// canvas rect for the viewport-edge class (`nil` skips it). Size never changes; only the origin
    /// shifts, each axis independently.
    public static func move(
        _ proposed: CGRect,
        others: [CGRect],
        viewport: CGRect? = nil,
        config: Config,
        previous: Resolution? = nil,
    ) -> Resolution {
        let xCandidates = moveCandidates(
            axis: .x,
            proposed: proposed,
            others: others,
            viewport: viewport,
            config: config,
        )
        let yCandidates = moveCandidates(
            axis: .y,
            proposed: proposed,
            others: others,
            viewport: viewport,
            config: config,
        )

        let x = resolveAxis(
            values: AxisValues(min: proposed.minX, mid: proposed.midX, max: proposed.maxX),
            candidates: xCandidates,
            previous: previous?.stickX,
            config: config,
            gridEdge: .min,
        )
        let y = resolveAxis(
            values: AxisValues(min: proposed.minY, mid: proposed.midY, max: proposed.maxY),
            candidates: yCandidates,
            previous: previous?.stickY,
            config: config,
            gridEdge: .min,
        )

        let snapped = sanitizedPreservingSize(proposed.offsetBy(dx: x.delta, dy: y.delta))
        return Resolution(
            frame: snapped,
            guides: guides(
                for: snapped,
                xCandidates: xCandidates,
                yCandidates: yCandidates,
                xSnapped: x.stick.map { !$0.isGrid } ?? false,
                ySnapped: y.stick.map { !$0.isGrid } ?? false,
            ),
            stickX: x.stick,
            stickY: y.stick,
        )
    }

    // MARK: Resize

    /// Snaps a RESIZE drag: `proposed` is the raw previewed frame (``CanvasGeometry/resizing`` of the
    /// raw translation). Only the edge(s) `anchor` moves are magnetic; centres are skipped (a resize
    /// aligns edges, not centres). Candidates that would push the size below `minSize` are DISCARDED
    /// — never clamped — so a drawn guide is always a true statement and the pinned edge never shifts.
    public static func resize(
        _ proposed: CGRect,
        anchor: ResizeAnchor,
        others: [CGRect],
        viewport: CGRect? = nil,
        minSize: CGSize = Canvas.minItemSize,
        config: Config,
        previous: Resolution? = nil,
    ) -> Resolution {
        var left = proposed.minX
        var right = proposed.maxX
        var top = proposed.minY
        var bottom = proposed.maxY

        let movesLeft = anchor == .topLeft || anchor == .left || anchor == .bottomLeft
        let movesRight = anchor == .topRight || anchor == .right || anchor == .bottomRight
        let movesTop = anchor == .topLeft || anchor == .top || anchor == .topRight
        let movesBottom = anchor == .bottomLeft || anchor == .bottom || anchor == .bottomRight

        var stickX: Stick?
        var stickY: Stick?
        var xCandidates: [Candidate] = []
        var yCandidates: [Candidate] = []

        if movesLeft || movesRight {
            let ownEdge: Stick.OwnEdge = movesLeft ? .min : .max
            // Min-size discard: the moving edge may not cross within minSize of the pinned edge.
            let valid: (CGFloat) -> Bool = movesLeft
                ? { target in right - target >= minSize.width }
                : { target in target - left >= minSize.width }
            xCandidates = resizeCandidates(
                axis: .x,
                ownEdge: ownEdge,
                others: others,
                viewport: viewport,
                config: config,
            ).filter { valid($0.target) }
            let own = movesLeft ? left : right
            let r = resolveEdge(
                own: own,
                ownEdge: ownEdge,
                candidates: xCandidates,
                previous: previous?.stickX,
                config: config,
                gridValid: valid,
            )
            if movesLeft { left += r.delta } else { right += r.delta }
            stickX = r.stick
        }
        if movesTop || movesBottom {
            let ownEdge: Stick.OwnEdge = movesTop ? .min : .max
            let valid: (CGFloat) -> Bool = movesTop
                ? { target in bottom - target >= minSize.height }
                : { target in target - top >= minSize.height }
            yCandidates = resizeCandidates(
                axis: .y,
                ownEdge: ownEdge,
                others: others,
                viewport: viewport,
                config: config,
            ).filter { valid($0.target) }
            let own = movesTop ? top : bottom
            let r = resolveEdge(
                own: own,
                ownEdge: ownEdge,
                candidates: yCandidates,
                previous: previous?.stickY,
                config: config,
                gridValid: valid,
            )
            if movesTop { top += r.delta } else { bottom += r.delta }
            stickY = r.stick
        }

        let snapped = sanitizedPreservingSize(CGRect(x: left, y: top, width: right - left, height: bottom - top))
        return Resolution(
            frame: snapped,
            guides: guides(
                for: snapped,
                xCandidates: xCandidates,
                yCandidates: yCandidates,
                xSnapped: stickX.map { !$0.isGrid } ?? false,
                ySnapped: stickY.map { !$0.isGrid } ?? false,
            ),
            stickX: stickX,
            stickY: stickY,
        )
    }

    // MARK: - Internal candidate model

    private enum Axis { case x, y }

    private struct AxisValues {
        var min: CGFloat
        var mid: CGFloat
        var max: CGFloat

        func value(_ edge: Stick.OwnEdge) -> CGFloat {
            switch edge {
            case .min: min
            case .mid: mid
            case .max: max
            }
        }
    }

    /// One pane/viewport-derived snap opportunity on one axis: a dragged edge that may land on a
    /// target coordinate, plus the source's perpendicular extent (for the guide span).
    private struct Candidate {
        var ownEdge: Stick.OwnEdge
        var target: CGFloat
        var kind: GuideKind
        var span: ClosedRange<CGFloat>
    }

    /// All MOVE candidates for one axis (gutter + edge + center per other rect, plus viewport).
    private static func moveCandidates(
        axis: Axis,
        proposed _: CGRect,
        others: [CGRect],
        viewport: CGRect?,
        config: Config,
    ) -> [Candidate] {
        guard config.snapsToPanes else { return [] }
        var result: [Candidate] = []
        for other in others {
            let (lo, mid, hi) = edges(of: other, axis: axis)
            let span = perpendicularSpan(of: other, axis: axis)
            // Gutter adjacency (tile next to the neighbour with the standard gap).
            result.append(Candidate(ownEdge: .min, target: hi + config.gutter, kind: .gutter, span: span))
            result.append(Candidate(ownEdge: .max, target: lo - config.gutter, kind: .gutter, span: span))
            // Edge alignment, any-to-any min/max (includes flush butting).
            for target in [lo, hi] {
                result.append(Candidate(ownEdge: .min, target: target, kind: .edge, span: span))
                result.append(Candidate(ownEdge: .max, target: target, kind: .edge, span: span))
            }
            // Centre alignment (mid ↔ mid only).
            result.append(Candidate(ownEdge: .mid, target: mid, kind: .center, span: span))
        }
        if let viewport {
            result.append(contentsOf: viewportCandidates(
                axis: axis,
                viewport: viewport,
                config: config,
                includeCenter: true,
            ))
        }
        return result
    }

    /// All RESIZE candidates for one MOVING edge on one axis (no centres; gutter butts the moving
    /// edge against the neighbour's near/far edge with the gap).
    private static func resizeCandidates(
        axis: Axis,
        ownEdge: Stick.OwnEdge,
        others: [CGRect],
        viewport: CGRect?,
        config: Config,
    ) -> [Candidate] {
        guard config.snapsToPanes else { return [] }
        var result: [Candidate] = []
        for other in others {
            let (lo, _, hi) = edges(of: other, axis: axis)
            let span = perpendicularSpan(of: other, axis: axis)
            // A growing-toward-neighbour edge butts BEFORE its near edge / AFTER its far edge.
            let gutterTarget = (ownEdge == .min) ? hi + config.gutter : lo - config.gutter
            result.append(Candidate(ownEdge: ownEdge, target: gutterTarget, kind: .gutter, span: span))
            for target in [lo, hi] {
                result.append(Candidate(ownEdge: ownEdge, target: target, kind: .edge, span: span))
            }
        }
        if let viewport {
            result.append(contentsOf: viewportCandidates(
                axis: axis,
                viewport: viewport,
                config: config,
                includeCenter: false,
            )
            .filter { $0.ownEdge == ownEdge })
        }
        return result
    }

    /// Viewport-edge candidates: the 16pt-inset visible edges (min/max) + the centreline (move only).
    private static func viewportCandidates(
        axis: Axis,
        viewport: CGRect,
        config: Config,
        includeCenter: Bool,
    ) -> [Candidate] {
        let inset = viewport.insetBy(dx: config.gutter, dy: config.gutter)
        let (lo, mid, hi) = edges(of: inset, axis: axis)
        let span = perpendicularSpan(of: viewport, axis: axis)
        var result: [Candidate] = [
            Candidate(ownEdge: .min, target: lo, kind: .viewportEdge, span: span),
            Candidate(ownEdge: .max, target: hi, kind: .viewportEdge, span: span),
        ]
        if includeCenter {
            // The TRUE viewport centre (not the inset's — same value, but keep it explicit).
            result.append(Candidate(ownEdge: .mid, target: mid, kind: .viewportEdge, span: span))
        }
        return result
    }

    private static func edges(of rect: CGRect, axis: Axis) -> (CGFloat, CGFloat, CGFloat) {
        switch axis {
        case .x: (rect.minX, rect.midX, rect.maxX)
        case .y: (rect.minY, rect.midY, rect.maxY)
        }
    }

    private static func perpendicularSpan(of rect: CGRect, axis: Axis) -> ClosedRange<CGFloat> {
        switch axis {
        case .x: rect.minY...rect.maxY
        case .y: rect.minX...rect.maxX
        }
    }

    // MARK: - Axis resolution (selection + hysteresis)

    private struct AxisResolution {
        var delta: CGFloat
        var stick: Stick?
    }

    /// Whether a held (non-grid) stick is still JUSTIFIED by a live candidate: its source edge must
    /// still exist (within the guide ε) in the current candidate set. Without this, a pane whose
    /// neighbour was closed/moved mid-drag would stay magnetized to a phantom coordinate with no
    /// guide drawable (snap active ⇔ guide drawable must hold both ways). Grid sticks skip the check —
    /// the lattice always exists.
    private static func isJustified(_ stick: Stick, by candidates: [Candidate]) -> Bool {
        if stick.isGrid { return true }
        return candidates.contains { $0.ownEdge == stick.ownEdge && abs($0.target - stick.target) <= 0.5 }
    }

    /// Order-independent best-candidate selection: pass 1 finds the smallest in-range |delta|;
    /// pass 2 picks, among the near-ties (within 0.5pt of that minimum), the strongest class —
    /// remaining ties break by smaller |delta|, then smaller target (full determinism). A single-pass
    /// pairwise comparator is NOT transitive under the near-tie rule and would let the winner depend
    /// on the `others` array order.
    private static func selectBest(
        _ candidates: [Candidate],
        own: (Stick.OwnEdge) -> CGFloat,
        engage: CGFloat,
    ) -> (candidate: Candidate, delta: CGFloat)? {
        var minAbs = CGFloat.infinity
        for candidate in candidates {
            let delta = candidate.target - own(candidate.ownEdge)
            guard delta.isFinite, abs(delta) <= engage else { continue }
            minAbs = Swift.min(minAbs, abs(delta))
        }
        guard minAbs.isFinite else { return nil }
        var best: (candidate: Candidate, delta: CGFloat)?
        for candidate in candidates {
            let delta = candidate.target - own(candidate.ownEdge)
            guard delta.isFinite, abs(delta) <= engage, abs(delta) <= minAbs + 0.5 else { continue }
            if let current = best {
                let better = candidate.kind < current.candidate.kind
                    || (candidate.kind == current.candidate.kind
                        && (abs(delta) < abs(current.delta)
                            || (abs(delta) == abs(current.delta) && candidate.target < current.candidate.target)))
                if !better { continue }
            }
            best = (candidate, delta)
        }
        return best
    }

    /// Resolves one MOVE axis: hold the previous stick while within release; else engage the best
    /// fresh candidate; else fall back to the grid (quantizing `gridEdge`, the leading edge).
    private static func resolveAxis(
        values: AxisValues,
        candidates: [Candidate],
        previous: Stick?,
        config: Config,
        gridEdge: Stick.OwnEdge,
    ) -> AxisResolution {
        // 1. A held stick persists while the RAW position is within its release threshold — even if a
        //    nearer candidate appeared (no mid-hold re-targeting; deterministic feel) — but only while
        //    its source candidate still exists (a vanished neighbour drops the hold).
        if let previous {
            let own = values.value(previous.ownEdge)
            let release = previous.isGrid ? config.gridRelease : config.release
            let enabled = previous.isGrid ? config.snapsToGrid : config.snapsToPanes
            if enabled, isJustified(previous, by: candidates), abs(previous.target - own) < release {
                return AxisResolution(delta: previous.target - own, stick: previous)
            }
        }
        // 2. Fresh engage: smallest |delta| within engage; near-ties (≤ 0.5pt) break by class priority.
        if config.snapsToPanes, let best = selectBest(candidates, own: values.value, engage: config.engage) {
            return AxisResolution(
                delta: best.delta,
                stick: Stick(ownEdge: best.candidate.ownEdge, target: best.candidate.target, isGrid: false),
            )
        }
        // 3. Grid fallback (fallback ONLY — never competes with an engaged pane/viewport candidate).
        if config.snapsToGrid, config.gridSpacing > 0 {
            let own = values.value(gridEdge)
            let quantized = (own / config.gridSpacing).rounded() * config.gridSpacing
            let delta = quantized - own
            if abs(delta) <= config.gridEngage {
                return AxisResolution(delta: delta, stick: Stick(ownEdge: gridEdge, target: quantized, isGrid: true))
            }
        }
        return AxisResolution(delta: 0, stick: nil)
    }

    /// Resolves one RESIZE moving edge (same hold → engage → grid ladder, single own value).
    private static func resolveEdge(
        own: CGFloat,
        ownEdge: Stick.OwnEdge,
        candidates: [Candidate],
        previous: Stick?,
        config: Config,
        gridValid: (CGFloat) -> Bool,
    ) -> AxisResolution {
        if let previous, previous.ownEdge == ownEdge {
            let release = previous.isGrid ? config.gridRelease : config.release
            let enabled = previous.isGrid ? config.snapsToGrid : config.snapsToPanes
            if enabled, isJustified(previous, by: candidates), abs(previous.target - own) < release {
                return AxisResolution(delta: previous.target - own, stick: previous)
            }
        }
        if config.snapsToPanes, let best = selectBest(candidates, own: { _ in own }, engage: config.engage) {
            return AxisResolution(
                delta: best.delta,
                stick: Stick(ownEdge: ownEdge, target: best.candidate.target, isGrid: false),
            )
        }
        if config.snapsToGrid, config.gridSpacing > 0 {
            let quantized = (own / config.gridSpacing).rounded() * config.gridSpacing
            let delta = quantized - own
            if abs(delta) <= config.gridEngage, gridValid(quantized) {
                return AxisResolution(delta: delta, stick: Stick(ownEdge: ownEdge, target: quantized, isGrid: true))
            }
        }
        return AxisResolution(delta: 0, stick: nil)
    }

    // MARK: - Guide synthesis

    /// Guides for every candidate that COINCIDES with the final snapped frame (within ε) on a
    /// pane-snapped axis — so every drawn line is a true statement about the committed geometry, and
    /// all co-winning sources extend the span. One guide per distinct position; the span is the union
    /// of the agreeing sources' extents and the dragged frame's own extent; the kind is the
    /// strongest contributing class (drives solid-vs-dashed). Grid snaps draw NO guide (the dot grid
    /// itself is the affordance).
    private static func guides(
        for snapped: CGRect,
        xCandidates: [Candidate],
        yCandidates: [Candidate],
        xSnapped: Bool,
        ySnapped: Bool,
    ) -> [Guide] {
        guard xSnapped || ySnapped else { return [] }
        let epsilon: CGFloat = 0.5
        var result: [Guide] = []

        // Group coincident candidates by the DRAGGED EDGE they bind (distinct edges cannot fall
        // within ε of each other above the min item size), and draw at the EXACT snapped own-edge
        // value — never at a candidate's (possibly ≤ε-off) target or any rounded bucket, so the line
        // always sits pixel-true on the committed coordinate.
        if xSnapped {
            let values = AxisValues(min: snapped.minX, mid: snapped.midX, max: snapped.maxX)
            var byEdge: [Stick.OwnEdge: (span: ClosedRange<CGFloat>, kind: GuideKind)] = [:]
            for candidate in xCandidates where abs(candidate.target - values.value(candidate.ownEdge)) <= epsilon {
                if let existing = byEdge[candidate.ownEdge] {
                    byEdge[candidate.ownEdge] = (
                        union(existing.span, candidate.span),
                        min(existing.kind, candidate.kind),
                    )
                } else {
                    byEdge[candidate.ownEdge] = (candidate.span, candidate.kind)
                }
            }
            for (edge, info) in byEdge {
                let full = union(info.span, snapped.minY...snapped.maxY)
                result.append(Guide(
                    orientation: .vertical,
                    position: values.value(edge),
                    start: full.lowerBound,
                    end: full.upperBound,
                    kind: info.kind,
                ))
            }
        }
        if ySnapped {
            let values = AxisValues(min: snapped.minY, mid: snapped.midY, max: snapped.maxY)
            var byEdge: [Stick.OwnEdge: (span: ClosedRange<CGFloat>, kind: GuideKind)] = [:]
            for candidate in yCandidates where abs(candidate.target - values.value(candidate.ownEdge)) <= epsilon {
                if let existing = byEdge[candidate.ownEdge] {
                    byEdge[candidate.ownEdge] = (
                        union(existing.span, candidate.span),
                        min(existing.kind, candidate.kind),
                    )
                } else {
                    byEdge[candidate.ownEdge] = (candidate.span, candidate.kind)
                }
            }
            for (edge, info) in byEdge {
                let full = union(info.span, snapped.minX...snapped.maxX)
                result.append(Guide(
                    orientation: .horizontal,
                    position: values.value(edge),
                    start: full.lowerBound,
                    end: full.upperBound,
                    kind: info.kind,
                ))
            }
        }
        // Deterministic order for the view's ForEach + test assertions.
        return result.sorted {
            if $0.orientation != $1.orientation { return $0.orientation == .vertical }
            return $0.position < $1.position
        }
    }

    private static func union(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        Swift.min(a.lowerBound, b.lowerBound)...Swift.max(a.upperBound, b.upperBound)
    }

    // MARK: - Sanitation

    /// Clamps the origin finite/bounded (the ``Canvas/sanitize(_:)`` rule) but passes the size through
    /// VERBATIM — a move never changes size, so the solver must not (Canvas.sanitize also floors size
    /// to `minItemSize`, which is a PERSISTENCE invariant, not a solver one). Non-finite sizes (never
    /// produced by these ops on finite inputs) collapse the same way `Canvas.sanitize` collapses them.
    private static func sanitizedPreservingSize(_ frame: CGRect) -> CGRect {
        let b = Canvas.coordinateBound
        let x = frame.origin.x.isFinite ? min(max(frame.origin.x, -b), b) : 0
        let y = frame.origin.y.isFinite ? min(max(frame.origin.y, -b), b) : 0
        let w = frame.width.isFinite ? min(max(frame.width, 0), b) : Canvas.minItemSize.width
        let h = frame.height.isFinite ? min(max(frame.height, 0), b) : Canvas.minItemSize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
