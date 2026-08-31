//! One family, one size, resolved: the faces, the fallback chain and everything measured against
//! them.
//!
//! ## Why the stack is the unit rather than the face
//!
//! A terminal never draws with one face. Bold and italic are separate cuts when the family has
//! them and a stroke or a shear when it does not, and the moment a cell holds a character the
//! family cannot map, Core Text substitutes a face nobody asked for. [`GlyphKey::font`] is a `u16`
//! that says only "which face", so *something* has to be the list those indices point into, and
//! the shaper that discovers a substitution and the rasteriser that has to draw it must be looking
//! at the same list. That is this type: the shaper and the rasteriser it hands out share one
//! growable `Vec<Face>`, and index 0 is always the family the user asked for.
//!
//! ## The cascade list is Core Text's, and stays there
//!
//! `CTFontCopyDefaultCascadeListForLanguages` answers ~40 descriptors on a stock macOS, and
//! resolving them into fonts up front would cost a face nobody will draw with for every language
//! nobody is typing. Core Text already walks that list inside `CTLine`, so the fallback chain here
//! is the RESULT of that walk — appended as substitutions are seen, deduplicated by `CFEqual`, and
//! never longer than the faces a session actually touched. A second copy of the cascade would
//! answer a slightly different question and look like the same one, which is the argument the
//! crate's own header already makes about font enumeration.
//!
//! ## Device pixels, decided once
//!
//! The renderer's units are device pixels and its header says the contents scale is applied once,
//! by the view. This is the other end of that: a stack takes a point size and a scale, multiplies
//! and rounds them ONCE, and every metric below — and every [`GlyphKey::size_px`] the shaper
//! stamps — is that one number. A stack is therefore per-scale: moving a window to a 1× display
//! builds a new one rather than re-deriving anything.

use core::ptr;
use std::cell::RefCell;
use std::rc::Rc;

use objc2_core_foundation::{CFRetained, CFString};
use objc2_core_graphics::CGGlyph;
use objc2_core_text::{CTFont, CTFontOrientation, CTFontSymbolicTraits};
use slopdesk_termrender::glyph::Synthetic;
use slopdesk_termrender::layout::FontMetrics;

use crate::raster::Rasterizer;
use crate::shape::Shaper;

/// The widest bitmap edge a single glyph is allowed to want, in device pixels.
///
/// Not a texture limit — the atlas has its own — but a guard on arithmetic that starts in a font's
/// own tables. A damaged face can report a bounding box in the millions, and the first thing that
/// would happen is a multi-gigabyte `Vec`.
pub(crate) const MAX_GLYPH_EDGE: u32 = 4096;

/// One resolved face, with the one thing about it the rasteriser must know before it can pick a
/// bitmap format.
#[derive(Debug)]
pub(crate) struct Face {
    /// The face itself, already at the stack's size.
    pub(crate) font: CFRetained<CTFont>,
    /// Whether its glyphs carry their own colour, so a coverage bitmap would lose them.
    pub(crate) color: bool,
}

impl Face {
    /// Resolves the one trait the rasteriser branches on.
    ///
    /// Colour is read from the FACE (`kCTFontTraitColorGlyphs`), not from the glyph. The per-glyph
    /// answer would mean parsing `sbix`/`COLR`/`CBDT` by hand, because no Core Text call exposes
    /// "is glyph N coloured", and the trait is what Core Text itself branches on when it decides
    /// whether to draw through the colour path. The error it can make is one-directional and worth
    /// naming: a face where only SOME glyphs are coloured is over-reported, which costs four bytes
    /// per texel instead of one and draws the right pixels. Under-reporting would draw the wrong
    /// ones, and the trait cannot do that — a face with no colour table does not carry the bit.
    pub(crate) fn new(font: CFRetained<CTFont>) -> Self {
        // SAFETY: framework rule. The Core Foundation GET rule — `CTFontGetSymbolicTraits` reads a
        // bitfield out of a live font and returns it by value. Nothing is created, nothing is
        // copied, and there is nothing for this caller to release; `unsafe` here is only `objc2`
        // declining to certify an `extern` it did not write.
        #[expect(
            unsafe_code,
            reason = "a Get-rule scalar read; nothing is owned and nothing escapes"
        )]
        let traits = unsafe { font.symbolic_traits() };
        Self {
            color: traits.contains(CTFontSymbolicTraits::TraitColorGlyphs),
            font,
        }
    }
}

/// The fallback chain, shared by the shaper that grows it and the rasteriser that reads it.
///
/// `Rc<RefCell<…>>` rather than an `Arc` or a lock because a font stack belongs to one surface on
/// one thread: Core Text objects are not documented as safe to hand between threads, the renderer
/// runs on the display link's callback, and an atomic here would only buy the right to do something
/// this crate has no reason to do.
pub(crate) type Faces = Rc<RefCell<Vec<Face>>>;

/// Which face a run's bold/italic pair lands on, and what is left for the rasteriser to fake.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Style {
    /// Index into [`Faces`].
    pub(crate) face: u16,
    /// Empty when the family had a real cut; the rasteriser strokes or shears only what is set.
    pub(crate) synthetic: Synthetic,
}

impl Style {
    /// The family as asked for, drawn as it is.
    pub(crate) const PRIMARY: Self = Self {
        face: 0,
        synthetic: Synthetic {
            bold: false,
            italic: false,
        },
    };
}

/// A family resolved at a size, and everything the renderer measures against it.
#[derive(Debug)]
pub struct FontStack {
    faces: Faces,
    styles: [Style; 4],
    metrics: FontMetrics,
    cell_width: f64,
    cell_height: f64,
    size_px: u16,
}

impl FontStack {
    /// Resolves `family` at `point_size` on a display of `contents_scale`, in cells `line_height`
    /// times the face's natural height.
    ///
    /// `None` for a size that is not a sane number of device pixels — a NaN scale, a zero point
    /// size, a value that would not survive the rounding — because every metric below is derived
    /// from it and a stack that answered a NaN baseline would put every glyph in the grid
    /// somewhere unpredictable rather than failing where the mistake was made.
    ///
    /// An UNKNOWN family is not a failure: `CTFontCreateWithName` never returns NULL, it returns
    /// Helvetica. That is deliberate here too — a typo in `config.toml` gets a legible terminal in
    /// the wrong face, and `slopdesk font list` is how the user finds out what to type instead.
    #[must_use]
    pub fn new(family: &str, point_size: f64, contents_scale: f64, line_height: f64) -> Option<Self> {
        let size_px = round_u16(point_size * contents_scale)?;
        if size_px == 0 {
            return None;
        }
        let size = f64::from(size_px);

        let name = CFString::from_str(family);
        // SAFETY: framework rule. The Core Foundation CREATE rule — `CTFontCreateWithName` answers
        // a reference this caller owns, which `objc2` wraps in a `CFRetained` that releases it. The
        // matrix argument is documented as optional, and a null one selects the identity matrix,
        // which is what a renderer that does its own transforms wants.
        #[expect(
            unsafe_code,
            reason = "a Create-rule return, and a null matrix meaning identity"
        )]
        let primary = unsafe { CTFont::with_name(&name, size, ptr::null()) };

        let (metrics, cell_height) = measure(&primary, size, line_height);
        let cell_width = advance(&primary)?;

        let bold = cut(&primary, size, CTFontSymbolicTraits::TraitBold);
        let italic = cut(&primary, size, CTFontSymbolicTraits::TraitItalic);
        let bold_italic = cut(
            &primary,
            size,
            CTFontSymbolicTraits::TraitBold | CTFontSymbolicTraits::TraitItalic,
        );

        let mut faces = vec![Face::new(primary)];
        let mut styles = [Style::PRIMARY; 4];
        for (slot, resolved, faked) in [
            (1_usize, bold, Synthetic {
                bold: true,
                italic: false,
            }),
            (2, italic, Synthetic {
                bold: false,
                italic: true,
            }),
            (3, bold_italic, Synthetic {
                bold: true,
                italic: true,
            }),
        ] {
            let Some(style) = styles.get_mut(slot) else {
                continue;
            };
            let Some(font) = resolved else {
                *style = Style {
                    face: 0,
                    synthetic: faked,
                };
                continue;
            };
            let Ok(index) = u16::try_from(faces.len()) else {
                continue;
            };
            faces.push(Face::new(font));
            *style = Style {
                face: index,
                synthetic: Synthetic {
                    bold: false,
                    italic: false,
                },
            };
        }

        Some(Self {
            faces: Rc::new(RefCell::new(faces)),
            styles,
            metrics,
            cell_width,
            cell_height,
            size_px,
        })
    }

    /// What the family says about drawing inside a cell, in device pixels.
    #[must_use]
    pub const fn metrics(&self) -> FontMetrics {
        self.metrics
    }

    /// The advance one cell occupies. A fullwidth glyph occupies two of these, not one wide cell.
    #[must_use]
    pub const fn cell_width(&self) -> f64 {
        self.cell_width
    }

    /// The height of one line of the grid.
    #[must_use]
    pub const fn cell_height(&self) -> f64 {
        self.cell_height
    }

    /// The size every face here was built at, and every [`GlyphKey`] the shaper stamps.
    ///
    /// [`GlyphKey`]: slopdesk_termrender::glyph::GlyphKey
    #[must_use]
    pub const fn size_px(&self) -> u16 {
        self.size_px
    }

    /// How many faces the chain holds — the family's own cuts, plus every substitution seen so far.
    ///
    /// Grows as text arrives, which is the point: a session that never types Japanese never
    /// resolves a Japanese face.
    #[must_use]
    pub fn face_count(&self) -> usize {
        self.faces.borrow().len()
    }

    /// A shaper over this stack's faces, which may grow the chain.
    #[must_use]
    pub fn shaper(&self) -> Shaper {
        Shaper::new(Rc::clone(&self.faces), self.styles, self.cell_width, self.size_px)
    }

    /// A rasteriser over this stack's faces.
    ///
    /// Separate from the shaper because `Painter::paint` takes both by `&mut`, so one object
    /// implementing both traits could not be passed to it. They share the chain, so a face the
    /// shaper discovers is one the rasteriser can already draw.
    #[must_use]
    pub fn rasterizer(&self) -> Rasterizer {
        Rasterizer::new(Rc::clone(&self.faces), self.size_px)
    }
}

/// The face in the same family carrying `wanted`, or `None` when the family has no such cut.
///
/// `None` is the whole reason [`Synthetic`] exists: a family with a real bold is drawn with it, and
/// only a family without one is stroked. Core Text will answer a face for a family it merely
/// approves of, so the traits are read back off the answer — a "bold" that does not carry the bold
/// bit is the same "no such cut" the NULL was supposed to mean, and believing it would ship a
/// regular face labelled bold that nothing downstream could tell apart.
fn cut(primary: &CTFont, size: f64, wanted: CTFontSymbolicTraits) -> Option<CFRetained<CTFont>> {
    // SAFETY: framework rule. The Core Foundation COPY rule — `CTFontCreateCopyWithSymbolicTraits`
    // answers a reference this caller owns, or NULL when the family holds no face with those
    // traits, which `objc2` maps to `None`. The matrix is null, documented as "preserve the
    // original font matrix".
    #[expect(
        unsafe_code,
        reason = "a Copy-rule return; objc2 cannot know the caller owns it"
    )]
    let copy = unsafe { primary.copy_with_symbolic_traits(size, ptr::null(), wanted, wanted) }?;
    // SAFETY: framework rule. The GET rule again — a bitfield read out of a live font, by value.
    #[expect(
        unsafe_code,
        reason = "a Get-rule scalar read; nothing is owned and nothing escapes"
    )]
    let got = unsafe { copy.symbolic_traits() };
    got.contains(wanted).then_some(copy)
}

/// What the face says about drawing inside a cell, plus the cell height it implies.
///
/// Every offset comes back measured DOWN from the cell's top edge, which is the one conversion
/// [`FontMetrics`]'s own header asks for: "Core Text reports underline position as a negative
/// offset from the baseline; converting once, at the boundary, is why nothing below has to remember
/// a sign convention." This is that boundary.
///
/// `line_height` is `terminal.line-height` as a MULTIPLIER of the face's natural cell — `1.0`
/// leaves every number below exactly where the face put it. A taller cell centres the glyph in the
/// space it gained rather than pinning it to the top: half the gain above the baseline and half
/// below is what "looser line spacing" means to a reader, and pinning would read as a paragraph
/// that drifted upwards. Every offset the font reported moves with the baseline, so an underline
/// stays the same distance under its own glyph at any multiplier.
fn measure(font: &CTFont, size: f64, line_height: f64) -> (FontMetrics, f64) {
    // SAFETY: framework rule. The Core Foundation GET rule, six times — each of these reads a
    // scalar out of a live font's own tables and returns it by value. Nothing is created, nothing
    // is retained, and there is nothing for this caller to release. They are grouped because they
    // are one obligation, not six.
    #[expect(
        unsafe_code,
        reason = "Get-rule scalar reads; nothing is owned and nothing escapes"
    )]
    let (ascent, descent, leading, underline_position, underline_thickness, x_height) = unsafe {
        (
            font.ascent(),
            font.descent(),
            font.leading(),
            font.underline_position(),
            font.underline_thickness(),
            font.x_height(),
        )
    };

    // Sanitised BEFORE anything compares them, and this is the only place that has to know why. A
    // damaged or synthesised face can report a NaN metric, and every clamp below is `f64::max` /
    // `f64::min`, which — unlike a `<` ternary — quietly answers the OTHER operand when one side is
    // NaN. A NaN reaching a clamp would therefore not fail loudly; it would place the underline
    // somewhere plausible and wrong, and stay there.
    let ascent = f64::max(finite(ascent, size * 0.8), 0.0);
    let descent = f64::max(finite(descent, size * 0.2), 0.0);
    let leading = f64::max(finite(leading, 0.0), 0.0);

    let natural_height = f64::max((leading + ascent + descent).ceil(), 1.0);
    // The multiplier is sanitised for the face metrics' own reason: a NaN reaching the `f64::max`
    // below would be answered by the OTHER operand and produce a plausible-looking grid at a height
    // nobody asked for. Repaired to the NATURAL cell rather than floored at some minimum — the
    // config table already bounds a real setting to [0.5, 3.0], so anything arriving outside that
    // is a caller's mistake and "the height the face itself asked for" is the honest answer to
    // it. The test is a VALIDITY guard against a constant, which is what `finite` already is;
    // it is not a `<` ternary picking between two live values, which is what this crate's float
    // rule bans.
    let line_height = if line_height.is_finite() && line_height > 0.0 {
        line_height
    } else {
        1.0
    };
    let cell_height = f64::max((natural_height * line_height).ceil(), 1.0);
    // Half the gain, above and below. Negative when the multiplier tightened the cell, which is the
    // same arithmetic reading the other way — the glyph rides up into the space that was removed.
    let lift = (cell_height - natural_height) * 0.5;
    let baseline = f64::min(f64::max((leading + ascent).ceil() + lift, 0.0), cell_height);

    // Never thinner than a device pixel: the renderer's own field doc says so, and a sub-pixel rect
    // on an unfiltered atlas draws as nothing at all rather than as something faint.
    let thickness = f64::max(finite(underline_thickness, 0.0).round(), 1.0);
    // Core Text's underline position is negative below the baseline; the fallback is one thickness
    // below, which is where a face that reports nothing should still put it.
    let underline_top = baseline - finite(underline_position, -thickness);
    let underline_position = clamp_into_cell(underline_top, thickness, cell_height);

    // No face in the tree carries a strikethrough metric, so it is placed rather than read: the
    // line's CENTRE at half the x-height above the baseline, which is where a strikethrough crosses
    // lower-case letters through their middle instead of clipping their descenders.
    let x_height = f64::max(finite(x_height, ascent * 0.5), 0.0);
    let strikethrough_top = baseline - x_height * 0.5 - thickness * 0.5;
    let strikethrough_position = clamp_into_cell(strikethrough_top, thickness, cell_height);

    (
        FontMetrics {
            baseline,
            underline_position,
            underline_thickness: thickness,
            strikethrough_position,
            strikethrough_thickness: thickness,
            // A cursor is a UI affordance rather than typography, which is why the renderer keeps
            // the field separate: one device pixel heavier than the font's own underline, and never
            // thinner than two, so a bar caret stays visible in a face whose underline is a
            // hairline.
            cursor_thickness: f64::max(thickness + 1.0, 2.0),
        },
        cell_height,
    )
}

/// The advance one cell occupies, or `None` when the face cannot map the character it is measured
/// from.
///
/// Measured off `M`. In a monospace face every ASCII advance is the same number, so the choice
/// would be arbitrary — except that `M` is also the widest ASCII glyph in a PROPORTIONAL one, so a
/// family configured by mistake gets a grid that is too loose rather than one that clips.
///
/// Rounded UP for the same reason: a cell narrower than the face's own advance clips every glyph in
/// the grid at once, and nothing further down the pipeline gets a second chance at it.
fn advance(font: &CTFont) -> Option<f64> {
    let mut characters = [u16::from(b'M')];
    let mut glyphs = [CGGlyph::MIN];
    // SAFETY: framework rule. Neither call owns anything: `CTFontGetGlyphsForCharacters` and
    // `CTFontGetAdvancesForGlyphs` are both GET-rule, and both write through slots the CALLER
    // allocated — the two one-element arrays above, with a count of 1 passed to match. That is the
    // shape `docs/57` §2 blesses through `AXValueGetValue`; neither function keeps the pointer past
    // its return. The advances out-parameter is null, which the header documents as "can be NULL"
    // when only the summed advance is wanted.
    #[expect(
        unsafe_code,
        reason = "Get-rule calls writing through one-element slots this fn owns"
    )]
    let width = unsafe {
        if !font.glyphs_for_characters(
            ptr::NonNull::from(&mut characters).cast(),
            ptr::NonNull::from(&mut glyphs).cast(),
            1,
        ) {
            return None;
        }
        font.advances_for_glyphs(
            CTFontOrientation::Horizontal,
            ptr::NonNull::from(&mut glyphs).cast(),
            ptr::null_mut(),
            1,
        )
    };
    Some(f64::max(finite(width, 0.0).ceil(), 1.0))
}

/// A decoration's top edge, kept inside the cell it decorates.
fn clamp_into_cell(top: f64, thickness: f64, cell_height: f64) -> f64 {
    f64::max(f64::min(top.round(), cell_height - thickness), 0.0)
}

/// `value` when it is a real number, `fallback` when a font's tables answered a NaN or an infinity.
pub(crate) const fn finite(value: f64, fallback: f64) -> f64 {
    if value.is_finite() { value } else { fallback }
}

/// A pixel count, rounded once and refused when it is not one.
pub(crate) fn round_u16(value: f64) -> Option<u16> {
    let rounded = value.round();
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the range check above is exactly the one the cast would otherwise be trusted for"
    )]
    (0.0..=f64::from(u16::MAX))
        .contains(&rounded)
        .then_some(rounded as u16)
}

/// A device-pixel offset, narrowed to what [`ShapedGlyph`] and [`RasterGlyph`] carry.
///
/// [`ShapedGlyph`]: slopdesk_termrender::glyph::ShapedGlyph
/// [`RasterGlyph`]: slopdesk_termrender::glyph::RasterGlyph
pub(crate) const fn narrow(value: f64) -> f32 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "device-pixel offsets are small integers; f32 is the renderer's own width here"
    )]
    let narrowed = value as f32;
    narrowed
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::FontStack;

    /// A face every macOS carries, so these run on any machine that can build this crate.
    const MONO: &str = "Menlo";

    /// The grid a real family implies has to be one a glyph fits inside. Every relationship here is
    /// one a renderer would otherwise discover as a clipped descender or an underline outside the
    /// cell it belongs to.
    #[test]
    fn a_real_family_measures_a_grid_that_could_hold_it() {
        let stack = FontStack::new(MONO, 13.0, 2.0, 1.0).unwrap();
        let metrics = stack.metrics();

        assert_eq!(
            stack.size_px(),
            26,
            "13 points at 2x is 26 device pixels, rounded once"
        );
        assert!(stack.cell_width() >= 1.0);
        assert!(stack.cell_height() >= f64::from(stack.size_px()));
        assert!(metrics.baseline > 0.0 && metrics.baseline <= stack.cell_height());

        for (position, thickness) in [
            (metrics.underline_position, metrics.underline_thickness),
            (metrics.strikethrough_position, metrics.strikethrough_thickness),
        ] {
            assert!(position >= 0.0, "a decoration never starts above the cell");
            assert!(position + thickness <= stack.cell_height(), "nor ends below it");
            assert!(thickness >= 1.0, "nor draws thinner than a device pixel");
        }
        assert!(metrics.cursor_thickness >= 2.0);
        // The underline is BELOW the baseline once the sign has been flipped, which is the one
        // conversion this crate owes `FontMetrics`.
        assert!(metrics.underline_position >= metrics.baseline);
        // The strikethrough is above it.
        assert!(metrics.strikethrough_position < metrics.baseline);
    }

    /// The family resolves four ways, and the chain starts as short as the family allows.
    #[test]
    fn the_four_cuts_resolve_before_any_text_arrives() {
        let stack = FontStack::new(MONO, 13.0, 2.0, 1.0).unwrap();
        // Menlo ships Regular, Bold, Italic and Bold Italic, so all four are real faces and none is
        // synthesised. A family with fewer would resolve fewer, which is what `Synthetic` covers.
        assert_eq!(stack.face_count(), 4);
    }

    /// A size that is not a number of pixels is refused where the mistake was made, rather than
    /// propagated into every metric below it.
    #[test]
    fn a_size_that_is_not_a_number_of_pixels_is_refused() {
        assert!(FontStack::new(MONO, f64::NAN, 2.0, 1.0).is_none());
        assert!(FontStack::new(MONO, 13.0, f64::NAN, 1.0).is_none());
        assert!(FontStack::new(MONO, 13.0, f64::INFINITY, 1.0).is_none());
        assert!(FontStack::new(MONO, 0.0, 2.0, 1.0).is_none());
        assert!(FontStack::new(MONO, -13.0, 2.0, 1.0).is_none());
        assert!(FontStack::new(MONO, 1e9, 2.0, 1.0).is_none());
    }

    /// An unknown family is Helvetica, not a failure — a typo in `config.toml` gets a legible
    /// terminal in the wrong face rather than a blank one.
    #[test]
    fn a_family_the_system_does_not_have_still_answers_a_stack() {
        let stack = FontStack::new("No Such Family At All", 13.0, 2.0, 1.0).unwrap();
        assert!(stack.cell_width() >= 1.0);
    }

    /// `terminal.line-height` makes the CELL taller and centres the glyph in what it gained — the
    /// half above the baseline is what stops a loose grid from reading as text that drifted to the
    /// top of every row. The decorations ride the baseline, so an underline stays the same distance
    /// under its own glyph at any multiplier.
    #[test]
    #[expect(
        clippy::float_cmp,
        reason = "bit-equality is the CLAIM: both sides are the same derived number, and a tolerance would \
                  pass a multiplier that had leaked into the width"
    )]
    fn a_multiplier_stretches_the_cell_and_centres_the_glyph_in_it() {
        let natural = FontStack::new(MONO, 13.0, 2.0, 1.0).unwrap();
        let loose = FontStack::new(MONO, 13.0, 2.0, 1.5).unwrap();

        assert!(loose.cell_height() > natural.cell_height());
        assert_eq!(
            loose.cell_width(),
            natural.cell_width(),
            "line height is a VERTICAL setting; a stretched row would be a different font"
        );

        let lift = (loose.cell_height() - natural.cell_height()) * 0.5;
        let drift = loose.metrics().baseline - natural.metrics().baseline - lift;
        assert!(
            f64::abs(drift) <= 1.0,
            "the glyph sits half the gain lower, within the rounding the ceil() costs"
        );
        let under = loose.metrics().underline_position - loose.metrics().baseline;
        let natural_under = natural.metrics().underline_position - natural.metrics().baseline;
        assert_eq!(
            under, natural_under,
            "the underline is the face's distance under the baseline, not the cell's"
        );
        assert!(
            loose.metrics().underline_position + loose.metrics().underline_thickness <= loose.cell_height()
        );
    }

    /// A multiplier out of `config.toml` is repaired where the mistake was made, exactly like the
    /// face's own metrics — a NaN reaching the `f64::max` below would be answered by the OTHER
    /// operand and produce a plausible grid at a height nobody asked for.
    #[test]
    #[expect(
        clippy::float_cmp,
        reason = "bit-equality is the CLAIM: a repaired multiplier answers the SAME cell the face measured, \
                  not one within a tolerance of it"
    )]
    fn a_multiplier_that_is_not_a_number_leaves_the_natural_cell() {
        let natural = FontStack::new(MONO, 13.0, 2.0, 1.0).unwrap();
        for broken in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0, 0.0] {
            let stack = FontStack::new(MONO, 13.0, 2.0, broken).unwrap();
            assert_eq!(
                stack.cell_height(),
                natural.cell_height(),
                "a multiplier outside the config's own [0.5, 3.0] answers the face's own cell",
            );
        }
    }

    /// The leak test this family owes: a thousand stacks, each taking and dropping four faces and a
    /// handful of descriptors, so a missing release shows up as growth rather than as a comment
    /// nobody checked.
    #[test]
    fn a_thousand_stacks_hold_nothing() {
        for _ in 0..1000 {
            assert!(FontStack::new(MONO, 13.0, 2.0, 1.0).is_some());
        }
    }
}
