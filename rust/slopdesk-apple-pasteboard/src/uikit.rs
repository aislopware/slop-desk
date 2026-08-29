//! `UIKit`'s half of the board, answering the same surface `appkit.rs` does.
//!
//! ## The one difference that is NOT a spelling
//! macOS lets anything read a pasteboard's content. iOS has not since iOS 16: an unattended read of
//! `string` / `image` / `dataForPasteboardType:` — content this app did not write, with no system
//! paste gesture behind it — raises a modal "Allow Paste?" alert. [`Board::change_count`],
//! [`Board::declared`] and [`Board::has_text`] do not: they report what the WRITER declared, and
//! disclose nothing.
//!
//! That is why the surface splits probes from reads at all, on both platforms. This crate does not
//! decide when a read is allowed — that is the caller's platform fact, and the caller is the one
//! holding the gesture — but the split has to exist here or the caller has nothing to choose
//! between.
//!
//! ## No TIFF, and no twin on the write
//! `UIPasteboard` resolves `public.png` for every image consumer on the platform and `setData:`
//! replaces the board's item outright, so the `AppKit` half's TIFF twin has no counterpart to
//! spell. The image READ still transcodes, because a copy may declare only `public.jpeg` or a
//! private image type, and the wire carries PNG either way.

use objc2::rc::Retained;
use objc2_foundation::{NSArray, NSData, NSString};
use objc2_ui_kit::{UIImage, UIPasteboard};

/// The concealed-clip marker password managers set (the nspasteboard.org convention).
///
/// A string rather than a framework constant for the reason the `AppKit` half gives: there is none.
/// It is a community convention, and this is the only spelling of it a Rust caller can reach.
pub const CONCEALED_TYPE: &str = "org.nspasteboard.ConcealedType";

/// The four board flavours clipboard sync asks about, plus the concealed marker.
///
/// The same enum the `AppKit` half exports, so a caller that names a flavour names one word on both
/// platforms. [`Flavour::Tiff`] exists here and is never written: the read path may still MEET one,
/// since a Mac's clip can arrive on a shared board, and a caller that could not name it would have
/// to type the UTI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flavour {
    /// Plain UTF-8 text — `UTTypeUTF8PlainText`.
    Text,
    /// A PNG image — `UTTypePNG`.
    Png,
    /// A TIFF image — `UTTypeTIFF`.
    Tiff,
    /// A file reference — `UTTypeFileURL`. A path on one machine means nothing on another, which is
    /// why the fold above refuses to ship one.
    File,
    /// The concealed-clip marker — see [`CONCEALED_TYPE`].
    Concealed,
}

impl Flavour {
    /// The raw UTI string `UniformTypeIdentifiers` names this flavour by.
    ///
    /// The one door onto the framework's own spelling, for the `AppKit` half's reason: the fold
    /// above this crate must build on a machine with no `UIKit` and therefore types two of
    /// these strings itself, and a typed constant that nothing checks against the framework is
    /// exactly the two-implementations drift `docs/55` §6 records.
    #[must_use]
    pub fn uti(self) -> String {
        flavour::named(self).to_string()
    }
}

/// `UniformTypeIdentifiers`' own type globals.
///
/// Reading a C global is `unsafe` in Rust 2024 because the compiler cannot see that it was
/// initialised. These four were initialised by dyld before this process ran a line of its own, and
/// they are immutable `UTType`s the framework itself vends.
#[expect(
    unsafe_code,
    reason = "an `extern` static read is unsafe in Rust 2024; these are UniformTypeIdentifiers' own \
              immutable globals, live from dyld onwards"
)]
mod flavour {
    use objc2::rc::Retained;
    use objc2_foundation::NSString;
    use objc2_uniform_type_identifiers::{UTType, UTTypeFileURL, UTTypePNG, UTTypeTIFF, UTTypeUTF8PlainText};

    use super::Flavour;

    /// The `NSString` UTI this flavour is named by.
    ///
    /// [`Flavour::Concealed`] has no framework type at all, so it is minted from
    /// [`super::CONCEALED_TYPE`] — the same shape the `AppKit` half's fifth arm has.
    pub(super) fn named(flavour: Flavour) -> Retained<NSString> {
        // SAFETY: each of the four is a `UTType *` constant in the framework's `__DATA` segment,
        // initialised at load time and never written. The framework's contract is that they are
        // valid for as long as it is loaded, which is the whole life of any process that linked it.
        let borrowed: &UTType = match flavour {
            Flavour::Text => unsafe { UTTypeUTF8PlainText },
            Flavour::Png => unsafe { UTTypePNG },
            Flavour::Tiff => unsafe { UTTypeTIFF },
            Flavour::File => unsafe { UTTypeFileURL },
            Flavour::Concealed => return NSString::from_str(super::CONCEALED_TYPE),
        };
        borrowed.identifier()
    }
}

/// One iOS pasteboard.
///
/// Holds a `Retained<UIPasteboard>` for the `AppKit` half's reason: the general board is a
/// process-wide singleton and a uniquely-named one lives as long as somebody holds it, so ownership
/// here is what keeps a test's board from being collected between two calls.
#[derive(Debug)]
pub struct Board {
    board: Retained<UIPasteboard>,
}

impl Board {
    /// The device's general pasteboard — what a Copy writes to and a Paste reads from.
    #[must_use]
    pub fn general() -> Self {
        Self {
            board: UIPasteboard::generalPasteboard(),
        }
    }

    /// A private board nobody else names.
    ///
    /// The test idiom, and the reason every assertion in this crate can run on a simulator without
    /// eating whatever the device had copied.
    #[must_use]
    pub fn unique() -> Self {
        Self {
            board: UIPasteboard::pasteboardWithUniqueName(),
        }
    }

    /// The board somebody else already named, created if it does not exist yet.
    ///
    /// Falls back to a UNIQUE board when `UIKit` declines to make one, which it does only for a
    /// name the system reserves. Deliberately not [`Board::general`]: the caller asked for a board
    /// that is not the machine's, and quietly handing it the machine's is the failure the name
    /// exists to prevent — a suite that clobbers whatever the user had copied. An unnamed private
    /// board is the wrong board too, but it is wrong in the direction that loses only the test's
    /// own assertion.
    #[must_use]
    pub fn named(name: &str) -> Self {
        UIPasteboard::pasteboardWithName_create(&NSString::from_str(name), true)
            .map_or_else(Self::unique, |board| Self { board })
    }

    /// Drops everything on the board.
    ///
    /// `setItems:` with an empty array, which is `UIKit`'s only clear — there is no
    /// `clearContents` twin, because a `UIPasteboard` write replaces the item rather than adding a
    /// flavour to a declaration.
    pub fn clear(&self) {
        // SAFETY: `setItems:` is generated `unsafe` because the property is not atomic. The
        // framework's rule is that a pasteboard may be used from any thread — `UIPasteboard` is one
        // of the few `UIKit` classes documented so, and `objc2` marks it `Send + Sync` on that
        // basis — and the array handed over is one this call allocated.
        #[expect(
            unsafe_code,
            reason = "objc2 generates the non-atomic property accessors unsafe"
        )]
        unsafe {
            self.board.setItems(&NSArray::new());
        }
    }

    /// The board's change counter, which advances on every write by anybody.
    ///
    /// The whole of a clipboard poll is this one integer — and on iOS it is the half of the poll
    /// the system still allows, because it discloses no content.
    #[must_use]
    pub fn change_count(&self) -> i64 {
        // SAFETY: a non-atomic property read on a class the framework documents as usable from any
        // thread. See [`Board::clear`]'s note for the rule this satisfies.
        #[expect(
            unsafe_code,
            reason = "objc2 generates the non-atomic property accessors unsafe"
        )]
        let count = unsafe { self.board.changeCount() };
        i64::try_from(count).unwrap_or(i64::MAX)
    }

    /// Every type the current owner DECLARED, as raw UTI strings.
    ///
    /// A declaration, not a read: this is what the writer said it has, so asking costs no content,
    /// discloses none, and — the whole point on this platform — prompts for nothing.
    #[must_use]
    pub fn declared(&self) -> Vec<String> {
        // SAFETY: as [`Board::change_count`].
        #[expect(
            unsafe_code,
            reason = "objc2 generates the non-atomic property accessors unsafe"
        )]
        let types = unsafe { self.board.pasteboardTypes() };
        types.iter().map(|ty| ty.to_string()).collect()
    }

    /// Whether the owner declared `flavour`. See [`Board::declared`] on why this is free.
    #[must_use]
    pub fn declares(&self, flavour: Flavour) -> bool {
        let wanted = flavour::named(flavour);
        self.declared().iter().any(|ty| *ty == *wanted.to_string())
    }

    /// Whether the board holds plain text at all, WITHOUT reading it.
    ///
    /// `hasStrings` is the probe the module header names: it discloses no content, so iOS answers
    /// it without the modal alert [`Board::text`] one line down raises. Enablement asks THIS; the
    /// paste itself asks [`Board::text`], on the gesture the user made.
    #[must_use]
    pub fn has_text(&self) -> bool {
        // SAFETY: as [`Board::change_count`].
        #[expect(
            unsafe_code,
            reason = "objc2 generates the non-atomic property accessors unsafe"
        )]
        unsafe {
            self.board.hasStrings()
        }
    }

    /// The board's plain-text flavour, or `None` when it holds something else.
    ///
    /// ⚠️ A CONTENT read — see the module header.
    #[must_use]
    pub fn text(&self) -> Option<String> {
        // SAFETY: as [`Board::change_count`].
        #[expect(
            unsafe_code,
            reason = "objc2 generates the non-atomic property accessors unsafe"
        )]
        let string = unsafe { self.board.string() };
        Some(string?.to_string())
    }

    /// The bytes behind one flavour, or `None` when the board does not have it.
    ///
    /// ⚠️ A CONTENT read.
    #[must_use]
    pub fn data(&self, flavour: Flavour) -> Option<Vec<u8>> {
        Some(
            self.board
                .dataForPasteboardType(&flavour::named(flavour))?
                .to_vec(),
        )
    }

    /// The board's image, as PNG: the declared PNG flavour as-is, else whatever image is there
    /// transcoded, else `None`.
    ///
    /// The board's own fidelity contract in one call, the same question the `AppKit` half answers:
    /// is there an image here, as PNG? A copy may declare only `public.jpeg` or a private image
    /// type, and `image` is what reads any of them.
    ///
    /// ⚠️ A CONTENT read.
    #[must_use]
    pub fn png(&self) -> Option<Vec<u8>> {
        if let Some(png) = self.data(Flavour::Png) {
            return Some(png);
        }
        // SAFETY: as [`Board::change_count`].
        #[expect(
            unsafe_code,
            reason = "objc2 generates the non-atomic property accessors unsafe"
        )]
        let image = unsafe { self.board.image() }?;
        Some(image.png_representation()?.to_vec())
    }

    /// Replaces the board's contents with `text`. `false` — board UNTOUCHED — for empty text.
    ///
    /// Validate-then-write, which is why this answers rather than returning `()`: a clip that will
    /// not write must be refused BEFORE anything is set.
    #[must_use]
    pub fn write_text(&self, text: &str) -> bool {
        if text.is_empty() {
            return false;
        }
        let value = NSString::from_str(text);
        // SAFETY: as [`Board::change_count`], with the string this call just allocated.
        #[expect(
            unsafe_code,
            reason = "objc2 generates the non-atomic property accessors unsafe"
        )]
        unsafe {
            self.board.setString(Some(&value));
        }
        true
    }

    /// Replaces the board's contents with a PNG image. `false` — board UNTOUCHED — for bytes that
    /// will not decode as an image.
    ///
    /// No TIFF twin — see the module header.
    #[must_use]
    pub fn write_png(&self, png: &[u8]) -> bool {
        let data = NSData::with_bytes(png);
        if UIImage::imageWithData(&data).is_none() {
            return false;
        }
        self.board
            .setData_forPasteboardType(&data, &flavour::named(Flavour::Png));
        true
    }

    /// Replaces the board's contents with an image in ANY format the system decoder reads.
    ///
    /// `false` — board UNTOUCHED — for bytes that are not an image at all. Format-blind for the
    /// `AppKit` half's reason, and transcoding to PNG for the same one.
    #[must_use]
    pub fn write_image(&self, bytes: &[u8]) -> bool {
        png_of_image(bytes).is_some_and(|png| self.write_png(&png))
    }
}

/// Image bytes in any format the system decoder reads, as PNG bytes; `None` when they will not
/// decode or will not re-encode.
///
/// The `AppKit` half's twin, and a free function for the same reason: a pure byte conversion the
/// fold above reaches for while holding no board.
#[must_use]
pub fn png_of_image(bytes: &[u8]) -> Option<Vec<u8>> {
    let image = UIImage::imageWithData(&NSData::with_bytes(bytes))?;
    Some(image.png_representation()?.to_vec())
}
