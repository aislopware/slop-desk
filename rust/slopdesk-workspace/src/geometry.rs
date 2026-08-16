//! The plane's coordinates, and the sanitation every one of them passes through.
//!
//! Canvas space is unbounded and its origin is the top left, with y increasing downward — the same
//! orientation the views use, so there is no flip anywhere in the domain. Screen space is the same
//! space translated by the camera, and nothing else: there is no scale term to invert.
//!
//! Every coordinate that reaches the plane is BOUNDED. A hand-edited or corrupt file with
//! extreme-but-finite numbers would otherwise overflow to infinity inside a bounding-box union, and
//! the encoder would then refuse the whole document — one bad number silently ending all
//! persistence. Clamping at a magnitude far past any real layout costs nothing and closes that.

/// A point on the plane.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point {
    /// Horizontal, increasing right.
    pub x: f64,
    /// Vertical, increasing DOWN.
    pub y: f64,
}

impl Point {
    /// The origin.
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    /// A point.
    #[must_use]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// An extent.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Size {
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl Size {
    /// The empty size.
    pub const ZERO: Self = Self {
        width: 0.0,
        height: 0.0,
    };

    /// A size.
    #[must_use]
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

/// An axis-aligned rectangle, its origin at the top-left corner.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    /// The top-left corner.
    pub origin: Point,
    /// The extent.
    pub size: Size,
}

impl Rect {
    /// A rect from its four numbers.
    #[must_use]
    pub const fn xywh(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            origin: Point::new(x, y),
            size: Size::new(width, height),
        }
    }

    /// A rect from an origin and a size.
    #[must_use]
    pub const fn new(origin: Point, size: Size) -> Self {
        Self { origin, size }
    }

    /// The left edge.
    #[must_use]
    pub const fn min_x(self) -> f64 {
        self.origin.x
    }

    /// The top edge.
    #[must_use]
    pub const fn min_y(self) -> f64 {
        self.origin.y
    }

    /// The right edge.
    #[must_use]
    pub const fn max_x(self) -> f64 {
        self.origin.x + self.size.width
    }

    /// The bottom edge.
    #[must_use]
    pub const fn max_y(self) -> f64 {
        self.origin.y + self.size.height
    }

    /// The horizontal centre.
    #[must_use]
    pub const fn mid_x(self) -> f64 {
        self.origin.x + self.size.width / 2.0
    }

    /// The vertical centre.
    #[must_use]
    pub const fn mid_y(self) -> f64 {
        self.origin.y + self.size.height / 2.0
    }

    /// The centre.
    #[must_use]
    pub const fn center(self) -> Point {
        Point::new(self.mid_x(), self.mid_y())
    }

    /// The same rect moved.
    #[must_use]
    pub const fn offset_by(self, dx: f64, dy: f64) -> Self {
        Self::xywh(
            self.origin.x + dx,
            self.origin.y + dy,
            self.size.width,
            self.size.height,
        )
    }

    /// The same rect grown by the given amounts on every side. Negative arguments shrink it.
    #[must_use]
    pub const fn outset_by(self, dx: f64, dy: f64) -> Self {
        Self::xywh(
            self.origin.x - dx,
            self.origin.y - dy,
            self.size.width + 2.0 * dx,
            self.size.height + 2.0 * dy,
        )
    }

    /// Whether two rects share any area. Edge contact alone is NOT an intersection, which is what
    /// lets two snapped-flush panes sit side by side without reading as overlapping.
    #[must_use]
    pub const fn intersects(self, other: Self) -> bool {
        self.min_x() < other.max_x()
            && other.min_x() < self.max_x()
            && self.min_y() < other.max_y()
            && other.min_y() < self.max_y()
    }

    /// The shared area, or `None` when they only touch or miss entirely.
    #[must_use]
    pub fn intersection(self, other: Self) -> Option<Self> {
        let left = self.min_x().max(other.min_x());
        let right = self.max_x().min(other.max_x());
        let top = self.min_y().max(other.min_y());
        let bottom = self.max_y().min(other.max_y());
        (left < right && top < bottom).then(|| Self::xywh(left, top, right - left, bottom - top))
    }

    /// The smallest rect containing both.
    ///
    /// Unlike [`intersection`](Self::intersection) this is total: two rects that miss entirely
    /// still have a union, which is what makes it foldable over a selection without a special
    /// first case.
    #[must_use]
    pub fn union(self, other: Self) -> Self {
        let left = self.min_x().min(other.min_x());
        let right = self.max_x().max(other.max_x());
        let top = self.min_y().min(other.min_y());
        let bottom = self.max_y().max(other.max_y());
        Self::xywh(left, top, right - left, bottom - top)
    }

    /// The area.
    #[must_use]
    pub const fn area(self) -> f64 {
        self.size.width * self.size.height
    }

    /// Whether a point lies inside, edges included.
    #[must_use]
    pub const fn contains(self, point: Point) -> bool {
        point.x >= self.min_x()
            && point.x <= self.max_x()
            && point.y >= self.min_y()
            && point.y <= self.max_y()
    }
}

/// The smallest a pane may be, in canvas points.
///
/// It is the terminal grid's floor, not an aesthetic one: below this a pane's columns and rows stop
/// being a usable grid.
pub const MIN_ITEM_SIZE: Size = Size::new(160.0, 120.0);

/// The size a brand-new pane opens at — a comfortable shell.
pub const DEFAULT_ITEM_SIZE: Size = Size::new(640.0, 420.0);

/// The step between cascaded new panes: one title bar and a margin.
pub const CASCADE_STEP: f64 = 28.0;

/// How far outside the viewport a pane is kept mounted, so one about to pan in is already warm
/// before it crosses the edge.
pub const CULL_MARGIN: f64 = 600.0;

/// The largest magnitude any canvas coordinate may hold.
///
/// Far past any real layout — thousands of screens — but bounding it is what stops a corrupt file's
/// extreme-but-finite numbers from overflowing to infinity in a bounding-box union.
pub const COORDINATE_BOUND: f64 = 1_000_000.0;

/// Bounds one coordinate: a non-finite value collapses to zero, a finite one is clamped.
#[must_use]
pub fn sanitized_coordinate(value: f64) -> f64 {
    if value.is_finite() {
        value.clamp(-COORDINATE_BOUND, COORDINATE_BOUND)
    } else {
        0.0
    }
}

/// Bounds one extent: a non-finite value collapses to the floor, a finite one is floored and
/// capped.
#[must_use]
pub const fn sanitized_extent(value: f64, floor: f64) -> f64 {
    if value.is_finite() {
        value.max(floor).min(COORDINATE_BOUND)
    } else {
        floor
    }
}

/// A frame with a finite, bounded origin and a size at or above the floor.
///
/// Total by construction: every output is finite and at least the minimum size, so it is always
/// safe to render and to drive a terminal reflow with.
#[must_use]
pub fn sanitize(frame: Rect) -> Rect {
    Rect::xywh(
        sanitized_coordinate(frame.origin.x),
        sanitized_coordinate(frame.origin.y),
        sanitized_extent(frame.size.width, MIN_ITEM_SIZE.width),
        sanitized_extent(frame.size.height, MIN_ITEM_SIZE.height),
    )
}

/// The same sanitation with the SIZE passed through verbatim beyond finiteness.
///
/// A slide or a make-space MOVES a body that was already valid, and never resizes it — so flooring
/// its size here would silently grow a pane the user only dragged. A non-finite extent still has to
/// become something, and the floor is the only safe answer.
#[must_use]
pub fn sanitize_preserving_size(frame: Rect) -> Rect {
    Rect::xywh(
        sanitized_coordinate(frame.origin.x),
        sanitized_coordinate(frame.origin.y),
        passed_through_extent(frame.size.width, MIN_ITEM_SIZE.width),
        passed_through_extent(frame.size.height, MIN_ITEM_SIZE.height),
    )
}

/// One extent kept as it is, bounded but not floored — with a non-finite one still forced onto the
/// minimum, because it has to become something and zero is not a pane.
const fn passed_through_extent(value: f64, fallback: f64) -> f64 {
    if value.is_finite() {
        value.max(0.0).min(COORDINATE_BOUND)
    } else {
        fallback
    }
}

/// The viewport's pan over one tab's plane: the canvas point shown at its top-left corner.
///
/// There is no scale field, and its absence is the enforcement rather than a simplification. A
/// terminal surface sizes itself from its host view's bounds in POINTS and pins its layer to those
/// bounds; a scale on any ancestor would desync that and break the one-to-one mouse mapping. A
/// field that does not exist cannot be set by a future caller who did not read this paragraph.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Camera {
    /// The canvas-space point at the viewport's top-left.
    pub origin: Point,
}

impl Camera {
    /// The camera at the canvas origin.
    pub const ZERO: Self = Self { origin: Point::ZERO };

    /// A camera.
    #[must_use]
    pub const fn new(origin: Point) -> Self {
        Self { origin }
    }

    /// The same camera panned. With no scale term, a screen-space drag IS the canvas-space delta.
    #[must_use]
    pub const fn translated(self, dx: f64, dy: f64) -> Self {
        Self {
            origin: Point::new(self.origin.x + dx, self.origin.y + dy),
        }
    }

    /// A camera whose origin is finite and bounded, so a corrupt one can never make a save throw.
    #[must_use]
    pub fn sanitized(self) -> Self {
        Self {
            origin: Point::new(
                sanitized_coordinate(self.origin.x),
                sanitized_coordinate(self.origin.y),
            ),
        }
    }

    /// The viewport in canvas space.
    #[must_use]
    pub const fn viewport_rect(self, viewport: Size) -> Rect {
        Rect::new(self.origin, viewport)
    }
}

/// The on-screen rect for a canvas-space frame — a pure translate, with the extent copied verbatim.
#[must_use]
pub const fn screen_rect(frame: Rect, camera: Camera) -> Rect {
    Rect::xywh(
        frame.origin.x - camera.origin.x,
        frame.origin.y - camera.origin.y,
        frame.size.width,
        frame.size.height,
    )
}

/// The canvas-space point for an on-screen one.
#[must_use]
pub const fn canvas_point(point: Point, camera: Camera) -> Point {
    Point::new(point.x + camera.origin.x, point.y + camera.origin.y)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the fixtures are exact integers and halves of the plane's own constants"
    )]

    use super::{
        COORDINATE_BOUND, Camera, MIN_ITEM_SIZE, Point, Rect, Size, canvas_point, sanitize,
        sanitize_preserving_size, screen_rect,
    };

    #[test]
    fn the_camera_maps_both_ways_without_a_scale_to_invert() {
        let camera = Camera::new(Point::new(100.0, 50.0));
        let frame = Rect::xywh(150.0, 80.0, 640.0, 420.0);
        let on_screen = screen_rect(frame, camera);
        assert_eq!(on_screen, Rect::xywh(50.0, 30.0, 640.0, 420.0));
        assert_eq!(
            canvas_point(Point::new(50.0, 30.0), camera),
            frame.origin,
            "and the inverse lands back on the same canvas point",
        );
    }

    #[test]
    fn a_pan_is_the_drag_itself() {
        assert_eq!(
            Camera::new(Point::new(10.0, 10.0)).translated(-5.0, 20.0).origin,
            Point::new(5.0, 30.0),
        );
    }

    #[test]
    fn touching_edges_are_not_an_overlap() {
        let left = Rect::xywh(0.0, 0.0, 100.0, 100.0);
        let flush = Rect::xywh(100.0, 0.0, 100.0, 100.0);
        assert!(
            !left.intersects(flush),
            "two snapped-flush panes must be able to sit side by side"
        );
        assert_eq!(left.intersection(flush), None);
        assert!(left.intersects(Rect::xywh(99.0, 0.0, 100.0, 100.0)));
    }

    #[test]
    fn the_intersection_is_the_shared_area() {
        let a = Rect::xywh(0.0, 0.0, 100.0, 100.0);
        let b = Rect::xywh(50.0, 25.0, 100.0, 100.0);
        assert_eq!(a.intersection(b), Some(Rect::xywh(50.0, 25.0, 50.0, 75.0)));
        assert_eq!(a.intersection(Rect::xywh(500.0, 0.0, 10.0, 10.0)), None);
    }

    #[test]
    fn a_corrupt_coordinate_collapses_instead_of_ending_all_persistence() {
        let sane = sanitize(Rect::xywh(f64::NAN, f64::INFINITY, 640.0, 420.0));
        assert_eq!(sane.origin, Point::ZERO);
        assert_eq!(sane.size, Size::new(640.0, 420.0));
    }

    #[test]
    fn an_extreme_but_finite_coordinate_is_clamped_so_a_union_cannot_overflow() {
        let sane = sanitize(Rect::xywh(1e30, -1e30, 1e30, 640.0));
        assert_eq!(sane.origin, Point::new(COORDINATE_BOUND, -COORDINATE_BOUND));
        assert_eq!(sane.size.width, COORDINATE_BOUND);
    }

    #[test]
    fn a_sub_minimum_pane_is_floored_to_a_usable_grid() {
        let sane = sanitize(Rect::xywh(0.0, 0.0, 10.0, 1.0));
        assert_eq!(sane.size, MIN_ITEM_SIZE);
        assert_eq!(
            sanitize(Rect::xywh(0.0, 0.0, f64::NAN, f64::NAN)).size,
            MIN_ITEM_SIZE,
            "and a nonsense extent lands on the floor too, never on zero",
        );
    }

    #[test]
    fn the_size_preserving_form_still_refuses_a_non_finite_extent() {
        let moved = sanitize_preserving_size(Rect::xywh(f64::NAN, 12.0, 640.0, 420.0));
        assert_eq!(moved.origin, Point::new(0.0, 12.0));
        assert_eq!(
            moved.size,
            Size::new(640.0, 420.0),
            "a valid size survives the move untouched"
        );
    }

    #[test]
    fn a_camera_is_bounded_the_same_way_a_frame_is() {
        assert_eq!(
            Camera::new(Point::new(f64::NAN, 1e30)).sanitized().origin,
            Point::new(0.0, COORDINATE_BOUND)
        );
    }
}
