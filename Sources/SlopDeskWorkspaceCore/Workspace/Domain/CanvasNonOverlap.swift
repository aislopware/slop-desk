import CoreGraphics
import Foundation

// MARK: - CanvasNonOverlap (pure non-overlapping layout solver for canvas drags)

/// Pure non-overlap layout for canvas move/resize drags: the dragged body **slides flush** along its
/// neighbours' boundaries instead of overlapping ("trượt theo boundary"), and on an insert-intent drop
/// the surrounded neighbours **part to make room** ("tự dịch ra để có khoảng trống"). The companion to
/// ``CanvasSnap`` — it runs STRICTLY AFTER it, consuming the snapped frame as the dragged body's target,
/// and shares the same 16pt gutter so a gutter-snapped box is already at the non-overlap boundary (the
/// slide is then a no-op at a snap line — the two solvers reinforce, never fight).
///
/// Free of SwiftUI by design (the `CanvasGeometry` / `CanvasSnap` discipline): every entry point is a
/// total, deterministic, path-INDEPENDENT function of `CGRect`s, so the whole solver is unit-tested with
/// no view and `preview ≡ commit` holds by construction (the live drag and the single `.onEnded` commit
/// recompute from the same raw inputs).
///
/// ### Two modes, two masses
/// The two requested behaviours need OPPOSITE mass models, so they are split:
/// - **SLIDE** (the live-drag default, every frame): the dragged body YIELDS — a swept-AABB
///   collide-and-slide sweeps it from its persisted origin to the snapped target against the
///   gutter-inflated neighbour/group bodies; on the earliest contact it cancels the into-face motion and
///   re-sweeps the tangential remainder, gliding the box flush one gutter off its neighbours and tucking
///   it into inside corners. ONLY the dragged body moves, so it renders through the SAME item-local
///   gesture-state channel ``CanvasSnap`` already uses (no new per-frame whole-canvas dependency).
/// - **MAKE-SPACE** (commit-only, the single `.onEnded`): the NEIGHBOURS yield — when the dropped target
///   shows insert-intent (its centre is over a neighbour, or it is wedged between opposing neighbours,
///   with enough coverage), the dragged body is PINNED at the target and a minimal-movement separation
///   relaxation flows every other body apart to admit it. On the infinite plane there is always room, so
///   this always converges; the store commits the dragged frame + the displaced neighbours atomically.
public enum CanvasNonOverlap {
    // MARK: Body model

    /// Which kind of canvas object a collision body stands for. A `.group` body is the derived
    /// ``Canvas/groupBoundingBox(_:)`` treated as one rigid box — its solved shift is distributed to all
    /// its members by the store, so group-vs-group / pane-vs-group non-overlap falls out of feeding group
    /// boxes into the SAME solver.
    public enum BodyID: Hashable, Sendable {
        case pane(PaneID)
        case group(PaneGroupID)

        /// A stable, total ordering key — the canonical processing order (so the solver is deterministic
        /// and INDEPENDENT of the input `bodies` array order). Panes sort before groups; within a kind,
        /// by UUID string.
        var orderKey: String {
            switch self {
            case let .pane(id): "0:" + id.raw.uuidString
            case let .group(id): "1:" + id.raw.uuidString
            }
        }
    }

    /// One collision body: an ungrouped pane frame, or a group's bounding box. `weight` is only consulted
    /// in make-space (the pinned dragged body is effectively immovable; every free body shares the push).
    public struct Body: Sendable, Equatable {
        public let id: BodyID
        public var rect: CGRect
        public init(id: BodyID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    // MARK: Config

    /// Tuning knobs, all in canvas points (1:1 with screen — the camera is a pure translate).
    public struct Config: Sendable, Equatable {
        /// The non-overlap gap, DERIVED from ``CanvasSnap/Config`` so the two can never drift: a box that
        /// `CanvasSnap` gutter-snaps flush to a neighbour is ALREADY at the slide separation → slide
        /// no-ops at a snap line.
        public var gutter: CGFloat
        /// Swept back-off along the contact normal so an abutting box is not re-detected as a zero-distance
        /// hit (stops seam-catch on a shared edge).
        public var skin: CGFloat
        /// Re-sweep cap for the slide (each pass removes one contact axis; a corner needs 2) — a hard
        /// termination bound.
        public var maxSlidePasses: Int
        /// Iteration cap for the make-space separation relaxation — a hard termination bound.
        public var maxRelaxIterations: Int
        /// Make-space intent gate: the normalized overlap coverage (Muuri `min(w,h)` normalizer, so a
        /// small pane fully over a big one still reaches 100%) a drop must reach before neighbours part.
        /// Below it the box just rests flush (slide only).
        public var insertCoverage: CGFloat
        /// Master switch (the setting-off / ⌘-bypass escape hatch — then every entry point is identity).
        public var enabled: Bool

        public init(
            gutter: CGFloat = CanvasSnap.Config().gutter,
            skin: CGFloat = 0.1,
            maxSlidePasses: Int = 4,
            maxRelaxIterations: Int = 32,
            insertCoverage: CGFloat = 0.5,
            enabled: Bool = true,
        ) {
            self.gutter = gutter
            self.skin = skin
            self.maxSlidePasses = maxSlidePasses
            self.maxRelaxIterations = maxRelaxIterations
            self.insertCoverage = insertCoverage
            self.enabled = enabled
        }

        /// Everything off — the ⌘ / setting-off bypass (matches ``CanvasSnap/Config/disabled``).
        public static let disabled = Self(enabled: false)
    }

    // MARK: Results

    /// The live-drag output: only the dragged box moves (`frame`). Rendered through the dragged pane's own
    /// gesture state — no neighbour is touched live.
    public struct SlideResult: Sendable, Equatable {
        public var frame: CGRect
        public init(frame: CGRect) { self.frame = frame }
    }

    /// The commit output: the new frame of every body that moved — the dragged body plus every neighbour
    /// (or group box) the make-space relaxation displaced. The store writes these in ONE canvas mutation.
    public struct CommitResult: Sendable, Equatable {
        public var frames: [BodyID: CGRect]
        public init(frames: [BodyID: CGRect]) { self.frames = frames }
    }

    // MARK: - SLIDE (live default + commit)

    /// Slides the dragged body to `snapped` without overlapping any `bodies`, gliding flush one gutter
    /// off each. `from` is the body's PERSISTED origin (the fixed gesture start) — the whole sweep is
    /// from `from` to `snapped.origin`, so the result is a pure function of the raw translation (NOT of
    /// frame-to-frame motion): `preview ≡ commit`. Identity when disabled or there is nothing to hit.
    public static func slide(_ snapped: CGRect, from: CGPoint, bodies: [Body], config: Config) -> SlideResult {
        guard config.enabled, !bodies.isEmpty else { return SlideResult(frame: snapped) }
        let size = snapped.size
        guard size.width > 0, size.height > 0 else { return SlideResult(frame: snapped) }
        let sorted = bodies.sorted { $0.id.orderKey < $1.id.orderKey }

        // 1. Depenetrate the START: if the persisted origin already overlaps a body (feature just turned
        //    on / a neighbour teleported), pop the box gutter-clear before sweeping (a no-op in the steady
        //    state, where every committed frame is already non-overlapping).
        var origin = depenetrate(origin: from, size: size, bodies: sorted, config: config)

        // 2. Swept collide-and-slide of the remaining motion toward the snapped target.
        var remaining = CGVector(dx: snapped.origin.x - origin.x, dy: snapped.origin.y - origin.y)
        var pass = 0
        while pass < config.maxSlidePasses, hypot(remaining.dx, remaining.dy) > config.skin {
            pass += 1
            guard let hit = earliestHit(
                origin: origin,
                size: size,
                velocity: remaining,
                bodies: sorted,
                config: config,
            ) else {
                origin.x += remaining.dx
                origin.y += remaining.dy
                remaining = .zero
                break
            }
            // Advance to the contact point, then back off `skin` along the (outward) normal so the same
            // surface is not re-detected on the next sweep.
            origin.x += remaining.dx * hit.t + hit.normal.dx * config.skin
            origin.y += remaining.dy * hit.t + hit.normal.dy * config.skin
            // Cancel the into-face component; keep the tangential remainder (the slide).
            let leftover = CGVector(dx: remaining.dx * (1 - hit.t), dy: remaining.dy * (1 - hit.t))
            remaining = hit.axis == .x ? CGVector(dx: 0, dy: leftover.dy) : CGVector(dx: leftover.dx, dy: 0)
        }
        // 3. Safety net: any residual penetration (e.g. the pass cap was hit in a dense pocket) is cleared,
        //    so the output NEVER overlaps. A no-op for a clean flush slide.
        origin = depenetrate(origin: origin, size: size, bodies: sorted, config: config)
        return SlideResult(frame: sanitizedPreservingSize(CGRect(origin: origin, size: size)))
    }

    // MARK: - MAKE-SPACE (commit-only)

    /// If the dropped `target` shows insert-intent against `bodies`, pins the dragged body at `target` and
    /// flows every overlapping neighbour/group apart by minimal movement to admit it — returning the new
    /// frame of the dragged body plus every displaced body. Returns `nil` when intent does NOT fire (the
    /// box merely rests against a boundary): the caller then commits the slid (flush) frame and nothing
    /// else moves. Always `nil` when disabled.
    public static func makeSpace(target: CGRect, draggedID: BodyID, bodies: [Body], config: Config) -> CommitResult? {
        guard config.enabled else { return nil }
        // S = the bodies the target actually OVERLAPS (positive area) — a within-gutter brush is "resting
        // flush" (slide's job), not an insert.
        let overlappers = bodies.filter { intersectionArea(target, $0.rect) > 0 }
        guard !overlappers.isEmpty,
              intentArmed(target: target, overlappers: overlappers, config: config) else { return nil }
        return separate(pinnedID: draggedID, pinnedRect: target, bodies: bodies, config: config)
    }

    /// The gate-FREE separation relaxation: pins one body at `pinnedRect` (immovable) and flows every
    /// OTHER body apart by minimal movement until none overlap (gutter-respecting). Used by `makeSpace`
    /// (behind the insert-intent gate) AND directly by the resize-push (a grown window / group must shove
    /// ANY overlapped neighbour, no intent needed) and the within-group reflow. On the infinite plane
    /// there is always room, so it converges; the iteration cap guarantees termination regardless.
    /// Returns the pinned body (at `pinnedRect`) plus every body that actually moved.
    public static func separate(pinnedID: BodyID, pinnedRect: CGRect, bodies: [Body], config: Config) -> CommitResult {
        guard config.enabled else { return CommitResult(frames: [pinnedID: pinnedRect]) }
        // Pin the dragged body; every other body is free (drop any stale free copy of the pinned id).
        var working = bodies.map { (id: $0.id, rect: $0.rect, pinned: false) }
        working.removeAll { $0.id == pinnedID }
        working.append((id: pinnedID, rect: pinnedRect, pinned: true))
        working.sort { $0.id.orderKey < $1.id.orderKey }

        var iteration = 0
        while iteration < config.maxRelaxIterations {
            iteration += 1
            var separatedAny = false
            for i in working.indices {
                for j in (i + 1)..<working.count {
                    guard let sep = separation(working[i].rect, working[j].rect, gutter: config.gutter)
                    else { continue }
                    let wi: CGFloat = working[i].pinned ? 0 : 1
                    let wj: CGFloat = working[j].pinned ? 0 : 1
                    let wsum = wi + wj
                    guard wsum > 0
                    else { continue } // two pinned bodies cannot be separated (never happens: only one is pinned)
                    separatedAny = true
                    working[i].rect = working[i].rect.offsetBy(dx: sep.dx * (wi / wsum), dy: sep.dy * (wi / wsum))
                    working[j].rect = working[j].rect.offsetBy(dx: -sep.dx * (wj / wsum), dy: -sep.dy * (wj / wsum))
                }
            }
            if !separatedAny { break }
        }

        // Emit the pinned body + every body whose centre actually moved.
        let priorByID = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0.rect) })
        var frames: [BodyID: CGRect] = [pinnedID: sanitizedPreservingSize(pinnedRect)]
        for entry in working where !entry.pinned {
            if let prior = priorByID[entry.id], !approxEqual(prior, entry.rect) {
                frames[entry.id] = sanitizedPreservingSize(entry.rect)
            }
        }
        return CommitResult(frames: frames)
    }

    // MARK: - RESIZE clamp (the growing edge stops flush at a neighbour)

    /// Clamps a resized `frame` so its MOVING edge(s) (per `anchor`) never cross into a neighbour body:
    /// each growing edge stops one gutter short of the nearest body it shares a perpendicular span with,
    /// floored so the frame never shrinks below `minSize` (the pinned edge never moves). The slide
    /// analogue for a resize — the box yields rather than overlapping. Order-independent (each edge takes
    /// a min/max over all bodies). Identity when disabled or nothing is in the way; SHRINKING is never
    /// constrained (the moving edge recedes away from neighbours).
    public static func clampResize(
        _ frame: CGRect,
        anchor: ResizeAnchor,
        bodies: [Body],
        minSize: CGSize,
        config: Config,
    ) -> CGRect {
        guard config.enabled, !bodies.isEmpty else { return frame }
        let g = config.gutter
        let movesLeft = anchor == .topLeft || anchor == .left || anchor == .bottomLeft
        let movesRight = anchor == .topRight || anchor == .right || anchor == .bottomRight
        let movesTop = anchor == .topLeft || anchor == .top || anchor == .topRight
        let movesBottom = anchor == .bottomLeft || anchor == .bottom || anchor == .bottomRight

        var left = frame.minX, right = frame.maxX, top = frame.minY, bottom = frame.maxY
        for body in bodies {
            let b = body.rect
            let vShare = frame.minY < b.maxY && b.minY < frame.maxY // share a Y span → vertical edges collide
            let hShare = frame.minX < b.maxX && b.minX < frame.maxX // share an X span → horizontal edges collide
            if movesRight, vShare, b.minX > left, b.minX - g < right {
                right = Swift.max(left + minSize.width, Swift.min(right, b.minX - g))
            }
            if movesLeft, vShare, b.maxX < right, b.maxX + g > left {
                left = Swift.min(right - minSize.width, Swift.max(left, b.maxX + g))
            }
            if movesBottom, hShare, b.minY > top, b.minY - g < bottom {
                bottom = Swift.max(top + minSize.height, Swift.min(bottom, b.minY - g))
            }
            if movesTop, hShare, b.maxY < bottom, b.maxY + g > top {
                top = Swift.min(bottom - minSize.height, Swift.max(top, b.maxY + g))
            }
        }
        return Canvas.sanitize(CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    // MARK: - Intent gate

    /// Whether a drop at `target` reads as "insert me between these" rather than "rest me against one".
    /// Armed iff coverage clears the threshold AND the target is either centred over a neighbour or wedged
    /// between neighbours on two OPPOSING sides (the canonical board-reflow trigger).
    private static func intentArmed(target: CGRect, overlappers: [Body], config: Config) -> Bool {
        let coverage = overlappers.map { coverageFraction(target, $0.rect) }.max() ?? 0
        guard coverage >= config.insertCoverage else { return false }

        let centerInside = overlappers.contains { $0.rect.contains(CGPoint(x: target.midX, y: target.midY)) }
        let left = overlappers.contains { $0.rect.midX < target.midX && verticalSpansOverlap($0.rect, target) }
        let right = overlappers.contains { $0.rect.midX > target.midX && verticalSpansOverlap($0.rect, target) }
        let above = overlappers.contains { $0.rect.midY < target.midY && horizontalSpansOverlap($0.rect, target) }
        let below = overlappers.contains { $0.rect.midY > target.midY && horizontalSpansOverlap($0.rect, target) }
        let opposing = (left && right) || (above && below)
        return centerInside || opposing
    }

    // MARK: - Geometry primitives (pure, unit-tested)

    enum Axis { case x, y }

    /// The minimal translation that separates `a` from `b` by `gutter` along the cheaper axis, or `nil`
    /// when they are already ≥ `gutter` apart. The vector moves `a` AWAY from `b` (the caller splits it
    /// between the pair by inverse mass). Two touching rects (raw overlap 0) still get a full-gutter push.
    static func separation(_ a: CGRect, _ b: CGRect, gutter: CGFloat) -> CGVector? {
        let overlapX = (Swift.min(a.maxX, b.maxX) - Swift.max(a.minX, b.minX)) + gutter
        let overlapY = (Swift.min(a.maxY, b.maxY) - Swift.max(a.minY, b.minY)) + gutter
        guard overlapX > 0, overlapY > 0 else { return nil }
        if overlapX < overlapY || (overlapX == overlapY && abs(a.midX - b.midX) >= abs(a.midY - b.midY)) {
            return CGVector(dx: a.midX <= b.midX ? -overlapX : overlapX, dy: 0)
        }
        return CGVector(dx: 0, dy: a.midY <= b.midY ? -overlapY : overlapY)
    }

    /// Pops a box at `origin` (size `size`) gutter-clear of every body, iterating a few passes so a box
    /// wedged among several is fully freed. Deterministic (bodies pre-sorted by the caller). A no-op when
    /// the box is already clear.
    private static func depenetrate(origin: CGPoint, size: CGSize, bodies: [Body], config: Config) -> CGPoint {
        var o = origin
        var pass = 0
        while pass < config.maxSlidePasses {
            pass += 1
            var moved = false
            for body in bodies {
                let box = CGRect(origin: o, size: size)
                if let sep = separation(box, body.rect, gutter: config.gutter) {
                    o.x += sep.dx
                    o.y += sep.dy
                    moved = true
                }
            }
            if !moved { break }
        }
        return o
    }

    /// The earliest contact of the box (size `size` at `origin`) sweeping by `velocity` against any body,
    /// gutter-inflated. Swept-AABB by the slab method on the box CENTRE against each body expanded by the
    /// box half-extents + gutter (Minkowski). Ties in entry time break by the body's canonical order key,
    /// so the choice is deterministic. `normal` points away from the obstacle (the slide back-off
    /// direction).
    private static func earliestHit(
        origin: CGPoint, size: CGSize, velocity: CGVector, bodies: [Body], config: Config,
    ) -> (t: CGFloat, axis: Axis, normal: CGVector)? {
        let c0 = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        var best: (t: CGFloat, axis: Axis, normal: CGVector, key: String)?
        for body in bodies {
            let expanded = body.rect.insetBy(
                dx: -(size.width / 2 + config.gutter),
                dy: -(size.height / 2 + config.gutter),
            )
            guard let hit = sweptCenter(c0: c0, velocity: velocity, box: expanded) else { continue }
            let isBetter: Bool =
                if let current = best {
                    hit.t < current.t - 1e-9
                        || (abs(hit.t - current.t) <= 1e-9 && body.id.orderKey < current.key)
                } else {
                    true
                }
            if isBetter {
                best = (hit.t, hit.axis, hit.normal, body.id.orderKey)
            }
        }
        guard let b = best else { return nil }
        return (b.t, b.axis, b.normal)
    }

    /// Swept point-vs-AABB (slab method). Returns the earliest entry time in `[0, 1)` at which the point
    /// `c0` moving by `velocity` enters `box`, plus the contact axis and the outward normal — or `nil`
    /// when the path does not enter the box during this move.
    static func sweptCenter(
        c0: CGPoint,
        velocity: CGVector,
        box: CGRect,
    ) -> (t: CGFloat, axis: Axis, normal: CGVector)? {
        // Per-axis (entry, exit) parameter window. A zero-velocity axis is "inside its slab for all time"
        // only when the point already lies within it, else there is no collision at all.
        func slab(p: CGFloat, v: CGFloat, lo: CGFloat, hi: CGFloat) -> (entry: CGFloat, exit: CGFloat)? {
            // STRICT membership for a zero-velocity axis: a centre sitting EXACTLY on the gutter-inflated
            // boundary (`p == lo`/`p == hi`) is one gutter clear on this axis — NOT overlapping — so it
            // must not block motion along the perpendicular axis. Inclusive (`>=`/`<=`) here froze a
            // horizontal drag against a neighbour exactly one gutter above/below (the steady state of any
            // tidied grid, whose row pitch is height + gutter). Matches clampResize's strict span tests.
            if v == 0 { return (p > lo && p < hi) ? (-.infinity, .infinity) : nil }
            let t1 = (lo - p) / v, t2 = (hi - p) / v
            return (Swift.min(t1, t2), Swift.max(t1, t2))
        }
        guard let xs = slab(p: c0.x, v: velocity.dx, lo: box.minX, hi: box.maxX),
              let ys = slab(p: c0.y, v: velocity.dy, lo: box.minY, hi: box.maxY) else { return nil }
        let entry = Swift.max(xs.entry, ys.entry)
        let exit = Swift.min(xs.exit, ys.exit)
        // Slabs must overlap in time, the contact must start before the move ends, and the box must be
        // ahead (not already passed).
        guard entry <= exit, entry < 1, exit > 0 else { return nil }
        let t = Swift.max(0, entry)
        if xs.entry > ys.entry {
            return (t, .x, CGVector(dx: velocity.dx > 0 ? -1 : 1, dy: 0))
        }
        return (t, .y, CGVector(dx: 0, dy: velocity.dy > 0 ? -1 : 1))
    }

    // MARK: - Small helpers

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    /// Muuri-style normalized coverage: the overlap area over the smaller of the two rects' dimensions,
    /// so a small box fully inside a large one still reads as 1.0.
    private static func coverageFraction(_ target: CGRect, _ other: CGRect) -> CGFloat {
        let denom = Swift.min(target.width, other.width) * Swift.min(target.height, other.height)
        guard denom > 0 else { return 0 }
        return intersectionArea(target, other) / denom
    }

    private static func verticalSpansOverlap(_ a: CGRect, _ b: CGRect) -> Bool { a.minY < b.maxY && b.minY < a.maxY }
    private static func horizontalSpansOverlap(_ a: CGRect, _ b: CGRect) -> Bool { a.minX < b.maxX && b.minX < a.maxX }

    private static func approxEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    /// Clamps the origin finite + within ``Canvas/coordinateBound`` but passes the size through verbatim
    /// (a slide / make-space never resizes the dragged body) — the ``CanvasSnap`` sanitize rule.
    static func sanitizedPreservingSize(_ frame: CGRect) -> CGRect {
        let b = Canvas.coordinateBound
        let x = frame.origin.x.isFinite ? Swift.min(Swift.max(frame.origin.x, -b), b) : 0
        let y = frame.origin.y.isFinite ? Swift.min(Swift.max(frame.origin.y, -b), b) : 0
        let w = frame.width.isFinite ? Swift.min(Swift.max(frame.width, 0), b) : Canvas.minItemSize.width
        let h = frame.height.isFinite ? Swift.min(Swift.max(frame.height, 0), b) : Canvas.minItemSize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
