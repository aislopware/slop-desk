//! The board: its counter, what its owner declared, its bytes, and a write that validates first.

use objc2::AnyThread;
use objc2::rc::Retained;
use objc2_app_kit::{NSBitmapImageFileType, NSBitmapImageRep, NSPasteboard};
use objc2_foundation::{NSData, NSDictionary, NSString};

/// The concealed-clip marker password managers set (the nspasteboard.org convention).
///
/// A string rather than a framework constant because `AppKit` has none: it is a community
/// convention, and the only spelling of it in this repository that a Rust caller can reach.
pub const CONCEALED_TYPE: &str = "org.nspasteboard.ConcealedType";

/// The four board flavours clipboard sync asks about, plus the concealed marker.
///
/// An enum rather than raw UTI strings at the call site so the framework's own constants stay
/// inside this crate — [`Flavour::File`] is `NSPasteboardTypeFileURL` and nothing else, and a
/// caller cannot reach for a fifth type this crate has not thought about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flavour {
    /// Plain UTF-8 text — `NSPasteboardTypeString`.
    Text,
    /// A PNG image — `NSPasteboardTypePNG`.
    Png,
    /// A TIFF image — `NSPasteboardTypeTIFF`, which is what most Mac apps actually declare when
    /// they copy a picture.
    Tiff,
    /// A file reference — `NSPasteboardTypeFileURL`. A path on one machine means nothing on
    /// another, which is why the fold above refuses to ship one.
    File,
    /// The concealed-clip marker — see [`CONCEALED_TYPE`].
    Concealed,
}

impl Flavour {
    /// The raw UTI string `AppKit` names this flavour by.
    ///
    /// The one door onto the framework's own spelling. It exists because the FOLD above this crate
    /// (`slopdesk_hostserver::clipsync`) must build on a machine with no `AppKit` and therefore
    /// types two of these strings itself — and a typed constant that nothing checks against the
    /// framework is exactly the two-implementations drift `docs/55` §6 records. Its suite asks
    /// here.
    #[must_use]
    pub fn uti(self) -> String {
        flavour::named(self).to_string()
    }
}

/// `AppKit`'s own pasteboard-type globals.
///
/// Reading a C global is `unsafe` in Rust 2024 because the compiler cannot see that it was
/// initialised. These four were initialised by dyld before this process ran a line of its own, and
/// they are immutable `NSString`s `AppKit` itself hands to every call below.
#[expect(
    unsafe_code,
    reason = "an `extern` static read is unsafe in Rust 2024; these are AppKit's own immutable globals, \
              live from dyld onwards"
)]
mod flavour {
    use objc2::rc::Retained;
    use objc2_app_kit::{
        NSPasteboardType, NSPasteboardTypeFileURL, NSPasteboardTypePNG, NSPasteboardTypeString,
        NSPasteboardTypeTIFF,
    };
    use objc2_foundation::NSString;

    use super::Flavour;

    /// The `NSString` `AppKit` names this flavour by.
    ///
    /// [`Flavour::Concealed`] has no `AppKit` constant, so it is minted from
    /// [`super::CONCEALED_TYPE`] — which is why this answers an owned `Retained` rather than the
    /// `&'static` the other four could give.
    pub(super) fn named(flavour: Flavour) -> Retained<NSPasteboardType> {
        // SAFETY: each of the four is an `NSString *` constant in AppKit's `__DATA` segment,
        // initialised at load time and never written. The framework's contract is that they are
        // valid for as long as AppKit is loaded, which is the whole life of any process that
        // linked it.
        let borrowed: &NSPasteboardType = match flavour {
            Flavour::Text => unsafe { NSPasteboardTypeString },
            Flavour::Png => unsafe { NSPasteboardTypePNG },
            Flavour::Tiff => unsafe { NSPasteboardTypeTIFF },
            Flavour::File => unsafe { NSPasteboardTypeFileURL },
            Flavour::Concealed => return NSString::from_str(super::CONCEALED_TYPE),
        };
        Retained::from(borrowed)
    }
}

/// One macOS pasteboard.
///
/// Holds a `Retained<NSPasteboard>` — the general board is a process-wide singleton and a unique
/// one lives as long as somebody holds it, so ownership here is what keeps a test's board from
/// being collected between two calls.
#[derive(Debug)]
pub struct Board {
    board: Retained<NSPasteboard>,
}

impl Board {
    /// The machine's general pasteboard — what ⌘C writes to and ⌘V reads from.
    #[must_use]
    pub fn general() -> Self {
        Self {
            board: NSPasteboard::generalPasteboard(),
        }
    }

    /// A private board nobody else names.
    ///
    /// The test idiom, and the reason every assertion in this crate can run on a developer's
    /// machine without eating their clipboard. `ClientPasteboard`'s Swift tests use the same door.
    #[must_use]
    pub fn unique() -> Self {
        Self {
            board: NSPasteboard::pasteboardWithUniqueName(),
        }
    }

    /// The board's change counter, which advances on every write by anybody.
    ///
    /// The whole of a clipboard poll is this one integer. `i64` rather than `NSInteger` because
    /// that is the width the wire carries it in, and the saturation can never be reached — the
    /// counter is a process-lifetime tally, not an address.
    #[must_use]
    pub fn change_count(&self) -> i64 {
        i64::try_from(self.board.changeCount()).unwrap_or(i64::MAX)
    }

    /// Every type the current owner DECLARED, as raw UTI strings.
    ///
    /// A declaration, not a read: this is what the writer said it has, so asking costs no content
    /// and discloses none. Empty for a board nothing has been written to.
    #[must_use]
    pub fn declared(&self) -> Vec<String> {
        self.board
            .types()
            .map_or_else(Vec::new, |types| types.iter().map(|ty| ty.to_string()).collect())
    }

    /// Whether the owner declared `flavour`. See [`Board::declared`] on why this is free.
    #[must_use]
    pub fn declares(&self, flavour: Flavour) -> bool {
        let wanted = flavour::named(flavour);
        self.board
            .types()
            .is_some_and(|types| types.iter().any(|ty| *ty == *wanted))
    }

    /// The board's plain-text flavour, or `None` when it holds something else.
    #[must_use]
    pub fn text(&self) -> Option<String> {
        Some(
            self.board
                .stringForType(&flavour::named(Flavour::Text))?
                .to_string(),
        )
    }

    /// The bytes behind one flavour, or `None` when the board does not have it.
    #[must_use]
    pub fn data(&self, flavour: Flavour) -> Option<Vec<u8>> {
        Some(self.board.dataForType(&flavour::named(flavour))?.to_vec())
    }

    /// The board's image, as PNG: the declared PNG flavour as-is, else its TIFF flavour
    /// transcoded, else `None`.
    ///
    /// The board's own fidelity contract in one call. An app that copies a picture declares
    /// whatever flavours it feels like — most Mac apps declare `public.tiff` and not `public.png` —
    /// and "is there an image here, as PNG" is a question about THIS board, not a preference a
    /// caller composes out of two reads. A caller that genuinely wants one flavour asks
    /// [`Board::data`].
    #[must_use]
    pub fn png(&self) -> Option<Vec<u8>> {
        self.data(Flavour::Png)
            .or_else(|| png_of_tiff(&self.data(Flavour::Tiff)?))
    }

    /// Replaces the board's contents with `text`. `false` — board UNTOUCHED — for empty text.
    ///
    /// Validate-then-clear, which is the whole reason this answers rather than returning `()`:
    /// `clearContents` destroys what a person put on the board, so a clip that will not write must
    /// be refused BEFORE it runs.
    #[must_use]
    pub fn write_text(&self, text: &str) -> bool {
        if text.is_empty() {
            return false;
        }
        let value = NSString::from_str(text);
        self.board.clearContents();
        self.board
            .setString_forType(&value, &flavour::named(Flavour::Text))
    }

    /// Replaces the board's contents with a PNG image. `false` — board UNTOUCHED — for bytes that
    /// will not decode as an image.
    ///
    /// Declares the TIFF flavour alongside the PNG, and that is not decoration: `public.tiff` is
    /// what many Mac apps read, while Claude Code's ⌃V reads the PNG. Declaring both is what makes
    /// ONE write paste everywhere. A TIFF the framework declines to produce is dropped rather than
    /// failing the write — the PNG is already on the board and is the fidelity ceiling.
    #[must_use]
    pub fn write_png(&self, png: &[u8]) -> bool {
        let data = NSData::with_bytes(png);
        let Some(rep) = NSBitmapImageRep::initWithData(NSBitmapImageRep::alloc(), &data) else {
            return false;
        };
        self.board.clearContents();
        let wrote = self
            .board
            .setData_forType(Some(&data), &flavour::named(Flavour::Png));
        if let Some(tiff) = rep.TIFFRepresentation() {
            let _twin = self
                .board
                .setData_forType(Some(&tiff), &flavour::named(Flavour::Tiff));
        }
        wrote
    }
}

/// TIFF bytes as PNG bytes, or `None` when they will not decode or will not re-encode.
///
/// The transcode the read path needs: most Mac apps declare `public.tiff` and not `public.png`, and
/// the wire carries PNG. A free function rather than a [`Board`] method because it is a pure byte
/// conversion — the fold that decides WHETHER to reach for it holds no board at that moment.
#[must_use]
pub fn png_of_tiff(tiff: &[u8]) -> Option<Vec<u8>> {
    let data = NSData::with_bytes(tiff);
    let rep = NSBitmapImageRep::initWithData(NSBitmapImageRep::alloc(), &data)?;
    let empty = NSDictionary::new();

    #[expect(
        unsafe_code,
        reason = "`representationUsingType:properties:` is generated unsafe because its properties \
                  dictionary is untyped in the header"
    )]
    // SAFETY: the framework's obligation is that the dictionary holds the keys this image type
    // understands. An EMPTY dictionary satisfies it vacuously — there is no key present to be of
    // the wrong type — and PNG's properties are all optional with framework defaults.
    let png = unsafe { rep.representationUsingType_properties(NSBitmapImageFileType::PNG, &empty) };
    Some(png?.to_vec())
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]
mod tests {
    use super::{Board, CONCEALED_TYPE, Flavour, png_of_tiff};

    /// A 1×1 opaque red PNG, byte for byte. Small enough to read, real enough to decode.
    const RED_DOT: &[u8] = &[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00,
        0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x03, 0x01,
        0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
        0x82,
    ];

    #[test]
    fn a_written_string_reads_back_and_moves_the_counter() {
        let board = Board::unique();
        let before = board.change_count();
        assert!(board.write_text("hello"), "a non-empty string must write");
        assert_eq!(board.text().as_deref(), Some("hello"));
        assert!(board.change_count() > before, "a write must advance the counter");
    }

    #[test]
    fn an_empty_string_is_refused_with_the_board_untouched() {
        let board = Board::unique();
        assert!(board.write_text("keep me"), "the fixture write must land");
        let after_fixture = board.change_count();

        assert!(!board.write_text(""), "an empty clip is not a clip");
        assert_eq!(
            board.text().as_deref(),
            Some("keep me"),
            "a refused write must not have cleared what was there — this is the whole reason `write_text` \
             answers rather than returning nothing",
        );
        assert_eq!(
            board.change_count(),
            after_fixture,
            "a refused write must not move the counter"
        );
    }

    #[test]
    fn a_png_write_declares_the_tiff_twin_as_well() {
        let board = Board::unique();
        assert!(board.write_png(RED_DOT), "a valid PNG must write");
        assert!(
            board.declares(Flavour::Png),
            "the PNG flavour is the one the wire carries"
        );
        assert!(
            board.declares(Flavour::Tiff),
            "the TIFF twin is what makes one write paste into apps that read `public.tiff`",
        );
        assert_eq!(
            board.data(Flavour::Png).as_deref(),
            Some(RED_DOT),
            "the PNG goes on as-is"
        );
    }

    #[test]
    fn bytes_that_are_not_an_image_are_refused_with_the_board_untouched() {
        let board = Board::unique();
        assert!(board.write_text("keep me"), "the fixture write must land");
        assert!(
            !board.write_png(b"not a png"),
            "undecodable bytes are not an image"
        );
        assert_eq!(
            board.text().as_deref(),
            Some("keep me"),
            "a refused image write must not have cleared the text that was there",
        );
    }

    #[test]
    fn a_tiff_transcodes_to_a_png_that_decodes_again() {
        let board = Board::unique();
        assert!(board.write_png(RED_DOT), "the fixture write must land");
        let tiff = board.data(Flavour::Tiff).expect("the write declares a TIFF twin");
        let png = png_of_tiff(&tiff).expect("a TIFF the framework produced must transcode back");
        // The bytes are NOT the ones we wrote — a re-encode is not a round trip — so the assertion
        // is the one the read path actually needs: what comes out is a PNG.
        assert_eq!(
            png.get(..8),
            RED_DOT.get(..8),
            "the answer must carry the PNG signature"
        );
    }

    #[test]
    fn an_image_reads_back_as_png_whichever_flavour_is_asked_for() {
        let board = Board::unique();
        assert!(board.write_png(RED_DOT), "the fixture write must land");
        assert_eq!(
            board.png().as_deref(),
            Some(RED_DOT),
            "a declared PNG comes back as-is"
        );
    }

    #[test]
    fn bytes_that_are_not_an_image_do_not_transcode() {
        assert!(
            png_of_tiff(b"not a tiff").is_none(),
            "an undecodable input is not an image"
        );
    }

    #[test]
    fn a_flavour_nobody_declared_reads_as_absent() {
        let board = Board::unique();
        assert!(board.write_text("plain"), "the fixture write must land");
        assert!(!board.declares(Flavour::File), "a text clip is not a file copy");
        assert!(
            !board.declares(Flavour::Concealed),
            "a text clip is not a password"
        );
        assert!(
            board.data(Flavour::Png).is_none(),
            "there is no image on this board"
        );
    }

    #[test]
    fn the_declared_list_is_what_the_writer_said_it_had() {
        let board = Board::unique();
        assert!(board.write_text("plain"), "the fixture write must land");
        let declared = board.declared();
        assert!(
            declared.iter().any(|ty| ty == "public.utf8-plain-text"),
            "a text write declares the plain-text UTI: {declared:?}",
        );
        assert!(
            !declared.iter().any(|ty| ty == CONCEALED_TYPE),
            "nothing declares the concealed marker unless a password manager wrote it",
        );
    }

    #[test]
    fn every_flavour_names_the_uti_the_framework_declares() {
        assert_eq!(Flavour::Text.uti(), "public.utf8-plain-text");
        assert_eq!(Flavour::Png.uti(), "public.png");
        assert_eq!(Flavour::Tiff.uti(), "public.tiff");
        assert_eq!(Flavour::File.uti(), "public.file-url");
        assert_eq!(Flavour::Concealed.uti(), CONCEALED_TYPE);
    }

    #[test]
    fn an_untouched_board_declares_nothing_and_holds_nothing() {
        let board = Board::unique();
        assert!(
            board.declared().is_empty(),
            "a fresh unique board has no owner and no types"
        );
        assert!(board.text().is_none(), "and nothing to read");
    }

    /// The `docs/57` §3 leak test, and the crate it was written for.
    ///
    /// This is the family's one `unsafe` block: `representationUsingType:properties:` builds an
    /// `NSBitmapImageRep` from bytes a peer chose and hands back an autoreleased `NSData`. Nothing
    /// else in this tree turns red for a rep that is retained and never released — a leaked one
    /// costs a bitmap's worth of memory per clip and the host runs for weeks. So the check is
    /// BALANCE: many transcodes and many boards, built and dropped, with the last one still
    /// answering. A retain the wrapper failed to hand over would grow a table monotonically; a
    /// release it made twice would have crashed long before the loop ended.
    #[test]
    fn transcoding_and_dropping_many_times_over_leaves_the_last_one_working() {
        let tiff = {
            let board = Board::unique();
            assert!(board.write_png(RED_DOT));
            board.data(Flavour::Tiff).expect("the twin the writer declared")
        };
        for _ in 0..2_000 {
            let board = Board::unique();
            assert!(board.write_png(RED_DOT), "every board still takes a write");
            assert!(png_of_tiff(&tiff).is_some(), "every transcode still answers");
            drop(board);
        }
        let last = Board::unique();
        assert!(last.write_text("still here"), "the process can still own a board");
        assert_eq!(last.text().as_deref(), Some("still here"));
    }
}
