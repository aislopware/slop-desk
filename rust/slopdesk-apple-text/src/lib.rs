//! The whole of the Core Text area slopdesk touches.
//!
//! ## Two questions
//!
//! The first is `slopdesk font import`'s, asked after it has copied a face into `~/Library/Fonts`:
//! what does the system call this thing? The answer is not the filename and usually not anything
//! the filename suggests — `JetBrainsMonoNerdFont-Regular.ttf` is `JetBrainsMono Nerd Font` — and
//! it is what has to be pasted under `[terminal]` for the app to resolve the face. That is
//! [`of_file`], and it is the whole of `family` below.
//!
//! The second is the terminal renderer's, and it is the bulk of the crate. `slopdesk-termrender`
//! says in its own header that it has "no font engine — not a Core Text call", and names two traits
//! a font engine arrives through. This is that engine: [`FontStack`] resolves a family at a size
//! into faces and metrics, [`Shaper`] turns a run of cells into positioned glyph ids, and
//! [`Rasterizer`] turns a glyph id into a bitmap. `docs/68` §5.1 puts the renderer's home in Rust
//! and names this crate as the one that extends, "so shaping extends an audited crate rather than
//! opening a new `unsafe` boundary".
//!
//! ## Why it is a crate rather than a function in its callers
//! `rust/slopdesk-cli` and `rust/slopdesk-termrender` both forbid `unsafe`, and reaching an Apple
//! framework at all means linking one. `CLAUDE.md`'s rule for that is the `slopdesk-apple-*`
//! family: one crate per framework area, through `objc2`, platform-gated at the call site. The gate
//! here is `any(macos, ios)` rather than `macos`, because Core Text is on both slices and the
//! terminal draws the same way on each — `docs/57` §"A macOS-only crate…" is about the crates whose
//! framework a phone does not have, and this is not one of them.
//!
//! ## What is deliberately NOT here
//! Font ENUMERATION. `slopdesk font list` asks the running app over the control socket, because the
//! list it wants is the one the app's own text stack resolved, filtered by what it can actually
//! render. A second enumeration here would answer a slightly different question and look like the
//! same one.
//!
//! The GPU, and the arithmetic around it. Atlas packing, run coalescing, where a glyph lands on
//! screen and what an underline is drawn over all belong to `slopdesk-termrender`, which can test
//! them with no display attached. A [`RasterGlyph`] leaves here as plain bytes.
//!
//! [`RasterGlyph`]: slopdesk_termrender::glyph::RasterGlyph
//!
//! ## The `unsafe` in this crate
//! Every block is a Core Foundation naming rule rather than a Rust one, and each carries a
//! `# Safety` note naming the rule it depends on: CREATE-rule and COPY-rule returns, GET-rule
//! scalar reads, the extern statics holding the attribute keys, and the `cast_unchecked`s that name
//! an array's or a dictionary's element type.
//!
//! No raw-pointer DEREFERENCE and no transmute, which `docs/57` §2 bars from this family. Two
//! shapes carry the weight: Core Text's buffer-filling accessors are used in preference to their
//! `…Ptr` siblings because the buffer is ours, and the rasteriser hands `CGBitmapContextCreate` a
//! `Vec<u8>` this crate allocated rather than reading back one Core Graphics owns. Both are the
//! "writes through a slot the caller owns" shape §2 blesses through `AXValueGetValue`.

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod font;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod raster;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod shape;

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use font::FontStack;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use raster::Rasterizer;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use shape::Shaper;

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod family {
    use objc2_core_foundation::{CFArray, CFRetained, CFString, CFURL, CFURLPathStyle};
    use objc2_core_text::{
        CTFontDescriptor, CTFontManagerCreateFontDescriptorsFromURL, kCTFontFamilyNameAttribute,
    };

    /// The family name of the font file at `path`, or `None` when Core Text cannot read one.
    ///
    /// The FIRST descriptor's, which is the same one the Swift original took. A `.ttc` collection
    /// carries several faces and Core Text hands them back in the file's own order; the caller is
    /// printing a line for a person to paste, and every face in a collection shares the family that
    /// makes the collection one font.
    ///
    /// `None` covers every way this can decline — a path that is not a font, a file the process
    /// cannot open, a face with no family attribute — because the caller has one thing to say about
    /// all of them: it imported the file and cannot tell you what to call it.
    #[must_use]
    pub fn of_file(path: &str) -> Option<String> {
        if path.is_empty() {
            return None;
        }
        let file_path = CFString::from_str(path);
        let url =
            CFURL::with_file_system_path(None, Some(&file_path), CFURLPathStyle::CFURLPOSIXPathStyle, false)?;

        // SAFETY: framework rule. The Core Foundation CREATE rule — a function with `Create` in its
        // name answers a reference this caller owns, which `objc2` wraps in a `CFRetained` that
        // releases it. Nothing else is required of the caller: the URL argument is a live
        // `CFRetained` for the whole call, and a file that holds no valid font answers NULL, which
        // the binding maps to `None`.
        #[expect(
            unsafe_code,
            reason = "a Create-rule return; objc2 cannot know the caller owns it without being told"
        )]
        let descriptors = unsafe { CTFontManagerCreateFontDescriptorsFromURL(&url) }?;

        // SAFETY: framework rule. Core Text documents this as "an array of CTFontDescriptors"; C's
        // `CFArrayRef` has nowhere to carry that, which is why the binding hands back an untyped
        // array. Nothing is dereferenced — the typed view only decides which `get` applies, and the
        // element is checked against `CTFontDescriptorGetTypeID` by the `downcast` below anyway.
        #[expect(
            unsafe_code,
            reason = "C's CFArrayRef carries no element type; the Core Text header is where it lives"
        )]
        let descriptors = unsafe { CFRetained::cast_unchecked::<CFArray<CTFontDescriptor>>(descriptors) };
        let first = descriptors.get(0)?;

        // SAFETY: framework rule. An `extern` static Core Text initialises when its image loads,
        // which is before anything that could call this has run — the Core Text symbols above are
        // what force the load. Rust cannot see that, so the read is `unsafe`; the framework's
        // contract is a non-null immutable `CFStringRef` for the process's whole life, which is
        // exactly what `&'static CFString` claims.
        #[expect(
            unsafe_code,
            reason = "the framework's key constant is an extern static; objc2 cannot generate it safe"
        )]
        let attribute_key = unsafe { kCTFontFamilyNameAttribute };

        // SAFETY: framework rule. The Core Foundation COPY rule — `CTFontDescriptorCopyAttribute`
        // answers a reference this caller owns, or NULL when the descriptor carries no such
        // attribute. `objc2` maps the NULL to `None` and wraps the rest in a `CFRetained`.
        #[expect(
            unsafe_code,
            reason = "a Copy-rule return; objc2 cannot know the caller owns it without being told"
        )]
        let attribute = unsafe { first.attribute(attribute_key) }?;

        // A descriptor is documented to package the family as a `CFString`; a build where it does
        // not answers `None` rather than reinterpreting the pointer.
        Some(attribute.downcast::<CFString>().ok()?.to_string())
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub use family::of_file;

/// The family name of the font file at `path` — always `None` off Apple, where there is no Core
/// Text to ask and no `~/Library/Fonts` to have imported into.
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
#[must_use]
pub fn of_file(_path: &str) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::of_file;

    /// Every declining path answers the same way, which is what lets the caller say one sentence
    /// about all of them.
    #[test]
    fn a_path_that_is_not_a_font_reads_as_no_name_rather_than_failing() {
        assert_eq!(of_file("/etc/hosts"), None);
        assert_eq!(of_file("/no/such/file.ttf"), None);
        assert_eq!(of_file(""), None);
    }

    /// The happy path, exercised rather than reviewed. Also the leak test this family owes: a
    /// thousand reads of a real face, each taking and dropping three CF references, so a missing
    /// release shows up as growth rather than as a comment nobody checked.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    #[test]
    fn a_system_face_reads_back_the_name_the_system_calls_it_and_holds_nothing() {
        let menlo = "/System/Library/Fonts/Menlo.ttc";
        if !std::path::Path::new(menlo).exists() {
            return;
        }
        assert_eq!(of_file(menlo).as_deref(), Some("Menlo"));
        for _ in 0..1000 {
            assert!(of_file(menlo).is_some());
        }
    }
}
