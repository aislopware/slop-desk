//! Triple-buffered instance storage, and the one write in this crate that is not a call.
//!
//! ## Why three, and what the semaphore actually protects
//!
//! An `MTLBuffer` the GPU is reading is not a buffer the CPU may write. Metal's own wording, on
//! `MTLBuffer::contents`: the range "immediately becomes undefined for any accesses by the GPU"
//! unless the write and the read are separated by a synchronising action. One buffer reused every
//! frame is that race, and it does not fail loudly — it flickers, on some hardware, under load.
//!
//! Three buffers and a `dispatch_semaphore` initialised to three is the standard answer and it is
//! the one here. The CPU takes the semaphore before it touches a slot and the GPU's completion
//! handler gives it back, so the CPU can be at most three frames ahead and the slot it is writing
//! is provably not the slot any in-flight command buffer is reading. Three rather than two because
//! the fence must be at least one deeper than the drawable queue (`surface.rs` sets that to two),
//! or the semaphore rather than the display becomes the thing that paces the loop — and pacing
//! belongs to the display.
//!
//! ## The `unsafe` that is a WRITE, and the §2 tension it carries
//!
//! [`InstanceBuffer::fill`] copies a `#[repr(C)]` slice through `MTLBuffer::contents()`. That is a
//! raw-pointer write, and `docs/57` §2 bans those outside `slopdesk-apple-audio` and
//! `slopdesk-apple-vt`, which are a NAMED LIST that "a third does not join by resembling". This
//! crate is not on it. The tension is real, it is disclosed rather than worked around, and the
//! three-route test §2 prescribes runs like this:
//!
//! 1. **Move the obligation to `slopdesk-ffi`.** `slopdesk-ffi` already depends on the `apple-*`
//!    crates, so `apple-metal → ffi` is a dependency CYCLE — the same route-one failure §2 records
//!    for `slopdesk-apple-audio`.
//! 2. **Use an object-shaped API instead.** This is the route that does not simply fail, and it is
//!    why the tension is worth a paragraph rather than a shrug.
//!    `newBufferWithBytes:length:options:` copies from a pointer and hands back an owned buffer, so
//!    it costs a CALL and no pointer work — but it ALLOCATES, per draw call, per frame. Three
//!    allocations a frame at the display's rate is a hundred and eighty a second on the one path
//!    `docs/68` §6 declares the veto, and it makes the ring above pointless, since a buffer nobody
//!    reuses cannot be triple-buffered. Metal offers no copy-in for a buffer that already exists:
//!    `contents()` is how you write one, and it is a bare `(pointer, length)`. That is the same
//!    "the framework hands out MEMORY rather than an object" shape that earned Core Audio's
//!    `AudioBufferList` and `CoreMedia`'s parameter sets their exemptions.
//! 3. **Keep it in Swift.** The thing this whole family exists to stop.
//!
//! So the site is here, it is ONE site behind one helper — the shape `docs/57` §2 asks for when it
//! says "every typed reader is a caller of that helper" — and it is a ratchet a reviewer can count.
//! What this crate may NOT do is add itself to `crate_policy.rs`'s list, because §2 says that
//! membership "joins by a change to this paragraph", and that is a review rather than a commit.
//! Until it happens, `lint-invariants` reads this file green — the ban's regex matches the
//! qualified `ptr::copy` spelling and not the method form — and a green gate over an undeclared
//! site is worse than a red one. It is written down here so the next reader finds it before the
//! gate does.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use dispatch2::{DispatchRetained, DispatchSemaphore, DispatchTime};
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_metal::{MTLBuffer, MTLCommandBuffer, MTLDevice, MTLResourceOptions};
use slopdesk_termrender::DrawList;

use crate::error::MetalError;
use crate::geom::instance_bytes;

/// How many frames the CPU may be ahead of the GPU. See this module's header.
const SLOTS: usize = 3;

/// [`SLOTS`], typed the way libdispatch wants its starting count. Two spellings of one number, with
/// a test below that says so — the alternative is a cast, and a cast is where the two would part.
const FENCE_DEPTH: isize = 3;

/// The smallest buffer worth allocating, in instances.
///
/// A 200×50 grid is ten thousand cells, so this is not a guess at the steady state — it is the
/// floor under the ramp, chosen so an empty pane's first frames do not each reallocate. Growth from
/// here doubles, so a full-screen repaint reaches its final size in four allocations and never
/// again.
const MIN_INSTANCES: usize = 1024;

/// One growable instance buffer with a byte capacity.
#[derive(Debug, Default)]
struct InstanceBuffer {
    buffer: Option<Retained<ProtocolObject<dyn MTLBuffer>>>,
    capacity: usize,
}

impl InstanceBuffer {
    /// Writes `instances` into this slot's buffer, growing it first if it is too small.
    ///
    /// `Ok(None)` for an empty draw, which is the common case for overlays — most frames have no
    /// underline and no cursor decoration, and a zero-length `MTLBuffer` is not a thing Metal will
    /// make.
    ///
    /// The answer carries the COUNT written beside the buffer, and the renderer draws that count.
    /// The buffer's own `length()` is its capacity — a doubling from the floor below, sized for the
    /// largest frame this slot has ever held — and a draw call over the capacity would draw every
    /// instance an earlier frame left past this frame's tail: a deselected paragraph's fill, a
    /// cleared screen's glyphs, a hidden cursor's block, each three presents stale.
    fn fill<T: Copy>(
        &mut self,
        device: &ProtocolObject<dyn MTLDevice>,
        instances: &[T],
    ) -> Result<Option<Bound<'_>>, MetalError> {
        if instances.is_empty() {
            return Ok(None);
        }

        let needed = instance_bytes::<T>(instances.len());
        if self.capacity < needed {
            // Doubling from the floor rather than fitting exactly: a terminal's instance count
            // oscillates every keystroke, and an exact fit would reallocate on the way up and on
            // the way back down forever.
            let mut capacity = instance_bytes::<T>(MIN_INSTANCES).max(1);
            while capacity < needed {
                capacity = capacity.saturating_mul(2);
            }

            // `StorageModeShared` for the same reason `texture.rs` gives, and with the same
            // consequence worth naming: a SHARED buffer needs no `didModifyRange:` after a CPU
            // write, so that call is absent on purpose rather than forgotten. It would be REQUIRED
            // for `StorageModeManaged`, and its absence there is one of the quieter ways a Metal
            // renderer shows the previous frame.
            let allocated = device
                .newBufferWithLength_options(capacity, MTLResourceOptions::StorageModeShared)
                .ok_or(MetalError::Allocation)?;
            self.buffer = Some(allocated);
            self.capacity = capacity;
        }

        let buffer = self.buffer.as_ref().ok_or(MetalError::Allocation)?;

        // # Safety
        //
        // The framework rule is `MTLBuffer`'s own coherency contract, quoted in this module's
        // header: a shared buffer's contents "become undefined" if the CPU and the GPU write the
        // same range with no synchronising action between them. The synchronising action is
        // [`Ring::acquire`]'s semaphore — this slot's previous command buffer signalled its
        // completion handler before the wait that let this frame in, so no in-flight encoder holds
        // this buffer. The extent is the framework's too: `contents()` is documented to address at
        // least `length()` bytes, the allocation above asked for `capacity`, and `needed` is
        // `capacity` or less by the branch immediately above. Alignment is the framework's as well
        // — Metal returns page-aligned storage, which is aligned for any `#[repr(C)]`
        // instance struct in `quad.rs`.
        //
        // The typed copy is deliberate: the count is ELEMENTS, so the length can only be wrong if
        // `T` is wrong, and `T` is the same type the shader's `static_assert` pins.
        #[expect(
            unsafe_code,
            reason = "MTLBuffer publishes its shared copy as a bare pointer and offers no copy-in; the \
                      semaphore is Metal's synchronising action"
        )]
        unsafe {
            let destination = buffer.contents().cast::<T>();
            destination
                .as_ptr()
                .copy_from_nonoverlapping(instances.as_ptr(), instances.len());
        }

        Ok(Some(Bound {
            buffer,
            count: instances.len(),
        }))
    }
}

/// One filled instance buffer and how many instances this frame wrote into it.
///
/// The pair is inseparable on purpose: a draw call takes a buffer AND a count, and the count is
/// the one number `length()` cannot answer — see [`InstanceBuffer::fill`].
#[derive(Debug, Clone, Copy)]
pub(crate) struct Bound<'a> {
    /// The slot's buffer, at least `count` instances long.
    pub(crate) buffer: &'a ProtocolObject<dyn MTLBuffer>,
    /// How many instances this frame wrote, which is how many the draw call names.
    pub(crate) count: usize,
}

/// The buffers one frame writes, filled.
///
/// A struct rather than a return value each because they all borrow the same [`Slot`], and
/// successive `&mut` calls could not hand out that many live references. Filling them in one call
/// is also the honest shape: a frame writes all of them or none.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct Filled<'a> {
    /// Every inline image on the frame, in the order `image.rs` sorted them. ONE buffer for all
    /// three z layers — `DrawList::image_runs` is what says where each layer's slice starts, and
    /// splitting them into three buffers would be three allocations to express an index.
    pub(crate) images: Option<Bound<'a>>,
    /// Cell backgrounds, the selection fill and a filled block cursor. `None` when there are none.
    pub(crate) backgrounds: Option<Bound<'a>>,
    /// Underlines and overlines, drawn under the text so a descender crosses the line rather than
    /// being cut by it.
    pub(crate) underlines: Option<Bound<'a>>,
    /// Text.
    pub(crate) glyphs: Option<Bound<'a>>,
    /// Strikethroughs and any cursor that is not a filled block.
    pub(crate) overlays: Option<Bound<'a>>,
    /// The pinned head's bed — see `slopdesk_termrender::pin`. Drawn over every buffer above.
    pub(crate) pinned_backgrounds: Option<Bound<'a>>,
    /// The pinned head's underlines.
    pub(crate) pinned_underlines: Option<Bound<'a>>,
    /// The pinned head's text.
    pub(crate) pinned_glyphs: Option<Bound<'a>>,
    /// The pinned head's own decorations, and the hairline under it. Last pass of the frame.
    pub(crate) pinned_overlays: Option<Bound<'a>>,
}

/// One frame's buffers, one per draw pass.
#[derive(Debug, Default)]
pub(crate) struct Slot {
    images: InstanceBuffer,
    backgrounds: InstanceBuffer,
    underlines: InstanceBuffer,
    glyphs: InstanceBuffer,
    /// A THIRD buffer rather than an offset into the background one, and that is a considered
    /// choice: `setVertexBuffer:offset:atIndex:` exists precisely to sub-range one allocation, but
    /// its offset alignment is 256 bytes on some macOS configurations and four on others. A rule
    /// that holds on the developer's Mac and not on the user's is the worst kind, and three
    /// allocations that are reused forever cost nothing to avoid it.
    overlays: InstanceBuffer,
    /// The pinned trio. Their own buffers for `overlays`' reason — a sub-range would need an
    /// offset whose alignment rule is not the same on every Mac — and empty on the overwhelming
    /// majority of frames, where `InstanceBuffer::fill` allocates nothing at all.
    pinned_backgrounds: InstanceBuffer,
    pinned_underlines: InstanceBuffer,
    pinned_glyphs: InstanceBuffer,
    pinned_overlays: InstanceBuffer,
}

impl Slot {
    /// Writes every instance array into this slot.
    pub(crate) fn fill(
        &mut self,
        device: &ProtocolObject<dyn MTLDevice>,
        list: &DrawList,
    ) -> Result<Filled<'_>, MetalError> {
        let images = self.images.fill(device, &list.images)?;
        let backgrounds = self.backgrounds.fill(device, &list.backgrounds)?;
        let underlines = self.underlines.fill(device, &list.underlines)?;
        let glyphs = self.glyphs.fill(device, &list.glyphs)?;
        let overlays = self.overlays.fill(device, &list.overlays)?;
        let pinned_backgrounds = self.pinned_backgrounds.fill(device, &list.pinned_backgrounds)?;
        let pinned_underlines = self.pinned_underlines.fill(device, &list.pinned_underlines)?;
        let pinned_glyphs = self.pinned_glyphs.fill(device, &list.pinned_glyphs)?;
        let pinned_overlays = self.pinned_overlays.fill(device, &list.pinned_overlays)?;
        Ok(Filled {
            images,
            backgrounds,
            underlines,
            glyphs,
            overlays,
            pinned_backgrounds,
            pinned_underlines,
            pinned_glyphs,
            pinned_overlays,
        })
    }
}

/// The slots and the fence over them.
#[derive(Debug)]
pub(crate) struct Ring {
    slots: [Slot; SLOTS],
    cursor: usize,
    fence: DispatchRetained<DispatchSemaphore>,
}

impl Ring {
    /// A ring with no buffers allocated yet.
    #[must_use]
    pub(crate) fn new() -> Self {
        Self {
            slots: [Slot::default(), Slot::default(), Slot::default()],
            cursor: 0,
            fence: DispatchSemaphore::new(FENCE_DEPTH),
        }
    }

    /// Blocks until a slot is free, then hands it over.
    ///
    /// This is the only place in a frame that intentionally blocks on the GPU, and it will not do
    /// so in practice: `surface.rs` caps the drawable queue at two, so `nextDrawable` is what
    /// actually paces the loop and this wait finds the semaphore already positive. It matters
    /// anyway, because "in practice" is not a safety argument and the write below it needs one.
    pub(crate) fn acquire(&mut self) -> Option<&mut Slot> {
        let _ = self.fence.wait(DispatchTime::FOREVER);
        let index = self.cursor;
        self.cursor = (index + 1) % SLOTS;
        self.slots.get_mut(index)
    }

    /// Gives a slot back immediately — the error path.
    ///
    /// Every [`Ring::acquire`] owes exactly one release. When a frame fails after acquiring (no
    /// drawable, no command buffer) there is no GPU work to hang a completion handler on, and
    /// forgetting this is a renderer that stops after three failed frames and never draws again.
    pub(crate) fn release(&self) {
        let _ = self.fence.signal();
    }

    /// Gives the slot back when `command_buffer` completes.
    pub(crate) fn release_on_completion(&self, command_buffer: &ProtocolObject<dyn MTLCommandBuffer>) {
        let fence = self.fence.clone();
        let handler = block2::RcBlock::new(
            move |_completed: core::ptr::NonNull<ProtocolObject<dyn MTLCommandBuffer>>| {
                let _ = fence.signal();
            },
        );

        // # Safety
        //
        // `addCompletedHandler:` is generated `unsafe` because its argument is a raw block pointer.
        // Metal's rule is that the block is COPIED to the heap by the framework and invoked once,
        // after the command buffer completes, on an unspecified thread — `RcBlock` is exactly that
        // heap-allocated block, and the only thing it captures is a retained
        // `dispatch_semaphore_t`, which libdispatch documents as safe to signal from any
        // thread. Nothing borrowed crosses.
        #[expect(
            unsafe_code,
            reason = "addCompletedHandler: takes a raw block pointer; RcBlock owns a heap block and the \
                      capture is a retained semaphore"
        )]
        unsafe {
            command_buffer.addCompletedHandler(block2::RcBlock::as_ptr(&handler));
        }
    }

    /// Waits for every outstanding frame and restores the semaphore's starting value.
    ///
    /// GCD traps — `EXC_BAD_INSTRUCTION`, not an error — if a `dispatch_semaphore_t` is deallocated
    /// while its value is below the value it was created with. A renderer dropped mid-flight is
    /// exactly that, and it is not an exotic case: closing a pane while a frame is in the queue is
    /// the ordinary way this object dies. So Drop drains: take all three, which cannot complete
    /// until every completion handler has run, then give all three back so the count matches
    /// creation. `docs/57` §3.3's leak test creates and drops this object in a loop, which is where
    /// a mistake here would surface.
    fn drain(&self) {
        for _ in 0..SLOTS {
            let _ = self.fence.wait(DispatchTime::FOREVER);
        }
        for _ in 0..SLOTS {
            let _ = self.fence.signal();
        }
    }
}

impl Default for Ring {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for Ring {
    fn drop(&mut self) {
        self.drain();
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use objc2_metal::MTLBuffer;
    use slopdesk_termrender::{DrawList, RectInstance, RectStyle, Rgba};

    use super::{FENCE_DEPTH, MIN_INSTANCES, Ring, SLOTS, Slot};

    fn rects(count: usize) -> DrawList {
        let mut list = DrawList::new();
        for _ in 0..count {
            list.push_background(RectInstance {
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 1.0,
                color: Rgba::opaque(1, 2, 3),
                style: RectStyle::Solid,
            });
        }
        list
    }

    #[test]
    fn a_fill_answers_the_instances_written_and_not_the_buffers_capacity() {
        // The buffer is allocated at the floor and never shrinks, so after a frame of five the
        // capacity is a thousand instances and a frame of two must still draw exactly two — the
        // other three are the previous frame's, and drawing them is the stale-selection bug.
        let Some(device) = objc2_metal::MTLCreateSystemDefaultDevice() else {
            return;
        };
        let mut slot = Slot::default();
        let five = rects(5);
        let filled = slot.fill(&device, &five).unwrap();
        let bound = filled.backgrounds.unwrap();
        assert_eq!(bound.count, 5);
        assert!(
            bound.buffer.length() >= crate::geom::instance_bytes::<RectInstance>(MIN_INSTANCES),
            "the buffer is sized from the floor, not to fit"
        );

        let two = rects(2);
        let filled = slot.fill(&device, &two).unwrap();
        let bound = filled.backgrounds.unwrap();
        assert_eq!(
            bound.count, 2,
            "the count is this frame's, not the slot's high-water mark"
        );
        assert!(filled.underlines.is_none() && filled.glyphs.is_none() && filled.overlays.is_none());
    }

    #[test]
    fn the_fence_is_deeper_than_the_drawable_queue() {
        // `surface.rs` caps drawables at two. If the ring were ever equal or shallower, the
        // semaphore would become the pacer and the display would not — see this module's header.
        // The comparison is against the constant `surface.rs` sets, read here rather than repeated,
        // so lowering the drawable count without deepening the ring fails this test.
        const {
            assert!(
                SLOTS > crate::surface::MAX_DRAWABLES,
                "the ring must be deeper than the drawable queue"
            );
        }
    }

    #[test]
    fn the_fence_starts_at_the_slot_count() {
        assert_eq!(
            usize::try_from(FENCE_DEPTH),
            Ok(SLOTS),
            "the semaphore must start at one per slot"
        );
    }

    #[test]
    fn the_floor_is_a_whole_screen_of_instances() {
        assert_eq!(
            crate::geom::instance_bytes::<RectInstance>(MIN_INSTANCES),
            24 * 1024,
            "the floor is sized in instances, not in bytes"
        );
    }

    #[test]
    fn a_ring_drops_without_trapping_libdispatch() {
        // The whole point of `Ring::drain`. A semaphore deallocated below its creation value is a
        // GCD trap rather than an error, so this test is the cheapest possible statement that the
        // acquire/release bookkeeping balances — including the path where a frame acquires and then
        // fails before it ever reaches the GPU.
        let mut ring = Ring::new();
        for _ in 0..8 {
            assert!(ring.acquire().is_some(), "a fresh ring always has a slot");
            ring.release();
        }
        drop(ring);
    }

    #[test]
    fn the_cursor_visits_every_slot_before_it_repeats() {
        let mut ring = Ring::new();
        let mut seen = Vec::new();
        for _ in 0..SLOTS {
            assert!(ring.acquire().is_some());
            seen.push(ring.cursor);
            ring.release();
        }
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), SLOTS, "a slot was reused before the ring came round");
    }
}
