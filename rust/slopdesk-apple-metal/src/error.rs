//! Every way this crate can fail to draw, as a value.
//!
//! The lint block denies `unwrap`, `expect`, `panic` and `panic_in_result_fn`, and that is not
//! decoration here. A Mac with no Metal device, a drawable the compositor refuses because the
//! window is off screen, an atlas that grew past what the device will allocate — all three are
//! ORDINARY on a remote-coding surface that outlives sleep, display changes and a monitor being
//! unplugged. A renderer that panicked on any of them would take the whole client down for a frame
//! it could have simply skipped.
//!
//! So there is no `Option` unwrapped anywhere below this module, and `Renderer::draw` answers
//! `Result<(), MetalError>` whose every arm the caller may reasonably ignore for one frame and
//! retry on the next.

use core::fmt;

/// What went wrong between a [`slopdesk_termrender::DrawList`] and a presented frame.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum MetalError {
    /// `MTLCreateSystemDefaultDevice` answered nothing.
    ///
    /// Not hypothetical: it is what a headless CI runner and a Mac in a sealed VM both answer,
    /// which is exactly why the device-backed tests in this crate SKIP on this arm rather than
    /// failing.
    NoDevice,
    /// The device refused a command queue.
    NoCommandQueue,
    /// The shader source did not compile, with what the compiler said.
    ///
    /// The message is carried rather than logged because this crate has no logger and `docs/57` §2
    /// says it makes no decisions — including the decision about where a diagnostic goes.
    ShaderCompile(String),
    /// A `vertex` or `fragment` entry point named in `pipeline.rs` is not in the compiled library.
    MissingFunction(&'static str),
    /// The device refused a render pipeline state, with what it said.
    PipelineState(String),
    /// The device refused a buffer or a texture allocation.
    ///
    /// An atlas at [`slopdesk_termrender::atlas`]'s 4096 ceiling is 16 MiB of coverage or 64 MiB of
    /// colour, and a device under memory pressure may decline. Recovering is the caller's business
    /// — [`slopdesk_termrender::GlyphCache::clear`] exists for it.
    Allocation,
    /// `nextDrawable` answered nothing.
    ///
    /// The common cause is a window that is off screen or occluded, where `CoreAnimation` has no
    /// drawable to give and never will until it is visible again. Skipping the frame is right; a
    /// blocking retry would stall the render thread against a compositor that is not waiting.
    NoDrawable,
    /// The command queue refused a command buffer.
    NoCommandBuffer,
}

impl fmt::Display for MetalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoDevice => f.write_str("no Metal device on this machine"),
            Self::NoCommandQueue => f.write_str("the Metal device refused a command queue"),
            Self::ShaderCompile(message) => write!(f, "the terminal shaders did not compile: {message}"),
            Self::MissingFunction(name) => write!(f, "the compiled library has no entry point named {name}"),
            Self::PipelineState(message) => write!(f, "the Metal device refused a pipeline state: {message}"),
            Self::Allocation => f.write_str("the Metal device refused a buffer or texture allocation"),
            Self::NoDrawable => {
                f.write_str("the layer had no drawable — the surface is probably not on screen")
            },
            Self::NoCommandBuffer => f.write_str("the Metal command queue refused a command buffer"),
        }
    }
}

impl core::error::Error for MetalError {}

#[cfg(test)]
mod tests {
    use super::MetalError;

    #[test]
    fn every_arm_says_something_a_reader_can_act_on() {
        let arms = [
            MetalError::NoDevice,
            MetalError::NoCommandQueue,
            MetalError::ShaderCompile("line 4".to_owned()),
            MetalError::MissingFunction("rect_vertex"),
            MetalError::PipelineState("bad blend".to_owned()),
            MetalError::Allocation,
            MetalError::NoDrawable,
            MetalError::NoCommandBuffer,
        ];
        for arm in &arms {
            let rendered = arm.to_string();
            assert!(!rendered.is_empty(), "{arm:?} renders empty");
            assert!(
                rendered.len() > 16,
                "{arm:?} renders too thin to act on: {rendered}"
            );
        }
    }
}
