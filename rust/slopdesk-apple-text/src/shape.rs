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
//! ## The fast path is legal only where it is measured to be
//!
//! `CTFontGetGlyphsForCharacters` reads a face's `cmap` and nothing else — no `GSUB`, so no
//! ligature and no stylistic alternate. That is the right answer for `Menlo`, whose ASCII means
//! exactly what its `cmap` says; it is the WRONG answer for a programming family, where `!=` is one
//! glyph and `terminal.font-feature` is the setting that asked for it. So which answer applies is
//! not assumed, it is [probed](substitutes_over_ascii) once per face at [`FontStack::new`]: shape
//! every ordered pair of printable ASCII through `CTLine`, compare against the `cmap`, and record
//! whether the two agree. A face that agrees keeps the fast path; a face that does not sends its
//! ASCII through `CTLine` too, which is what its user chose by naming it.
//!
//! The probe wears the face's own descriptor, so it answers the CONFIGURED font rather than the
//! raw one: a family whose `calt` is on by default probes as substituting, and the same family
//! under `terminal.font-feature = "-calt -liga"` probes as literal and keeps the fast path. No
//! feature name is parsed anywhere — the comparison is the whole test.
//!
//! **Measured** — release build, macOS 26, best of 30: [`FontStack::new`] goes from **0.07 ms** to
//! **1.46 ms** for `Menlo` and **2.77 ms** for `Helvetica`, which is four cuts probed against the
//! whole corpus. That is paid once per stack — at launch, and again on a settings write or a move
//! to a display of a different scale — and it buys back the per-frame cost of shaping every ASCII
//! run through `CTLine` on the families that do not need it.
//!
//! [`FontStack::new`]: crate::FontStack::new
//!
//! ## Where a ligature lands
//!
//! On its first cell. `CTRunGetStringIndices` reports the cluster's first character, [`cell_map`]
//! turns that into a column, and [`Shaper::emit_run`] pins the cluster's first glyph to
//! `cell_width * cell` — so `!=` draws from the left edge of the `!` column, and the ligature glyph
//! of a monospace family is drawn two cells wide because that is how the family drew it. Nothing
//! clips it: the rasteriser sizes each bitmap from `CTFontGetBoundingRectsForGlyphs` rounded OUT,
//! and the painter's quad takes that bitmap's own width. The cell after it holds no glyph, which is
//! correct — a ligature is one mark over several columns.
//!
//! The painter is what keeps this honest under a cursor or a selection: `Painter` breaks a run at
//! the cursor cell and at every colour change, so a caret standing inside `!=` splits the pair into
//! two runs and the two halves draw unligated, which is the behaviour every editor has.
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
    /// `false` means "I could not do this" and costs nothing — the guard is three comparisons
    /// before any framework call. `run.text.len()` is a BYTE count, so it equals the cell count
    /// only when every cell holds exactly one single-byte character; combined with `is_ascii`, that
    /// is the whole precondition, and it rules out combining marks, wide characters and emoji
    /// without having to look for them.
    ///
    /// [`Style::ascii_is_literal`] is the first of the three, and the only one that is not a fact
    /// about this run: it is the face's answer to [`substitutes_over_ascii`], taken once at
    /// construction. A face that ligates never reaches the `cmap` call below.
    fn shape_monospace(&mut self, run: &TextRun<'_>, style: Style, out: &mut Vec<ShapedGlyph>) -> bool {
        let cells = usize::from(run.cells);
        if !style.ascii_is_literal || cells == 0 || run.text.len() != cells || !run.text.is_ascii() {
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
        line_for(&face.font, run.text)
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

/// The `CTLine` for `text`, shaped in exactly `font` — the face as configured, features and all.
///
/// Free rather than a method because the capability probe runs at [`FontStack::new`], before any
/// [`Shaper`] exists, and it needs the same line the shaper would have built. Answering `None`
/// rather than an empty line keeps "Core Text refused" distinguishable from "this text has no
/// glyphs", which the probe reads as a reason to stay on the safe path.
///
/// [`FontStack::new`]: crate::FontStack::new
fn line_for(font: &CTFont, text: &str) -> Option<CFRetained<CTLine>> {
    let text = CFString::from_str(text);

    // SAFETY: framework rule. An `extern` static Core Text initialises when its image loads, which
    // is before anything that could reach this has run — the Core Text calls around it are what
    // force the load. Rust cannot see that, so the read is `unsafe`; the framework's contract is a
    // non-null immutable `CFStringRef` for the process's whole life, which is exactly what
    // `&'static CFString` claims.
    #[expect(
        unsafe_code,
        reason = "the framework's key constant is an extern static; objc2 cannot generate it safe"
    )]
    let key = unsafe { kCTFontAttributeName };
    let carrier = CFDictionary::<CFString, CTFont>::from_slices(&[key], &[font]);

    // SAFETY: framework rule. The Core Foundation CREATE rule — `CFAttributedStringCreate` answers
    // a reference this caller owns. Both arguments are live for the whole call and neither is null;
    // the `unsafe` is `objc2` refusing to certify the nullability and the dictionary's element
    // types, which the line above just fixed.
    #[expect(
        unsafe_code,
        reason = "a Create-rule return over a dictionary whose types this fn chose"
    )]
    let attributed = unsafe {
        objc2_core_foundation::CFAttributedString::new(None, Some(&text), Some(carrier.as_opaque()))
    }?;

    // SAFETY: framework rule. The CREATE rule again — `CTLineCreateWithAttributedString` answers a
    // reference this caller owns, which `CFRetained` releases. The attributed string is live for
    // the whole call and Core Text copies what it needs out of it.
    #[expect(
        unsafe_code,
        reason = "a Create-rule return; objc2 cannot know the caller owns it"
    )]
    let line = unsafe { CTLine::with_attributed_string(&attributed) };
    Some(line)
}

/// Every glyph a line shaped to, in order, ignoring where they landed.
///
/// `false` for a line that answered nothing at all, which is the one case a caller cannot tell from
/// an honest empty answer by looking at `out`.
fn line_glyphs(line: &CTLine, out: &mut Vec<CGGlyph>) -> bool {
    out.clear();

    // SAFETY: framework rule. `CTLineGetGlyphRuns` is documented as GET, and `objc2`'s binding
    // retains before handing the array over, so what arrives is owned either way and `CFRetained`
    // releases it.
    #[expect(
        unsafe_code,
        reason = "an array objc2 has already retained on this caller's behalf"
    )]
    let runs = unsafe { line.glyph_runs() };
    // SAFETY: framework rule. Core Text documents this as "an array of CTRun objects"; C's
    // `CFArrayRef` has nowhere to carry that. Nothing is dereferenced — the typed view only decides
    // which `get` applies.
    #[expect(
        unsafe_code,
        reason = "C's CFArrayRef carries no element type; the CTLine header is where it lives"
    )]
    let runs = unsafe { CFRetained::cast_unchecked::<CFArray<CTRun>>(runs) };

    for slot in 0..runs.len() {
        let Some(ct_run) = runs.get(slot) else {
            return false;
        };
        // SAFETY: framework rule. GET-rule — a count read off a live run, by value.
        #[expect(
            unsafe_code,
            reason = "a Get-rule scalar read; nothing is owned and nothing escapes"
        )]
        let count = unsafe { ct_run.glyph_count() };
        let Ok(len) = usize::try_from(count) else {
            return false;
        };
        let base = out.len();
        out.resize(base + len, CGGlyph::MIN);
        let Some(slots) = out.get_mut(base..) else {
            return false;
        };
        let Some(slots) = NonNull::new(slots.as_mut_ptr()) else {
            return false;
        };
        // SAFETY: framework rule. A GET-rule call writing through a slot this function owns: the
        // `Vec` was just grown by the run's own glyph count, `slots` addresses exactly that tail,
        // and `WHOLE` is Core Text's spelling for "the entire run", so the call cannot write past
        // what was reserved. Nothing is retained and the pointer does not escape.
        #[expect(
            unsafe_code,
            reason = "a Get-rule call writing through a slot this fn just reserved"
        )]
        unsafe {
            ct_run.glyphs(WHOLE, slots);
        }
    }
    !out.is_empty()
}

/// The printable ASCII alphabet, which is the whole of what the fast path claims to know.
const PRINTABLE: core::ops::RangeInclusive<u8> = 0x20..=0x7E;

/// How much of the probe's corpus goes through one `CTLine`.
///
/// **Measured**, macOS 26, `Helvetica`: `CTLine` applies `liga` to `"fi"` repeated 5 000 times —
/// 10 000 characters — and STOPS applying it at 12 000. Somewhere between the two Core Text gives
/// up on substitution for a line that long and hands back the `cmap`, which for a probe that
/// compares the two is the worst possible failure: every face on the system reads as literal and
/// nobody ever gets a ligature. 2 048 is an order of magnitude below the cliff and still only nine
/// lines for the whole corpus, which is the trade this constant is making.
const PROBE_CHUNK: usize = 2048;

/// Whether this face answers anything other than its own `cmap` for plain ASCII.
///
/// This is the fact [`Shaper::shape_monospace`] rests on, and it is measured rather than assumed.
/// The corpus is every ORDERED pair of printable ASCII characters, concatenated — 9 025 pairs, 18
/// 050 characters, one `CTLine`. Concatenation is exhaustive without a de Bruijn construction and
/// sound without one too: the pairs that straddle two chunks are themselves ASCII pairs, so a
/// substitution found at a seam is still a substitution this face performs.
///
/// Both halves of the comparison matter. A different glyph COUNT is a ligature — several characters
/// fused into one mark. The same count with different IDS is a stylistic alternate, `ss01` or a
/// slashed zero, which the fast path would silently drop even though the user paid for it in
/// `terminal.font-feature`.
///
/// `true` — "assume it substitutes" — is the answer to every failure, because that answer costs
/// speed and the other one costs correctness. It is also the answer when the face cannot map some
/// printable character at all: `CTLine` would find a fallback for it and the `cmap` path would
/// have to decline anyway.
///
/// A ligature of THREE characters or more whose two-character prefix does not also substitute would
/// be missed. That failure is soft in the only direction that matters — such a face renders
/// unligated, exactly as it does today — and no shipping programming family is built that way;
/// `===` exists because `==` does.
pub(crate) fn substitutes_over_ascii(font: &CTFont) -> bool {
    let alphabet = PRINTABLE.count();
    let mut text = String::with_capacity(alphabet * alphabet * 2);
    for first in PRINTABLE {
        for second in PRINTABLE {
            text.push(char::from(first));
            text.push(char::from(second));
        }
    }

    // Every character is one byte and one UTF-16 unit, so the three sequences below index alike.
    let mut utf16: Vec<u16> = text.bytes().map(u16::from).collect();
    let Ok(count) = CFIndex::try_from(utf16.len()) else {
        return true;
    };
    let mut cmap = vec![CGGlyph::MIN; utf16.len()];
    let (Some(characters), Some(glyphs)) =
        (NonNull::new(utf16.as_mut_ptr()), NonNull::new(cmap.as_mut_ptr()))
    else {
        return true;
    };
    // SAFETY: framework rule. `CTFontGetGlyphsForCharacters` is GET-rule — it owns nothing and
    // answers a bool. Both pointers address `Vec`s this function owns, each of length `count` and
    // neither touched again until the call returns. This is the caller-owned-slot shape `docs/57`
    // §2 blesses; the function does not keep either pointer.
    #[expect(
        unsafe_code,
        reason = "a Get-rule call writing through two slots this fn owns"
    )]
    let mapped = unsafe { font.glyphs_for_characters(characters, glyphs, count) };
    if !mapped {
        return true;
    }

    let mut shaped = Vec::with_capacity(PROBE_CHUNK);
    let mut start = 0_usize;
    while start < text.len() {
        let end = text.len().min(start + PROBE_CHUNK);
        let (Some(chunk), Some(expected)) = (text.get(start..end), cmap.get(start..end)) else {
            return true;
        };
        let Some(line) = line_for(font, chunk) else {
            return true;
        };
        if !line_glyphs(&line, &mut shaped) || shaped != expected {
            return true;
        }
        // One character of overlap, so the pair that straddles two chunks is still shaped by one of
        // them. Without it a face could hide a ligature in the seam of every chunk but the first.
        start = end.saturating_sub(1).max(start.saturating_add(1));
    }
    false
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

    use slopdesk_terminal::config::FontSpec;
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

    /// The probe's negative half, on the family this crate is measured against: `Menlo` puts
    /// nothing between its `cmap` and its ASCII, so the fast path is legal and the guard says so.
    #[test]
    fn a_grid_family_takes_the_fast_path() {
        let stack = FontStack::new(&spec_of(MONO, 13.0, 1.0), 2.0).unwrap();
        let mut shaper = stack.shaper();
        let style = shaper.style_of(&run("!=", 2));
        assert!(style.ascii_is_literal);

        let mut out = Vec::new();
        assert!(shaper.shape_monospace(&run("!=", 2), style, &mut out));
        assert_eq!(out.len(), 2, "two characters, two cells, two glyphs");
    }

    /// The probe's positive half, without a vendored fixture. No ligature family is on a stock
    /// system, but `Helvetica` is, and it fuses `f`+`i` under the default `liga` — which is the
    /// same `GSUB` substitution a programming family performs on `!=`, so it exercises the same
    /// two decisions: the fast path declines, and the ligature arrives as ONE glyph on the FIRST
    /// of the two cells.
    #[test]
    fn a_ligating_family_routes_its_ascii_through_core_text() {
        let stack = FontStack::new(&spec_of("Helvetica", 13.0, 1.0), 2.0).unwrap();
        let mut shaper = stack.shaper();
        let style = shaper.style_of(&run("fi", 2));
        assert!(!style.ascii_is_literal, "Helvetica substitutes over ASCII");

        let mut declined = Vec::new();
        assert!(
            !shaper.shape_monospace(&run("fi", 2), style, &mut declined),
            "and the fast path knows it"
        );
        assert!(declined.is_empty());

        let mut out = Vec::new();
        shaper.shape(&run("fi", 2), &mut out);
        assert_eq!(out.len(), 1, "one ligature, not two letters");
        let glyph = out.first().unwrap();
        assert_eq!(glyph.cell, 0, "on the first cell it covers");
        assert!((f64::from(glyph.x) - 0.0).abs() < 1e-3, "at that cell's origin");

        // A pair the family does NOT fuse still shapes one glyph per cell down the same path, so
        // the routing costs nothing but time.
        out.clear();
        shaper.shape(&run("xy", 2), &mut out);
        assert_eq!(out.len(), 2);
        assert_eq!(out.last().unwrap().cell, 1);
    }

    /// The probe reads the CONFIGURED face, not the raw one — so a user who turns ligatures off in
    /// `terminal.font-feature` gets the fast path back, on the very same family that lost it. This
    /// is the reason no feature name is parsed anywhere: the setting is honoured by being measured.
    #[test]
    fn turning_ligatures_off_hands_the_fast_path_back() {
        let mut spec = spec_of("Helvetica", 13.0, 1.0);
        spec.features = FontSpec::features_of(&["-liga, -calt, -dlig".to_owned()]);
        let stack = FontStack::new(&spec, 2.0).unwrap();
        let mut shaper = stack.shaper();
        let style = shaper.style_of(&run("fi", 2));
        assert!(style.ascii_is_literal, "no substitution is left to miss");

        let mut out = Vec::new();
        shaper.shape(&run("fi", 2), &mut out);
        assert_eq!(out.len(), 2, "two letters again");
        assert_eq!(out.last().unwrap().cell, 1);
    }

    /// The fast path is an OPTIMISATION, not a second implementation: it has to answer the glyph
    /// ids Core Text would have. If these ever diverge, the atlas holds two entries for one
    /// character and only one of them is right. The probe is what makes this test's premise true
    /// rather than hoped for — it is only asserted of a face the probe called literal.
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
