//! Inline images: what the kitty graphics protocol put in the buffer, as plain owned data.
//!
//! ## The one thing this module is for
//!
//! `libghostty-vt` parses the whole kitty graphics protocol — transmission, placement, deletion,
//! the unicode-placeholder form — and keeps the result in a storage the terminal owns. What it
//! never does is draw, because it "leaves pixel-pushing to the host application". So the storage is
//! a set of questions, and this module is where they are asked and where the answers become
//! something `slopdesk-termrender` can place without ever touching the engine.
//!
//! One of those answers is not in the storage at all. A VIRTUAL placement — the `U=1`
//! unicode-placeholder form — is positioned by the GRID rather than by itself, so the engine
//! reports no position for one and [`crate::placeholder`] reads it out of the cells during the
//! frame scan. [`VtSession::placements`] is where the two meet, and it is the only reason this
//! module knows the frame exists. That is the same
//! bargain [`crate::frame`] strikes for cells, and it is struck twice for the same reason:
//! everything downstream reads plain data, and only this crate holds a handle.
//!
//! ## The storage limit is the switch, and it starts at zero because WE put it there
//!
//! A terminal with no room to store an image parses a transmission, finds nowhere to put it, and
//! discards it — the behaviour of a terminal with no image support, reached without a second code
//! path. So [`crate::VtSession::set_image_storage_limit`] is both the memory bound and the feature
//! flag, and `terminal.images` is the setting behind it.
//!
//! ⚠️ The zero is OURS, and reading the bindings is what would have missed it. Their module header
//! says images can be stored "only once a non-zero storage limit has been set", which reads as "a
//! fresh terminal has none" and is not what happens: the engine ships a LARGE non-zero default,
//! because it assumes an embedder that draws. Measured rather than read — the first cut of
//! `nothing_is_stored_until_a_storage_limit_says_so` failed, on a session that had transmitted,
//! stored and placed an image without anything ever asking for one. So
//! [`crate::VtSession::seal_image_transmission`] writes the zero explicitly, and without that line
//! every pane would buffer image payloads for a renderer that may never have been switched on.
//!
//! ## Why a placement is copied out rather than iterated in place
//!
//! An [`ImagePlacement`] is fifteen integers. The alternative — handing the renderer a live
//! [`PlacementIteration`] — would put an engine handle in the paint pass, which is the one thing
//! `lib.rs`'s "the engine never escapes" guarantee forbids, and it would make the borrow of the
//! terminal outlive a frame that also wants to ask the engine other questions. Copying a screenful
//! of placements is a handful of them: a placement exists per *displayed* image, and a session with
//! a hundred on screen at once is not a session anyone has.
//!
//! ## Pixels are copied ONCE per image generation, never per frame
//!
//! [`ImagePixels`] owns its bytes, and a megapixel image is four megabytes, so the copy is the
//! expensive thing in this module and the reason [`ImageMeta`] exists separately. The engine stamps
//! every image with a GENERATION that changes whenever its content could have — including a
//! retransmission of the same id at the same size, which no size or length heuristic can see — so a
//! caller asks for the metadata every frame, compares the generation against what it already
//! uploaded, and asks for the bytes only when the two differ. `slopdesk_termrender::ImageStore` is
//! the cache that comparison drives.
//!
//! ## RGBA8, always, and the conversion is here
//!
//! The engine stores an image in the format it arrived in: [`ImageFormat::Rgb`],
//! [`ImageFormat::Rgba`], [`ImageFormat::Gray`] or [`ImageFormat::GrayAlpha`]. A PNG is decoded to
//! RGBA at transmission time and never reaches storage as one. Widening the three narrow forms
//! belongs HERE rather than downstream, for [`crate::frame`]'s reason: what leaves this crate is
//! plain data in one shape, so no reader downstream needs a format table, a stride rule, or a
//! branch per pixel layout. The channel order is RGBA rather than BGRA because that is what the
//! protocol names and what the texture upload asks for; there is no swizzle anywhere on the path.

use libghostty_vt::alloc::{Allocator, Bytes};
use libghostty_vt::kitty::graphics::{DecodePng, DecodedImage, Graphics, ImageFormat, set_png_decoder};

use crate::session::{Result, VtSession};

/// How many bytes one RGBA8 pixel takes.
const RGBA_CHANNELS: usize = 4;

/// One image's identity and age, without its pixels.
///
/// The cheap half of the pair, asked once per visible image per frame. See the module header for
/// why [`Self::generation`] rather than the dimensions is what a texture cache keys on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageMeta {
    /// The protocol's image id.
    pub id: u32,
    /// The engine's content stamp. Never zero for a stored image, and monotonic process-wide, so a
    /// cache may key on it alone.
    pub generation: u64,
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
}

impl ImageMeta {
    /// How many bytes [`ImagePixels::rgba`] holds for an image this size.
    ///
    /// Saturating rather than wrapping: a hostile transmission can name dimensions whose product
    /// overflows, and the engine refuses to store one that large — but the arithmetic that decides
    /// so must not be the thing that panics.
    #[must_use]
    pub const fn rgba_len(self) -> usize {
        (self.width as usize)
            .saturating_mul(self.height as usize)
            .saturating_mul(RGBA_CHANNELS)
    }
}

/// One image's pixels, widened to RGBA8 and owned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImagePixels {
    /// Which image, and how old.
    pub meta: ImageMeta,
    /// `width × height × 4` bytes, row-major, top row first, STRAIGHT alpha.
    ///
    /// Straight rather than premultiplied because that is what the protocol transmits and what a
    /// program that reads its own PNG back would expect. The multiply happens in the fragment
    /// shader, where `slopdesk-apple-metal`'s premultiplied blend needs it — doing it here would
    /// bake a renderer's blend convention into the engine's data.
    pub rgba: Vec<u8>,
}

/// One image placed on the grid, in the units the engine measured it in.
///
/// Every pixel field is a DEVICE pixel, because the engine was told the cell's device-pixel size at
/// construction and every size it computes rides on that. Every grid field is a cell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImagePlacement {
    /// Which image this draws.
    pub image_id: u32,
    /// Which placement of it. An image may be placed many times.
    pub placement_id: u32,
    /// The protocol's z index, which decides what the image sits above and below.
    pub z: i32,
    /// Viewport-relative column of the top-left corner.
    pub col: i32,
    /// Viewport-relative row of the top-left corner.
    ///
    /// NEGATIVE when the placement's origin has scrolled above the viewport, in which case that
    /// many rows of the image are off the top and the renderer clips them. Positive-only would have
    /// been the lossy spelling: an image half-scrolled off the top is the ordinary case in a
    /// scrollback, and clamping the row would slide the visible half upward.
    pub row: i32,
    /// Rendered width in device pixels.
    pub width_px: u32,
    /// Rendered height in device pixels.
    pub height_px: u32,
    /// How many columns the placement covers.
    pub cols: u32,
    /// How many rows the placement covers.
    pub rows: u32,
    /// Source rectangle inside the image, x origin in pixels.
    pub source_x: u32,
    /// Source rectangle y origin in pixels.
    pub source_y: u32,
    /// Source rectangle width in pixels, already resolved against the protocol's "0 means all".
    pub source_width: u32,
    /// Source rectangle height in pixels.
    pub source_height: u32,
    /// Pixels in from the left edge of the anchor cell before the image starts.
    ///
    /// The protocol's `X=`, and for a virtual placement the horizontal band the aspect fit left
    /// over. Sub-cell, always: a program uses it to line an image up with something drawn beside
    /// it, and dropping it slides the picture by up to a cell.
    pub cell_offset_x: u32,
    /// Pixels down from the top edge of the anchor row before the image starts. The protocol's
    /// `Y=`.
    pub cell_offset_y: u32,
}

/// The PNG decoder the engine calls when a transmission names `f=100`.
///
/// ## Why this is ours and not the bindings'
///
/// `libghostty-vt` exposes PNG decoding as a HOOK rather than a dependency — nothing is decoded
/// unless a decoder is installed — because the engine will not choose an image library for its
/// embedders. It ships a `RustPngDecoder` behind an optional feature, and that one cannot work: it
/// `reserve`s capacity into a `Vec` and then hands the `Vec` to `next_frame`, which reads its
/// LENGTH, so the buffer it passes is always empty and every decode fails. Writing four lines here
/// rather than taking the feature is not a fork of anything — the hook is the published API, and
/// this is what it is for.
///
/// The transformations are the engine's requirement, not a preference: it accepts RGBA8 only, so a
/// palette or a greyscale PNG is expanded and a 16-bit one is stripped to 8. Anything the `png`
/// crate refuses becomes `None`, which the engine reads as "this image cannot be stored" and
/// discards — the same end a terminal without a decoder reaches, and never a panic on a byte
/// stream the far side chose.
#[derive(Debug, Default, Clone, Copy)]
struct PngDecoder;

impl DecodePng for PngDecoder {
    fn decode_png<'alloc>(
        &mut self,
        alloc: &'alloc Allocator<'_>,
        data: &[u8],
    ) -> Option<DecodedImage<'alloc>> {
        let mut decoder = png::Decoder::new(std::io::Cursor::new(data));
        decoder.set_transformations(png::Transformations::ALPHA | png::Transformations::STRIP_16);

        let mut reader = decoder.read_info().ok()?;
        let mut scratch = vec![0_u8; reader.output_buffer_size()?];
        let info = reader.next_frame(&mut scratch).ok()?;

        // The engine takes ownership of what is returned and frees it with the allocator it handed
        // over, so it cannot be a `Vec`: allocating through the caller's allocator is the whole
        // contract of the hook. The intermediate `scratch` is the `png` crate's requirement — it
        // decodes into a slice — and it dies at the end of this call.
        let pixels = scratch.get(..info.buffer_size())?;
        let mut bytes = Bytes::new_with_alloc(alloc, pixels.len()).ok()?;
        bytes.copy_from_slice(pixels);

        Some(DecodedImage {
            width: info.width,
            height: info.height,
            data: bytes,
        })
    }
}

thread_local! {
    /// Whether [`install_png_decoder`] has already run on this thread.
    ///
    /// `set_png_decoder` is a THREAD-local hook in the bindings and a process-wide one in the
    /// engine, so installing it once per session would replace a live decoder every time a second
    /// pane opened. Once per thread is the honest granularity, and a terminal never leaves its own
    /// thread — `VtSession` is `!Send`.
    static PNG_INSTALLED: core::cell::Cell<bool> = const { core::cell::Cell::new(false) };
}

/// Installs the PNG decoder on this thread, at most once.
///
/// Failure is silent and survivable by construction: without a decoder the engine declines `f=100`
/// transmissions and stores every other format as before, so a pane still runs — it simply cannot
/// show a PNG. Refusing to construct a terminal over it would trade every feature for one.
pub(crate) fn install_png_decoder() {
    PNG_INSTALLED.with(|installed| {
        if installed.get() {
            return;
        }
        installed.set(true);
        let _refused = set_png_decoder(Some(Box::new(PngDecoder)));
    });
}

/// Widens `data` from `format` into RGBA8, or `None` if it is not the size `format` implies.
///
/// The `None` is a real guard rather than a formality. `width`, `height` and the payload length all
/// arrive from a program on the pty, and a short payload with a large declared size is the shape
/// that turns an unchecked stride walk into a read past the end. Everything here is bounds-checked
/// by `chunks_exact`, which yields nothing at all for a remainder, and the length is verified
/// against the declared geometry before a single pixel is touched.
fn widen(format: ImageFormat, meta: ImageMeta, data: &[u8]) -> Option<Vec<u8>> {
    let pixels = (meta.width as usize).checked_mul(meta.height as usize)?;
    let channels = match format {
        ImageFormat::Gray => 1,
        ImageFormat::GrayAlpha => 2,
        ImageFormat::Rgb => 3,
        ImageFormat::Rgba => RGBA_CHANNELS,
        // `Png` never reaches storage: the decoder above turns one into RGBA at transmission time,
        // and an image that could not be decoded was never stored at all. A future variant lands
        // here too, and declining to guess its stride is the only safe answer.
        _ => return None,
    };
    if data.len() != pixels.checked_mul(channels)? {
        return None;
    }
    if channels == RGBA_CHANNELS {
        return Some(data.to_vec());
    }

    let mut rgba = Vec::with_capacity(meta.rgba_len());
    for pixel in data.chunks_exact(channels) {
        match *pixel {
            [gray] => rgba.extend_from_slice(&[gray, gray, gray, u8::MAX]),
            [gray, alpha] => rgba.extend_from_slice(&[gray, gray, gray, alpha]),
            [r, g, b] => rgba.extend_from_slice(&[r, g, b, u8::MAX]),
            // `chunks_exact(channels)` yields slices of exactly `channels`, and `channels` is one
            // of the three above by the match that produced it. Unreachable in the ordinary sense,
            // and written as a drop rather than an `unreachable!` because a panic on the render
            // path is never the right way to find out otherwise.
            _ => return None,
        }
    }
    Some(rgba)
}

impl VtSession {
    /// How many bytes of image data the terminal may hold, and whether it holds any at all.
    ///
    /// **Zero disables the protocol**: with no room to store one, a transmission is parsed and
    /// dropped. So this door is both the feature flag and the memory bound, and there is no second
    /// place either can be set. Every session starts at zero — see
    /// [`Self::seal_image_transmission`] for why that is a line of code rather than a default.
    ///
    /// # Errors
    /// The engine's own, if it declines the limit.
    pub fn set_image_storage_limit(&mut self, bytes: u64) -> Result<()> {
        self.terminal.set_kitty_image_storage_limit(bytes)?;
        Ok(())
    }

    /// Whether the terminal may read image payloads out of FILES the far side names.
    ///
    /// ⚠️ **Off, and it stays off.** The kitty protocol's `t=f`/`t=t`/`t=s` transmission mediums
    /// let a program on the pty name a PATH or a shared-memory object instead of sending bytes,
    /// and the terminal opens it. In this app the terminal is the CLIENT and the program is on
    /// a REMOTE host, so the path a program names would be resolved against the user's own
    /// laptop — a remote shell reading local files through an escape sequence. The direct
    /// medium carries every real use (`t=d`, base64 in the APC payload) at the cost of the
    /// bytes crossing the wire, which they had to do anyway.
    ///
    /// It is a door rather than a hardcoded `false` because the ENGINE's default is the opposite,
    /// so somewhere has to say so out loud, and construction is where it does.
    ///
    /// # Errors
    /// The engine's own, if it declines.
    fn set_image_file_transmission(&mut self, allowed: bool) -> Result<()> {
        self.terminal.set_kitty_image_from_file_allowed(allowed)?;
        self.terminal.set_kitty_image_from_shared_mem_allowed(allowed)?;
        Ok(())
    }

    /// Closes the two file mediums, installs the PNG decoder, and starts with images OFF.
    ///
    /// ⚠️ **The zero is not redundant.** The engine ships a large non-zero default storage limit —
    /// it assumes an embedder that draws — so a terminal built without this line accumulates image
    /// payloads for a renderer that may not have been told to place them. Starting at zero makes
    /// `terminal.images` a real switch with a real off position, and makes the setting's actuator
    /// the ONLY thing that ever turns the protocol on.
    ///
    /// # Errors
    /// The engine's own, if it declines a medium or the limit.
    pub(crate) fn seal_image_transmission(&mut self) -> Result<()> {
        install_png_decoder();
        self.set_image_file_transmission(false)?;
        self.set_image_storage_limit(0)
    }

    /// The storage's content stamp, or zero when nothing has ever been stored.
    ///
    /// Unchanged between two frames means the set of placements and every image's bytes are
    /// identical, so a caller may skip [`Self::placements`] entirely — but NOT the geometry it
    /// produces, because scrolling and resizing move a placement without touching the storage. That
    /// is why the surface re-places every frame and re-uploads only on a change.
    #[must_use]
    pub fn graphics_generation(&self) -> u64 {
        self.graphics()
            .and_then(|graphics| graphics.generation().ok())
            .unwrap_or_default()
    }

    /// One image's identity and age, without copying a pixel.
    #[must_use]
    pub fn image_meta(&self, id: u32) -> Option<ImageMeta> {
        meta_of(&self.graphics()?, id)
    }

    /// One image's pixels, widened to RGBA8.
    ///
    /// `None` while a transmission is still arriving in chunks — the metadata is resident before
    /// the payload is — and for a format this build cannot widen. Both are transient or permanent
    /// in the caller's favour: a chunked image answers on a later frame, and a format that never
    /// widens simply never draws.
    #[must_use]
    pub fn image_pixels(&self, id: u32) -> Option<ImagePixels> {
        let graphics = self.graphics()?;
        let meta = meta_of(&graphics, id)?;
        let image = graphics.image(id)?;
        let data = image.data().ok()??;
        Some(ImagePixels {
            meta,
            rgba: widen(image.format().ok()?, meta, data)?,
        })
    }

    /// Fills `out` with every placement the viewport can see, nearest-to-back last.
    ///
    /// `out` is cleared first and its allocation kept, so the steady state of a pane with an image
    /// on screen allocates nothing per frame.
    ///
    /// ## The two kinds, and why the second needs the frame
    ///
    /// An ORDINARY placement carries its own screen position and the engine answers where it landed
    /// — that is the first loop, and it is all most programs use.
    ///
    /// A VIRTUAL placement carries none. It declares a size and nothing else, and the program then
    /// writes `U+10EEEE` into the cells the image should cover, encoding which image and which
    /// fragment in each cell's colours and diacritics. So the engine's answer for one is "no
    /// position", and the position has to be read out of the GRID — which [`crate::frame`]'s scan
    /// already did, into [`crate::frame::FrameRow::placeholders`]. The second loop is that join:
    /// every decoded run, matched to the placement whose grid it belongs to, turned into the same
    /// flat [`ImagePlacement`] the renderer draws either way. See [`crate::placeholder`] for the
    /// protocol and for whose arithmetic the fit is.
    ///
    /// The frame must therefore be CURRENT — `render` before `placements`, which is the order the
    /// surface's paint already has. A stale frame places a virtually-positioned image where it was
    /// last frame, which is the same staleness the text beside it would have.
    pub fn placements(&mut self, out: &mut Vec<ImagePlacement>) {
        out.clear();
        // Destructured rather than taken through `&mut self`, because the iteration borrows the
        // ITERATOR mutably and the TERMINAL immutably at the same time, and a method on `self`
        // cannot express that they are different fields.
        let Self {
            terminal,
            placements,
            frame,
            cell_width_px,
            cell_height_px,
            ..
        } = self;
        let Ok(graphics) = terminal.kitty_graphics() else {
            return;
        };
        let Ok(mut iteration) = placements.update(&graphics) else {
            return;
        };

        // The grid each virtual placement declared, which is the only thing the engine knows about
        // one. Never allocates for a session that has no virtual placement — which is every session
        // that uses `icat`, `timg` or any of the ordinary image programs — because a `Vec` that is
        // never pushed to never asks for memory.
        let mut virtual_grids: Vec<VirtualGrid> = Vec::new();
        while let Some(placement) = iteration.next() {
            let (Ok(image_id), Ok(placement_id), Ok(is_virtual)) = (
                placement.image_id(),
                placement.placement_id(),
                placement.is_virtual(),
            ) else {
                continue;
            };
            if is_virtual {
                let (Ok(columns), Ok(rows)) = (placement.columns(), placement.rows()) else {
                    continue;
                };
                virtual_grids.push(VirtualGrid {
                    image_id,
                    placement_id,
                    columns,
                    rows,
                });
                continue;
            }
            let Some(image) = graphics.image(image_id) else {
                continue;
            };
            let Ok(info) = placement.placement_render_info(&image, terminal) else {
                continue;
            };
            if !info.viewport_visible {
                continue;
            }
            let Ok(z) = placement.z() else {
                continue;
            };
            out.push(ImagePlacement {
                image_id,
                placement_id,
                z,
                col: info.viewport_col,
                row: info.viewport_row,
                width_px: info.pixel_width,
                height_px: info.pixel_height,
                cols: info.grid_cols,
                rows: info.grid_rows,
                source_x: info.source_x,
                source_y: info.source_y,
                source_width: info.source_width,
                source_height: info.source_height,
                // The protocol's `X=`/`Y=`, which the render info does not carry.
                cell_offset_x: placement.x_offset().unwrap_or(0),
                cell_offset_y: placement.y_offset().unwrap_or(0),
            });
        }

        if virtual_grids.is_empty() {
            return;
        }
        expand_placeholders(
            &graphics,
            frame,
            &virtual_grids,
            *cell_width_px,
            *cell_height_px,
            out,
        );
    }

    /// The active screen's image storage, if the engine will hand it over.
    fn graphics(&self) -> Option<Graphics<'_>> {
        self.terminal.kitty_graphics().ok()
    }
}

/// One virtual placement's declared grid, which is everything the engine knows about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct VirtualGrid {
    /// Which image it places.
    image_id: u32,
    /// Which placement of it, or zero when the program named none.
    placement_id: u32,
    /// Columns the program asked for, or zero for "as many as the image's own size takes".
    columns: u32,
    /// Rows the program asked for, or zero for the same reason.
    rows: u32,
}

/// One image's identity and age, read straight off a storage handle.
fn meta_of(graphics: &Graphics<'_>, id: u32) -> Option<ImageMeta> {
    let image = graphics.image(id)?;
    Some(ImageMeta {
        id,
        generation: image.generation().ok()?,
        width: image.width().ok()?,
        height: image.height().ok()?,
    })
}

/// Turns every placeholder run the frame decoded into a placement, and appends them to `out`.
///
/// The `z` is `-1` for all of them, matching ghostty: a virtual placement has no z of its own, and
/// `-1` is the band behind the text and in front of the cell background — which is what a program
/// tiling an image behind its own output expects, and what every image drawn this way gets.
///
/// A run whose image is not stored, whose placement went away between the frame scan and here, or
/// whose fragment falls entirely inside the blank band the aspect fit left over is dropped. All
/// three are ordinary: the first is a transmission still arriving, the second a placement deleted a
/// frame ago, and the third the corner cells of a wide image in a tall grid.
fn expand_placeholders(
    graphics: &Graphics<'_>,
    frame: &crate::frame::Frame,
    virtual_grids: &[VirtualGrid],
    cell_width_px: u32,
    cell_height_px: u32,
    out: &mut Vec<ImagePlacement>,
) {
    for (y, row) in frame.rows.iter().enumerate() {
        if row.placeholders.is_empty() {
            continue;
        }
        let Ok(viewport_row) = i32::try_from(y) else {
            continue;
        };
        for run in &row.placeholders {
            // A run that named a placement id wants that exact one; a run that named none takes the
            // first virtual placement of its image, which is the protocol's rule and the reason the
            // id is optional at all.
            let Some(grid) = virtual_grids.iter().find(|grid| {
                grid.image_id == run.image_id
                    && (run.placement_id == 0 || grid.placement_id == run.placement_id)
            }) else {
                continue;
            };
            let Some(meta) = meta_of(graphics, run.image_id) else {
                continue;
            };
            let Some(geometry) = crate::placeholder::geometry(
                *run,
                meta,
                grid.columns,
                grid.rows,
                cell_width_px,
                cell_height_px,
            ) else {
                continue;
            };
            out.push(ImagePlacement {
                image_id: run.image_id,
                placement_id: grid.placement_id,
                z: -1,
                col: i32::from(run.start_col),
                row: viewport_row,
                width_px: geometry.dest_width,
                height_px: geometry.dest_height,
                cols: run.width,
                rows: 1,
                source_x: geometry.source_x,
                source_y: geometry.source_y,
                source_width: geometry.source_width,
                source_height: geometry.source_height,
                cell_offset_x: geometry.offset_x,
                cell_offset_y: geometry.offset_y,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use base64::Engine as _;
    use libghostty_vt::kitty::graphics::ImageFormat;

    use super::{ImageMeta, widen};
    use crate::VtSession;

    /// A session with images ENABLED, at the grid and cell size the numbers below are read against.
    fn session() -> VtSession {
        let mut session = VtSession::new(20, 10, 8, 16).unwrap();
        session.set_image_storage_limit(16 * 1024 * 1024).unwrap();
        session
    }

    /// One kitty `a=T` transmit-and-display APC for a `width × height` RGB image, all one colour.
    fn transmit(width: u32, height: u32, colour: [u8; 3]) -> Vec<u8> {
        let pixels: Vec<u8> = (0..width * height).flat_map(|_| colour).collect();
        let payload = base64::engine::general_purpose::STANDARD.encode(&pixels);
        format!("\x1b_Ga=T,f=24,s={width},v={height},i=1;{payload}\x1b\\").into_bytes()
    }

    #[test]
    fn a_transmitted_image_is_stored_placed_and_widened_to_rgba() {
        // The end-to-end pin, and the only one that can catch the whole path going quiet: the
        // protocol reaches the engine, the engine finds room for it (which it has only because the
        // storage limit was set), a placement lands on the viewport, and the pixels come back in
        // the one format everything downstream reads.
        let mut session = session();
        session.feed(&transmit(2, 2, [10, 20, 30]));

        let mut placements = Vec::new();
        session.placements(&mut placements);
        let placement = placements.first().copied().unwrap();
        assert_eq!(placement.image_id, 1);
        assert_eq!(
            placement.row, 0,
            "an image at the home position starts at row zero"
        );
        assert_eq!(placement.col, 0);
        assert_eq!(placement.source_width, 2, "`w=0` resolves to the whole image");
        assert_eq!(placement.source_height, 2);

        // The four numbers `slopdesk-termrender`'s `place` builds the DESTINATION rectangle from,
        // pinned here because a zero in any of them is the one failure the renderer cannot see: a
        // zero-area quad is dropped before it reaches a buffer, so an engine that reported the size
        // only when the program named one would draw NOTHING and pass every test downstream. A
        // transmission with no `c=`/`r=` is the common case — `icat` sends it — and it must resolve
        // to the image's own pixel size and the cells that size covers.
        assert_eq!(
            (placement.width_px, placement.height_px),
            (2, 2),
            "a placement with no explicit size takes the image's"
        );
        assert_eq!(
            (placement.cols, placement.rows),
            (1, 1),
            "two pixels across an eight-pixel cell is one cell"
        );

        let pixels = session.image_pixels(1).unwrap();
        assert_eq!(pixels.meta.width, 2);
        assert_eq!(pixels.meta.height, 2);
        assert_ne!(
            pixels.meta.generation, 0,
            "a stored image is never generation zero"
        );
        assert_eq!(pixels.rgba.len(), pixels.meta.rgba_len());
        assert_eq!(
            pixels.rgba.get(..4),
            Some(&[10, 20, 30, 255][..]),
            "an RGB transmission gains an opaque alpha"
        );
    }

    #[test]
    fn a_placement_carries_the_offsets_that_move_it_inside_its_anchor_cell() {
        // `X=`/`Y=` are the protocol's sub-cell nudge, and the render info does not carry them —
        // they come off the placement itself. Without this the accessors could answer zero forever
        // and every other test would still pass, because nothing else in the engine reads them.
        let mut session = session();
        let pixels: Vec<u8> = (0..4).flat_map(|_| [1_u8, 2, 3]).collect();
        let payload = base64::engine::general_purpose::STANDARD.encode(&pixels);
        session.feed(
            format!("\x1b_Ga=T,f=24,s=2,v=2,i=1,X=3,Y=5;{payload}\x1b\\")
                .into_bytes()
                .as_slice(),
        );

        let mut placements = Vec::new();
        session.placements(&mut placements);
        let placement = placements.first().copied().unwrap();
        assert_eq!(
            (placement.cell_offset_x, placement.cell_offset_y),
            (3, 5),
            "the offsets survive the flattening the renderer reads"
        );
    }

    /// One `a=T,U=1` APC: transmit, and declare a VIRTUAL placement over a `cols × rows` grid.
    fn transmit_virtual(width: u32, height: u32, cols: u32, rows: u32) -> Vec<u8> {
        let pixels: Vec<u8> = (0..width * height).flat_map(|_| [9_u8, 9, 9]).collect();
        let payload = base64::engine::general_purpose::STANDARD.encode(&pixels);
        format!("\x1b_Ga=T,f=24,s={width},v={height},i=1,U=1,c={cols},r={rows};{payload}\x1b\\").into_bytes()
    }

    /// The bytes a program writes to put fragment `row`/`col` of image 1 in the cell under the
    /// cursor.
    ///
    /// The id in the foreground colour and the fragment in two diacritics — the whole encoding, in
    /// the spelling `icat --unicode-placeholder` emits.
    fn placeholder_cell(row: usize, col: usize) -> String {
        let marks: String = [row, col]
            .into_iter()
            .filter_map(crate::placeholder::diacritic_at)
            .collect();
        format!("\x1b[38;2;0;0;1m\u{10EEEE}{marks}")
    }

    #[test]
    fn a_virtual_placement_is_positioned_by_the_cells_and_not_by_itself() {
        // The end-to-end pin for the unicode-placeholder form, and the one that catches the join
        // going quiet: the engine stores a placement with NO position, the frame scan decodes the
        // runs out of the grid, and `placements` puts the two together. Every link is invisible on
        // its own — a virtual placement the engine reports is unplaceable, and a decoded run with
        // no placement to match names a grid nobody declared.
        //
        // A 16×32 image over a 2×2 grid of 8×16 cells is exactly the grid's shape, so each row is
        // half the image at full width and there is no band to complicate the numbers.
        let mut session = session();
        session.feed(&transmit_virtual(16, 32, 2, 2));
        for row in 0..2_usize {
            session.feed(format!("\x1b[{};1H", row + 1).as_bytes());
            session.feed(placeholder_cell(row, 0).as_bytes());
            session.feed(placeholder_cell(row, 1).as_bytes());
        }
        session.render().unwrap();

        let mut placements = Vec::new();
        session.placements(&mut placements);
        assert_eq!(
            placements.len(),
            2,
            "two rows of placeholders are two runs, not four cells and not one strip"
        );

        let top = placements.first().copied().unwrap();
        assert_eq!((top.image_id, top.col, top.row), (1, 0, 0));
        assert_eq!(
            top.z, -1,
            "a virtual placement draws behind the text and in front of the background"
        );
        assert_eq!(
            (top.cols, top.rows),
            (2, 1),
            "a run is one row wide by construction"
        );
        assert_eq!((top.width_px, top.height_px), (16, 16));
        assert_eq!((top.source_y, top.source_height), (0, 16));

        let bottom = placements.get(1).copied().unwrap();
        assert_eq!(bottom.row, 1);
        assert_eq!(
            (bottom.source_y, bottom.source_height),
            (16, 16),
            "the second row drew the first half of the image again"
        );
    }

    #[test]
    fn a_placeholder_cell_carries_no_text_for_a_font_to_draw() {
        // `U+10EEEE` is private-use and no font has it, so a placeholder that survived into the
        // frame's text arena would put a `.notdef` box in every cell of every virtually placed
        // image — over the image itself. Blanked on the CODEPOINT rather than on whether images are
        // on, which is why this asserts on a session with the storage limit at zero too.
        let mut session = VtSession::new(20, 10, 8, 16).unwrap();
        session.feed(placeholder_cell(0, 0).as_bytes());
        session.feed(b"x");
        session.render().unwrap();

        let row = session.frame().rows.first().unwrap();
        let first = row.cells.first().copied().unwrap();
        assert_eq!(
            row.cell_text(first),
            "",
            "the placeholder reached the renderer as a glyph"
        );
        let second = row.cells.get(1).copied().unwrap();
        assert_eq!(row.cell_text(second), "x", "the cell after it lost its text");
    }

    #[test]
    fn a_run_survives_a_frame_in_which_its_row_is_clean() {
        // The one hazard the per-row cache creates and the reason the runs live on the row: the
        // frame scan SKIPS a row the engine reports clean, so a placeholder decoded into a scratch
        // that reset per frame would vanish the moment the row stopped changing — an image that
        // appears for one frame and then disappears while its cells are still on screen.
        let mut session = session();
        session.feed(&transmit_virtual(16, 32, 2, 2));
        session.feed(placeholder_cell(0, 0).as_bytes());
        session.feed(placeholder_cell(0, 1).as_bytes());
        session.render().unwrap();

        let mut placements = Vec::new();
        session.placements(&mut placements);
        assert_eq!(placements.len(), 1);

        // A second render with nothing fed. Row zero is clean now, so it is not refilled.
        session.render().unwrap();
        session.placements(&mut placements);
        assert_eq!(
            placements.len(),
            1,
            "the run was lost the moment its row stopped changing"
        );
    }

    #[test]
    fn nothing_is_stored_until_a_storage_limit_says_so() {
        // The engine's own switch, and the reason `terminal.images` needs no second flag anywhere.
        // A terminal at the default limit parses the transmission and has nowhere to put it, which
        // is exactly the behaviour of a terminal with no image support — reached without a branch.
        let mut off = VtSession::new(20, 10, 8, 16).unwrap();
        off.feed(&transmit(2, 2, [1, 2, 3]));
        let mut placements = Vec::new();
        off.placements(&mut placements);
        assert!(placements.is_empty(), "an image was stored with no room for one");
        assert!(
            off.image_meta(1).is_none(),
            "the transmission was parsed and stored rather than parsed and dropped"
        );
    }

    #[test]
    fn a_retransmission_moves_the_generation_the_dimensions_cannot() {
        // Why a texture cache keys on the generation and not on the size: the same id at the same
        // size with different pixels is the case every other heuristic misses, and it is the case a
        // program that redraws a chart in place produces on every update.
        let mut session = session();
        session.feed(&transmit(2, 2, [10, 20, 30]));
        let first = session.image_meta(1).unwrap();

        session.feed(&transmit(2, 2, [200, 100, 50]));
        let second = session.image_meta(1).unwrap();

        assert_eq!((first.width, first.height), (second.width, second.height));
        assert_ne!(
            first.generation, second.generation,
            "a retransmission that changed only the pixels moved nothing a cache could see"
        );
    }

    #[test]
    fn placing_reuses_its_buffer_and_clears_what_was_there() {
        let mut session = session();
        let mut placements = vec![super::ImagePlacement {
            image_id: 99,
            placement_id: 0,
            z: 0,
            col: 0,
            row: 0,
            width_px: 0,
            height_px: 0,
            cols: 0,
            rows: 0,
            source_x: 0,
            source_y: 0,
            source_width: 0,
            source_height: 0,
            cell_offset_x: 0,
            cell_offset_y: 0,
        }];
        session.placements(&mut placements);
        assert!(
            placements.is_empty(),
            "a stale placement survived into the next frame"
        );
    }

    fn meta(width: u32, height: u32) -> ImageMeta {
        ImageMeta {
            id: 1,
            generation: 7,
            width,
            height,
        }
    }

    #[test]
    fn rgba_arrives_unchanged() {
        let data = [1, 2, 3, 4, 5, 6, 7, 8];
        assert_eq!(
            widen(ImageFormat::Rgba, meta(2, 1), &data).unwrap(),
            data.to_vec()
        );
    }

    #[test]
    fn rgb_gains_an_opaque_alpha() {
        let widened = widen(ImageFormat::Rgb, meta(2, 1), &[1, 2, 3, 4, 5, 6]).unwrap();
        assert_eq!(widened, vec![1, 2, 3, 255, 4, 5, 6, 255]);
    }

    #[test]
    fn grey_spreads_across_three_channels() {
        assert_eq!(widen(ImageFormat::Gray, meta(2, 1), &[9, 200]).unwrap(), vec![
            9, 9, 9, 255, 200, 200, 200, 255
        ]);
        assert_eq!(
            widen(ImageFormat::GrayAlpha, meta(1, 1), &[9, 128]).unwrap(),
            vec![9, 9, 9, 128]
        );
    }

    #[test]
    fn a_payload_that_does_not_match_its_declared_size_is_refused() {
        // The guard that matters, and the only one a hostile pty can reach: a program declares a
        // large image and sends a short payload. Refusing here is what keeps every walk below it
        // over a slice whose length was checked rather than assumed.
        assert!(widen(ImageFormat::Rgb, meta(1000, 1000), &[1, 2, 3]).is_none());
        assert!(widen(ImageFormat::Rgba, meta(2, 2), &[1, 2, 3, 4]).is_none());
    }

    #[test]
    fn a_png_never_widens_because_it_never_reaches_storage() {
        // Storage holds decoded pixels only — the hook turns a PNG into RGBA at transmission time.
        // A stored image reporting `Png` would mean the engine and this module disagree about what
        // storage contains, and drawing whatever the bytes happened to be is the wrong way to find
        // out.
        assert!(widen(ImageFormat::Png, meta(1, 1), &[0, 0, 0, 0]).is_none());
    }

    #[test]
    fn a_size_that_overflows_is_refused_rather_than_wrapping() {
        assert!(widen(ImageFormat::Rgba, meta(u32::MAX, u32::MAX), &[]).is_none());
        assert_eq!(meta(u32::MAX, u32::MAX).rgba_len(), usize::MAX);
    }
}
