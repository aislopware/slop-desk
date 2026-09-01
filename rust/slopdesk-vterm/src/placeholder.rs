//! Kitty's unicode-placeholder form: an image positioned by CELLS rather than by its placement.
//!
//! ## What the protocol actually does here, and why it needs its own module
//!
//! An ordinary kitty placement carries its own position — the engine knows which screen pin it was
//! placed at, and [`crate::graphics`] asks. A VIRTUAL placement carries none. The program says
//! "this image has a placement, it is `columns × rows` big, now go look at the grid", and then
//! writes the placeholder codepoint `U+10EEEE` into every cell the image should cover. Which image,
//! which fragment of it, and where the run starts are all encoded IN THE CELL: the image id in the
//! foreground colour, the placement id in the underline colour, and the fragment's row and column
//! as combining diacritics on the placeholder itself.
//!
//! So the position lives in the text, and only a pass over the cells can find it. That pass is
//! here, in pure arithmetic over what [`crate::frame`]'s scan already reads, and it is the whole
//! reason this module exists rather than one more question asked of the engine: `libghostty-vt`
//! parses and stores the virtual placement but exposes no iterator over the placeholders, because
//! the cells are the embedder's to walk.
//!
//! ## Why the run and not the cell is the unit
//!
//! A 40-column image is 40 placeholder cells, and the diacritics are OPTIONAL on every one of them
//! after the first — a program may write the full triple on each cell, or write it once and let the
//! rest continue the run implicitly. kitty's own rule for "continues" is
//! [`Incomplete::can_append`], and it is the reason a run is accumulated rather than each cell
//! turned into its own placement: 40 one-cell quads would each carry a fortieth of the image and a
//! seam of resampling between them, where one 40-cell quad carries the strip.
//!
//! A run is always a single ROW. That is ghostty's assumption and kitty's, and it is what makes the
//! accumulator a flat piece of state that the frame scan can flush at the end of every row.
//!
//! ## Why the placeholder never draws as a glyph
//!
//! `U+10EEEE` is in a private-use plane and no font has it, so a cell that reached the shaper with
//! it would draw a `.notdef` box over every cell of every virtually-placed image. ghostty's shaper
//! substitutes a space; [`crate::session`]'s scan writes no text at all, which is the same picture
//! and one fewer glyph. It does so on the CODEPOINT alone, never on whether images are enabled: the
//! placeholder is a positioning mark either way, and a terminal with images off should show a blank
//! rather than 40 boxes.
//!
//! ## The port
//!
//! Ported from ghostty `22d13172`'s `src/terminal/kitty/graphics_unicode.zig` — the diacritic
//! table, [`Incomplete::can_append`], and [`fit`]'s aspect-preserving fit are its logic, kept
//! numerically identical rather than re-derived. `docs/68` §5.7 records why the core follows
//! ghostty here: the protocol's own specification leaves the fit underdetermined, so agreeing with
//! the terminal every image program is tested against is worth more than any choice of our own.

use libghostty_vt::style::StyleColor;

use crate::graphics::ImageMeta;

/// The codepoint a program writes into a cell to say "an image goes here".
pub const PLACEHOLDER: char = '\u{10EEEE}';

/// The combining marks that carry a fragment's row, column and image-id high byte.
///
/// The INDEX into this table is the value, which is why it is a sorted array searched by binary
/// search rather than a map: the search answers the value and the containment test at once.
///
/// Derived from kitty's `rowcolumn-diacritics.txt` by way of ghostty's copy of it. Reproduced
/// rather than computed because there is nothing to compute — it is a published list, and any
/// codepoint missing from it is a codepoint kitty would not accept either.
#[rustfmt::skip]
const DIACRITICS: [char; 297] = [
    '\u{0305}', '\u{030d}', '\u{030e}', '\u{0310}', '\u{0312}', '\u{033d}', '\u{033e}', '\u{033f}',
    '\u{0346}', '\u{034a}', '\u{034b}', '\u{034c}', '\u{0350}', '\u{0351}', '\u{0352}', '\u{0357}',
    '\u{035b}', '\u{0363}', '\u{0364}', '\u{0365}', '\u{0366}', '\u{0367}', '\u{0368}', '\u{0369}',
    '\u{036a}', '\u{036b}', '\u{036c}', '\u{036d}', '\u{036e}', '\u{036f}', '\u{0483}', '\u{0484}',
    '\u{0485}', '\u{0486}', '\u{0487}', '\u{0592}', '\u{0593}', '\u{0594}', '\u{0595}', '\u{0597}',
    '\u{0598}', '\u{0599}', '\u{059c}', '\u{059d}', '\u{059e}', '\u{059f}', '\u{05a0}', '\u{05a1}',
    '\u{05a8}', '\u{05a9}', '\u{05ab}', '\u{05ac}', '\u{05af}', '\u{05c4}', '\u{0610}', '\u{0611}',
    '\u{0612}', '\u{0613}', '\u{0614}', '\u{0615}', '\u{0616}', '\u{0617}', '\u{0657}', '\u{0658}',
    '\u{0659}', '\u{065a}', '\u{065b}', '\u{065d}', '\u{065e}', '\u{06d6}', '\u{06d7}', '\u{06d8}',
    '\u{06d9}', '\u{06da}', '\u{06db}', '\u{06dc}', '\u{06df}', '\u{06e0}', '\u{06e1}', '\u{06e2}',
    '\u{06e4}', '\u{06e7}', '\u{06e8}', '\u{06eb}', '\u{06ec}', '\u{0730}', '\u{0732}', '\u{0733}',
    '\u{0735}', '\u{0736}', '\u{073a}', '\u{073d}', '\u{073f}', '\u{0740}', '\u{0741}', '\u{0743}',
    '\u{0745}', '\u{0747}', '\u{0749}', '\u{074a}', '\u{07eb}', '\u{07ec}', '\u{07ed}', '\u{07ee}',
    '\u{07ef}', '\u{07f0}', '\u{07f1}', '\u{07f3}', '\u{0816}', '\u{0817}', '\u{0818}', '\u{0819}',
    '\u{081b}', '\u{081c}', '\u{081d}', '\u{081e}', '\u{081f}', '\u{0820}', '\u{0821}', '\u{0822}',
    '\u{0823}', '\u{0825}', '\u{0826}', '\u{0827}', '\u{0829}', '\u{082a}', '\u{082b}', '\u{082c}',
    '\u{082d}', '\u{0951}', '\u{0953}', '\u{0954}', '\u{0f82}', '\u{0f83}', '\u{0f86}', '\u{0f87}',
    '\u{135d}', '\u{135e}', '\u{135f}', '\u{17dd}', '\u{193a}', '\u{1a17}', '\u{1a75}', '\u{1a76}',
    '\u{1a77}', '\u{1a78}', '\u{1a79}', '\u{1a7a}', '\u{1a7b}', '\u{1a7c}', '\u{1b6b}', '\u{1b6d}',
    '\u{1b6e}', '\u{1b6f}', '\u{1b70}', '\u{1b71}', '\u{1b72}', '\u{1b73}', '\u{1cd0}', '\u{1cd1}',
    '\u{1cd2}', '\u{1cda}', '\u{1cdb}', '\u{1ce0}', '\u{1dc0}', '\u{1dc1}', '\u{1dc3}', '\u{1dc4}',
    '\u{1dc5}', '\u{1dc6}', '\u{1dc7}', '\u{1dc8}', '\u{1dc9}', '\u{1dcb}', '\u{1dcc}', '\u{1dd1}',
    '\u{1dd2}', '\u{1dd3}', '\u{1dd4}', '\u{1dd5}', '\u{1dd6}', '\u{1dd7}', '\u{1dd8}', '\u{1dd9}',
    '\u{1dda}', '\u{1ddb}', '\u{1ddc}', '\u{1ddd}', '\u{1dde}', '\u{1ddf}', '\u{1de0}', '\u{1de1}',
    '\u{1de2}', '\u{1de3}', '\u{1de4}', '\u{1de5}', '\u{1de6}', '\u{1dfe}', '\u{20d0}', '\u{20d1}',
    '\u{20d4}', '\u{20d5}', '\u{20d6}', '\u{20d7}', '\u{20db}', '\u{20dc}', '\u{20e1}', '\u{20e7}',
    '\u{20e9}', '\u{20f0}', '\u{2cef}', '\u{2cf0}', '\u{2cf1}', '\u{2de0}', '\u{2de1}', '\u{2de2}',
    '\u{2de3}', '\u{2de4}', '\u{2de5}', '\u{2de6}', '\u{2de7}', '\u{2de8}', '\u{2de9}', '\u{2dea}',
    '\u{2deb}', '\u{2dec}', '\u{2ded}', '\u{2dee}', '\u{2def}', '\u{2df0}', '\u{2df1}', '\u{2df2}',
    '\u{2df3}', '\u{2df4}', '\u{2df5}', '\u{2df6}', '\u{2df7}', '\u{2df8}', '\u{2df9}', '\u{2dfa}',
    '\u{2dfb}', '\u{2dfc}', '\u{2dfd}', '\u{2dfe}', '\u{2dff}', '\u{a66f}', '\u{a67c}', '\u{a67d}',
    '\u{a6f0}', '\u{a6f1}', '\u{a8e0}', '\u{a8e1}', '\u{a8e2}', '\u{a8e3}', '\u{a8e4}', '\u{a8e5}',
    '\u{a8e6}', '\u{a8e7}', '\u{a8e8}', '\u{a8e9}', '\u{a8ea}', '\u{a8eb}', '\u{a8ec}', '\u{a8ed}',
    '\u{a8ee}', '\u{a8ef}', '\u{a8f0}', '\u{a8f1}', '\u{aab0}', '\u{aab2}', '\u{aab3}', '\u{aab7}',
    '\u{aab8}', '\u{aabe}', '\u{aabf}', '\u{aac1}', '\u{fe20}', '\u{fe21}', '\u{fe22}', '\u{fe23}',
    '\u{fe24}', '\u{fe25}', '\u{fe26}', '\u{10a0f}', '\u{10a38}', '\u{1d185}', '\u{1d186}', '\u{1d187}',
    '\u{1d188}', '\u{1d189}', '\u{1d1aa}', '\u{1d1ab}', '\u{1d1ac}', '\u{1d1ad}', '\u{1d242}', '\u{1d243}',
    '\u{1d244}',
];

/// The value a diacritic encodes, or `None` for a codepoint that is not one.
///
/// `None` is not an error the caller reports: kitty treats an invalid diacritic as an ABSENT one,
/// so a cell with a mark nobody recognises continues the run instead of breaking it. Following that
/// rather than refusing is what keeps a program that emits one stray combining character showing an
/// image rather than a blank strip.
fn diacritic_value(cp: char) -> Option<u32> {
    let index = DIACRITICS.binary_search(&cp).ok()?;
    u32::try_from(index).ok()
}

/// The 24 bits of an id packed into a style colour.
///
/// The protocol reuses the foreground and underline colours as integer fields, which is why a
/// PALETTE colour answers its index and an RGB one answers its three bytes packed — the program
/// picked whichever spelling reached 24 bits, and both mean the same number. `None` is zero, which
/// is also "no id" for the underline case.
const fn color_to_id(color: StyleColor) -> u32 {
    match color {
        StyleColor::None => 0,
        StyleColor::Palette(index) => index.0 as u32,
        StyleColor::Rgb(rgb) => ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32),
    }
}

/// One completed run of placeholder cells: one row of one image's fragment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlaceholderRun {
    /// Which image, low 24 bits from the foreground colour and high 8 from the third diacritic.
    pub image_id: u32,
    /// Which of that image's placements, or zero for "the first virtual one".
    pub placement_id: u32,
    /// The fragment's column origin, in PLACEMENT cells. Zero-indexed.
    pub col: u32,
    /// The fragment's row origin, in PLACEMENT cells. Zero-indexed.
    pub row: u32,
    /// How many cells the run covers. Always at least one.
    pub width: u32,
    /// The viewport column the run starts at.
    pub start_col: u16,
}

/// One cell's worth of placement information, before it is known whether the run continues.
///
/// "Incomplete" is the protocol's shape rather than a convenience: every field but the image id's
/// low bits may be absent from a cell, and an absent field means "the same as the run so far".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Incomplete {
    /// Low 24 bits of the image id, from the foreground colour. Always present.
    image_id_low: u32,
    /// High 8 bits, from the third diacritic.
    image_id_high: Option<u32>,
    /// The placement id from the underline colour, or `None` when that colour was unset.
    placement_id: Option<u32>,
    /// The fragment row, from the first diacritic.
    row: Option<u32>,
    /// The fragment column, from the second diacritic.
    col: Option<u32>,
    /// The run's width so far, in cells.
    width: u32,
    /// The viewport column the run starts at.
    start_col: u16,
}

impl Incomplete {
    /// Reads one placeholder cell.
    ///
    /// `scalars` is the cell's whole grapheme cluster with the placeholder itself first, which is
    /// the shape the engine hands over — so the three optional diacritics are elements one, two and
    /// three, and any beyond them are ignored exactly as kitty ignores them.
    fn read(x: u16, scalars: &[char], fg: StyleColor, underline: StyleColor) -> Self {
        let placement_id = match color_to_id(underline) {
            0 => None,
            id => Some(id),
        };
        // Positional, and read by POSITION rather than by whether the mark before them decoded:
        // an unrecognised diacritic is absent, not terminal, so the second mark is still the column
        // even when the first was gibberish. That is kitty's behaviour and ghostty's port of it.
        let row = scalars.get(1).copied().and_then(diacritic_value);
        let col = scalars.get(2).copied().and_then(diacritic_value);
        // The high byte is the only field with a RANGE: it is eight bits of a 32-bit id, and the
        // table runs to 297, so a mark past 255 names no byte and is dropped rather than truncated.
        let image_id_high = scalars
            .get(3)
            .copied()
            .and_then(diacritic_value)
            .filter(|high| u8::try_from(*high).is_ok());
        Self {
            image_id_low: color_to_id(fg),
            image_id_high,
            placement_id,
            row,
            col,
            width: 1,
            start_col: x,
        }
    }

    /// Whether `next` continues this run rather than starting a new one.
    ///
    /// kitty's rule, ported without reinterpretation: same image and placement, the same fragment
    /// row if it names one, the very next fragment column if it names one, and the same high byte
    /// if it names one. Anything absent continues by definition — that is the whole point of the
    /// abbreviated form, and it is why the test for "absent" comes first in every clause.
    fn can_append(&self, next: &Self) -> bool {
        // `is_none_or` reads as "absent, or equal", which is the rule in the same order kitty
        // states it. The `self.col` side is an `is_some_and` rather than an unwrap because a run
        // whose first cell had no column diacritic is given zero before it is ever appended
        // to — see [`RunScan::cell`] — so the `None` branch here is unreachable and
        // answering `false` for it is a refusal to continue rather than a panic on a shape
        // the far side chose.
        let row_ok = next.row.is_none_or(|row| self.row == Some(row));
        let col_ok = next
            .col
            .is_none_or(|col| self.col.is_some_and(|mine| col == mine + self.width));
        let high_ok = next
            .image_id_high
            .is_none_or(|high| self.image_id_high == Some(high));
        self.image_id_low == next.image_id_low
            && self.placement_id == next.placement_id
            && row_ok
            && col_ok
            && high_ok
    }

    /// Turns the accumulated run into the placement it describes.
    ///
    /// The two `unwrap_or(0)`s are the protocol's defaults for a run that named neither a fragment
    /// row nor a column: the whole image, from its top-left.
    fn complete(&self) -> PlaceholderRun {
        PlaceholderRun {
            image_id: self.image_id_low | (self.image_id_high.unwrap_or(0) << 24),
            placement_id: self.placement_id.unwrap_or(0),
            col: self.col.unwrap_or(0),
            row: self.row.unwrap_or(0),
            width: self.width,
            start_col: self.start_col,
        }
    }
}

/// The run being accumulated across one row's cells.
///
/// Held on the session's scratch and reset per row, so a viewport full of images allocates nothing
/// per frame beyond the runs themselves.
#[derive(Debug, Default, Clone, Copy)]
pub struct RunScan {
    /// The run in progress, if the previous cell was a placeholder that could continue.
    current: Option<Incomplete>,
}

impl RunScan {
    /// Feeds one cell, answering the run this cell ENDED if it ended one.
    ///
    /// `scalars` is empty for a cell with no text, which ends a run like any other non-placeholder.
    pub fn cell(
        &mut self,
        x: u16,
        scalars: &[char],
        fg: StyleColor,
        underline: StyleColor,
    ) -> Option<PlaceholderRun> {
        if scalars.first() != Some(&PLACEHOLDER) {
            return self.finish();
        }

        let next = Incomplete::read(x, scalars, fg, underline);
        match &mut self.current {
            Some(run) if run.can_append(&next) => {
                run.width += 1;
                None
            },
            // Either there was no run or this cell could not continue it. Both start one HERE, and
            // the incompatible case also completes what came before — the cell is never re-read,
            // which is the one place this differs in shape from ghostty's iterator and not at all
            // in result.
            slot => {
                let ended = slot.map(|run| run.complete());
                // The first cell of a run defaults its row and column, so `can_append`'s "the very
                // next column" has something to be next to. kitty does the same, and without it a
                // program that abbreviates from the second cell onward would break its own run.
                let mut started = next;
                started.row = started.row.or(Some(0));
                started.col = started.col.or(Some(0));
                *slot = Some(started);
                ended
            },
        }
    }

    /// Ends the row, answering the run still open if there was one.
    pub fn finish(&mut self) -> Option<PlaceholderRun> {
        self.current.take().map(|run| run.complete())
    }
}

/// The mark that encodes `value`, for a test that has to WRITE the protocol rather than read it.
///
/// Test-only because nothing in the terminal ever encodes a placeholder — the far side does — and a
/// door that exists only to be the inverse of [`diacritic_value`] would otherwise read as one half
/// of a round trip this crate performs.
#[cfg(test)]
#[must_use]
pub fn diacritic_at(value: usize) -> Option<char> {
    DIACRITICS.get(value).copied()
}

/// The grid one virtual placement covers, in cells.
///
/// The protocol lets a placement name neither dimension, in which case the image is laid out at its
/// own pixel size and the grid is however many whole cells that takes — rounded UP, because a half
/// cell of image still needs a cell to sit in.
#[must_use]
pub const fn grid_of(
    columns: u32,
    rows: u32,
    image: ImageMeta,
    cell_width: u32,
    cell_height: u32,
) -> (u32, u32) {
    let columns = if columns == 0 {
        image.width.div_ceil(cell_width)
    } else {
        columns
    };
    let rows = if rows == 0 {
        image.height.div_ceil(cell_height)
    } else {
        rows
    };
    (columns, rows)
}

/// Where one run draws, and which slice of its image fills it.
///
/// Every number is a DEVICE pixel or an IMAGE pixel, matching [`crate::graphics::ImagePlacement`],
/// which is what this is folded into.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunGeometry {
    /// Pixels in from the left edge of the run's first cell.
    pub offset_x: u32,
    /// Pixels down from the top edge of the run's row.
    pub offset_y: u32,
    /// Source rectangle inside the image.
    pub source_x: u32,
    /// Source rectangle inside the image.
    pub source_y: u32,
    /// Source rectangle inside the image.
    pub source_width: u32,
    /// Source rectangle inside the image.
    pub source_height: u32,
    /// Destination width in device pixels.
    pub dest_width: u32,
    /// Destination height in device pixels.
    pub dest_height: u32,
}

/// Rounds a computed pixel count to the integer a vertex buffer can hold.
///
/// Saturating at both ends and answering zero for a NaN. Every input here is a quotient of finite
/// numbers, so a NaN can only come from a degenerate grid the guard in [`fit`] already refuses —
/// but a render path is the wrong place to find out that the guard was ever wrong, and a zero draws
/// nothing where a wrapped cast would draw a garbage rectangle.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "both ends are clamped on the line above the cast, and a NaN answers zero"
)]
fn round_px(value: f64) -> u32 {
    let rounded = value.round();
    // `f64::max`/`min` rather than comparisons, per `CLAUDE.md` — and load-bearing beyond the rule
    // here, because they implement IEEE `maxNum`/`minNum`, which SWALLOW a NaN and answer the other
    // operand. A NaN therefore clamps to zero instead of casting to an arbitrary integer.
    let clamped = f64::min(f64::max(rounded, 0.0), f64::from(u32::MAX));
    clamped as u32
}

/// Fits `image` into the grid the placement asked for, then narrows to the fragment `run` names.
///
/// ## What the two halves do
///
/// The FIT preserves the aspect ratio and centres what is left over, exactly as kitty does: an
/// image wider than its grid is scaled to the grid's width and gets blank bands above and below, a
/// taller one is scaled to the height and gets bands left and right. The bands are not pixels — the
/// texture has no blank border — so the second half converts the fragment's cell rectangle back
/// into image space, discovers where it overlaps the band, and shortens BOTH the source and the
/// destination by the overlap. That is why the destination is not simply `width × cell_width`: a
/// run that covers a band's cells must draw only the part of them the image actually reaches.
///
/// `None` when nothing survives — a fragment entirely inside a band, or a grid with no cells in it.
///
/// ## Why it is ghostty's arithmetic to the digit
///
/// The protocol says an image is "scaled to fit" its grid and stops there. Every real difference —
/// whether the leftover is centred or flushed, whether a fragment inside a band draws nothing or
/// draws the nearest row of pixels — is a terminal's own decision, and the programs that emit these
/// sequences were tested against kitty and ghostty. Deriving our own would put an off-by-a-pixel
/// seam between adjacent fragments of the same image, which is what a tiled image is made of.
fn fit(
    run: PlaceholderRun,
    image: ImageMeta,
    grid: (u32, u32),
    cell_width: u32,
    cell_height: u32,
) -> Option<RunGeometry> {
    let (grid_cols, grid_rows) = grid;
    if grid_cols == 0 || grid_rows == 0 || image.width == 0 || image.height == 0 {
        return None;
    }

    let img_width = f64::from(image.width);
    let img_height = f64::from(image.height);
    let grid_width_px = f64::from(grid_cols) * f64::from(cell_width);
    let grid_height_px = f64::from(grid_rows) * f64::from(cell_height);

    // The scale, and the padding the scale leaves over. One axis is always fully used and the other
    // is centred; which is which is the only thing this comparison decides.
    let (scale_x, scale_y, pad_x, pad_y) = if img_width * grid_height_px > img_height * grid_width_px {
        let scale = grid_width_px / f64::max(img_width, 1.0);
        (scale, scale, 0.0, (grid_height_px - img_height * scale) / 2.0)
    } else {
        let scale = grid_height_px / f64::max(img_height, 1.0);
        (scale, scale, (grid_width_px - img_width * scale) / 2.0, 0.0)
    };
    if !(scale_x > 0.0 && scale_y > 0.0) {
        return None;
    }

    // The same padding measured in IMAGE pixels, and the image as it would be with the bands
    // actually present. The fragment arithmetic below happens in this padded space because that is
    // the space the grid divides evenly.
    let pad_img_x = pad_x / scale_x;
    let pad_img_y = pad_y / scale_y;
    let padded_width = img_width + pad_img_x * 2.0;
    let padded_height = img_height + pad_img_y * 2.0;

    // The fragment, as a rectangle of the padded image.
    let mut source_x = padded_width * (f64::from(run.col) / f64::from(grid_cols));
    let mut source_y = padded_height * (f64::from(run.row) / f64::from(grid_rows));
    let mut source_width = padded_width * (f64::from(run.width) / f64::from(grid_cols));
    // A run is one row tall, always — see this module's header.
    let mut source_height = padded_height * (1.0 / f64::from(grid_rows));

    let mut dest_width = f64::from(run.width) * f64::from(cell_width);
    let mut dest_height = f64::from(cell_height);
    let mut offset_x = 0.0_f64;
    let mut offset_y = 0.0_f64;

    // Vertical: either the fragment starts inside the top band, ends inside the bottom one, or
    // clears both — in which case only the origin shifts out of padded space and into image space.
    if source_y < pad_img_y {
        let overlap = pad_img_y - source_y;
        source_height -= overlap;
        offset_y = overlap;
        dest_height -= overlap * scale_y;
        source_y = 0.0;
        // Both bands at once, which is a one-row grid over a very wide image. Without this the
        // source would run past the bottom of the texture.
        if source_height > img_height {
            source_height = img_height;
            dest_height = img_height * scale_y;
        }
    } else if source_y + source_height > padded_height - pad_img_y {
        source_y -= pad_img_y;
        source_height = padded_height - pad_img_y - source_y;
        source_height -= pad_img_y;
        dest_height = source_height * scale_y;
    } else {
        source_y -= pad_img_y;
    }

    // Horizontal, by the same three cases.
    if source_x < pad_img_x {
        let overlap = pad_img_x - source_x;
        source_width -= overlap;
        offset_x = overlap;
        dest_width -= overlap * scale_x;
        source_x = 0.0;
        if source_width > img_width {
            source_width = img_width;
            dest_width = img_width * scale_x;
        }
    } else if source_x + source_width > padded_width - pad_img_x {
        source_x -= pad_img_x;
        source_width = padded_width - pad_img_x - source_x;
        source_width -= pad_img_x;
        dest_width = source_width * scale_x;
    } else {
        source_x -= pad_img_x;
    }

    // A fragment wholly inside a band. It draws nothing, which is right — those cells are the blank
    // the aspect fit put there.
    if !(source_width > 0.0 && source_height > 0.0) {
        return None;
    }

    Some(RunGeometry {
        offset_x: round_px(offset_x * scale_x),
        offset_y: round_px(offset_y * scale_y),
        source_x: round_px(source_x),
        source_y: round_px(source_y),
        source_width: round_px(source_width),
        source_height: round_px(source_height),
        dest_width: round_px(dest_width),
        dest_height: round_px(dest_height),
    })
}

/// Where `run` draws, given the grid its placement declared.
///
/// The one door out of this module for geometry. See [`fit`] for the arithmetic and why it is
/// ghostty's.
#[must_use]
pub fn geometry(
    run: PlaceholderRun,
    image: ImageMeta,
    columns: u32,
    rows: u32,
    cell_width: u32,
    cell_height: u32,
) -> Option<RunGeometry> {
    if cell_width == 0 || cell_height == 0 {
        return None;
    }
    let grid = grid_of(columns, rows, image, cell_width, cell_height);
    fit(run, image, grid, cell_width, cell_height)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use libghostty_vt::style::{PaletteIndex, RgbColor, StyleColor};

    use super::{
        DIACRITICS, ImageMeta, PLACEHOLDER, PlaceholderRun, RunScan, color_to_id, diacritic_value, geometry,
    };

    /// The `n`th diacritic, which is the mark that encodes the value `n`.
    fn mark(value: usize) -> char {
        *DIACRITICS.get(value).unwrap()
    }

    /// A placeholder cell's grapheme cluster: the placeholder, then whichever marks are named.
    fn cell(marks: &[usize]) -> Vec<char> {
        let mut scalars = vec![PLACEHOLDER];
        scalars.extend(marks.iter().map(|value| mark(*value)));
        scalars
    }

    /// The foreground colour that names image id `id` in its low 24 bits.
    const fn fg(id: u32) -> StyleColor {
        StyleColor::Rgb(RgbColor {
            r: ((id >> 16) & 0xFF) as u8,
            g: ((id >> 8) & 0xFF) as u8,
            b: (id & 0xFF) as u8,
        })
    }

    #[test]
    fn the_table_is_sorted_because_the_search_over_it_is_binary() {
        // The one property the whole decode rests on, and the one a hand-copied table can lose
        // silently: `binary_search` on an unsorted array answers `Err` for entries that ARE there,
        // so a table with two rows swapped would drop those two row indices and place a fragment of
        // an image somewhere else — with no error anywhere. Verified rather than trusted.
        assert!(
            DIACRITICS.windows(2).all(|pair| {
                match pair {
                    [left, right] => left < right,
                    _ => false,
                }
            }),
            "the diacritic table is not strictly ascending"
        );
        assert_eq!(DIACRITICS.len(), 297, "kitty publishes 297 marks");
        assert_eq!(diacritic_value(mark(0)), Some(0));
        assert_eq!(diacritic_value(mark(296)), Some(296));
        assert_eq!(
            diacritic_value('a'),
            None,
            "an ordinary letter is not a position mark"
        );
    }

    #[test]
    fn an_id_is_the_low_24_bits_of_whichever_colour_spelling_arrived() {
        // Both spellings mean one number, which is why the protocol can hide an id in a colour at
        // all: a program picks palette or RGB by which reaches the id it wants.
        assert_eq!(color_to_id(StyleColor::None), 0);
        assert_eq!(color_to_id(StyleColor::Palette(PaletteIndex(7))), 7);
        assert_eq!(color_to_id(fg(0x00_12_34_56)), 0x12_34_56);
    }

    #[test]
    fn a_row_of_abbreviated_cells_is_one_run() {
        // The case every real program produces: the first cell carries row and column, the rest
        // carry nothing and continue implicitly. One run of four is what must come out — four runs
        // of one would put three resampling seams across one image.
        let mut scan = RunScan::default();
        assert_eq!(scan.cell(0, &cell(&[0, 0]), fg(1), StyleColor::None), None);
        for x in 1..4_u16 {
            assert_eq!(
                scan.cell(x, &cell(&[]), fg(1), StyleColor::None),
                None,
                "an abbreviated cell broke the run it was continuing"
            );
        }
        assert_eq!(
            scan.finish(),
            Some(PlaceholderRun {
                image_id: 1,
                placement_id: 0,
                col: 0,
                row: 0,
                width: 4,
                start_col: 0,
            })
        );
        assert_eq!(scan.finish(), None, "a finished run was answered twice");
    }

    #[test]
    fn a_fully_spelled_row_reaches_the_same_run() {
        // The other half of the abbreviation rule: a program that writes the column on every cell
        // must produce exactly what the abbreviated form does, or the same image drawn two ways
        // would land in two places.
        let mut scan = RunScan::default();
        for x in 0..4_u32 {
            let column = usize::try_from(x).unwrap();
            let ended = scan.cell(
                u16::try_from(x).unwrap(),
                &cell(&[0, column]),
                fg(1),
                StyleColor::None,
            );
            assert_eq!(ended, None, "a fully spelled cell broke its own run");
        }
        assert_eq!(scan.finish().unwrap().width, 4);
    }

    #[test]
    fn a_gap_a_new_image_and_a_jumped_column_each_end_the_run() {
        // The three ways a run stops, all of which a tiled image relies on: an ordinary character
        // between two images, two images side by side, and a fragment that skips a column.
        let mut scan = RunScan::default();
        assert!(scan.cell(0, &cell(&[0, 0]), fg(1), StyleColor::None).is_none());
        let ended = scan.cell(1, &['x'], fg(1), StyleColor::None).unwrap();
        assert_eq!((ended.width, ended.start_col), (1, 0));

        let mut scan = RunScan::default();
        assert!(scan.cell(0, &cell(&[0, 0]), fg(1), StyleColor::None).is_none());
        let ended = scan.cell(1, &cell(&[0, 0]), fg(2), StyleColor::None).unwrap();
        assert_eq!(ended.image_id, 1, "the first image's run must end at the second");
        assert_eq!(scan.finish().unwrap().image_id, 2);

        let mut scan = RunScan::default();
        assert!(scan.cell(0, &cell(&[0, 0]), fg(1), StyleColor::None).is_none());
        let ended = scan.cell(1, &cell(&[0, 5]), fg(1), StyleColor::None).unwrap();
        assert_eq!(ended.width, 1, "column 5 does not follow column 0");
        assert_eq!(scan.finish().unwrap().col, 5);
    }

    #[test]
    fn the_third_mark_is_the_high_byte_and_the_underline_is_the_placement() {
        // The two optional fields, and the reason an id needs 32 bits when a colour holds 24.
        let mut scan = RunScan::default();
        assert!(
            scan.cell(
                0,
                &cell(&[0, 0, 2]),
                fg(0x00_00_00_09),
                StyleColor::Palette(PaletteIndex(4)),
            )
            .is_none()
        );
        let run = scan.finish().unwrap();
        assert_eq!(run.image_id, 9 | (2 << 24));
        assert_eq!(run.placement_id, 4);
    }

    #[test]
    fn an_unrecognised_mark_is_absent_rather_than_fatal() {
        // kitty's behaviour, and the reason it matters here: the marks are POSITIONAL, so a first
        // mark nobody recognises must not shift the second one out of the column slot. A program
        // that emits one stray combining character keeps its image.
        let mut scan = RunScan::default();
        assert!(
            scan.cell(0, &[PLACEHOLDER, 'a', mark(3)], fg(1), StyleColor::None)
                .is_none()
        );
        let run = scan.finish().unwrap();
        assert_eq!(run.row, 0, "an invalid row mark defaults rather than refuses");
        assert_eq!(run.col, 3, "the second mark is still the column");
    }

    fn meta(width: u32, height: u32) -> ImageMeta {
        ImageMeta {
            id: 1,
            generation: 1,
            width,
            height,
        }
    }

    fn run(col: u32, row: u32, width: u32) -> PlaceholderRun {
        PlaceholderRun {
            image_id: 1,
            placement_id: 0,
            col,
            row,
            width,
            start_col: 0,
        }
    }

    #[test]
    fn an_image_whose_aspect_matches_its_grid_fills_it_exactly() {
        // A 16×32 image in a 2×2 grid of 8×16 cells is 16×32 device pixels — the same shape, so
        // there is no band anywhere and every row is half the image at full width. The baseline the
        // two band cases below are read against.
        let top = geometry(run(0, 0, 2), meta(16, 32), 2, 2, 8, 16).unwrap();
        assert_eq!((top.dest_width, top.dest_height), (16, 16));
        assert_eq!((top.offset_x, top.offset_y), (0, 0), "nothing to centre");
        assert_eq!(
            (top.source_x, top.source_y, top.source_width, top.source_height),
            (0, 0, 16, 16)
        );

        let bottom = geometry(run(0, 1, 2), meta(16, 32), 2, 2, 8, 16).unwrap();
        assert_eq!(
            (bottom.source_y, bottom.source_height),
            (16, 16),
            "the second row is the second half of the image and not the first again"
        );
        assert_eq!((bottom.offset_y, bottom.dest_height), (0, 16));
    }

    #[test]
    fn a_wide_image_is_centred_and_its_row_draws_only_where_the_image_reaches() {
        // The band case, which is what makes this arithmetic worth porting rather than inventing. A
        // 32×16 image in the same 16×32-pixel grid scales to half size — 16×8 — and sits centred
        // with 12 blank pixels above and below. Row 0 covers the top 16 pixels of the grid, so it
        // must draw 4 pixels at an offset of 12 and sample only the image's top half. Getting the
        // offset wrong shifts every tiled image by most of a row; getting the source wrong
        // stretches it.
        let top = geometry(run(0, 0, 2), meta(32, 16), 2, 2, 8, 16).unwrap();
        assert_eq!((top.offset_x, top.offset_y), (0, 12));
        assert_eq!((top.dest_width, top.dest_height), (16, 4));
        assert_eq!(
            (top.source_x, top.source_y, top.source_width, top.source_height),
            (0, 0, 32, 8)
        );
    }

    #[test]
    fn a_grid_the_placement_did_not_name_comes_from_the_image_and_the_cell() {
        // `c=`/`r=` are optional, and a placement without them is laid out at the image's own pixel
        // size — rounded up, because a half cell of image still needs a whole cell to sit in. A
        // 20×20 image over 8×16 cells is three columns and two rows.
        let fitted = geometry(run(0, 0, 3), meta(20, 20), 0, 0, 8, 16).unwrap();
        assert_eq!(
            super::grid_of(0, 0, meta(20, 20), 8, 16),
            (3, 2),
            "the grid must round up on both axes"
        );
        assert!(fitted.dest_width > 0 && fitted.dest_height > 0);
    }

    #[test]
    fn a_degenerate_grid_or_image_draws_nothing_rather_than_dividing_by_zero() {
        // Every one of these is reachable from the pty: a zero-sized cell before the first layout,
        // and a placement naming a grid for an image that never arrived. A `None` skips the
        // placement; a division here would put a NaN in a vertex buffer.
        assert!(geometry(run(0, 0, 1), meta(0, 10), 2, 2, 8, 16).is_none());
        assert!(geometry(run(0, 0, 1), meta(10, 0), 2, 2, 8, 16).is_none());
        assert!(geometry(run(0, 0, 1), meta(10, 10), 2, 2, 0, 16).is_none());
        assert!(geometry(run(0, 0, 1), meta(10, 10), 2, 2, 8, 0).is_none());
    }
}
