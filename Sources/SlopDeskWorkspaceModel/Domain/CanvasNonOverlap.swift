import CoreGraphics
import CSlopDeskFFI

// MARK: - CanvasNonOverlap (non-overlapping layout for canvas drags)

/// Non-overlap layout for canvas move/resize drags: the dragged body **slides flush** along its
/// neighbours' boundaries instead of overlapping, and on an insert-intent drop the surrounded
/// neighbours **part to make room**. The companion to ``CanvasSnap`` — it runs STRICTLY AFTER it,
/// consuming the snapped frame as the dragged body's target, and shares the same gutter so a
/// gutter-snapped box is already at the non-overlap boundary (the slide is then a no-op at a snap
/// line — the two solvers reinforce, never fight).
///
/// The solver is `rust/slopdesk-workspace`'s `canvas_non_overlap` (docs/55). What stays here is the
/// body model the canvas speaks in; what crossed is every rule that decides where a rect goes.
///
/// ### Two modes, two masses
/// The two requested behaviours need OPPOSITE mass models, so they are split:
/// - **SLIDE** (the live-drag default, every frame): the dragged body YIELDS — a swept-AABB
///   collide-and-slide sweeps it from its persisted origin to the snapped target against the
///   gutter-inflated neighbour/group bodies; on the earliest contact it cancels the into-face motion
///   and re-sweeps the tangential remainder, gliding the box flush one gutter off its neighbours and
///   tucking it into inside corners. ONLY the dragged body moves, so it renders through the SAME
///   item-local gesture-state channel ``CanvasSnap`` already uses.
/// - **MAKE-SPACE** (commit-only, the single `.onEnded`): the NEIGHBOURS yield — when the dropped
///   target shows insert-intent, the dragged body is PINNED at the target and a minimal-movement
///   separation relaxation flows every other body apart to admit it. On the infinite plane there is
///   always room, so this always converges; the store commits the dragged frame + the displaced
///   neighbours atomically.
///
/// Every entry point is a total, deterministic, path-INDEPENDENT function of `CGRect`s, so
/// `preview ≡ commit` holds by construction: the live drag and the single `.onEnded` commit
/// recompute from the same raw inputs.
public enum CanvasNonOverlap {
    // MARK: Body model

    /// Which kind of canvas object a collision body stands for. A `.group` body is the derived
    /// ``Canvas/groupBoundingBox(_:)`` treated as one rigid box — its solved shift is distributed to
    /// all its members by the store, so group-vs-group / pane-vs-group non-overlap falls out of
    /// feeding group boxes into the SAME solver.
    public enum BodyID: Hashable, Sendable {
        case pane(PaneID)
        case group(PaneGroupID)

        /// The `(kind, id)` pair the crate sorts by. Panes before groups, then by UUID bytes — which
        /// is the same total order the old `orderKey` string produced, and is what makes the solver
        /// independent of the order the `bodies` array happened to arrive in.
        var ffi: SlopDeskWsBodyRef {
            switch self {
            case let .pane(id): SlopDeskWsBodyRef(kind: 0, id: id.ffi)
            case let .group(id): SlopDeskWsBodyRef(kind: 1, id: SlopDeskWsUuid(id.raw))
            }
        }

        init(ffi: SlopDeskWsBodyRef) {
            self = ffi.kind == 1 ? .group(PaneGroupID(raw: ffi.id.uuid)) : .pane(PaneID(ffi: ffi.id))
        }
    }

    /// One collision body: an ungrouped pane frame, or a group's bounding box.
    public struct Body: Sendable, Equatable {
        public let id: BodyID
        public var rect: CGRect
        public init(id: BodyID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }

        var ffi: SlopDeskWsBody { SlopDeskWsBody(id: id.ffi, rect: SlopDeskWsRect(rect)) }
    }

    // MARK: Config

    /// Tuning knobs, all in canvas points (1:1 with screen — the camera is a pure translate).
    ///
    /// The defaults come from the crate rather than being transcribed here: the gutter the snapper
    /// uses and the gutter the slide keeps have to be the SAME number for a gutter-snapped box to
    /// already sit at the non-overlap boundary, and two copies of it would be two chances to drift.
    public struct Config: Sendable, Equatable {
        /// The non-overlap gap, shared with ``CanvasSnap/Config``.
        public var gutter: CGFloat
        /// Swept back-off along the contact normal so an abutting box is not re-detected as a
        /// zero-distance hit (stops seam-catch on a shared edge).
        public var skin: CGFloat
        /// Re-sweep cap for the slide (each pass removes one contact axis; a corner needs 2) — a
        /// hard termination bound.
        public var maxSlidePasses: Int
        /// Iteration cap for the make-space separation relaxation — a hard termination bound.
        public var maxRelaxIterations: Int
        /// Make-space intent gate: the normalized overlap coverage a drop must reach before
        /// neighbours part. Below it the box just rests flush (slide only).
        public var insertCoverage: CGFloat
        /// Master switch (the setting-off / ⌘-bypass escape hatch — then every entry point is
        /// identity).
        public var enabled: Bool

        public init(
            gutter: CGFloat? = nil,
            skin: CGFloat? = nil,
            maxSlidePasses: Int? = nil,
            maxRelaxIterations: Int? = nil,
            insertCoverage: CGFloat? = nil,
            enabled: Bool? = nil,
        ) {
            let defaults = slopdesk_ws_non_overlap_default()
            self.gutter = gutter ?? defaults.gutter
            self.skin = skin ?? defaults.skin
            self.maxSlidePasses = maxSlidePasses ?? Int(defaults.max_slide_passes)
            self.maxRelaxIterations = maxRelaxIterations ?? Int(defaults.max_relax_iterations)
            self.insertCoverage = insertCoverage ?? defaults.insert_coverage
            self.enabled = enabled ?? defaults.enabled
        }

        /// Everything off — the ⌘ / setting-off bypass (matches ``CanvasSnap/Config/disabled``).
        public static let disabled = Self(enabled: false)

        var ffi: SlopDeskWsNonOverlap {
            SlopDeskWsNonOverlap(
                gutter: gutter,
                skin: skin,
                max_slide_passes: UInt32(max(0, maxSlidePasses)),
                max_relax_iterations: UInt32(max(0, maxRelaxIterations)),
                insert_coverage: insertCoverage,
                enabled: enabled,
            )
        }
    }

    // MARK: Results

    /// The live-drag output: only the dragged box moves. Rendered through the dragged pane's own
    /// gesture state — no neighbour is touched live.
    public struct SlideResult: Sendable, Equatable {
        public var frame: CGRect
        public init(frame: CGRect) { self.frame = frame }
    }

    /// The commit output: the new frame of every body that moved — the dragged body plus every
    /// neighbour (or group box) the make-space relaxation displaced. The store writes these in ONE
    /// canvas mutation.
    public struct CommitResult: Sendable, Equatable {
        public var frames: [BodyID: CGRect]
        public init(frames: [BodyID: CGRect]) { self.frames = frames }
    }

    // MARK: - SLIDE (live default + commit)

    /// Slides the dragged body to `snapped` without overlapping any `bodies`, gliding flush one
    /// gutter off each. `from` is the body's PERSISTED origin (the fixed gesture start), so the
    /// result is a pure function of the raw translation rather than of frame-to-frame motion.
    /// Identity when disabled or there is nothing to hit.
    public static func slide(_ snapped: CGRect, from: CGPoint, bodies: [Body], config: Config) -> SlideResult {
        withBodies(bodies) { buffer in
            SlideResult(frame: slopdesk_ws_slide(
                SlopDeskWsRect(snapped),
                SlopDeskWsPoint(from),
                buffer.baseAddress,
                buffer.count,
                config.ffi,
            ).rect)
        }
    }

    // MARK: - MAKE-SPACE (commit only)

    /// The neighbours parted to admit a drop at `target`, or `nil` when insert-intent did NOT fire —
    /// the box is merely resting against a boundary, and the caller commits the slid frame with
    /// nothing else moved. Always `nil` when disabled.
    public static func makeSpace(target: CGRect, draggedID: BodyID, bodies: [Body], config: Config) -> CommitResult? {
        let frames = withBodies(bodies) { buffer in
            commit { out, cap in
                slopdesk_ws_make_space(
                    SlopDeskWsRect(target),
                    draggedID.ffi,
                    buffer.baseAddress,
                    buffer.count,
                    config.ffi,
                    out,
                    cap,
                )
            }
        }
        return frames.map(CommitResult.init(frames:))
    }

    /// The separation pass around a pinned body: everyone else moves, it does not. The answer
    /// INCLUDES the pinned body at its target, so one write commits the whole arrangement.
    public static func separate(pinnedID: BodyID, pinnedRect: CGRect, bodies: [Body], config: Config) -> CommitResult {
        let frames = withBodies(bodies) { buffer in
            commit { out, cap in
                slopdesk_ws_separate(
                    pinnedID.ffi,
                    SlopDeskWsRect(pinnedRect),
                    buffer.baseAddress,
                    buffer.count,
                    config.ffi,
                    out,
                    cap,
                )
            }
        }
        return CommitResult(frames: frames ?? [:])
    }

    // MARK: - Resize

    /// A resize clamped off its neighbours: only the edges the anchor MOVES are pushed back, so the
    /// pinned edge never creeps.
    public static func clampResize(
        _ frame: CGRect,
        anchor: ResizeAnchor,
        bodies: [Body],
        minSize: CGSize,
        config: Config,
    ) -> CGRect {
        withBodies(bodies) { buffer in
            slopdesk_ws_clamp_resize(
                SlopDeskWsRect(frame),
                anchor.ffiByte,
                buffer.baseAddress,
                buffer.count,
                minSize.width,
                minSize.height,
                config.ffi,
            ).rect
        }
    }

    /// The minimum push that would part two rects by `gutter`, or `nil` when they already are.
    public static func separation(_ a: CGRect, _ b: CGRect, gutter: CGFloat) -> CGVector? {
        var dx = 0.0
        var dy = 0.0
        let parted = slopdesk_ws_separation(SlopDeskWsRect(a), SlopDeskWsRect(b), gutter, &dx, &dy)
        return parted ? CGVector(dx: dx, dy: dy) : nil
    }

    // MARK: - Marshalling

    /// Lends the bodies for exactly one call. The `withUnsafeMutableBufferPointer` scope IS the
    /// safety contract, so nothing else goes inside it.
    private static func withBodies<T>(
        _ bodies: [Body],
        _ body: (UnsafeMutableBufferPointer<SlopDeskWsBody>) -> T,
    ) -> T {
        var encoded = bodies.map(\.ffi)
        return encoded.withUnsafeMutableBufferPointer { buffer in body(buffer) }
    }

    /// Reads a committed arrangement, with the retry docs/55 §4 describes.
    ///
    /// `nil` is "the rule did not fire", which the crate spells as `SIZE_MAX` precisely because it is
    /// a different answer from a commit of zero bodies.
    private static func commit(_ call: (UnsafeMutablePointer<SlopDeskWsBody>?, Int) -> Int) -> [BodyID: CGRect]? {
        var out = [SlopDeskWsBody](repeating: SlopDeskWsBody(), count: 32)
        var count = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        if count == Int(bitPattern: UInt.max) { return nil }
        if count > out.count {
            out = [SlopDeskWsBody](repeating: SlopDeskWsBody(), count: count)
            count = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        }
        guard count <= out.count else { return [:] }
        var frames: [BodyID: CGRect] = [:]
        for body in out[0..<count] {
            frames[BodyID(ffi: body.id)] = body.rect.rect
        }
        return frames
    }
}
