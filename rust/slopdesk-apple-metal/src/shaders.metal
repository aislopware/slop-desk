// The whole GPU program for the terminal surface: three vertex shaders, three fragment shaders.
//
// This file is the OTHER half of `slopdesk-termrender`'s `quad.rs`. The structs below must match
// that module field for field, and the `static_assert`s at the bottom of each one are how that stops
// being a hope — `pipeline.rs` compiles this source at start-up, so a layout drift is a start-up
// error with a line number rather than a screen of shifted glyphs. The Rust side pins the same four
// numbers in `geom.rs`'s tests, so a `#[repr(C)]` edit fails `cargo test` even with no GPU present.
//
// ## No vertex buffer
// Every draw is `drawPrimitives(triangleStrip, 0, 4, instanceCount)` with NO position attribute
// bound. The four corners come out of `vertex_id` arithmetic, which is cheaper than a bound quad and
// removes the one thing a vertex descriptor could get wrong. A terminal repaint is ten thousand
// axis-aligned rectangles; there is no geometry here worth streaming.
//
// ## Pixels in, clip space out
// Every coordinate arriving from Rust is a DEVICE pixel with a TOP-LEFT origin — `quad.rs` says so
// and `layout.rs` is what makes it true. Metal's clip space is centre-origin and Y-up, so the vertex
// stage divides by the viewport, doubles, subtracts one and flips Y. The viewport size arrives as a
// `setVertexBytes` uniform rather than as a per-instance field: it is one value per frame, and
// putting it on every instance would cost 8 bytes × 10 000 to say the same thing.
//
// ## Premultiplied alpha, and who premultiplies
// The pipelines blend `One / OneMinusSourceAlpha`, so every fragment shader here returns
// PREMULTIPLIED colour. The two sides of the atlas arrive differently and that is the reason the
// glyph shader has a branch at all:
//
//   - `AtlasFormat::Bgra8` — the colour atlas, emoji. `atlas.rs` documents its texels as
//     "blue-green-red-alpha, premultiplied", so a colour glyph is sampled and returned UNCHANGED.
//     `MTLPixelFormat::BGRA8Unorm` does the channel swizzle in hardware, so `.rgba` here is already
//     in the right order and no shader swizzle is wanted.
//   - `AtlasFormat::Alpha8` — the coverage atlas, text. A single coverage byte and no colour at all,
//     which is what a CoreText rasterisation into an 8-bit context produces. The tint that arrives
//     on the instance is STRAIGHT alpha (`Rgba` is four plain bytes), so this shader multiplies it
//     out: `rgb * a` for the colour channels, `a` for alpha.
//
// A `RectInstance`'s colour is straight alpha for the same reason, so the rect shader premultiplies
// too. Doing it here rather than on the CPU keeps `quad.rs` free of a convention it would otherwise
// have to document and test.

#include <metal_stdlib>

using namespace metal;

// MARK: - The contract with `quad.rs`

// `packed_` on every vector member, deliberately. Metal aligns a plain `float4` to 16 bytes and a
// plain `uchar4` to 4; Rust's `#[repr(C)]` aligns an `[f32; 4]` to 4 and a four-`u8` struct to 1. The
// packed spellings have the alignment `repr(C)` gives, which is what makes the `static_assert`s
// below pass rather than merely look right.
struct RectInstance {
    packed_float4 rect;   // x, y, width, height — device pixels, top-left origin
    packed_uchar4 color;  // straight alpha; this shader premultiplies
    uint style;           // `RectStyle`, and the discriminants below must match its `#[repr(u32)]`
};
static_assert(sizeof(RectInstance) == 24, "RectInstance drifted from quad.rs");

struct GlyphInstance {
    packed_float4 rect;   // x, y, width, height — device pixels, top-left origin
    packed_float4 uv;     // u0, v0, u1, v1 into whichever atlas `colorAtlas` names
    packed_uchar4 color;  // the tint; ignored when `colorAtlas` is set
    uint colorAtlas;      // non-zero selects the BGRA atlas
};
static_assert(sizeof(GlyphInstance) == 40, "GlyphInstance drifted from quad.rs");

// `RectStyle`, mirrored. `quad.rs` gives the enum `#[repr(u32)]` with these exact discriminants, and
// `geom.rs`'s `the_rect_styles_match_the_shader` pins them from the Rust side.
constant uint kStyleSolid  = 0u;
constant uint kStyleDotted = 1u;
constant uint kStyleDashed = 2u;
constant uint kStyleCurly  = 3u;
constant uint kStyleHollow = 4u;

struct ImageInstance {
    packed_float4 rect;   // x, y, width, height — device pixels, top-left origin
    packed_float4 uv;     // u0, v0, u1, v1 into the image's own texture
};
static_assert(sizeof(ImageInstance) == 32, "ImageInstance drifted from quad.rs");

// One value per frame: the drawable's size in device pixels. `renderer.rs` writes it with
// `setVertexBytes`, Metal's inline path for a uniform too small to be worth a buffer.
struct Viewport {
    packed_float2 size;
};
static_assert(sizeof(Viewport) == 8, "Viewport drifted from geom.rs");

// MARK: - Shared vertex arithmetic

// The four corners of a triangle strip, from the vertex id alone.
//
//   0 -> (0,0)   1 -> (1,0)   2 -> (0,1)   3 -> (1,1)
//
// which is the winding `MTLPrimitiveType::TriangleStrip` wants for a quad. Bit 0 is X and bit 1 is
// Y, so this is two shifts and no branch.
static inline float2 corner_of(uint vertexId) {
    return float2(float(vertexId & 1u), float((vertexId >> 1u) & 1u));
}

// Device pixels to clip space. Top-left origin in, centre origin and Y-up out.
//
// Written as three statements rather than one expression on purpose: `CLAUDE.md`'s bit-exactness
// rule keeps `a * b + c` apart everywhere in this repo so a fused multiply-add cannot change a
// result by a half-ulp, and a shader that spelled the same conversion differently from `geom.rs`'s
// `to_clip` would make that test a test of nothing.
static inline float4 to_clip(float2 pixels, float2 viewport) {
    float2 unit = pixels / viewport;
    float2 doubled = unit * 2.0;
    float2 ndc = doubled - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

// MARK: - Rectangles: backgrounds, decorations, cursors

struct RectVarying {
    float4 position [[position]];
    float4 color;
    float2 local;               // where in the rect this fragment is, in device pixels
    float2 extent;              // the rect's own size, in device pixels
    uint style [[flat]];        // `flat`: an integer has no meaningful interpolation
};

vertex RectVarying rect_vertex(uint vertexId [[vertex_id]],
                               uint instanceId [[instance_id]],
                               const device RectInstance *instances [[buffer(0)]],
                               constant Viewport &viewport [[buffer(1)]]) {
    RectInstance instance = instances[instanceId];
    float2 origin = float2(instance.rect.x, instance.rect.y);
    float2 extent = float2(instance.rect.z, instance.rect.w);
    float2 unit = corner_of(vertexId);
    float2 local = unit * extent;
    float2 pixels = origin + local;

    RectVarying out;
    out.position = to_clip(pixels, float2(viewport.size));
    out.color = float4(uchar4(instance.color)) / 255.0;
    out.local = local;
    out.extent = extent;
    out.style = instance.style;
    return out;
}

// A one-pixel-wide analytic edge. `distance` is how far inside the shape this fragment is, in
// device pixels; the half-pixel band on either side of zero is the antialiasing, and it is done by
// arithmetic rather than by multisampling because a terminal is thirty thousand edges a frame and
// MSAA would pay for all of them to smooth the handful that are not axis-aligned.
static inline float edge_coverage(float distance) {
    return saturate(distance + 0.5);
}

// Coverage for the periodic styles. `phase` is the distance along the rect from its own LEFT edge,
// which is what `quad.rs` means by "phase-locked to the rect's own left edge so adjacent cells
// continue one pattern rather than restarting it": the painter emits one instance per RUN, not one
// per cell, so a run that spans forty columns carries one unbroken pattern.
//
// The period scales with the rect's height — the underline's own thickness — so a dotted underline
// at 2× looks like the same underline rather than like a finer one.
static inline float dash_coverage(float phase, float unit, float period, float duty) {
    float scaled = period * unit;
    float on = duty * scaled;
    float position = fmod(phase, scaled);
    // Distance into the "on" run, from whichever end is nearer. Positive inside, negative outside.
    float from_start = position;
    float from_end = on - position;
    return edge_coverage(min(from_start, from_end));
}

// A sine wave fitted to the rect's height, which is the whole of `RectStyle::Curly`. The rect is the
// wave's BOUNDING BOX: the stroke is a quarter of the height, the amplitude is what is left over
// after the stroke, and the wavelength is twice the height so one period reads as a single curl
// rather than as a ripple. Every one of those is a ratio rather than a constant, so the decoration
// survives a font size change and a scale change without a second table to keep in step.
static inline float curly_coverage(float2 local, float2 extent) {
    float stroke = max(1.0, extent.y * 0.25);
    float amplitude = max(0.0, extent.y - stroke) * 0.5;
    float centre = extent.y * 0.5;
    float wavelength = max(4.0, extent.y * 2.0);
    float angle = local.x / wavelength * 6.283185307179586;
    float wave = centre + amplitude * sin(angle);
    float distance = abs(local.y - wave);
    float half_stroke = stroke * 0.5;
    return edge_coverage(half_stroke - distance);
}

// One device pixel of outline, inside the rect's own bounds — the unfocused cursor. Inside means
// "further than one pixel from every edge", so a 2×2 rect is all outline and never inverts.
static inline float hollow_coverage(float2 local, float2 extent) {
    float from_left = local.x;
    float from_right = extent.x - local.x;
    float from_top = local.y;
    float from_bottom = extent.y - local.y;
    float inset = min(min(from_left, from_right), min(from_top, from_bottom));
    return edge_coverage(1.0 - inset);
}

fragment float4 rect_fragment(RectVarying in [[stage_in]]) {
    float coverage = 1.0;
    if (in.style == kStyleDotted) {
        coverage = dash_coverage(in.local.x, max(1.0, in.extent.y), 3.0, 0.5);
    } else if (in.style == kStyleDashed) {
        coverage = dash_coverage(in.local.x, max(1.0, in.extent.y), 8.0, 0.625);
    } else if (in.style == kStyleCurly) {
        coverage = curly_coverage(in.local, in.extent);
    } else if (in.style == kStyleHollow) {
        coverage = hollow_coverage(in.local, in.extent);
    }
    // `kStyleSolid` falls through with full coverage, which is the commonest case by two orders of
    // magnitude and therefore the one that gets no comparison at all.
    float alpha = in.color.a * coverage;
    return float4(in.color.rgb * alpha, alpha);
}

// MARK: - Glyphs

struct GlyphVarying {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint colorAtlas [[flat]];
};

vertex GlyphVarying glyph_vertex(uint vertexId [[vertex_id]],
                                 uint instanceId [[instance_id]],
                                 const device GlyphInstance *instances [[buffer(0)]],
                                 constant Viewport &viewport [[buffer(1)]]) {
    GlyphInstance instance = instances[instanceId];
    float2 origin = float2(instance.rect.x, instance.rect.y);
    float2 extent = float2(instance.rect.z, instance.rect.w);
    float2 unit = corner_of(vertexId);
    float2 pixels = origin + unit * extent;

    float2 uv0 = float2(instance.uv.x, instance.uv.y);
    float2 uv1 = float2(instance.uv.z, instance.uv.w);

    GlyphVarying out;
    out.position = to_clip(pixels, float2(viewport.size));
    // The same unit corner indexes the atlas rectangle, which is why the glyph never needs a second
    // winding rule: the bitmap's top-left is the quad's top-left in both spaces.
    out.uv = uv0 + unit * (uv1 - uv0);
    out.color = float4(uchar4(instance.color)) / 255.0;
    out.colorAtlas = instance.colorAtlas;
    return out;
}

fragment float4 glyph_fragment(GlyphVarying in [[stage_in]],
                               texture2d<float> coverage [[texture(0)]],
                               texture2d<float> colored [[texture(1)]]) {
    // `nearest`, not `linear`, and that is the whole subpixel story. The atlas holds glyphs
    // rasterised AT the device scale into cells whose UVs land on texel boundaries, so every sample
    // is already one-to-one with a destination pixel. Linear filtering would only blur a bitmap that
    // is being drawn at its own size, and it would bleed a neighbour's shelf across the padding.
    constexpr sampler atlas_sampler(coord::normalized, filter::nearest, address::clamp_to_edge);

    if (in.colorAtlas != 0u) {
        // Already premultiplied, and carrying its own colour. `quad.rs` says the tint is ignored
        // here, and ignoring it is what makes an emoji an emoji rather than a silhouette.
        return colored.sample(atlas_sampler, in.uv);
    }
    float mask = coverage.sample(atlas_sampler, in.uv).r;
    float alpha = in.color.a * mask;
    return float4(in.color.rgb * alpha, alpha);
}

// MARK: - Inline images

struct ImageVarying {
    float4 position [[position]];
    float2 uv;
};

vertex ImageVarying image_vertex(uint vertexId [[vertex_id]],
                                 uint instanceId [[instance_id]],
                                 const device ImageInstance *instances [[buffer(0)]],
                                 constant Viewport &viewport [[buffer(1)]]) {
    ImageInstance instance = instances[instanceId];
    float2 origin = float2(instance.rect.x, instance.rect.y);
    float2 extent = float2(instance.rect.z, instance.rect.w);
    float2 unit = corner_of(vertexId);
    float2 pixels = origin + unit * extent;

    float2 uv0 = float2(instance.uv.x, instance.uv.y);
    float2 uv1 = float2(instance.uv.z, instance.uv.w);

    ImageVarying out;
    out.position = to_clip(pixels, float2(viewport.size));
    // The same unit corner indexes the source rectangle, so the image's top-left is the quad's
    // top-left and a cropped placement (`image.rs`'s `clip`) needs no second winding rule.
    out.uv = uv0 + unit * (uv1 - uv0);
    return out;
}

fragment float4 image_fragment(ImageVarying in [[stage_in]],
                               texture2d<float> image [[texture(0)]]) {
    // `linear`, and this is the ONE sampler in this file that is not `nearest`. A glyph is
    // rasterised at the device scale and drawn at its own size, so filtering it could only blur it.
    // An image is not: the program picked its pixel dimensions and the placement's box comes from a
    // cell grid, so the two disagree by whatever the font size happens to be and every image is
    // resampled. `nearest` there is visible aliasing on the diagonal of every chart.
    //
    // `clamp_to_edge` because `image.rs` crops a placement by NARROWING its uv rectangle, so an
    // edge texel is a real edge and repeating or bordering it would put the far side of the picture
    // — or black — into the last half-texel of every scrolled image.
    constexpr sampler image_sampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // STRAIGHT alpha in, premultiplied out. `slopdesk-vterm`'s `ImagePixels` documents its RGBA as
    // straight and `images.rs` uploads those bytes unchanged, so the multiply the `One /
    // OneMinusSourceAlpha` blend expects is owed here. Doing it in the shader rather than on upload
    // is what keeps the store's pixels the same bytes the engine produced — see `images.rs`.
    float4 texel = image.sample(image_sampler, in.uv);
    return float4(texel.rgb * texel.a, texel.a);
}
