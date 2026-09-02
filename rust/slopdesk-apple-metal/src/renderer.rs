//! One object, one entry point: a [`DrawList`] and a [`GlyphCache`] in, one presented frame out.
//!
//! ## The six draws, and why the order is not this crate's to choose
//!
//! ``text
//!   images   z <  i32::MIN/2   (behind even the cell background)
//!   backgrounds
//!   images   i32::MIN/2 <= z < 0
//!   glyphs
//!   images   z >= 0
//!   overlays
//! ``
//!
//! The three text passes are the order `quad.rs` stores them in, because the reason for the order
//! is stated there: a filled block cursor sits UNDER its glyph and inverts it, a bar or an
//! underline sits OVER it, and a strikethrough the glyph painted over is not a strikethrough. The
//! three image passes are the kitty graphics protocol's own z bands, interleaved at the two points
//! the protocol names, and `slopdesk_termrender::layer_of` is what assigns them. This module
//! encodes six lists in sequence and makes no decision at all about what is in them. There is no
//! sort here, no depth buffer and no stencil: painter's order over pre-separated lists is the whole
//! hidden-surface algorithm, and it is exact.
//!
//! The overlays go LAST, after every image, so a cursor and a selection stay visible over a picture
//! — which is also what every other terminal that draws images does.
//!
//! ## What a frame costs
//!
//! One command buffer, one render pass, at most four pipeline switches, three `drawPrimitives`
//! calls plus one per image on screen, and two texture binds plus one per image — for any number of
//! cells. A 200×50 repaint and a one-character update issue the same calls with different instance
//! counts, which is the property that makes `docs/68` §6's budget a budget rather than a hope. An
//! image-free frame — every frame in an ordinary session — costs exactly what it did before images
//! existed, because each of the three image passes returns on an empty run list before it touches
//! the encoder.

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_metal::{
    MTLBuffer, MTLClearColor, MTLCommandBuffer, MTLCommandEncoder, MTLCommandQueue, MTLDevice, MTLLoadAction,
    MTLPrimitiveType, MTLRenderCommandEncoder, MTLRenderPassDescriptor, MTLRenderPipelineState,
    MTLStoreAction, MTLTexture,
};
use objc2_quartz_core::CAMetalDrawable;
use slopdesk_termrender::{
    DrawList, GlyphCache, GlyphInstance, ImageInstance, ImageLayer, ImageRun, ImageStore, RectInstance, Rgba,
};

use crate::error::MetalError;
use crate::frames::{Bound, Filled, Ring};
use crate::geom::Viewport;
use crate::images::ImageTextures;
use crate::pipeline::Pipelines;
use crate::surface::Surface;
use crate::texture::AtlasTexture;

/// Where the per-instance buffer is bound. Matches `[[buffer(0)]]` in `shaders.metal`.
const INSTANCE_INDEX: usize = 0;
/// Where the viewport uniform is bound. Matches `[[buffer(1)]]`.
const VIEWPORT_INDEX: usize = 1;
/// Fragment texture slots, matching `[[texture(0)]]` and `[[texture(1)]]`.
///
/// `image_fragment` declares only slot 0, so an image binds its texture where the glyph pass binds
/// the coverage atlas. One constant, two shaders — not a coincidence worth a second name.
const COVERAGE_TEXTURE: usize = 0;
const COLOR_TEXTURE: usize = 1;

/// The four corners a triangle strip expands from `vertex_id`. See `shaders.metal`'s `corner_of`.
const QUAD_VERTICES: usize = 4;

/// The GPU half of the terminal surface.
#[derive(Debug)]
pub struct Renderer {
    device: Retained<ProtocolObject<dyn MTLDevice>>,
    queue: Retained<ProtocolObject<dyn MTLCommandQueue>>,
    surface: Surface,
    pipelines: Pipelines,
    ring: Ring,
    coverage: AtlasTexture,
    colored: AtlasTexture,
    images: ImageTextures,
}

impl Renderer {
    /// Takes the system default device and builds everything on it.
    ///
    /// `MTLCreateSystemDefaultDevice` rather than picking out of `MTLCopyAllDevices`: on a
    /// multi-GPU Mac it answers the one driving the main display, which is where the window is, and
    /// rendering on any other means the drawable crosses a bus every frame. It is also what
    /// triggers the discrete-GPU switch on the Macs that have one — accepted deliberately,
    /// because a mismatched device is a copy per frame and this is the surface `docs/68` §6
    /// protects.
    ///
    /// # Errors
    ///
    /// [`MetalError::NoDevice`] on a machine with no GPU, [`MetalError::NoCommandQueue`] if the
    /// device refuses one, and [`MetalError::ShaderCompile`], [`MetalError::MissingFunction`] or
    /// [`MetalError::PipelineState`] if `shaders.metal` and the two pipelines do not build.
    pub fn new() -> Result<Self, MetalError> {
        let device = objc2_metal::MTLCreateSystemDefaultDevice().ok_or(MetalError::NoDevice)?;
        let queue = device.newCommandQueue().ok_or(MetalError::NoCommandQueue)?;
        let pipelines = Pipelines::build(&device)?;
        let surface = Surface::new(&device);

        Ok(Self {
            device,
            queue,
            surface,
            pipelines,
            ring: Ring::new(),
            coverage: AtlasTexture::new(),
            colored: AtlasTexture::new(),
            images: ImageTextures::new(),
        })
    }

    /// The layer to install on the hosting view.
    #[must_use]
    pub const fn surface(&self) -> &Surface {
        &self.surface
    }

    /// Draws one frame and presents it.
    ///
    /// `cache` is mutable because uploading a dirty rect CONSUMES it — see
    /// [`slopdesk_termrender::Atlas::take_dirty`]. Nothing else about the cache is touched, and no
    /// glyph is ever rasterised here.
    ///
    /// `images` is the store `list.image_runs` names by id. Passed BESIDE the draw list rather than
    /// inside it because a `DrawList` is rebuilt every frame and an image store is not: the pixels
    /// survive across frames and the instances do not, which is the same split `cache` already has.
    ///
    /// `background` is the pass's clear colour, and clearing to it is why `quad.rs` may drop a rect
    /// that matches: a terminal's commonest cell is a space on the default background, and the
    /// cheapest way to paint ten thousand of them is a load action.
    ///
    /// # Errors
    ///
    /// Every arm of [`MetalError`] a frame can reach: [`MetalError::Allocation`] if the device
    /// refuses a buffer or a texture, [`MetalError::NoDrawable`] if the surface is not on screen,
    /// and [`MetalError::NoCommandBuffer`] if the queue refuses one. All three are worth skipping a
    /// frame over and retrying on the next.
    pub fn draw(
        &mut self,
        list: &DrawList,
        cache: &mut GlyphCache,
        images: &ImageStore,
        background: Rgba,
    ) -> Result<(), MetalError> {
        let size = self.surface.drawable_size();
        let viewport = Viewport {
            width: narrow(size.width),
            height: narrow(size.height),
        };
        if viewport.is_degenerate() {
            // A collapsed split or a window mid-resize. Not an error — there is simply nowhere to
            // draw, and the next frame will have somewhere.
            return Ok(());
        }

        // Atlases first, and before the semaphore. An upload is a CPU write into shared memory with
        // no command buffer involved, so it neither needs a slot nor should hold one; doing it here
        // also means the textures are current before anything binds them.
        let (alpha, color) = cache.atlases_mut();
        self.coverage.sync(&self.device, alpha)?;
        self.colored.sync(&self.device, color)?;
        self.images.sync(&self.device, images)?;

        // The slot is borrowed out of the ring for exactly as long as the encode, which is why the
        // fill and the encode are two calls rather than one method on `Renderer`: `Filled` holds
        // three references INTO the slot, and Rust's borrow checker is what proves no other frame
        // can touch those buffers while an encoder reads them. The semaphore proves the same thing
        // about the GPU; between them there is no window.
        let Some(slot) = self.ring.acquire() else {
            return Err(MetalError::Allocation);
        };
        let filled = match slot.fill(&self.device, list) {
            Ok(filled) => filled,
            Err(error) => {
                self.ring.release();
                return Err(error);
            },
        };

        let gpu = Gpu {
            queue: &self.queue,
            surface: &self.surface,
            pipelines: &self.pipelines,
            coverage: &self.coverage,
            colored: &self.colored,
            images: &self.images,
        };
        match encode(gpu, viewport, background, list.image_runs.as_slice(), filled) {
            Ok(command_buffer) => {
                self.ring.release_on_completion(&command_buffer);
                command_buffer.commit();
                Ok(())
            },
            Err(error) => {
                // The slot was taken and no GPU work will ever give it back. Three of these without
                // this line and the renderer blocks forever on a semaphore nothing will signal.
                self.ring.release();
                Err(error)
            },
        }
    }
}

/// The renderer's long-lived GPU objects, borrowed for one encode.
///
/// A borrow struct rather than five parameters: the whole set travels together, `Renderer::draw`
/// holds a `&mut` slot across the call so nothing here may reach `&mut self`, and threading them
/// individually is how a signature grows past what a reader can hold.
#[derive(Debug, Clone, Copy)]
struct Gpu<'a> {
    queue: &'a ProtocolObject<dyn MTLCommandQueue>,
    surface: &'a Surface,
    pipelines: &'a Pipelines,
    coverage: &'a AtlasTexture,
    colored: &'a AtlasTexture,
    images: &'a ImageTextures,
}

/// Everything between a drawable and a committed command buffer.
///
/// A free function rather than a method so the semaphore's acquire and release stay visible in one
/// place: [`Renderer::draw`] holds the slot borrow across this call, so nothing here may reach
/// `&mut self`. Every path out is either a command buffer to hang the release on, or an error.
fn encode(
    gpu: Gpu<'_>,
    viewport: Viewport,
    background: Rgba,
    runs: &[ImageRun],
    filled: Filled<'_>,
) -> Result<Retained<ProtocolObject<dyn MTLCommandBuffer>>, MetalError> {
    let drawable = gpu.surface.next_drawable()?;
    let command_buffer = gpu.queue.commandBuffer().ok_or(MetalError::NoCommandBuffer)?;

    let descriptor = render_pass(&drawable.texture(), background);
    let Some(encoder) = command_buffer.renderCommandEncoderWithDescriptor(&descriptor) else {
        // No encoder means nothing was encoded, so the command buffer may simply be dropped — an
        // uncommitted `MTLCommandBuffer` releases its resources on deallocation.
        return Err(MetalError::NoCommandBuffer);
    };

    let images = Images {
        buffer: filled.images,
        runs,
    };
    encode_images(&encoder, viewport, images, ImageLayer::BelowBackground, gpu);
    encode_rects(&encoder, viewport, filled.backgrounds, &gpu.pipelines.rect);
    encode_images(&encoder, viewport, images, ImageLayer::BelowText, gpu);
    // Underlines and overlines UNDER the glyphs, the way ghostty layers them, so a descender
    // crosses the line rather than being cut out of it. Strikethroughs and non-block cursors stay
    // in the overlay pass below, drawn OVER the text.
    encode_rects(&encoder, viewport, filled.underlines, &gpu.pipelines.rect);
    encode_glyphs(&encoder, viewport, filled.glyphs, gpu);
    encode_images(&encoder, viewport, images, ImageLayer::AboveText, gpu);
    encode_rects(&encoder, viewport, filled.overlays, &gpu.pipelines.rect);

    // The pinned head, over everything — its bed, its text, its hairline, in the same order the six
    // passes above put a background under a glyph under an overlay. This is the whole of what
    // replaces a scissor rect: the band cannot be CLIPPED, so `slopdesk_termrender::pin` keeps it
    // inside the content box and the z ordering is what puts it on top. Three no-op calls on every
    // frame that has no head, which is most of them — `encode_rects` and `encode_glyphs` both
    // return on a `None` buffer, and a slot with no pinned instances never allocates one.
    encode_rects(&encoder, viewport, filled.pinned_backgrounds, &gpu.pipelines.rect);
    encode_rects(&encoder, viewport, filled.pinned_underlines, &gpu.pipelines.rect);
    encode_glyphs(&encoder, viewport, filled.pinned_glyphs, gpu);
    encode_rects(&encoder, viewport, filled.pinned_overlays, &gpu.pipelines.rect);

    encoder.endEncoding();
    command_buffer.presentDrawable(ProtocolObject::from_ref(&*drawable));
    Ok(command_buffer)
}

/// One rect pass — backgrounds or overlays, the same pipeline both times.
fn encode_rects(
    encoder: &ProtocolObject<dyn MTLRenderCommandEncoder>,
    viewport: Viewport,
    instances: Option<Bound<'_>>,
    pipeline: &ProtocolObject<dyn MTLRenderPipelineState>,
) {
    let Some(bound) = instances.filter(|bound| bound.count > 0) else {
        return;
    };
    encoder.setRenderPipelineState(pipeline);
    bind(encoder, bound.buffer, viewport);
    // `bound.count`, this frame's own tally — never `instance_count`, which is the buffer's
    // capacity and would draw whatever an earlier, larger frame left in the slot.
    draw_instances(encoder, clamped(bound, size_of::<RectInstance>()));
}

/// The glyph pass, with both atlases bound.
///
/// Both, unconditionally, even for a frame with no emoji in it. `shaders.metal`'s glyph fragment
/// shader BRANCHES on `colorAtlas` rather than being two shaders, and Metal validates every texture
/// a shader references as bound whether the branch is taken or not. Two binds a frame is nothing;
/// two pipelines and a sort of the glyph list by atlas would be a real cost for the same picture.
fn encode_glyphs(
    encoder: &ProtocolObject<dyn MTLRenderCommandEncoder>,
    viewport: Viewport,
    instances: Option<Bound<'_>>,
    gpu: Gpu<'_>,
) {
    let (Some(bound), Some(coverage), Some(colored)) = (
        instances.filter(|bound| bound.count > 0),
        gpu.coverage.texture(),
        gpu.colored.texture(),
    ) else {
        return;
    };
    encoder.setRenderPipelineState(&gpu.pipelines.glyph);
    bind(encoder, bound.buffer, viewport);

    // # Safety
    //
    // `setFragmentTexture:atIndex:` is generated `unsafe` because Metal does not bounds-check the
    // slot. The framework rule is that the index must be one the fragment function declares:
    // `glyph_fragment` in `shaders.metal` declares `[[texture(0)]]` and `[[texture(1)]]`, and these
    // are those two constants. Both textures are alive for the encode — this crate owns them and
    // nothing here can drop them before `endEncoding`.
    #[expect(
        unsafe_code,
        reason = "setFragmentTexture:atIndex: is an unchecked slot; both slots are declared by \
                  glyph_fragment"
    )]
    unsafe {
        encoder.setFragmentTexture_atIndex(Some(coverage), COVERAGE_TEXTURE);
        encoder.setFragmentTexture_atIndex(Some(colored), COLOR_TEXTURE);
    }

    draw_instances(encoder, clamped(bound, size_of::<GlyphInstance>()));
}

/// One frame's images: the instances, and the runs that index them.
///
/// The pair travels together and is `Copy`, so all three passes read the same two values and none
/// of them can be given one without the other.
#[derive(Debug, Clone, Copy)]
struct Images<'a> {
    buffer: Option<Bound<'a>>,
    runs: &'a [ImageRun],
}

/// One image layer's draws — one per run, each with its own texture bound.
///
/// A draw call per run rather than a texture array or an argument buffer, and it is not a
/// compromise: a frame with images has a handful of them, the runs are already coalesced by
/// `DrawList::push_image`, and the alternative costs a residency set to maintain plus a
/// per-instance index in the vertex struct — machinery for a count that is never large. If a
/// session ever does place hundreds of distinct images at once, the answer is `MTLArgumentEncoder`,
/// and it is a change to this function and `image_fragment` and nothing else.
///
/// The whole pass returns before it touches the encoder when no run matches, which is what keeps an
/// image-free frame exactly as cheap as it was before this existed.
fn encode_images(
    encoder: &ProtocolObject<dyn MTLRenderCommandEncoder>,
    viewport: Viewport,
    images: Images<'_>,
    layer: ImageLayer,
    gpu: Gpu<'_>,
) {
    let Some(image_buffer) = images.buffer else {
        return;
    };
    // The count this frame wrote, not the buffer's capacity: a run past it would mean `quad.rs`
    // and this function disagree about the same `Vec`, and a stale run from a larger frame is
    // exactly what the count guards against.
    let capacity = clamped(image_buffer, size_of::<ImageInstance>());
    let mut set = false;

    for run in images.runs.iter().filter(|run| run.layer == layer) {
        // A run whose texture has not arrived yet is SKIPPED rather than drawn untextured.
        // `image.rs` already drops a placement whose pixels the store lacks, so this is the second
        // half of the same rule and covers the frame where an upload failed for want of memory.
        let Some(texture) = gpu.images.texture(run.image) else {
            continue;
        };
        let (Ok(first), Ok(count)) = (usize::try_from(run.first), usize::try_from(run.count)) else {
            continue;
        };
        // The bound the safety note on `draw_run` leans on: every instance this run names has to be
        // inside the buffer that was actually allocated. `first + count` cannot wrap, and a run
        // past the end would mean `quad.rs` and this function disagree about the same
        // `Vec`.
        if count == 0 || first.saturating_add(count) > capacity {
            continue;
        }

        if !set {
            // Once per LAYER, not once per run: the pipeline and the instance buffer are the same
            // for every run in a pass, and only the texture changes.
            encoder.setRenderPipelineState(&gpu.pipelines.image);
            bind(encoder, image_buffer.buffer, viewport);
            set = true;
        }

        // # Safety
        //
        // The same Metal rule `encode_glyphs` discharges: `setFragmentTexture:atIndex:` is an
        // unchecked slot, and `image_fragment` in `shaders.metal` declares exactly
        // `[[texture(0)]]`, which is `COVERAGE_TEXTURE`. The texture is alive for the
        // encode — `gpu.images` owns it and `Renderer::draw` holds `&self` across this
        // call, so nothing can drop it before `endEncoding`.
        #[expect(
            unsafe_code,
            reason = "setFragmentTexture:atIndex: is an unchecked slot; slot 0 is the only one \
                      image_fragment declares"
        )]
        unsafe {
            encoder.setFragmentTexture_atIndex(Some(texture), COVERAGE_TEXTURE);
        }

        draw_run(encoder, first, count);
    }
}

/// The render pass descriptor for one frame.
///
/// `Clear` on load and `Store` on store, which is the pair worth arguing. Clearing rather than
/// loading is FASTER on tile hardware, not slower: a `Load` would drag the previous frame's
/// contents from memory into tile memory before the first fragment, and this renderer overwrites
/// every pixel it cares about anyway. `Store` because the drawable is what gets presented;
/// `DontCare` there would present whatever the compositor last had.
fn render_pass(
    texture: &ProtocolObject<dyn MTLTexture>,
    background: Rgba,
) -> Retained<MTLRenderPassDescriptor> {
    let descriptor = MTLRenderPassDescriptor::new();

    // # Safety
    //
    // The same Metal rule `pipeline.rs` names on the other side of the pair: `colorAttachments` is
    // indexed by attachment slot and the binding is `unsafe` because Objective-C's subscript is not
    // bounds-checked. Slot 0 exists on every render pass descriptor, and it is the slot
    // `pipeline.rs` gave the pixel format to — a pass and a pipeline that disagreed about the slot
    // would be a validation failure at encode time.
    #[expect(
        unsafe_code,
        reason = "objectAtIndexedSubscript: is an unchecked ObjC subscript; slot 0 is Metal's own"
    )]
    let attachment = unsafe { descriptor.colorAttachments().objectAtIndexedSubscript(0) };

    attachment.setTexture(Some(texture));
    attachment.setLoadAction(MTLLoadAction::Clear);
    attachment.setStoreAction(MTLStoreAction::Store);
    attachment.setClearColor(clear_color(background));
    descriptor
}

/// A `Rgba` as the `f64` clear colour Metal wants, PREMULTIPLIED.
///
/// Premultiplied because the pipelines blend `One / OneMinusSourceAlpha` and the clear value is the
/// destination those blends start from — a straight-alpha clear would make every subsequent blend
/// start from a colour that is too bright by `1/alpha`. `surface.rs` sets the layer opaque, so
/// alpha is one in practice and the multiply is a no-op; it is written out because "in practice"
/// stops being true the day someone wants a translucent pane, and the bug that day would be
/// invisible.
///
/// The divide by 255 and the multiply stay separate statements — `CLAUDE.md`'s bit-exactness rule.
fn clear_color(color: Rgba) -> MTLClearColor {
    let alpha = f64::from(color.a) / 255.0;
    let red = f64::from(color.r) / 255.0;
    let green = f64::from(color.g) / 255.0;
    let blue = f64::from(color.b) / 255.0;
    MTLClearColor {
        red: red * alpha,
        green: green * alpha,
        blue: blue * alpha,
        alpha,
    }
}

/// Binds the instance buffer and the per-frame viewport uniform.
fn bind(
    encoder: &ProtocolObject<dyn MTLRenderCommandEncoder>,
    buffer: &ProtocolObject<dyn MTLBuffer>,
    viewport: Viewport,
) {
    // # Safety
    //
    // Two rules, both Metal's. `setVertexBuffer:offset:atIndex:` requires the index to be one the
    // vertex function declares and the offset to be inside the buffer: both shaders declare
    // `[[buffer(0)]]` and `[[buffer(1)]]`, and the offset is zero. `setVertexBytes:length:atIndex:`
    // requires the length to be under 4 KiB and the pointer to be readable for that length — a
    // `Viewport` is eight bytes and the reference is to a local that outlives the call, which
    // copies eagerly. Nothing borrowed survives the statement.
    #[expect(
        unsafe_code,
        reason = "the vertex-binding setters take an unchecked slot and a bare pointer; both slots are \
                  declared by the shaders"
    )]
    unsafe {
        encoder.setVertexBuffer_offset_atIndex(Some(buffer), 0, INSTANCE_INDEX);
        encoder.setVertexBytes_length_atIndex(
            core::ptr::NonNull::from(&viewport).cast::<core::ffi::c_void>(),
            size_of::<Viewport>(),
            VIEWPORT_INDEX,
        );
    }
}

/// The one draw call shape this crate issues.
fn draw_instances(encoder: &ProtocolObject<dyn MTLRenderCommandEncoder>, count: usize) {
    // # Safety
    //
    // `drawPrimitives:vertexStart:vertexCount:instanceCount:` is generated `unsafe` because Metal
    // validates the counts against the bound buffers only in a debug device. The framework rule is
    // that every vertex and instance the call names must be addressable in what is bound: four
    // vertices come from `vertex_id` arithmetic and address no buffer at all, and `count` is
    // `clamped` to the bound buffer's own `length()` at the call site, so the last instance read is
    // inside the allocation whether the frame's tally or the capacity is smaller.
    #[expect(
        unsafe_code,
        reason = "drawPrimitives: counts are validated only by a debug device; count comes from the bound \
                  buffer's length"
    )]
    unsafe {
        encoder.drawPrimitives_vertexStart_vertexCount_instanceCount(
            MTLPrimitiveType::TriangleStrip,
            0,
            QUAD_VERTICES,
            count,
        );
    }
}

/// One run's instances, starting partway into the bound buffer.
///
/// The `baseInstance` sibling of [`draw_instances`], and the reason images need it while nothing
/// else does: three z layers share ONE instance buffer, so a pass draws a SLICE of it rather than
/// all of it. Metal's own way of expressing that without four buffers or four binds.
fn draw_run(encoder: &ProtocolObject<dyn MTLRenderCommandEncoder>, first: usize, count: usize) {
    // # Safety
    //
    // `drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:` carries
    // `drawPrimitives`' own contract plus one term: every instance from `baseInstance` to
    // `baseInstance + count` must be addressable in the bound buffer. `encode_images` checked
    // exactly that against `instance_count`, which reads the bound buffer's own `length()` — so
    // the last instance read is the last one written. The four vertices come from `vertex_id`
    // arithmetic and address no buffer at all.
    #[expect(
        unsafe_code,
        reason = "drawPrimitives: counts are validated only by a debug device; the run was bounds-checked \
                  against the bound buffer's length"
    )]
    unsafe {
        encoder.drawPrimitives_vertexStart_vertexCount_instanceCount_baseInstance(
            MTLPrimitiveType::TriangleStrip,
            0,
            QUAD_VERTICES,
            count,
            first,
        );
    }
}

/// How many `T` the buffer holds, from the buffer itself.
///
/// Deriving the count from `length()` rather than carrying the slice's `len()` forward is what
/// makes [`draw_instances`]'s safety note checkable on the line: the number handed to Metal and the
/// number Metal will address come from the same place.
fn instance_count(buffer: &ProtocolObject<dyn MTLBuffer>, instance_size: usize) -> usize {
    // `checked_div` rather than `/`, and the lint that asks for it is right for once: a zero-sized
    // instance type is not reachable through `quad.rs` today, and a panic on the render path would
    // be an odd way to find out that it became so.
    buffer.length().checked_div(instance_size).unwrap_or_default()
}

/// This frame's instance count, clamped to what the buffer can actually address.
///
/// The count is the truth — [`crate::frames::InstanceBuffer::fill`] wrote exactly that many — and
/// the buffer is always at least that long, so the clamp never bites. It is here for the safety
/// note on [`draw_instances`]: the number handed to Metal is provably inside the bound buffer,
/// whichever of the two is smaller.
fn clamped(bound: Bound<'_>, instance_size: usize) -> usize {
    let capacity = instance_count(bound.buffer, instance_size);
    debug_assert!(bound.count <= capacity, "fill wrote past the buffer it grew");
    bound.count.min(capacity)
}

/// A `CGFloat` drawable dimension as the `f32` the shader reads.
#[expect(
    clippy::cast_possible_truncation,
    reason = "a drawable dimension is bounded by the display; f32 carries it exactly, and quad.rs narrows \
              the same way"
)]
const fn narrow(value: f64) -> f32 {
    value as f32
}

#[cfg(test)]
mod tests {
    use slopdesk_termrender::Rgba;

    use super::{
        COLOR_TEXTURE, COVERAGE_TEXTURE, INSTANCE_INDEX, QUAD_VERTICES, VIEWPORT_INDEX, clear_color, narrow,
    };

    #[test]
    fn the_binding_slots_are_the_ones_the_shaders_declare() {
        // `shaders.metal` spells these as `[[buffer(0)]]`, `[[buffer(1)]]`, `[[texture(0)]]` and
        // `[[texture(1)]]`. A mismatch is not a crash — Metal binds nothing and the pass draws
        // garbage or nothing at all — so pinning them from a test is the only cheap check there is.
        assert_eq!(INSTANCE_INDEX, 0);
        assert_eq!(VIEWPORT_INDEX, 1);
        assert_eq!(COVERAGE_TEXTURE, 0);
        assert_eq!(COLOR_TEXTURE, 1);
        assert_eq!(QUAD_VERTICES, 4, "a triangle strip quad is four vertices");
    }

    #[test]
    fn an_opaque_clear_colour_is_its_own_premultiplication() {
        let clear = clear_color(Rgba::opaque(255, 128, 0));
        assert!((clear.red - 1.0).abs() < f64::EPSILON);
        assert!((clear.green - 128.0 / 255.0).abs() < f64::EPSILON);
        assert!((clear.blue - 0.0).abs() < f64::EPSILON);
        assert!((clear.alpha - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn a_translucent_clear_colour_is_premultiplied() {
        // The case `surface.rs`'s opaque layer makes unreachable today and that a translucent pane
        // would reach tomorrow. Half alpha halves every channel, because that is what the blend the
        // pipelines are configured for expects to find in the destination.
        let clear = clear_color(Rgba::opaque(255, 255, 255).with_alpha(128));
        let alpha = 128.0 / 255.0;
        assert!((clear.alpha - alpha).abs() < f64::EPSILON);
        assert!(
            (clear.red - alpha).abs() < f64::EPSILON,
            "white at half alpha is grey, not white"
        );
    }

    #[test]
    fn a_drawable_dimension_narrows_exactly() {
        assert!((narrow(3456.0) - 3456.0_f32).abs() < f32::EPSILON);
        assert!((narrow(0.0) - 0.0_f32).abs() < f32::EPSILON);
    }
}
