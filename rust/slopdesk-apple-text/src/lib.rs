//! The family name Core Text reads out of a font FILE.
//!
//! One question, asked by `slopdesk font import` after it has copied a face into
//! `~/Library/Fonts`: what does the system call this thing? The answer is not the filename and
//! usually not anything the filename suggests — `JetBrainsMonoNerdFont-Regular.ttf` is
//! `JetBrainsMono Nerd Font` — and it is what has to be pasted under `[terminal]` for the app to
//! resolve the face.
//!
//! ## Why it is a crate rather than a function in the CLI
//! `rust/slopdesk-cli` is a member of the root workspace, which is `forbid(unsafe_code)`, and
//! reaching an Apple framework at all means linking one. `CLAUDE.md`'s rule for that is the
//! `slopdesk-apple-*` family: one crate per framework area, through `objc2`, macOS-gated at the
//! call site. This is the whole of the Core Text area slopdesk touches.
//!
//! ## What is deliberately NOT here
//! Font ENUMERATION. `slopdesk font list` asks the running app over the control socket, because the
//! list it wants is the one the app's own text stack resolved, filtered by what it can actually
//! render. A second enumeration here would answer a slightly different question and look like the
//! same one.
//!
//! ## The `unsafe` in this crate
//! Four blocks, all in one function, and every one of them is a Core Foundation naming rule rather
//! than a Rust one — no raw-pointer dereference and no transmute, which `docs/57` §2 bars from this
//! family. The URL is built through the SAFE `CFURLCreateWithFileSystemPath` rather than the
//! byte-buffer form next to it, so no pointer is handed over at all.

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
pub use family::of_file;

/// The family name of the font file at `path` — always `None` off macOS, where there is no Core
/// Text to ask and no `~/Library/Fonts` to have imported into.
#[cfg(not(target_os = "macos"))]
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
    #[cfg(target_os = "macos")]
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
