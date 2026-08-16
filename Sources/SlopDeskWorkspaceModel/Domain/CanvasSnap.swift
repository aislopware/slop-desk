import CoreGraphics
import CSlopDeskFFI

// MARK: - CanvasSnap (the magnetic solver behind every canvas drag)

/// Where a dragged pane WANTS to go: the magnetic alignment solver, its asymmetric hold, and the
/// guides the view draws while a snap is live. The companion to ``CanvasNonOverlap``, which runs
/// strictly after it and decides where the pane is ALLOWED to go.
///
/// The solver is `rust/slopdesk-workspace`'s `canvas_snap` (docs/55). What stays here is the
/// vocabulary the view speaks in — a ``Guide`` is drawn by SwiftUI and a ``Stick`` is carried in
/// gesture state — and what crossed is every rule that turns a raw translation into a frame.
///
/// ### The hold is why `previous` crosses in both directions
/// Engage and release are asymmetric on purpose: a stick grabs at a closer distance than it lets go
/// at, so a drag does not chatter at the boundary. That means a solve is not a pure function of the
/// current frame alone — the caller hands back last frame's sticks, and the solver decides whether
/// they survive. Everything else is still path-independent, so `preview ≡ commit` holds.
public enum CanvasSnap {
    // MARK: Config

    /// The snapper's tuning, in canvas points.
    ///
    /// The defaults come from the crate rather than being transcribed: ``CanvasNonOverlap/Config``
    /// shares the gutter, and one number in two places is one chance for a gutter-snapped box to
    /// stop sitting exactly at the non-overlap boundary.
    public struct Config: Sendable, Equatable {
        /// How near an edge must come to engage a stick.
        public var engage: CGFloat
        /// How far it must travel to release one — deliberately larger than ``engage``.
        public var release: CGFloat
        /// The gap a pane-to-pane snap leaves, shared with ``CanvasNonOverlap/Config/gutter``.
        public var gutter: CGFloat
        /// The grid's pitch.
        public var gridSpacing: CGFloat
        /// The grid's engage threshold.
        public var gridEngage: CGFloat
        /// The grid's release threshold.
        public var gridRelease: CGFloat
        /// Whether panes attract.
        public var snapsToPanes: Bool
        /// Whether the grid does.
        public var snapsToGrid: Bool

        public init(
            engage: CGFloat? = nil,
            release: CGFloat? = nil,
            gutter: CGFloat? = nil,
            gridSpacing: CGFloat? = nil,
            gridEngage: CGFloat? = nil,
            gridRelease: CGFloat? = nil,
            snapsToPanes: Bool? = nil,
            snapsToGrid: Bool? = nil,
        ) {
            let defaults = slopdesk_ws_snap_default()
            self.engage = engage ?? defaults.engage
            self.release = release ?? defaults.release
            self.gutter = gutter ?? defaults.gutter
            self.gridSpacing = gridSpacing ?? defaults.grid_spacing
            self.gridEngage = gridEngage ?? defaults.grid_engage
            self.gridRelease = gridRelease ?? defaults.grid_release
            self.snapsToPanes = snapsToPanes ?? defaults.snaps_to_panes
            self.snapsToGrid = snapsToGrid ?? defaults.snaps_to_grid
        }

        /// Everything off — the escape hatch behind "hold a modifier to drag freely".
        public static let disabled = Self(snapsToPanes: false, snapsToGrid: false)

        var ffi: SlopDeskWsSnap {
            SlopDeskWsSnap(
                engage: engage,
                release: release,
                gutter: gutter,
                grid_spacing: gridSpacing,
                grid_engage: gridEngage,
                grid_release: gridRelease,
                snaps_to_panes: snapsToPanes,
                snaps_to_grid: snapsToGrid,
            )
        }
    }

    // MARK: Guides

    /// The candidate class that produced a guide. The order IS the priority — lower is stronger —
    /// and the view's style cue (centres draw dashed, the Keynote distinction).
    public enum GuideKind: Int, Sendable, Equatable, Hashable, Comparable {
        case gutter = 0
        case edge
        case center
        case viewportEdge
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init(ffiByte: UInt8) {
            self = Self(rawValue: Int(ffiByte)) ?? .gutter
        }
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

        init(ffi: SlopDeskWsGuide) {
            self.init(
                orientation: ffi.orientation == 1 ? .horizontal : .vertical,
                position: ffi.position,
                start: ffi.start,
                end: ffi.end,
                kind: GuideKind(ffiByte: ffi.kind),
            )
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

        init?(ffi: SlopDeskWsStick) {
            guard ffi.present else { return nil }
            let edge: OwnEdge =
                switch ffi.own_edge {
                case 1: .mid
                case 2: .max
                default: .min
                }
            self.init(ownEdge: edge, target: ffi.target, isGrid: ffi.is_grid)
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
        solve(others: others, previous: previous) { rects, answer, guides, cap, stickX, stickY in
            slopdesk_ws_snap_move(
                SlopDeskWsRect(proposed),
                rects.baseAddress,
                rects.count,
                SlopDeskWsRect(viewport ?? .zero),
                viewport != nil,
                config.ffi,
                stickX,
                stickY,
                answer,
                guides,
                cap,
            )
        }
    }

    // MARK: Resize

    /// Snaps a RESIZE drag.
    ///
    /// Only the edges the anchor MOVES are magnetic, and centres are skipped entirely: a resize
    /// aligns edges, not centres. A candidate that would push the pane below `minSize` is DISCARDED
    /// rather than clamped, so every guide the view draws is a true statement and the pinned edge
    /// never shifts.
    public static func resize(
        _ proposed: CGRect,
        anchor: ResizeAnchor,
        others: [CGRect],
        viewport: CGRect? = nil,
        minSize: CGSize = Canvas.minItemSize,
        config: Config,
        previous: Resolution? = nil,
    ) -> Resolution {
        solve(others: others, previous: previous) { rects, answer, guides, cap, stickX, stickY in
            slopdesk_ws_snap_resize(
                SlopDeskWsRect(proposed),
                anchor.ffiByte,
                rects.baseAddress,
                rects.count,
                SlopDeskWsRect(viewport ?? .zero),
                viewport != nil,
                minSize.width,
                minSize.height,
                config.ffi,
                stickX,
                stickY,
                answer,
                guides,
                cap,
            )
        }
    }

    // MARK: - Marshalling

    /// Runs a solve and reads back both halves of its answer.
    ///
    /// The frame and the sticks are FIXED-size and always written, so a guide buffer that turned out
    /// too small costs one retry of the guides and never of the frame — which matters because a
    /// commit draws no guides at all and should never have to size a buffer for them.
    private static func solve(
        others: [CGRect],
        previous: Resolution?,
        _ call: (
            UnsafeMutableBufferPointer<SlopDeskWsRect>,
            UnsafeMutablePointer<SlopDeskWsSnapAnswer>?,
            UnsafeMutablePointer<SlopDeskWsGuide>?,
            Int,
            SlopDeskWsStick,
            SlopDeskWsStick,
        ) -> Int,
    ) -> Resolution {
        var rects = others.map(SlopDeskWsRect.init)
        var answer = SlopDeskWsSnapAnswer()
        var guides = [SlopDeskWsGuide](repeating: SlopDeskWsGuide(), count: 8)
        let stickX = ffiStick(previous?.stickX)
        let stickY = ffiStick(previous?.stickY)

        var needed = rects.withUnsafeMutableBufferPointer { input in
            guides.withUnsafeMutableBufferPointer { buffer in
                call(input, &answer, buffer.baseAddress, buffer.count, stickX, stickY)
            }
        }
        if needed > guides.count {
            guides = [SlopDeskWsGuide](repeating: SlopDeskWsGuide(), count: needed)
            needed = rects.withUnsafeMutableBufferPointer { input in
                guides.withUnsafeMutableBufferPointer { buffer in
                    call(input, &answer, buffer.baseAddress, buffer.count, stickX, stickY)
                }
            }
        }
        return Resolution(
            frame: answer.frame.rect,
            guides: needed <= guides.count ? guides[0..<needed].map(Guide.init(ffi:)) : [],
            stickX: Stick(ffi: answer.stick_x),
            stickY: Stick(ffi: answer.stick_y),
        )
    }

    /// A held stick on its way OUT to the solver. Absence is a flag rather than a null pointer: the
    /// struct is by-value, and one shape for "held" and "not held" is one thing to get wrong.
    private static func ffiStick(_ stick: Stick?) -> SlopDeskWsStick {
        guard let stick else {
            return SlopDeskWsStick(present: false, own_edge: 0, target: 0, is_grid: false)
        }
        let edge: UInt8 =
            switch stick.ownEdge {
            case .min: 0
            case .mid: 1
            case .max: 2
            }
        return SlopDeskWsStick(present: true, own_edge: edge, target: stick.target, is_grid: stick.isGrid)
    }
}
