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
    pub(crate) const fn new(origin: Point, size: Size) -> Self {
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
}

/// The smallest a pane may be, in points.
///
/// It is the terminal grid's floor, not an aesthetic one: below this a pane's columns and rows stop
/// being a usable grid.
pub const MIN_ITEM_SIZE: Size = Size::new(160.0, 120.0);
