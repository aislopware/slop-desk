//! The measurements every sprite family shares.
//!
//! Ported from Ghostty's `src/font/sprite/draw/common.zig` (MIT), like the four families that use
//! it. The names are kept close to the original so the ports can be diffed against it; what changed
//! is the shape of the arguments — Ghostty threads its whole `font.Metrics` through every helper,
//! and here the three numbers a sprite actually needs are a [`Cell`].

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

/// The cell a sprite is drawn into, in device pixels.
///
/// `thickness` is the base a [`Thickness`] scales, and it is the SAME number the underline uses —
/// `FontMetrics::underline_thickness`, which is what Ghostty calls `box_thickness`. Sharing it is
/// deliberate: a box rule and an underline drawn at different weights on one screen read as a bug,
/// and there is no second measurement a font could offer that would be more right.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Cell {
    /// Cell width in device pixels.
    pub width: u32,
    /// Cell height in device pixels.
    pub height: u32,
    /// The base line weight, at least one pixel.
    pub thickness: u32,
}

/// How heavy a line is, relative to the cell's base thickness.
///
/// The reference has a third, `super_light`, at half the base. Nothing in the four ranges ported
/// here asks for it — it belongs to the Symbols-for-Legacy-Computing families, which are not drawn
/// — so it is not carried.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Thickness {
    /// The base weight.
    Light,
    /// Twice the base weight — what `━` and `┃` are.
    Heavy,
}

impl Thickness {
    /// This weight in pixels, given the cell's base.
    pub(crate) const fn height(self, base: u32) -> u32 {
        match self {
            Self::Light => base,
            Self::Heavy => base.saturating_mul(2),
        }
    }
}

/// The four shades a block element can be painted at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Shade {
    /// `░`, a quarter ink.
    Light,
    /// `▒`, half ink.
    Medium,
    /// `▓`, three-quarter ink.
    Dark,
    /// Solid.
    On,
}

impl Shade {
    /// The alpha this shade paints at.
    pub(crate) const fn alpha(self) -> u8 {
        match self {
            Self::Light => 0x40,
            Self::Medium => 0x80,
            Self::Dark => 0xC0,
            Self::On => 0xFF,
        }
    }
}

/// A fraction across the cell, horizontally or vertically.
///
/// The asymmetry between [`Self::min`] and [`Self::max`] is the whole point of the type and is
/// copied exactly from the reference. A min coordinate rounds the COMPLEMENTARY fraction from the
/// far edge; a max coordinate rounds directly. At an odd cell size that makes `start`→`half` and
/// `half`→`end` the same width — 4px each across 7 — where rounding both the same way would give 3
/// and 4 and leave `▌` and `▐` visibly different sizes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Frac(pub f64);

impl Frac {
    /// The cell's near edge.
    pub(crate) const ZERO: Self = Self(0.0);
    /// The centre line — the only interior fraction that has to tile exactly, which is why it is
    /// the only one that goes through this type rather than being a plain multiplication.
    pub(crate) const HALF: Self = Self(0.5);
    /// The cell's far edge.
    pub(crate) const FULL: Self = Self(1.0);

    /// This fraction as the MIN (left or top) coordinate of a block.
    pub(crate) fn min(self, size: u32) -> i32 {
        let s = f64::from(size);
        round_i32(s - ((1.0 - self.0) * s).round())
    }

    /// This fraction as the MAX (right or bottom) coordinate of a block.
    pub(crate) fn max(self, size: u32) -> i32 {
        let s = f64::from(size);
        round_i32((self.0 * s).round())
    }
}

/// Which style of line runs from an edge of the cell to its centre.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum LineStyle {
    /// No line on this edge.
    #[default]
    None,
    /// A light line.
    Light,
    /// A heavy line.
    Heavy,
    /// One half of a double line.
    Double,
}

impl LineStyle {
    /// Whether an edge carries any line at all — what a neighbouring arrow asks.
    pub(crate) const fn is_drawn(self) -> bool {
        !matches!(self, Self::None)
    }
}

/// A traditional intersection-style box-drawing character, one style per edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Lines {
    /// The line running up from the centre.
    pub up: LineStyle,
    /// The line running right from the centre.
    pub right: LineStyle,
    /// The line running down from the centre.
    pub down: LineStyle,
    /// The line running left from the centre.
    pub left: LineStyle,
}

impl Lines {
    /// A `Lines` with only the named edges set, for the dispatch table's readability.
    pub(crate) const fn of(up: LineStyle, right: LineStyle, down: LineStyle, left: LineStyle) -> Self {
        Self {
            up,
            right,
            down,
            left,
        }
    }
}

/// One side of a cell.
///
/// `CellEdge` and not `Edge` because `TerminalBindingAction`'s `Edge` — a split direction — already
/// holds that name in Swift, and `lint-invariants`' `wire-enums-agree` compares shared alphabets by
/// NAME. Two enums called `Edge` with different ordinals in one tree is the ambiguity that rule
/// exists to catch; this one never crosses the FFI, but the next one to take the name might.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellEdge {
    /// The top.
    Up,
    /// The right-hand side.
    Right,
    /// The bottom.
    Down,
    /// The left-hand side.
    Left,
}

impl CellEdge {
    /// All four, in the order [`JoinMask`] packs them.
    pub(crate) const ALL: [Self; 4] = [Self::Up, Self::Right, Self::Down, Self::Left];

    /// This edge's bit in a [`JoinMask`].
    const fn bit(self) -> u8 {
        match self {
            Self::Up => 1,
            Self::Right => 2,
            Self::Down => 4,
            Self::Left => 8,
        }
    }
}

/// Which of a cell's four sides has a box rule arriving at it from the neighbouring cell.
///
/// Only an arrow or a triangle carries one, and only because those are the two families whose shape
/// depends on what is NEXT to them. Every other sprite is decided by its codepoint alone — which is
/// what makes them cacheable by codepoint alone, and why this is a field of the cache key rather
/// than something the drawing code looks up.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct JoinMask(u8);

impl JoinMask {
    /// No rule arrives at any side — the standalone case, which never takes the sprite path.
    pub const NONE: Self = Self(0);

    /// This mask with `edge` added.
    #[must_use]
    pub const fn with(self, edge: CellEdge) -> Self {
        Self(self.0 | edge.bit())
    }

    /// Whether a rule arrives at `edge`.
    #[must_use]
    pub const fn has(self, edge: CellEdge) -> bool {
        self.0 & edge.bit() != 0
    }

    /// Whether no rule arrives at any side.
    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }
}

/// Half a value, floored — the centring arithmetic every family repeats.
#[expect(
    clippy::integer_division,
    reason = "a centred line starts on a whole pixel; the floor IS the measurement"
)]
pub(crate) const fn half(value: u32) -> u32 {
    value / 2
}

/// Where a centred line of `thick` pixels starts, across `size`.
pub(crate) const fn centered(size: u32, thick: u32) -> u32 {
    half(size.saturating_sub(thick))
}

/// A `u32` as a signed pixel coordinate, saturating.
pub(crate) const fn signed(value: u32) -> i32 {
    if value > i32::MAX as u32 {
        i32::MAX
    } else {
        value.cast_signed()
    }
}

/// A rounded `f64` as a signed pixel coordinate, saturating and NaN-safe.
#[expect(
    clippy::cast_possible_truncation,
    reason = "clamped into the i32 range before it is narrowed"
)]
pub(crate) const fn round_i32(value: f64) -> i32 {
    if value.is_nan() {
        return 0;
    }
    value.round().clamp(-2_147_483_000.0, 2_147_483_000.0) as i32
}

#[cfg(test)]
mod tests {
    use super::{Frac, Thickness, centered, half, signed};

    #[test]
    fn a_heavy_line_is_twice_a_light_one() {
        assert_eq!(Thickness::Light.height(3), 3);
        assert_eq!(Thickness::Heavy.height(3), 6);
        assert_eq!(Thickness::Heavy.height(u32::MAX), u32::MAX, "and never wraps");
    }

    #[test]
    fn the_two_halves_of_an_odd_cell_are_the_same_width() {
        // The rounding asymmetry this type exists for. Across 7 pixels, `start`→`half` runs 0..4
        // and `half`→`end` runs 3..7 — four pixels each, with one shared. Rounding both ends the
        // same way would give 3 and 4, and `▌` would be visibly narrower than `▐`.
        assert_eq!(Frac::ZERO.min(7), 0);
        assert_eq!(Frac::HALF.max(7), 4);
        assert_eq!(Frac::HALF.min(7), 3);
        assert_eq!(Frac::FULL.max(7), 7);
    }

    #[test]
    fn a_fraction_spans_the_whole_cell_at_the_edges() {
        assert_eq!(Frac::ZERO.min(20), 0);
        assert_eq!(Frac::FULL.max(20), 20);
        assert_eq!(Frac::HALF.min(20), 10, "an even cell splits cleanly");
        assert_eq!(Frac::HALF.max(20), 10);
    }

    #[test]
    fn centring_floors_and_never_underflows() {
        assert_eq!(half(7), 3);
        assert_eq!(centered(20, 2), 9);
        assert_eq!(centered(1, 4), 0, "a line wider than the cell starts at zero");
        assert_eq!(signed(u32::MAX), i32::MAX);
    }
}
