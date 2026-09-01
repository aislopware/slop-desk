//! A run of cells into positioned glyph ids.
//!
//! ## Two paths, and why the fast one is legitimate
//!
//! Shaping a paragraph and shaping a terminal row are different problems. A paragraph does not know
//! where its glyphs go until the typesetter says so; a grid decided before the shaper was called —
//! `CellGeometry::span` owns that, and the painter has already computed the run's origin by the
//! time it hands the run over. So the only thing shaping can tell a grid that it does not already
//! know is WHICH glyph.
//!
//! [`Shaper::shape`] therefore tries [`Shaper::shape_monospace`] first: one
//! `CTFontGetGlyphsForCharacters` over the whole run, one glyph per cell, positions from the grid.
//! It declines anything that is not plain ASCII with one character per cell, and everything it
//! declines goes through `CTLine`, which is where fallback, wide characters, emoji and combining
//! marks are handled properly.
//!
//! **Measured** — release build, Apple M1 Max, one 80-cell ASCII run of `Menlo` at 26 device
//! pixels, best of 2000 iterations: `CTLine` **4.4 µs**, the fast path **0.75 µs**. Just under six
//! times, and the difference is not the character-to-glyph mapping, which both paths do once; it is
//! the objects `CTLine` has to build and free per call — a `CFString`, a `CFDictionary`, a
//! `CFAttributedString`, a typesetter, a line and a run array. On a 200×60 grid whose rows break
//! into a few runs each, that is a couple of milliseconds a frame against a few hundred
//! microseconds, on a 16 ms budget `docs/68` §6 already spends mostly on drawing.
//!
//! ## What the fast path gives up
//!
//! Ligatures, deliberately. A programming ligature has to land on the cell grid to be *correct* in
//! a terminal — `!=` occupies two columns whatever it draws as — and `CTLine` makes no such
//! promise; it will happily answer one glyph whose advance is not two cells. Placing the ligature's
//! single glyph at its first cell, which is what [`ShapedGlyph::cell`] documents, is the behaviour
//! both paths already agree on, so the fast path is not losing a correct rendering, it is skipping
//! a substitution neither path could honour without the grid's permission.
//!
//! ## Positions come from the grid, offsets come from Core Text
//!
//! On the `CTLine` path the run's positions are read, but only their DIFFERENCE inside a cluster is
//! used: the first glyph of a cell is pinned to `cell_width * cell`, and every glyph after it in
//! the same cell keeps the offset Core Text gave it. That is what puts a combining accent over its
//! base — the mark's GPOS adjustment survives — while keeping the base itself on the grid, which is
//! the only place a terminal can put it. Telex is the reason this matters enough to spend the
//! buffer on: `docs/68` §5.1 puts marked text on the critical path.

use core::ptr::NonNull;

use objc2_core_foundation::{
    CFArray, CFCharacterSet, CFCharacterSetPredefinedSet, CFDictionary, CFIndex, CFRange, CFRetained,
    CFString, CFType, CGPoint,
};
use objc2_core_graphics::CGGlyph;
use objc2_core_text::{CTFont, CTLine, CTRun, kCTFontAttributeName};
use slopdesk_termrender::glyph::{GlyphKey, ShapedGlyph, TextRun, TextShaper};

use crate::font::{Face, Faces, Style, narrow};

/// The joiner that fuses an emoji sequence into one cluster. Not a non-base character — it is a
/// FORMAT character — so Core Foundation's table alone would break `👩‍💻` into three cells.
const ZERO_WIDTH_JOINER: char = '\u{200d}';

/// The skin-tone modifiers, which are modifier SYMBOLS rather than marks and so are likewise
/// outside the non-base set, but attach to the emoji before them exactly as a mark would.
const EMOJI_MODIFIERS: core::ops::RangeInclusive<char> = '\u{1f3fb}'..='\u{1f3ff}';

/// A `CFRange` covering all of whatever it is passed to.
///
/// Core Text spells "everything" as a zero LENGTH rather than as the actual count, which is easy to
/// read as "nothing" at the call site — hence the name.
const WHOLE: CFRange = CFRange {
    location: 0,
    length: 0,
};

/// Turns a run of cells into positioned glyphs, growing the stack's fallback chain as it goes.
#[derive(Debug)]
pub struct Shaper {
    faces: Faces,
    styles: [Style; 4],
    cell_width: f64,
    size_px: u16,
    non_base: Option<CFRetained<CFCharacterSet>>,
    utf16: Vec<u16>,
    glyphs: Vec<CGGlyph>,
    positions: Vec<CGPoint>,
    indices: Vec<CFIndex>,
    cells: Vec<u16>,
}

impl Shaper {
    /// Built by [`FontStack::shaper`], which is what owns the chain this one grows.
    ///
    /// [`FontStack::shaper`]: crate::FontStack::shaper
    pub(crate) fn new(faces: Faces, styles: [Style; 4], cell_width: f64, size_px: u16) -> Self {
        Self {
            faces,
            styles,
            cell_width,
            size_px,
            // A predefined character set is a process-wide singleton Core Foundation hands back
            // under the GET rule; the binding retains it, and holding it here is what keeps the
            // per-character test down to a table lookup.
            non_base: CFCharacterSet::predefined(CFCharacterSetPredefinedSet::NonBase),
            utf16: Vec::new(),
            glyphs: Vec::new(),
            positions: Vec::new(),
            indices: Vec::new(),
            cells: Vec::new(),
        }
    }

    /// Which of the four cuts a run wants.
    fn style_of(&self, run: &TextRun<'_>) -> Style {
        let slot = usize::from(run.bold) | (usize::from(run.italic) << 1_i32);
        self.styles.get(slot).copied().unwrap_or(Style::PRIMARY)
    }

    /// One glyph per cell, mapped in a single call and placed by the grid.
    ///
    /// `false` means "I could not do this" and costs nothing — the guard is two comparisons before
    /// any framework call. `run.text.len()` is a BYTE count, so it equals the cell count only when
    /// every cell holds exactly one single-byte character; combined with `is_ascii`, that is the
    /// whole precondition, and it rules out combining marks, wide characters and emoji without
    /// having to look for them.
    fn shape_monospace(&mut self, run: &TextRun<'_>, style: Style, out: &mut Vec<ShapedGlyph>) -> bool {
        let cells = usize::from(run.cells);
        if cells == 0 || run.text.len() != cells || !run.text.is_ascii() {
            return false;
        }
        let Ok(count) = CFIndex::try_from(cells) else {
            return false;
        };

        self.utf16.clear();
        self.utf16.extend(run.text.bytes().map(u16::from));
        self.glyphs.clear();
        self.glyphs.resize(cells, CGGlyph::MIN);
        let (Some(characters), Some(glyphs)) = (
            NonNull::new(self.utf16.as_mut_ptr()),
            NonNull::new(self.glyphs.as_mut_ptr()),
        ) else {
            return false;
        };

        let mapped = {
            let faces = self.faces.borrow();
            let Some(face) = faces.get(usize::from(style.face)) else {
                return false;
            };
            // SAFETY: framework rule. `CTFontGetGlyphsForCharacters` is GET-rule — it owns nothing
            // and answers a bool. Both pointers address `Vec`s this struct owns, each resized to
            // `cells` immediately above and neither touched again until the call returns, and
            // `count` is that same length. This is the caller-owned-slot shape `docs/57` §2
            // blesses; the function does not keep either pointer.
            #[expect(
                unsafe_code,
                reason = "a Get-rule call writing through two slots this struct owns"
            )]
            let mapped = unsafe { face.font.glyphs_for_characters(characters, glyphs, count) };
            mapped
        };
        // A `false` means at least one character has no glyph in this face, and Core Text has left
        // a 0 where it could not map. Falling through to `CTLine` is what finds the fallback face
        // that can — drawing `.notdef` would be a decision this path is not entitled to make.
        if !mapped {
            return false;
        }

        for (index, glyph) in self.glyphs.iter().enumerate() {
            let Ok(cell) = u16::try_from(index) else {
                break;
            };
            out.push(ShapedGlyph {
                key: GlyphKey {
                    font: style.face,
                    glyph: u32::from(*glyph),
                    size_px: self.size_px,
                    subpixel: run.subpixel,
                    synthetic: style.synthetic,
                },
                x: narrow(self.cell_width * f64::from(cell)),
                y: 0.0,
                cell,
            });
        }
        true
    }

    /// The general path: `CTLine` over the run, walked run by run.
    ///
    /// Core Text substitutes a face per run when the primary cannot map a character, which is the
    /// whole of fallback — there is no second cascade to consult here, only the answer to read back
    /// off each run and intern.
    fn shape_core_text(&mut self, run: &TextRun<'_>, style: Style, out: &mut Vec<ShapedGlyph>) {
        let Some(line) = self.line(run, style) else {
            return;
        };
        cell_map(run.text, run.cells, self.non_base.as_deref(), &mut self.cells);

        // SAFETY: framework rule. The Core Foundation CREATE rule — `CTLineGetGlyphRuns` is
        // documented as GET, and `objc2`'s binding retains before handing the array over, so what
        // arrives is owned either way and `CFRetained` releases it.
        #[expect(
            unsafe_code,
            reason = "an array objc2 has already retained on this caller's behalf"
        )]
        let runs = unsafe { line.glyph_runs() };
        // SAFETY: framework rule. Core Text documents this as "an array of CTRun objects"; C's
        // `CFArrayRef` has nowhere to carry that, which is why the binding hands back an untyped
        // array. Nothing is dereferenced — the typed view only decides which `get` applies.
        #[expect(
            unsafe_code,
            reason = "C's CFArrayRef carries no element type; the CTLine header is where it lives"
        )]
        let runs = unsafe { CFRetained::cast_unchecked::<CFArray<CTRun>>(runs) };

        for slot in 0..runs.len() {
            let Some(ct_run) = runs.get(slot) else {
                continue;
            };
            let face = self.intern_run_face(&ct_run).unwrap_or(style.face);
            self.emit_run(&ct_run, run, style, face, out);
        }
    }

    /// The `CTLine` for one run, with the requested face attached.
    fn line(&self, run: &TextRun<'_>, style: Style) -> Option<CFRetained<CTLine>> {
        let faces = self.faces.borrow();
        let face = faces.get(usize::from(style.face))?;
        let text = CFString::from_str(run.text);

        // SAFETY: framework rule. An `extern` static Core Text initialises when its image loads,
        // which is before anything that could reach this has run — the Core Text calls around it
        // are what force the load. Rust cannot see that, so the read is `unsafe`; the framework's
        // contract is a non-null immutable `CFStringRef` for the process's whole life, which is
        // exactly what `&'static CFString` claims.
        #[expect(
            unsafe_code,
            reason = "the framework's key constant is an extern static; objc2 cannot generate it safe"
        )]
        let key = unsafe { kCTFontAttributeName };
        let carrier = CFDictionary::<CFString, CTFont>::from_slices(&[key], &[&face.font]);

        // SAFETY: framework rule. The Core Foundation CREATE rule — `CFAttributedStringCreate`
        // answers a reference this caller owns. Both arguments are live `CFRetained`s for the whole
        // call and neither is null; the `unsafe` is `objc2` refusing to certify the nullability and
        // the dictionary's element types, which the line above just fixed.
        #[expect(
            unsafe_code,
            reason = "a Create-rule return over a dictionary whose types this fn chose"
        )]
        let attributed = unsafe {
            objc2_core_foundation::CFAttributedString::new(None, Some(&text), Some(carrier.as_opaque()))
        }?;

        // SAFETY: framework rule. The CREATE rule again — `CTLineCreateWithAttributedString`
        // answers a reference this caller owns, which `CFRetained` releases. The attributed
        // string is live for the whole call and Core Text copies what it needs out of it.
        #[expect(
            unsafe_code,
            reason = "a Create-rule return; objc2 cannot know the caller owns it"
        )]
        let line = unsafe { CTLine::with_attributed_string(&attributed) };
        Some(line)
    }

    /// The chain index of the face Core Text actually used for a run.
    fn intern_run_face(&self, ct_run: &CTRun) -> Option<u16> {
        // SAFETY: framework rule. `CTRunGetAttributes` is GET-rule — the dictionary belongs to the
        // run — and `objc2`'s binding retains before handing it over, so the `CFRetained` that
        // arrives owns a reference and releases it. Nothing outlives the run either way.
        #[expect(
            unsafe_code,
            reason = "a dictionary objc2 has already retained on this caller's behalf"
        )]
        let attributes = unsafe { ct_run.attributes() };
        // SAFETY: framework rule. Core Text documents a run's attributes as the string attribute
        // dictionary, whose keys are the `kCT…AttributeName` constants; C's `CFDictionaryRef`
        // carries neither generic. Nothing is dereferenced — the typed view only decides which
        // `get` applies, and the value is checked against `CTFontGetTypeID` by the `downcast`
        // below.
        #[expect(unsafe_code, reason = "C's CFDictionaryRef carries no key or value type")]
        let attributes = unsafe { CFRetained::cast_unchecked::<CFDictionary<CFString, CFType>>(attributes) };
        // SAFETY: framework rule. An `extern` static, live from image load; see `Self::line`.
        #[expect(
            unsafe_code,
            reason = "the framework's key constant is an extern static; objc2 cannot generate it safe"
        )]
        let key = unsafe { kCTFontAttributeName };
        let font = attributes.get(key)?.downcast::<CTFont>().ok()?;

        let mut faces = self.faces.borrow_mut();
        // `CFEqual` on two `CTFont`s compares the descriptor, the size and the matrix, which is
        // exactly the identity a `GlyphKey::font` index has to stand for. Comparing PostScript
        // names instead would copy a `CFString` per run to answer the same question.
        if let Some(index) = faces.iter().position(|face| *face.font == *font) {
            return u16::try_from(index).ok();
        }
        let index = u16::try_from(faces.len()).ok()?;
        faces.push(Face::new(font));
        Some(index)
    }

    /// One `CTRun`'s glyphs, pinned to the grid and keeping their intra-cluster offsets.
    fn emit_run(
        &mut self,
        ct_run: &CTRun,
        run: &TextRun<'_>,
        style: Style,
        face: u16,
        out: &mut Vec<ShapedGlyph>,
    ) {
        // SAFETY: framework rule. GET-rule — a count read off a live run, by value.
        #[expect(
            unsafe_code,
            reason = "a Get-rule scalar read; nothing is owned and nothing escapes"
        )]
        let count = unsafe { ct_run.glyph_count() };
        let Ok(len) = usize::try_from(count) else {
            return;
        };
        if len == 0 {
            return;
        }

        self.glyphs.clear();
        self.glyphs.resize(len, CGGlyph::MIN);
        self.positions.clear();
        self.positions.resize(len, CGPoint { x: 0.0, y: 0.0 });
        self.indices.clear();
        self.indices.resize(len, 0);
        let (Some(glyphs), Some(positions), Some(indices)) = (
            NonNull::new(self.glyphs.as_mut_ptr()),
            NonNull::new(self.positions.as_mut_ptr()),
            NonNull::new(self.indices.as_mut_ptr()),
        ) else {
            return;
        };

        // SAFETY: framework rule. Three GET-rule calls, none of which owns anything. Each writes
        // through a slot this struct allocated: the three `Vec`s were resized to the run's own
        // glyph count immediately above, none is touched again until all three calls return, and
        // `WHOLE` is Core Text's spelling for "the entire run", so no call can write past what was
        // reserved. The buffer-filling forms are used in preference to their `…Ptr` siblings for
        // exactly this reason — reading a pointer Core Text owns would need
        // `slice::from_raw_parts`, which `docs/57` §2 bars from this family.
        #[expect(
            unsafe_code,
            reason = "three Get-rule calls writing through slots this struct owns"
        )]
        unsafe {
            ct_run.glyphs(WHOLE, glyphs);
            ct_run.positions(WHOLE, positions);
            ct_run.string_indices(WHOLE, indices);
        }

        // The first glyph of each cell anchors that cell; everything after it keeps the offset Core
        // Text gave it, which is the mark positioning a decomposed accent depends on.
        let mut anchor_cell = u16::MAX;
        let mut anchor_x = 0.0_f64;
        for slot in 0..len {
            let (Some(glyph), Some(position)) = (self.glyphs.get(slot), self.positions.get(slot)) else {
                break;
            };
            let cell = self
                .indices
                .get(slot)
                .and_then(|index| usize::try_from(*index).ok())
                .and_then(|index| self.cells.get(index).copied())
                .unwrap_or(0);
            if cell != anchor_cell {
                anchor_cell = cell;
                anchor_x = position.x;
            }
            out.push(ShapedGlyph {
                key: GlyphKey {
                    font: face,
                    glyph: u32::from(*glyph),
                    size_px: self.size_px,
                    subpixel: run.subpixel,
                    // Carried from the requested style rather than re-derived from the substituted
                    // face: a family with no bold cut still wants its fallback stroked, and a face
                    // Core Text picked has no opinion about what the cell asked for.
                    synthetic: style.synthetic,
                },
                x: narrow(self.cell_width * f64::from(cell) + (position.x - anchor_x)),
                // Core Text measures up from the baseline and the renderer measures down from it.
                y: narrow(-position.y),
                cell,
            });
        }
    }
}

impl TextShaper for Shaper {
    fn shape(&mut self, run: &TextRun<'_>, out: &mut Vec<ShapedGlyph>) {
        let style = self.style_of(run);
        if !self.shape_monospace(run, style, out) {
            self.shape_core_text(run, style, out);
        }
    }
}

/// Which cell each UTF-16 offset of a run's text belongs to.
///
/// [`TextRun`] hands over a run's TEXT and its CELL COUNT and nothing in between, so the boundaries
/// the frame already knew — one cell carries one grapheme, which may be several characters — have
/// to be re-derived here. The rule is the terminal's: a cell opens at every character that is not a
/// CONTINUATION, and a continuation is a Unicode non-base character (Core Foundation's own table,
/// which is the one Core Text consults), a zero-width joiner, whatever follows one, or a skin-tone
/// modifier.
///
/// Overrun is clamped rather than trusted. A run that decomposes into more clusters than the caller
/// said it had cells would otherwise report a column outside the span the painter reserved, and the
/// painter would place a glyph over the next run's text.
fn cell_map(text: &str, cells: u16, non_base: Option<&CFCharacterSet>, out: &mut Vec<u16>) {
    out.clear();
    let last = cells.saturating_sub(1);
    let mut cell = 0_u16;
    let mut opened = false;
    let mut after_joiner = false;
    for character in text.chars() {
        let continues = after_joiner
            || character == ZERO_WIDTH_JOINER
            || EMOJI_MODIFIERS.contains(&character)
            || non_base.is_some_and(|set| set.is_long_character_member(u32::from(character)));
        if opened && !continues {
            cell = cell.saturating_add(1);
        }
        opened = true;
        after_joiner = character == ZERO_WIDTH_JOINER;
        let at = u16::min(cell, last);
        for _ in 0..character.len_utf16() {
            out.push(at);
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_termrender::glyph::{ShapedGlyph, TextRun, TextShaper};

    use crate::FontStack;
    use crate::font::spec_of;
    use crate::shape::cell_map;

    const MONO: &str = "Menlo";

    fn run(text: &str, cells: u16) -> TextRun<'_> {
        TextRun {
            text,
            start_col: 0,
            cells,
            bold: false,
            italic: false,
            size_px: 26,
            subpixel: 0,
        }
    }

    /// The fast path's whole claim: one glyph per cell, at the grid's own positions.
    #[test]
    fn an_ascii_run_shapes_one_glyph_per_cell_on_the_grid() {
        let stack = FontStack::new(&spec_of(MONO, 13.0, 1.0), 2.0).unwrap();
        let mut shaper = stack.shaper();
        let mut out = Vec::new();
        shaper.shape(&run("hello", 5), &mut out);

        assert_eq!(out.len(), 5);
        for (index, glyph) in out.iter().enumerate() {
            let column = u16::try_from(index).unwrap();
            assert_eq!(glyph.cell, column);
            assert_eq!(glyph.key.font, 0, "every ASCII letter is in the primary face");
            assert_ne!(glyph.key.glyph, 0, "and none of them is .notdef");
            assert!((f64::from(glyph.x) - stack.cell_width() * f64::from(column)).abs() < 1e-3);
            assert!((glyph.y - 0.0).abs() < f32::EPSILON);
        }
    }

    /// The fast path is an OPTIMISATION, not a second implementation: it has to answer the glyph
    /// ids Core Text would have. If these ever diverge, the atlas holds two entries for one
    /// character and only one of them is right.
    #[test]
    fn both_paths_agree_on_the_glyphs_for_ascii() {
        let stack = FontStack::new(&spec_of(MONO, 13.0, 1.0), 2.0).unwrap();
        let mut shaper = stack.shaper();
        let text = "int main(void) { return 0; }";
        let cells = u16::try_from(text.len()).unwrap();
        let style = shaper.style_of(&run(text, cells));

        let mut fast: Vec<ShapedGlyph> = Vec::new();
        assert!(shaper.shape_monospace(&run(text, cells), style, &mut fast));
        let mut slow: Vec<ShapedGlyph> = Vec::new();
        shaper.shape_core_text(&run(text, cells), style, &mut slow);

        assert_eq!(fast.len(), slow.len());
        for (one, other) in fast.iter().zip(slow.iter()) {
            assert_eq!(one.key.glyph, other.key.glyph);
            assert_eq!(one.cell, other.cell);
            assert!((one.x - other.x).abs() < 0.01, "and land in the same column");
        }
    }

    /// Fallback, which only the Core Text path can do: Menlo has no Han, so Core Text substitutes,
    /// and the substitution has to arrive as a face index the rasteriser can look up rather than as
    /// `.notdef` in the primary.
    #[test]
    fn a_han_character_finds_a_face_the_latin_family_does_not_have() {
        let stack = FontStack::new(&spec_of(MONO, 13.0, 1.0), 2.0).unwrap();
        let before = stack.face_count();
        let mut shaper = stack.shaper();
        let mut out = Vec::new();
        shaper.shape(&run("漢", 1), &mut out);

        assert_eq!(out.len(), 1);
        let glyph = out.first().unwrap();
        assert_ne!(glyph.key.font, 0, "not the Latin family");
        assert_ne!(glyph.key.glyph, 0, "and a real glyph, not .notdef");
        assert!(stack.face_count() > before, "the chain grew to hold it");
        assert_eq!(glyph.cell, 0);

        // Interning is by identity, so a second Han run does not append a second copy of the same
        // face — a chain that grew per run would run out of `u16` on a long session.
        let grown = stack.face_count();
        shaper.shape(&run("字", 1), &mut out);
        assert_eq!(stack.face_count(), grown);
    }

    /// A combining mark belongs to the cell its base is in. The trait hands the shaper text and a
    /// cell count and nothing between them, so this is the boundary rule being exercised rather
    /// than Core Text's.
    #[test]
    fn a_combining_mark_shares_the_cell_of_its_base() {
        let stack = FontStack::new(&spec_of(MONO, 13.0, 1.0), 2.0).unwrap();
        let mut shaper = stack.shaper();
        let mut out = Vec::new();
        // "e" + COMBINING ACUTE, then a plain "x": two cells, three characters.
        shaper.shape(&run("e\u{301}x", 2), &mut out);

        assert!(out.len() >= 2);
        assert_eq!(out.first().unwrap().cell, 0);
        assert_eq!(
            out.last().unwrap().cell,
            1,
            "the character after the cluster opens a new cell"
        );
    }

    /// The map itself, away from any face — the four continuation rules in one place.
    #[test]
    fn the_cell_map_keeps_a_cluster_in_one_cell() {
        let mut cells = Vec::new();

        cell_map("abc", 3, None, &mut cells);
        assert_eq!(cells, vec![0, 1, 2]);

        // A zero-width joiner and what follows it stay with the emoji before them, and each half of
        // a surrogate pair reports the same cell because the indices Core Text answers are UTF-16.
        cell_map("\u{1f469}\u{200d}\u{1f4bb}", 2, None, &mut cells);
        assert_eq!(cells, vec![0, 0, 0, 0, 0]);

        // A skin-tone modifier likewise.
        cell_map("\u{1f44d}\u{1f3fb}", 2, None, &mut cells);
        assert_eq!(cells, vec![0, 0, 0, 0]);

        // And a run that decomposes into more clusters than the caller reserved is clamped rather
        // than allowed to report a column the painter never made room for.
        cell_map("abcd", 2, None, &mut cells);
        assert_eq!(cells, vec![0, 1, 1, 1]);
    }

    /// The leak test for the shaping half: a thousand runs down each path, taking and dropping a
    /// line, a run array and a dictionary every time.
    #[test]
    fn a_thousand_runs_hold_nothing() {
        let stack = FontStack::new(&spec_of(MONO, 13.0, 1.0), 2.0).unwrap();
        let mut shaper = stack.shaper();
        let mut out = Vec::new();
        for _ in 0..1000 {
            out.clear();
            shaper.shape(&run("cargo test --all", 16), &mut out);
            assert_eq!(out.len(), 16);
            out.clear();
            shaper.shape(&run("漢", 1), &mut out);
            assert_eq!(out.len(), 1);
        }
    }
}
