//! The shader library and the two pipeline states.
//!
//! ## The decision: compile at RUN TIME, from `include_str!`, and here is the trade
//!
//! The two options are a `build.rs` that shells out to `xcrun -sdk macosx metal` and `metallib` and
//! `include_bytes!`s a `.metallib`, or `newLibraryWithSource:options:error:` on the string. This
//! crate takes the second, and the reason is the SLICE COUNT rather than the startup cost.
//!
//! A `.metallib` is per-SDK. This repo ships three slices — `aarch64-apple-darwin`,
//! `aarch64-apple-ios` and the simulator — so a `build.rs` would have to map the Cargo target to
//! `-sdk macosx` / `-sdk iphoneos` / `-sdk iphonesimulator`, find `xcrun` on a machine where the
//! command-line tools may be selected somewhere other than where Xcode is, invoke two tools, and
//! fail a `cargo build` with a diagnostic nobody would recognise when it could not. That is
//! precisely the shape `docs/68` §3 records deleting: a build script with a toolchain shim in it,
//! under the ruling that "no build recipe is ours to write". Re-introducing one for four shaders
//! would trade a measured problem for an unmeasured one.
//!
//! The cost is a one-shot compile at surface creation — tens of milliseconds, once, on a thread
//! that is already doing device and pipeline creation. It is NOT on the path `docs/68` §6.3 pins:
//! that baseline is key→render-feed and explicitly excludes draw, and it certainly excludes the
//! one-time construction of the thing that draws. A terminal surface is created when a pane opens
//! and lives until it closes.
//!
//! What the choice gives back is worth more than the milliseconds: the shader source is a Rust
//! string constant, so `cargo test` can compile it (see the tests at the bottom of this module) and
//! a syntax error is a test failure with a line number instead of a black pane at run time. With a
//! `build.rs` the same check exists but only for the host slice and only as a build failure, which
//! is strictly less useful and strictly more machinery.
//!
//! If the compile ever DOES show up in a profile, the answer is `MTLBinaryArchive` — cache the
//! compiled pipelines next to the app's support directory and warm from it — not a build script.
//! That is a change to this module and nothing else.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_foundation::{NSError, NSString};
use objc2_metal::{
    MTLBlendFactor, MTLBlendOperation, MTLDevice, MTLFunction, MTLLibrary, MTLRenderPipelineDescriptor,
    MTLRenderPipelineState,
};

use crate::error::MetalError;
use crate::surface::DRAWABLE_FORMAT;

/// The shaders, verbatim. See `shaders.metal`'s own header for what is in them.
const SHADER_SOURCE: &str = include_str!("shaders.metal");

/// The four entry points, named once so a typo is a compile error rather than a run-time `None`.
const RECT_VERTEX: &str = "rect_vertex";
const RECT_FRAGMENT: &str = "rect_fragment";
const GLYPH_VERTEX: &str = "glyph_vertex";
const GLYPH_FRAGMENT: &str = "glyph_fragment";

/// The two states one frame switches between.
#[derive(Debug)]
pub(crate) struct Pipelines {
    /// Backgrounds and overlays — `RectInstance`, five styles, one fragment shader.
    pub(crate) rect: Retained<ProtocolObject<dyn MTLRenderPipelineState>>,
    /// Text — `GlyphInstance`, two atlases, one fragment shader.
    pub(crate) glyph: Retained<ProtocolObject<dyn MTLRenderPipelineState>>,
}

impl Pipelines {
    /// Compiles the shaders and builds both states, or says which step refused.
    pub(crate) fn build(device: &ProtocolObject<dyn MTLDevice>) -> Result<Self, MetalError> {
        let source = NSString::from_str(SHADER_SOURCE);
        let library = device
            .newLibraryWithSource_options_error(&source, None)
            .map_err(|error| MetalError::ShaderCompile(describe(&error)))?;

        let rect_vertex = function(&library, RECT_VERTEX)?;
        let rect_fragment = function(&library, RECT_FRAGMENT)?;
        let glyph_vertex = function(&library, GLYPH_VERTEX)?;
        let glyph_fragment = function(&library, GLYPH_FRAGMENT)?;

        let rect = build_state(device, &rect_vertex, &rect_fragment)?;
        let glyph = build_state(device, &glyph_vertex, &glyph_fragment)?;

        Ok(Self { rect, glyph })
    }
}

/// One entry point out of the compiled library.
fn function(
    library: &ProtocolObject<dyn MTLLibrary>,
    name: &'static str,
) -> Result<Retained<ProtocolObject<dyn MTLFunction>>, MetalError> {
    let key = NSString::from_str(name);
    library
        .newFunctionWithName(&key)
        .ok_or(MetalError::MissingFunction(name))
}

/// One pipeline state, with the blend mode both of them share.
fn build_state(
    device: &ProtocolObject<dyn MTLDevice>,
    vertex: &ProtocolObject<dyn MTLFunction>,
    fragment: &ProtocolObject<dyn MTLFunction>,
) -> Result<Retained<ProtocolObject<dyn MTLRenderPipelineState>>, MetalError> {
    let descriptor = MTLRenderPipelineDescriptor::new();
    descriptor.setVertexFunction(Some(vertex));
    descriptor.setFragmentFunction(Some(fragment));

    // # Safety
    //
    // Metal's rule: a render pipeline descriptor's `colorAttachments` array is indexed by
    // attachment slot, and slot 0 is the one every render pass descriptor in this crate
    // populates. The binding is `unsafe` because Objective-C's subscript is not bounds-checked;
    // the framework's own contract is that slot 0 exists on every descriptor, and `renderer.rs`
    // writes the matching slot 0 on the pass side.
    #[expect(
        unsafe_code,
        reason = "objectAtIndexedSubscript: is an unchecked ObjC subscript; slot 0 is Metal's own"
    )]
    let attachment = unsafe { descriptor.colorAttachments().objectAtIndexedSubscript(0) };

    attachment.setPixelFormat(DRAWABLE_FORMAT);

    // PREMULTIPLIED alpha, and the convention is stated where it is spent. `shaders.metal` returns
    // `rgb` already multiplied by `a` from every fragment shader, and `atlas.rs` documents the
    // colour atlas's texels as premultiplied too — so `One` for the source rather than
    // `SourceAlpha` is not an optimisation, it is the arithmetic being done once instead of
    // twice. The straight-alpha spelling (`SourceAlpha / OneMinusSourceAlpha`) would
    // double-multiply every emoji.
    attachment.setBlendingEnabled(true);
    attachment.setRgbBlendOperation(MTLBlendOperation::Add);
    attachment.setAlphaBlendOperation(MTLBlendOperation::Add);
    attachment.setSourceRGBBlendFactor(MTLBlendFactor::One);
    attachment.setSourceAlphaBlendFactor(MTLBlendFactor::One);
    attachment.setDestinationRGBBlendFactor(MTLBlendFactor::OneMinusSourceAlpha);
    attachment.setDestinationAlphaBlendFactor(MTLBlendFactor::OneMinusSourceAlpha);

    device
        .newRenderPipelineStateWithDescriptor_error(&descriptor)
        .map_err(|error| MetalError::PipelineState(describe(&error)))
}

/// An `NSError` as something a human can read.
fn describe(error: &NSError) -> String {
    error.localizedDescription().to_string()
}

#[cfg(test)]
mod tests {
    use super::{GLYPH_FRAGMENT, GLYPH_VERTEX, RECT_FRAGMENT, RECT_VERTEX, SHADER_SOURCE};

    #[test]
    fn the_source_is_embedded_and_declares_the_four_entry_points() {
        // Cheap, unconditional, and it catches the thing a rename actually breaks: the Rust name
        // and the Metal name are two spellings of one fact, and `newFunctionWithName`
        // answers `None` rather than failing loudly when they part.
        assert!(
            SHADER_SOURCE.len() > 1024,
            "shaders.metal did not make it into the binary"
        );
        for name in [RECT_VERTEX, RECT_FRAGMENT, GLYPH_VERTEX, GLYPH_FRAGMENT] {
            assert!(
                SHADER_SOURCE.contains(name),
                "shaders.metal has no entry point named {name}"
            );
        }
    }

    #[test]
    fn the_shader_source_compiles() {
        // The point of choosing `newLibraryWithSource:` over a `build.rs` (see this module's
        // header) is that the source is a string `cargo test` can reach. This runs the real
        // Metal front end over it, so a syntax error, a bad `static_assert` — the two
        // struct layouts — or a type mistake fails HERE rather than at the first
        // `Renderer::new` on a machine with a GPU.
        //
        // It SKIPS rather than fails where the offline compiler is not installed, and that is not a
        // hypothetical: Xcode 16 unbundled the Metal toolchain into a separately downloaded
        // component, so `xcrun metal` on a stock install answers "cannot execute tool 'metal' due
        // to missing Metal Toolchain". THIS MACHINE is one of them — which is, incidentally, the
        // strongest form of the argument this module's header makes for compiling at run time: a
        // `build.rs` would not have skipped here, it would have failed the whole build.
        //
        // The skip is decided by COMPILING A TRIVIAL SHADER rather than by looking for the binary.
        // `xcrun --find metal` succeeds on this machine and the tool then refuses to run, so a
        // presence check would have reported the toolchain as available and turned a missing
        // component into a red test. Asking the compiler to compile something that cannot fail is
        // the only honest probe.
        let Some(compile) = compiler() else {
            return;
        };
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/shaders.metal");
        let Some(output) = compile(&source) else {
            return;
        };
        assert!(
            output.status.success(),
            "shaders.metal did not compile:\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    /// Runs the offline Metal compiler over one file, or `None` if it could not be invoked.
    fn compile_metal(source: &std::path::Path) -> Option<std::process::Output> {
        std::process::Command::new("xcrun")
            .args(["-sdk", "macosx", "metal", "-x", "metal", "-c", "-o", "/dev/null"])
            .arg(source)
            .output()
            .ok()
    }

    /// The compiler, if this machine has a WORKING one. `None` is a skip, not a failure.
    fn compiler() -> Option<fn(&std::path::Path) -> Option<std::process::Output>> {
        let probe = std::env::temp_dir().join("slopdesk-apple-metal-probe.metal");
        std::fs::write(&probe, "#include <metal_stdlib>\nkernel void probe() {}\n").ok()?;
        let output = compile_metal(&probe);
        drop(std::fs::remove_file(&probe));
        output?.status.success().then_some(compile_metal)
    }
}
