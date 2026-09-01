//! The tests that need a real Metal device, and the leak test `docs/57` §3.3 demands.
//!
//! Every one of them SKIPS rather than fails when there is no device. That is not laxity: a
//! headless CI runner and a sealed VM both answer `None` from `MTLCreateSystemDefaultDevice`, and a
//! test suite that failed there would be a test of the runner rather than of the crate. The pure
//! half of this crate — the coordinate conversion, the buffer sizing, the dirty-rect arithmetic and
//! the generation rule — is in `src/geom.rs`'s unit tests and runs unconditionally, which is where
//! the arithmetic a reviewer would actually doubt is pinned.
//!
//! What is left for THIS file is the questions no arithmetic can answer: does the Metal front end
//! accept `shaders.metal`, do all three pipeline states build against the drawable's pixel format,
//! and does the whole object create and drop without climbing.

#![cfg(target_os = "macos")]
#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "an integration test's assertions are its failure mode; the lint block is for the library"
)]

use slopdesk_apple_metal::Renderer;

/// A renderer, or a skip. `None` means this machine has no GPU to ask.
fn renderer() -> Option<Renderer> {
    match Renderer::new() {
        Ok(renderer) => Some(renderer),
        Err(slopdesk_apple_metal::MetalError::NoDevice) => None,
        Err(other) => panic!("a machine WITH a device refused to build the renderer: {other}"),
    }
}

#[test]
fn the_shaders_compile_and_every_pipeline_builds() {
    // `Renderer::new` compiles `shaders.metal` through the real Metal front end and builds all
    // three pipeline states against `DRAWABLE_FORMAT`. So this one line covers the shader
    // source, the four `static_assert`s in it, all six entry-point names, the `constexpr
    // sampler` baked into `image_fragment`, and the blend configuration — anything wrong in any
    // of them is a `ShaderCompile`, `MissingFunction` or `PipelineState` here rather than a
    // black pane at run time.
    let Some(renderer) = renderer() else {
        return;
    };
    assert!(renderer.surface().drawable_size().width >= 0.0);
}

#[test]
fn a_layer_takes_the_size_it_is_given_in_device_pixels() {
    let Some(renderer) = renderer() else {
        return;
    };
    let surface = renderer.surface();

    surface.set_size(800.0, 600.0, 2.0);
    let size = surface.drawable_size();
    assert!(
        (size.width - 1600.0).abs() < f64::EPSILON,
        "points times scale, in texels"
    );
    assert!((size.height - 1200.0).abs() < f64::EPSILON);

    // A scale below one is not a thing `CoreAnimation` has, and clamping it here is what stops a
    // bad reading of `backingScaleFactor` on a disconnected display from collapsing the
    // drawable.
    surface.set_size(800.0, 600.0, 0.0);
    let clamped = surface.drawable_size();
    assert!(
        (clamped.width - 800.0).abs() < f64::EPSILON,
        "a sub-unit scale clamps to 1"
    );
}

#[test]
fn creating_and_dropping_the_renderer_does_not_climb() {
    // `docs/57` §3.3's leak test. The risk it covers is the generated bindings' reference counting:
    // a `Retained` this crate takes and never gives back, a `dispatch_semaphore_t` deallocated
    // below its creation value, or a completion-handler block that captures the ring and keeps
    // it alive.
    //
    // The renderer is the crate's central object and it holds every other one — device, queue,
    // layer, three pipeline states, three slots of buffers, two atlas textures — so a loop over
    // its whole lifetime is the widest possible statement in the fewest lines.
    if renderer().is_none() {
        return;
    }

    // Warm up first: the first renderer pays for the Metal compiler, the shader cache and the
    // device's own lazy initialisation, none of which come back. Measuring from cold would read
    // those one-time costs as a leak.
    for _ in 0..4 {
        drop(renderer());
    }
    let before = resident_bytes();

    for _ in 0..32 {
        drop(renderer());
    }
    let after = resident_bytes();

    // A generous ceiling on purpose. The claim under test is "does not CLIMB", and thirty-two
    // renderers each holding a shader library and three pipeline states would be tens of megabytes
    // if any of them were held; a few hundred kilobytes of drift is the allocator and the Metal
    // shader cache, not a leak.
    let ceiling = before + 4 * 1024 * 1024;
    assert!(
        after <= ceiling,
        "resident footprint climbed from {before} to {after} across 32 renderers — something is retained"
    );
}

/// This process's resident footprint, in bytes.
///
/// Through `ps` rather than through `task_info`: reading the Mach task port needs `unsafe` and a
/// binding this crate does not otherwise take, and `docs/57` §2 is explicit that a crate here
/// covers ONE framework area. A test that grew a second one to measure the first would be the wrong
/// trade.
fn resident_bytes() -> u64 {
    let pid = std::process::id();
    let output = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .expect("ps is on every macOS");
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u64>()
        .map(|kib| kib * 1024)
        .expect("ps -o rss= prints kibibytes")
}
