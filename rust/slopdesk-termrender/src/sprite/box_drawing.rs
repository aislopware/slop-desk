//! Box Drawing — U+2500…U+257F.
//!
//! ```text
//! ─━│┃┄┅┆┇┈┉┊┋┌┍┎┏┐┑┒┓└┕┖┗┘┙┚┛├┝┞┟
//! ┠┡┢┣┤┥┦┧┨┩┪┫┬┭┮┯┰┱┲┳┴┵┶┷┸┹┺┻┼┽┾┿
//! ╀╁╂╃╄╅╆╇╈╉╊╋╌╍╎╏═║╒╓╔╕╖╗╘╙╚╛╜╝╞╟
//! ╠╡╢╣╤╥╦╧╨╩╪╫╬╭╮╯╰╱╲╳╴╵╶╷╸╹╺╻╼╽╾╿
//! ```
//!
//! Ported from Ghostty's `src/font/sprite/draw/box.zig` (MIT). The dispatch table, [`draw_lines`]'s
//! junction arithmetic, the arc control points and both dash layouts are the reference's; what is
//! new is [`lines_of`], which reads the table BACKWARDS so a neighbouring cell can ask which edges
//! this character puts a line on. Ghostty has no reason to ask — nothing in it joins to a box rule
//! — and it is the whole basis of `arrow-box-drawing-join`.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use LineStyle::{Double as D, Heavy as H, Light as L, None as N};

use super::canvas::{Canvas, Point, flatten_cubic, pt};
use super::common::{Cell, LineStyle, Lines, Shade, Thickness, centered, half, signed};

/// Which two edges a rounded corner joins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Corner {
    /// `╯` — up and left.
    TopLeft,
    /// `╰` — up and right.
    TopRight,
    /// `╮` — down and left.
    BottomLeft,
    /// `╭` — down and right.
    BottomRight,
}

/// What one codepoint in the range draws.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Glyph {
    /// A junction of up to four edge lines.
    Junction(Lines),
    /// A horizontally dashed rule: dash count, weight, desired gap.
    DashHorizontal(u8, Thickness, u32),
    /// A vertically dashed rule: dash count, weight, desired gap.
    DashVertical(u8, Thickness, u32),
    /// A quarter-circle joining two edges.
    Arc(Corner),
    /// `╱`.
    DiagonalUpRight,
    /// `╲`.
    DiagonalDownRight,
    /// `╳`.
    DiagonalCross,
}

/// Whether this crate draws `cp` itself rather than asking the font.
pub(crate) const fn covers(cp: u32) -> bool {
    classify(cp).is_some()
}

/// Which edges `cp` runs a line to, or `None` when it is not a box-drawing character.
///
/// A dashed rule answers as though it were solid and an arc answers with the two edges it joins:
/// what the caller is asking is "does a rule arrive at this edge", and both do. The three diagonals
/// answer `None` — they cross the cell without touching an edge's midpoint, so there is nothing for
/// a neighbour to meet.
pub(crate) fn lines_of(cp: u32) -> Option<Lines> {
    match classify(cp)? {
        Glyph::Junction(lines) => Some(lines),
        Glyph::DashHorizontal(_, thickness, _) => {
            let style = dash_style(thickness);
            Some(Lines::of(N, style, N, style))
        },
        Glyph::DashVertical(_, thickness, _) => {
            let style = dash_style(thickness);
            Some(Lines::of(style, N, style, N))
        },
        Glyph::Arc(corner) => {
            Some(match corner {
                Corner::TopLeft => Lines::of(L, N, N, L),
                Corner::TopRight => Lines::of(L, L, N, N),
                Corner::BottomLeft => Lines::of(N, N, L, L),
                Corner::BottomRight => Lines::of(N, L, L, N),
            })
        },
        Glyph::DiagonalUpRight | Glyph::DiagonalDownRight | Glyph::DiagonalCross => None,
    }
}

/// Draws `cp` into `canvas`, answering whether it was one of ours.
pub(crate) fn draw(cp: u32, canvas: &mut Canvas, cell: Cell) -> bool {
    let Some(glyph) = classify(cp) else {
        return false;
    };
    match glyph {
        Glyph::Junction(lines) => draw_lines(canvas, cell, lines),
        Glyph::DashHorizontal(count, thickness, gap) => {
            dash_horizontal(canvas, cell, count, thickness.height(cell.thickness), gap);
        },
        Glyph::DashVertical(count, thickness, gap) => {
            dash_vertical(canvas, cell, count, thickness.height(cell.thickness), gap);
        },
        Glyph::Arc(corner) => arc(canvas, cell, corner, Thickness::Light),
        Glyph::DiagonalUpRight => diagonal_up_right(canvas, cell),
        Glyph::DiagonalDownRight => diagonal_down_right(canvas, cell),
        Glyph::DiagonalCross => {
            diagonal_up_right(canvas, cell);
            diagonal_down_right(canvas, cell);
        },
    }
    true
}

/// The weight a dashed rule reports to a neighbour.
const fn dash_style(thickness: Thickness) -> LineStyle {
    match thickness {
        Thickness::Heavy => H,
        Thickness::Light => L,
    }
}

/// The gap the 3- and 4-dash rules want: four pixels, or the line weight when that is heavier.
const fn wide_gap(base: u32) -> u32 {
    let light = Thickness::Light.height(base);
    if light > 4 { light } else { 4 }
}

/// The dispatch table, transcribed from the reference.
#[expect(
    clippy::too_many_lines,
    reason = "one arm per codepoint is the table; splitting it would hide what it is"
)]
const fn classify(cp: u32) -> Option<Glyph> {
    // The gap arguments are MARKERS, resolved against the cell's real base thickness by
    // `resolve_gap` at draw time. The reference computes them inline from `metrics`, which it can
    // because its table is not also the answer to `lines_of`.
    Some(match cp {
        0x2500 => Glyph::Junction(Lines::of(N, L, N, L)),
        0x2501 => Glyph::Junction(Lines::of(N, H, N, H)),
        0x2502 => Glyph::Junction(Lines::of(L, N, L, N)),
        0x2503 => Glyph::Junction(Lines::of(H, N, H, N)),
        0x2504 => Glyph::DashHorizontal(3, Thickness::Light, GAP_WIDE),
        0x2505 => Glyph::DashHorizontal(3, Thickness::Heavy, GAP_WIDE),
        0x2506 => Glyph::DashVertical(3, Thickness::Light, GAP_WIDE),
        0x2507 => Glyph::DashVertical(3, Thickness::Heavy, GAP_WIDE),
        0x2508 => Glyph::DashHorizontal(4, Thickness::Light, GAP_WIDE),
        0x2509 => Glyph::DashHorizontal(4, Thickness::Heavy, GAP_WIDE),
        0x250A => Glyph::DashVertical(4, Thickness::Light, GAP_WIDE),
        0x250B => Glyph::DashVertical(4, Thickness::Heavy, GAP_WIDE),
        0x250C => Glyph::Junction(Lines::of(N, L, L, N)),
        0x250D => Glyph::Junction(Lines::of(N, H, L, N)),
        0x250E => Glyph::Junction(Lines::of(N, L, H, N)),
        0x250F => Glyph::Junction(Lines::of(N, H, H, N)),

        0x2510 => Glyph::Junction(Lines::of(N, N, L, L)),
        0x2511 => Glyph::Junction(Lines::of(N, N, L, H)),
        0x2512 => Glyph::Junction(Lines::of(N, N, H, L)),
        0x2513 => Glyph::Junction(Lines::of(N, N, H, H)),
        0x2514 => Glyph::Junction(Lines::of(L, L, N, N)),
        0x2515 => Glyph::Junction(Lines::of(L, H, N, N)),
        0x2516 => Glyph::Junction(Lines::of(H, L, N, N)),
        0x2517 => Glyph::Junction(Lines::of(H, H, N, N)),
        0x2518 => Glyph::Junction(Lines::of(L, N, N, L)),
        0x2519 => Glyph::Junction(Lines::of(L, N, N, H)),
        0x251A => Glyph::Junction(Lines::of(H, N, N, L)),
        0x251B => Glyph::Junction(Lines::of(H, N, N, H)),
        0x251C => Glyph::Junction(Lines::of(L, L, L, N)),
        0x251D => Glyph::Junction(Lines::of(L, H, L, N)),
        0x251E => Glyph::Junction(Lines::of(H, L, L, N)),
        0x251F => Glyph::Junction(Lines::of(L, L, H, N)),

        0x2520 => Glyph::Junction(Lines::of(H, L, H, N)),
        0x2521 => Glyph::Junction(Lines::of(H, H, L, N)),
        0x2522 => Glyph::Junction(Lines::of(L, H, H, N)),
        0x2523 => Glyph::Junction(Lines::of(H, H, H, N)),
        0x2524 => Glyph::Junction(Lines::of(L, N, L, L)),
        0x2525 => Glyph::Junction(Lines::of(L, N, L, H)),
        0x2526 => Glyph::Junction(Lines::of(H, N, L, L)),
        0x2527 => Glyph::Junction(Lines::of(L, N, H, L)),
        0x2528 => Glyph::Junction(Lines::of(H, N, H, L)),
        0x2529 => Glyph::Junction(Lines::of(H, N, L, H)),
        0x252A => Glyph::Junction(Lines::of(L, N, H, H)),
        0x252B => Glyph::Junction(Lines::of(H, N, H, H)),
        0x252C => Glyph::Junction(Lines::of(N, L, L, L)),
        0x252D => Glyph::Junction(Lines::of(N, L, L, H)),
        0x252E => Glyph::Junction(Lines::of(N, H, L, L)),
        0x252F => Glyph::Junction(Lines::of(N, H, L, H)),

        0x2530 => Glyph::Junction(Lines::of(N, L, H, L)),
        0x2531 => Glyph::Junction(Lines::of(N, L, H, H)),
        0x2532 => Glyph::Junction(Lines::of(N, H, H, L)),
        0x2533 => Glyph::Junction(Lines::of(N, H, H, H)),
        0x2534 => Glyph::Junction(Lines::of(L, L, N, L)),
        0x2535 => Glyph::Junction(Lines::of(L, L, N, H)),
        0x2536 => Glyph::Junction(Lines::of(L, H, N, L)),
        0x2537 => Glyph::Junction(Lines::of(L, H, N, H)),
        0x2538 => Glyph::Junction(Lines::of(H, L, N, L)),
        0x2539 => Glyph::Junction(Lines::of(H, L, N, H)),
        0x253A => Glyph::Junction(Lines::of(H, H, N, L)),
        0x253B => Glyph::Junction(Lines::of(H, H, N, H)),
        0x253C => Glyph::Junction(Lines::of(L, L, L, L)),
        0x253D => Glyph::Junction(Lines::of(L, L, L, H)),
        0x253E => Glyph::Junction(Lines::of(L, H, L, L)),
        0x253F => Glyph::Junction(Lines::of(L, H, L, H)),

        0x2540 => Glyph::Junction(Lines::of(H, L, L, L)),
        0x2541 => Glyph::Junction(Lines::of(L, L, H, L)),
        0x2542 => Glyph::Junction(Lines::of(H, L, H, L)),
        0x2543 => Glyph::Junction(Lines::of(H, L, L, H)),
        0x2544 => Glyph::Junction(Lines::of(H, H, L, L)),
        0x2545 => Glyph::Junction(Lines::of(L, L, H, H)),
        0x2546 => Glyph::Junction(Lines::of(L, H, H, L)),
        0x2547 => Glyph::Junction(Lines::of(H, H, L, H)),
        0x2548 => Glyph::Junction(Lines::of(L, H, H, H)),
        0x2549 => Glyph::Junction(Lines::of(H, L, H, H)),
        0x254A => Glyph::Junction(Lines::of(H, H, H, L)),
        0x254B => Glyph::Junction(Lines::of(H, H, H, H)),
        0x254C => Glyph::DashHorizontal(2, Thickness::Light, GAP_LIGHT),
        0x254D => Glyph::DashHorizontal(2, Thickness::Heavy, GAP_HEAVY),
        0x254E => Glyph::DashVertical(2, Thickness::Light, GAP_HEAVY),
        0x254F => Glyph::DashVertical(2, Thickness::Heavy, GAP_HEAVY),

        0x2550 => Glyph::Junction(Lines::of(N, D, N, D)),
        0x2551 => Glyph::Junction(Lines::of(D, N, D, N)),
        0x2552 => Glyph::Junction(Lines::of(N, D, L, N)),
        0x2553 => Glyph::Junction(Lines::of(N, L, D, N)),
        0x2554 => Glyph::Junction(Lines::of(N, D, D, N)),
        0x2555 => Glyph::Junction(Lines::of(N, N, L, D)),
        0x2556 => Glyph::Junction(Lines::of(N, N, D, L)),
        0x2557 => Glyph::Junction(Lines::of(N, N, D, D)),
        0x2558 => Glyph::Junction(Lines::of(L, D, N, N)),
        0x2559 => Glyph::Junction(Lines::of(D, L, N, N)),
        0x255A => Glyph::Junction(Lines::of(D, D, N, N)),
        0x255B => Glyph::Junction(Lines::of(L, N, N, D)),
        0x255C => Glyph::Junction(Lines::of(D, N, N, L)),
        0x255D => Glyph::Junction(Lines::of(D, N, N, D)),
        0x255E => Glyph::Junction(Lines::of(L, D, L, N)),
        0x255F => Glyph::Junction(Lines::of(D, L, D, N)),

        0x2560 => Glyph::Junction(Lines::of(D, D, D, N)),
        0x2561 => Glyph::Junction(Lines::of(L, N, L, D)),
        0x2562 => Glyph::Junction(Lines::of(D, N, D, L)),
        0x2563 => Glyph::Junction(Lines::of(D, N, D, D)),
        0x2564 => Glyph::Junction(Lines::of(N, D, L, D)),
        0x2565 => Glyph::Junction(Lines::of(N, L, D, L)),
        0x2566 => Glyph::Junction(Lines::of(N, D, D, D)),
        0x2567 => Glyph::Junction(Lines::of(L, D, N, D)),
        0x2568 => Glyph::Junction(Lines::of(D, L, N, L)),
        0x2569 => Glyph::Junction(Lines::of(D, D, N, D)),
        0x256A => Glyph::Junction(Lines::of(L, D, L, D)),
        0x256B => Glyph::Junction(Lines::of(D, L, D, L)),
        0x256C => Glyph::Junction(Lines::of(D, D, D, D)),
        0x256D => Glyph::Arc(Corner::BottomRight),
        0x256E => Glyph::Arc(Corner::BottomLeft),
        0x256F => Glyph::Arc(Corner::TopLeft),

        0x2570 => Glyph::Arc(Corner::TopRight),
        0x2571 => Glyph::DiagonalUpRight,
        0x2572 => Glyph::DiagonalDownRight,
        0x2573 => Glyph::DiagonalCross,
        0x2574 => Glyph::Junction(Lines::of(N, N, N, L)),
        0x2575 => Glyph::Junction(Lines::of(L, N, N, N)),
        0x2576 => Glyph::Junction(Lines::of(N, L, N, N)),
        0x2577 => Glyph::Junction(Lines::of(N, N, L, N)),
        0x2578 => Glyph::Junction(Lines::of(N, N, N, H)),
        0x2579 => Glyph::Junction(Lines::of(H, N, N, N)),
        0x257A => Glyph::Junction(Lines::of(N, H, N, N)),
        0x257B => Glyph::Junction(Lines::of(N, N, H, N)),
        0x257C => Glyph::Junction(Lines::of(N, H, N, L)),
        0x257D => Glyph::Junction(Lines::of(L, N, H, N)),
        0x257E => Glyph::Junction(Lines::of(N, L, N, H)),
        0x257F => Glyph::Junction(Lines::of(H, N, L, N)),

        _ => return None,
    })
}

/// Marker for "four pixels, or the light weight when that is heavier" — resolved in [`draw`].
const GAP_WIDE: u32 = u32::MAX;
/// Marker for "the light weight".
const GAP_LIGHT: u32 = u32::MAX - 1;
/// Marker for "the heavy weight".
const GAP_HEAVY: u32 = u32::MAX - 2;

/// Resolves a gap marker against the cell's real base thickness.
const fn resolve_gap(marker: u32, base: u32) -> u32 {
    match marker {
        GAP_WIDE => wide_gap(base),
        GAP_LIGHT => Thickness::Light.height(base),
        GAP_HEAVY => Thickness::Heavy.height(base),
        other => other,
    }
}

/// Draws a junction of up to four edge lines.
///
/// The four `*_bottom` / `*_top` / `*_right` / `*_left` bindings below are the reference's junction
/// arithmetic verbatim. They answer the only hard question in the whole family: how far past the
/// centre each arm runs, so that a light arm meeting a heavy one stops at the heavy one's edge
/// rather than poking through it, and so that a double line's two strokes break correctly where
/// another double crosses them.
#[expect(
    clippy::too_many_lines,
    reason = "four arms, four weights; the reference is one function too and splitting it would separate \
              the arithmetic from the only place it is used"
)]
fn draw_lines(canvas: &mut Canvas, cell: Cell, lines: Lines) {
    let light_px = Thickness::Light.height(cell.thickness);
    let heavy_px = Thickness::Heavy.height(cell.thickness);

    let h_light_top = centered(cell.height, light_px);
    let h_light_bottom = h_light_top.saturating_add(light_px);
    let h_heavy_top = centered(cell.height, heavy_px);
    let h_heavy_bottom = h_heavy_top.saturating_add(heavy_px);
    let h_double_top = h_light_top.saturating_sub(light_px);
    let h_double_bottom = h_light_bottom.saturating_add(light_px);

    let v_light_left = centered(cell.width, light_px);
    let v_light_right = v_light_left.saturating_add(light_px);
    let v_heavy_left = centered(cell.width, heavy_px);
    let v_heavy_right = v_heavy_left.saturating_add(heavy_px);
    let v_double_left = v_light_left.saturating_sub(light_px);
    let v_double_right = v_light_right.saturating_add(light_px);

    let up_bottom = if lines.left == H || lines.right == H {
        h_heavy_bottom
    } else if lines.left != lines.right || lines.down == lines.up {
        if lines.left == D || lines.right == D {
            h_double_bottom
        } else {
            h_light_bottom
        }
    } else if lines.left == N && lines.right == N {
        h_light_bottom
    } else {
        h_light_top
    };

    let down_top = if lines.left == H || lines.right == H {
        h_heavy_top
    } else if lines.left != lines.right || lines.up == lines.down {
        if lines.left == D || lines.right == D {
            h_double_top
        } else {
            h_light_top
        }
    } else if lines.left == N && lines.right == N {
        h_light_top
    } else {
        h_light_bottom
    };

    let left_right = if lines.up == H || lines.down == H {
        v_heavy_right
    } else if lines.up != lines.down || lines.left == lines.right {
        if lines.up == D || lines.down == D {
            v_double_right
        } else {
            v_light_right
        }
    } else if lines.up == N && lines.down == N {
        v_light_right
    } else {
        v_light_left
    };

    let right_left = if lines.up == H || lines.down == H {
        v_heavy_left
    } else if lines.up != lines.down || lines.right == lines.left {
        if lines.up == D || lines.down == D {
            v_double_left
        } else {
            v_light_left
        }
    } else if lines.up == N && lines.down == N {
        v_light_left
    } else {
        v_light_right
    };

    let ink = Shade::On.alpha();

    match lines.up {
        N => {},
        L => {
            canvas.fill_box(
                signed(v_light_left),
                0,
                signed(v_light_right),
                signed(up_bottom),
                ink,
            );
        },
        H => {
            canvas.fill_box(
                signed(v_heavy_left),
                0,
                signed(v_heavy_right),
                signed(up_bottom),
                ink,
            );
        },
        D => {
            let left_bottom = if lines.left == D { h_light_top } else { up_bottom };
            let right_bottom = if lines.right == D { h_light_top } else { up_bottom };
            canvas.fill_box(
                signed(v_double_left),
                0,
                signed(v_light_left),
                signed(left_bottom),
                ink,
            );
            canvas.fill_box(
                signed(v_light_right),
                0,
                signed(v_double_right),
                signed(right_bottom),
                ink,
            );
        },
    }

    match lines.right {
        N => {},
        L => {
            canvas.fill_box(
                signed(right_left),
                signed(h_light_top),
                signed(cell.width),
                signed(h_light_bottom),
                ink,
            );
        },
        H => {
            canvas.fill_box(
                signed(right_left),
                signed(h_heavy_top),
                signed(cell.width),
                signed(h_heavy_bottom),
                ink,
            );
        },
        D => {
            let top_left = if lines.up == D { v_light_right } else { right_left };
            let bottom_left = if lines.down == D {
                v_light_right
            } else {
                right_left
            };
            canvas.fill_box(
                signed(top_left),
                signed(h_double_top),
                signed(cell.width),
                signed(h_light_top),
                ink,
            );
            canvas.fill_box(
                signed(bottom_left),
                signed(h_light_bottom),
                signed(cell.width),
                signed(h_double_bottom),
                ink,
            );
        },
    }

    match lines.down {
        N => {},
        L => {
            canvas.fill_box(
                signed(v_light_left),
                signed(down_top),
                signed(v_light_right),
                signed(cell.height),
                ink,
            );
        },
        H => {
            canvas.fill_box(
                signed(v_heavy_left),
                signed(down_top),
                signed(v_heavy_right),
                signed(cell.height),
                ink,
            );
        },
        D => {
            let left_top = if lines.left == D { h_light_bottom } else { down_top };
            let right_top = if lines.right == D {
                h_light_bottom
            } else {
                down_top
            };
            canvas.fill_box(
                signed(v_double_left),
                signed(left_top),
                signed(v_light_left),
                signed(cell.height),
                ink,
            );
            canvas.fill_box(
                signed(v_light_right),
                signed(right_top),
                signed(v_double_right),
                signed(cell.height),
                ink,
            );
        },
    }

    match lines.left {
        N => {},
        L => {
            canvas.fill_box(
                0,
                signed(h_light_top),
                signed(left_right),
                signed(h_light_bottom),
                ink,
            );
        },
        H => {
            canvas.fill_box(
                0,
                signed(h_heavy_top),
                signed(left_right),
                signed(h_heavy_bottom),
                ink,
            );
        },
        D => {
            let top_right = if lines.up == D { v_light_left } else { left_right };
            let bottom_right = if lines.down == D { v_light_left } else { left_right };
            canvas.fill_box(
                0,
                signed(h_double_top),
                signed(top_right),
                signed(h_light_top),
                ink,
            );
            canvas.fill_box(
                0,
                signed(h_light_bottom),
                signed(bottom_right),
                signed(h_double_bottom),
                ink,
            );
        },
    }
}

/// `╱` — the reference's slope-preserving overshoot past both corners.
pub(crate) fn diagonal_up_right(canvas: &mut Canvas, cell: Cell) {
    let (width, height) = (f64::from(cell.width), f64::from(cell.height));
    let (slope_x, slope_y) = diagonal_slopes(width, height);
    canvas.stroke(
        &[
            pt(width + 0.5 * slope_x, -0.5 * slope_y),
            pt(-0.5 * slope_x, height + 0.5 * slope_y),
        ],
        f64::from(Thickness::Light.height(cell.thickness)),
        false,
        Shade::On.alpha(),
    );
}

/// `╲` — the reference's slope-preserving overshoot past both corners.
pub(crate) fn diagonal_down_right(canvas: &mut Canvas, cell: Cell) {
    let (width, height) = (f64::from(cell.width), f64::from(cell.height));
    let (slope_x, slope_y) = diagonal_slopes(width, height);
    canvas.stroke(
        &[
            pt(-0.5 * slope_x, -0.5 * slope_y),
            pt(width + 0.5 * slope_x, height + 0.5 * slope_y),
        ],
        f64::from(Thickness::Light.height(cell.thickness)),
        false,
        Shade::On.alpha(),
    );
}

/// How far past each corner a diagonal runs, so tiled diagonals keep one unbroken slope.
fn diagonal_slopes(width: f64, height: f64) -> (f64, f64) {
    if width <= 0.0 || height <= 0.0 {
        return (0.0, 0.0);
    }
    (f64::min(1.0, width / height), f64::min(1.0, height / width))
}

/// A quarter-circle joining two edges, stroked butt-capped so it meets the next cell's rule flush.
fn arc(canvas: &mut Canvas, cell: Cell, corner: Corner, thickness: Thickness) {
    let thick_px = thickness.height(cell.thickness);
    let (width, height) = (f64::from(cell.width), f64::from(cell.height));
    let thick = f64::from(thick_px);
    let center_x = f64::from(centered(cell.width, thick_px)) + thick / 2.0;
    let center_y = f64::from(centered(cell.height, thick_px)) + thick / 2.0;
    let radius = f64::min(width, height) / 2.0;

    // How far from the corner the middle control points sit. The reference's number, and it is not
    // a circle's — a true quarter-circle wants 0.5523; 0.25 pulls the curve tighter, which reads
    // better at a text cell's size than a geometrically exact arc does.
    let s = 0.25;

    let (vertical_end, horizontal_end, sy, sx) = match corner {
        Corner::TopLeft => (pt(center_x, 0.0), pt(0.0, center_y), -1.0, -1.0),
        Corner::TopRight => (pt(center_x, 0.0), pt(width, center_y), -1.0, 1.0),
        Corner::BottomLeft => (pt(center_x, height), pt(0.0, center_y), 1.0, -1.0),
        Corner::BottomRight => (pt(center_x, height), pt(width, center_y), 1.0, 1.0),
    };

    let curve_start = pt(center_x, center_y + sy * radius);
    let curve_end = pt(center_x + sx * radius, center_y);
    let mut path: Vec<Point> = vec![vertical_end, curve_start];
    flatten_cubic(
        curve_start,
        pt(center_x, center_y + sy * s * radius),
        pt(center_x + sx * s * radius, center_y),
        curve_end,
        &mut path,
    );
    path.push(horizontal_end);

    canvas.stroke(&path, thick, false, Shade::On.alpha());
}

/// A horizontally dashed rule, laid out so that tiled copies read as one line.
///
/// Half a gap at each end rather than a whole one at one end: a horizontal rule is usually drawn in
/// a run, and centring the dashes is what stops the seam between two cells from looking like a
/// wider or narrower gap than the ones inside them.
fn dash_horizontal(canvas: &mut Canvas, cell: Cell, count: u8, thick_px: u32, gap_marker: u32) {
    let gap_count = u32::from(count);
    if gap_count == 0 {
        return;
    }
    // Below one pixel per dash and per gap there is nothing to draw but a solid line.
    if cell.width < gap_count.saturating_mul(2) {
        horizontal_middle(canvas, cell, Thickness::Light);
        return;
    }
    let desired = resolve_gap(gap_marker, cell.thickness);
    // Gaps never take more than half the cell — past that the dashes are too small to read as one.
    let gap = desired.min(divide(cell.width, gap_count.saturating_mul(2)).0);
    let total_gap = gap.saturating_mul(gap_count);
    let total_dash = cell.width.saturating_sub(total_gap);
    let (dash, mut extra) = divide(total_dash, gap_count);

    let y = signed(centered(cell.height, thick_px));
    let mut x = signed(half(gap));
    for _ in 0..count {
        let mut end = x.saturating_add(signed(dash));
        // Left-over pixels go into the DASHES, one each, because an uneven gap is far more visible
        // than an uneven dash.
        if extra > 0 {
            extra -= 1;
            end = end.saturating_add(1);
        }
        canvas.fill_box(x, y, end, y.saturating_add(signed(thick_px)), Shade::On.alpha());
        x = end.saturating_add(signed(gap));
    }
}

/// A vertically dashed rule.
///
/// One whole gap at the BOTTOM rather than half at each end, which is the reference's choice and
/// the right one: a vertical rule joins solid characters above and below far more often than a
/// horizontal one does, and a half gap at the top would show as a nick where they meet.
fn dash_vertical(canvas: &mut Canvas, cell: Cell, count: u8, thick_px: u32, gap_marker: u32) {
    let gap_count = u32::from(count);
    if gap_count == 0 {
        return;
    }
    if cell.height < gap_count.saturating_mul(2) {
        vertical_middle(canvas, cell, Thickness::Light);
        return;
    }
    let desired = resolve_gap(gap_marker, cell.thickness);
    let gap = desired.min(divide(cell.height, gap_count.saturating_mul(2)).0);
    let total_gap = gap.saturating_mul(gap_count);
    let total_dash = cell.height.saturating_sub(total_gap);
    let (dash, mut extra) = divide(total_dash, gap_count);

    let x = signed(centered(cell.width, thick_px));
    let mut y = 0_i32;
    for _ in 0..count {
        let mut end = y.saturating_add(signed(dash));
        if extra > 0 {
            extra -= 1;
            end = end.saturating_add(1);
        }
        canvas.fill_box(x, y, x.saturating_add(signed(thick_px)), end, Shade::On.alpha());
        y = end.saturating_add(signed(gap));
    }
}

/// Quotient and remainder, the one place this module divides.
#[expect(
    clippy::integer_division,
    reason = "dashes are whole pixels and the remainder is handed back to be distributed"
)]
const fn divide(total: u32, count: u32) -> (u32, u32) {
    if count == 0 {
        return (0, 0);
    }
    (total / count, total % count)
}

/// A centred horizontal rule across the whole cell.
fn horizontal_middle(canvas: &mut Canvas, cell: Cell, thickness: Thickness) {
    let thick_px = thickness.height(cell.thickness);
    let y = signed(centered(cell.height, thick_px));
    canvas.fill_box(
        0,
        y,
        signed(cell.width),
        y.saturating_add(signed(thick_px)),
        Shade::On.alpha(),
    );
}

/// A centred vertical rule down the whole cell.
fn vertical_middle(canvas: &mut Canvas, cell: Cell, thickness: Thickness) {
    let thick_px = thickness.height(cell.thickness);
    let x = signed(centered(cell.width, thick_px));
    canvas.fill_box(
        x,
        0,
        x.saturating_add(signed(thick_px)),
        signed(cell.height),
        Shade::On.alpha(),
    );
}

/// Where a light rule's near edge sits across `size` — what an arrow's stem lines up with.
///
/// The arrow family draws its stem at exactly this offset and exactly this weight, and that is the
/// entire trick behind `arrow-box-drawing-join`: the two families agree on one number, so an `↓`
/// meeting a `─` continues it rather than approaching it.
pub(crate) const fn light_edge(size: u32, base: u32) -> u32 {
    centered(size, Thickness::Light.height(base))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Canvas, Cell, LineStyle, covers, draw, lines_of};

    fn cell() -> Cell {
        Cell {
            width: 10,
            height: 20,
            thickness: 2,
        }
    }

    fn render(cp: u32) -> Canvas {
        let mut canvas = Canvas::new(10, 20).expect("canvas");
        assert!(draw(cp, &mut canvas, cell()), "{cp:#06x} is ours");
        canvas
    }

    fn ink(canvas: &Canvas, x: usize, y: usize) -> bool {
        canvas.texel(x, y) > 0
    }

    #[test]
    fn the_range_is_covered_end_to_end() {
        for cp in 0x2500..=0x257F_u32 {
            assert!(covers(cp), "{cp:#06x} has no sprite");
        }
        assert!(!covers(0x24FF), "the range starts at 2500");
        assert!(!covers(0x2580), "the range ends at 257F");
    }

    #[test]
    fn a_horizontal_rule_spans_the_whole_cell() {
        // Seamless tiling is the entire point: the rule must reach BOTH edges, or two adjacent
        // cells show a hairline between them.
        let canvas = render(0x2500);
        let y = 9;
        assert!(ink(&canvas, 0, y), "the rule reaches the left edge");
        assert!(ink(&canvas, 9, y), "the rule reaches the right edge");
        assert!(!ink(&canvas, 5, 0), "and does not fill the cell");
    }

    #[test]
    fn a_vertical_rule_spans_the_whole_cell() {
        let canvas = render(0x2502);
        assert!(ink(&canvas, 4, 0), "the rule reaches the top edge");
        assert!(ink(&canvas, 4, 19), "the rule reaches the bottom edge");
    }

    #[test]
    fn a_heavy_rule_is_twice_a_light_one() {
        let light = render(0x2500);
        let heavy = render(0x2501);
        let column = |canvas: &Canvas| (0..20).filter(|&y| ink(canvas, 5, y)).count();
        assert_eq!(column(&light), 2);
        assert_eq!(column(&heavy), 4);
    }

    #[test]
    fn a_corner_reaches_only_its_own_two_edges() {
        // `┌` runs down and right and must NOT touch the top or left edge, or a table's outer
        // border would grow whiskers.
        let canvas = render(0x250C);
        assert!(ink(&canvas, 9, 9), "the right arm");
        assert!(ink(&canvas, 4, 19), "the down arm");
        assert!(!ink(&canvas, 0, 9), "nothing to the left");
        assert!(!ink(&canvas, 4, 0), "nothing above");
    }

    #[test]
    fn a_double_line_is_two_strokes_with_a_gap() {
        let canvas = render(0x2550);
        let column: Vec<bool> = (0..20).map(|y| ink(&canvas, 5, y)).collect();
        let runs = column
            .iter()
            .zip(core::iter::once(&false).chain(column.iter()))
            .filter(|(now, before)| **now && !**before)
            .count();
        assert_eq!(runs, 2, "`═` is two rules, not one thick one");
    }

    #[test]
    fn a_dashed_rule_leaves_gaps_but_still_reads_as_a_line() {
        let canvas = render(0x2504);
        let row: Vec<bool> = (0..10).map(|x| ink(&canvas, x, 9)).collect();
        assert!(row.iter().any(|on| *on), "there is ink");
        assert!(row.iter().any(|on| !*on), "and there are gaps");
    }

    #[test]
    fn a_dash_degrades_to_a_solid_rule_in_a_cell_too_narrow_to_hold_it() {
        let mut canvas = Canvas::new(3, 20).expect("canvas");
        let narrow = Cell {
            width: 3,
            height: 20,
            thickness: 2,
        };
        assert!(draw(0x2508, &mut canvas, narrow));
        assert!(
            (0..3).all(|x| canvas.texel(x, 9) > 0),
            "solid rather than nothing"
        );
    }

    #[test]
    fn an_arc_touches_the_two_edges_it_joins_and_no_others() {
        // `╭` joins down and right.
        let canvas = render(0x256D);
        assert!((8..10).any(|x| ink(&canvas, x, 9)), "it reaches the right edge");
        assert!((3..6).any(|x| ink(&canvas, x, 19)), "it reaches the bottom edge");
        assert!(!ink(&canvas, 0, 9), "nothing on the left edge");
        assert!(!ink(&canvas, 4, 0), "nothing on the top edge");
    }

    #[test]
    fn a_diagonal_runs_corner_to_corner() {
        let canvas = render(0x2572);
        assert!(ink(&canvas, 0, 0), "`╲` starts top-left");
        assert!(ink(&canvas, 9, 19), "and ends bottom-right");
        assert!(!ink(&canvas, 9, 0), "and misses the other two corners");
    }

    #[test]
    fn a_half_line_stops_at_the_centre() {
        // `╴` is a left half line: ink on the left edge, nothing on the right.
        let canvas = render(0x2574);
        assert!(ink(&canvas, 0, 9));
        assert!(!ink(&canvas, 9, 9));
    }

    #[test]
    fn the_edges_a_character_runs_to_are_reported_back() {
        // The query `arrow-box-drawing-join` is built on. A cross has all four; a corner has two.
        let cross = lines_of(0x253C).expect("`┼` is box drawing");
        assert!(cross.up.is_drawn() && cross.down.is_drawn());
        assert!(cross.left.is_drawn() && cross.right.is_drawn());

        let corner = lines_of(0x250C).expect("`┌` is box drawing");
        assert!(corner.right.is_drawn() && corner.down.is_drawn());
        assert!(!corner.up.is_drawn() && !corner.left.is_drawn());

        let dashed = lines_of(0x2504).expect("`┄` is box drawing");
        assert!(
            dashed.left.is_drawn() && dashed.right.is_drawn(),
            "a dash is still a rule"
        );

        let arc = lines_of(0x2570).expect("`╰` is box drawing");
        assert_eq!((arc.up, arc.right), (LineStyle::Light, LineStyle::Light));
        assert!(!arc.down.is_drawn() && !arc.left.is_drawn());

        assert!(lines_of(0x2573).is_none(), "`╳` meets no edge midpoint");
        assert!(lines_of(0x0041).is_none(), "`A` is not box drawing");
    }

    #[test]
    fn nothing_outside_the_range_is_claimed() {
        let mut canvas = Canvas::new(10, 20).expect("canvas");
        assert!(!draw(0x0041, &mut canvas, cell()));
        assert!(
            !draw(0x2588, &mut canvas, cell()),
            "the full block is another family"
        );
    }
}
