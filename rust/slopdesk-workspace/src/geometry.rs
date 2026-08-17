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

/// The smallest a pane may be, in points.
///
/// It is the terminal grid's floor, not an aesthetic one: below this a pane's columns and rows stop
/// being a usable grid.
pub const MIN_ITEM_SIZE: Size = Size::new(160.0, 120.0);

#[cfg(test)]
mod tests {
    use super::Rect;

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
}
