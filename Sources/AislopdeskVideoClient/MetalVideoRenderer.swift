#if canImport(Metal) && canImport(QuartzCore)
import AislopdeskVideoProtocol
import CoreVideo
import Foundation
import Metal
import OSLog
import QuartzCore
import simd

/// Zero-copy NV12 → RGB Metal renderer for decoded frames (doc 04, doc 17 §3.7).
///
/// ⚠️ **GUI-ONLY:** needs a real Metal device + a layer on screen. COMPILED +
/// reviewed; not driven from tests.
///
/// Design (cited):
/// - `CVMetalTextureCache` maps the decoded NV12 `CVPixelBuffer` to Metal textures
///   **zero-copy** (plane 0 = luma R8, plane 1 = chroma RG8) — a YCbCr→RGB fragment
///   shader converts on the GPU (doc 04 / doc 17 §3.7).
/// - Presents to a `CAMetalLayer` with `maximumDrawableCount = 2` (latency ~1 vsync,
///   doc 04 line 117).
/// - Driven from **VSync (`CADisplayLink`)**, NOT decode-completion — see
///   ``FramePacer``. On an empty queue it shows the last decoded frame; late frames
///   are skipped (doc 17 §3.7).
/// - Does NOT use `AVSampleBufferDisplayLayer` (adds >=1 frame buffering — doc 18 §F).
///
/// `@MainActor`-isolated: it owns + presents to a `CAMetalLayer`, which is main-thread
/// state. The frame pacer renders through a main-actor hop each vsync.
@preconcurrency
@MainActor
public final class MetalVideoRenderer {
    private let log = Logger(subsystem: "aislopdesk.video.client", category: "MetalVideoRenderer")
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// The layer presented to. Configured for low-latency presentation.
    public let metalLayer: CAMetalLayer

    /// VNC-style zoom (≥1) + normalized pan, applied by CROPPING the sampled texture region
    /// (so zooming re-samples the source at the drawable's native Retina resolution — it
    /// reveals real detail, not a magnified blur). Driven by pinch/pan gestures; the frame
    /// pacer re-presents the last frame each vsync, so changes apply live on a static window.
    public var zoom: CGFloat = 1
    public var panNormalized: CGPoint = .zero

    /// SCROLL-HINT REPROJECTION (default-OFF, env `AISLOPDESK_SCROLL_REPROJECT`): a small normalized
    /// UV translation the renderer ADDS to the sampled coordinate so the last decoded frame can be
    /// shifted by the integrated local scroll velocity on the pacer's between-content ticks — the
    /// picture keeps moving at display rate between real codec frames. It is a DEDICATED uniform that
    /// COMPOSES with zoom/pan (it never overloads them); the fragment shader clamps any sample that
    /// falls outside `[0, 1]` (the newly-revealed disocclusion edge) to black. The offset law lives in
    /// the Rust core (`ScrollReprojector`); this is purely the GPU application of its current value.
    /// Stays exactly `(0, 0)` when the feature is off, so the sampled UV — and the rendered bytes —
    /// are byte-identical to before this feature.
    public var reprojectionOffset: SIMD2<Float> = .zero
    /// CHROME-REGION REPROJECT MASK (host-measured, 2026-06-18): the moving-content vertical band as
    /// normalized sample-UV `y` bounds `(top, bottom)`. The reproject offset is applied ONLY to samples
    /// whose `uv.y` is inside this band (the editor body) and the shifted sample is CLAMPED to it, so
    /// the static chrome (toolbars / tabs / status bar) above and below keeps its un-shifted UV and does
    /// NOT slide with the content — the whole-frame warp was the single worst scroll-reproject artifact.
    /// A degenerate band (`y <= x`, e.g. the default `(0, 0)`) ⇒ the legacy whole-frame warp, so the
    /// rendered bytes are unchanged when no band is set (and when the feature is off, `reprojectionOffset`
    /// stays `(0, 0)` ⇒ the band is irrelevant). Set from `VideoWindowPipeline.applyHostScrollOffset`.
    public var reprojectBand: SIMD2<Float> = .zero
    /// `.fit` (letterbox/pillarbox — whole window, bars) or `.fill` (cover — the video is
    /// scaled up to cover the whole drawable, the overflowing axis clipped by the viewport;
    /// no bars, aspect preserved). Both go through the SAME ``AspectFit/displayedVideoRect``
    /// the input encoder + cursor invert, so a fit↔fill toggle never desyncs click mapping.
    public var contentMode: VideoContentMode = .fit

    /// WF-6 (#8): the negotiated luma range driving the YCbCr→RGB shader coefficients. Set before the
    /// first render from the stream's `helloAck.fullRange` (via the pipeline's `setColorRange` hook).
    /// Default `.video` ⇒ the GPU output is byte-identical to today — the `.video` coefficients ARE the
    /// prior hardcoded shader literals. There is ONE pipeline state (the matrix is the same); only the
    /// per-frame coefficient uniform values differ, so no shader recompile is needed.
    public var colorRange: ColorRange = .video

    /// CONTENT MASK (transparency, 2026-06-17): the opaque-content rects (capture PIXELS, top-left)
    /// the host sent after a DIALOG-EXPAND region change — the window block + each popup. The
    /// fragment shader masks every sample OUTSIDE these rects to alpha 0, so a popup overhanging the
    /// window floats over the canvas instead of sitting in a black bar. EMPTY ⇒ no mask (whole frame
    /// opaque, the default). Setting it toggles `metalLayer.isOpaque` so the alpha actually
    /// composites; the pacer re-presents the last frame each vsync, so it applies live on a static
    /// window. Capped at ``maxMaskRects`` (a window + nested menus never need more).
    public var contentMask: [MaskRect] = [] {
        didSet { metalLayer.isOpaque = contentMask.isEmpty }
    }

    /// Max opaque rects the shader loop handles (window + a few nested menus). Extra rects are
    /// dropped — the overflow would fall back to transparent, never wrong-opaque.
    static let maxMaskRects = 8

    /// Unsharp-mask strength on the LUMA channel (`AISLOPDESK_SHARPEN`, default 0 = off). When the host
    /// streams 1× (downscaled, for smoothness — `AISLOPDESK_CAPTURE_SCALE=1`) the upscaled text reads
    /// soft; a luma unsharp pass crisps the edges back up (text = luma edges; chroma/images left
    /// alone). It ENHANCES perceived sharpness, it cannot reconstruct the detail lost at 1×. Typical
    /// 0.4–1.0; live-tunable since it's read per-render. `0` ⇒ byte-identical to before (no sharpen).
    static let sharpenStrength: Float = resolveSharpenStrength()

    /// Resolve `AISLOPDESK_SHARPEN` through ``EnvConfig`` (ProcessInfo env → settings overlay) — W12 —
    /// so a GUI slider can override it. The EXACT parse/clamp the old inline `static let` used (parse
    /// `Float`; reject `<= 0` → 0 off; clamp `> 4` → 4): an EMPTY overlay + no env ⇒ `0`, byte-identical
    /// to before. Extracted to a named function so the reaches-consumer test can drive it via the
    /// overlay without forcing the (Metal-touching) renderer type.
    static func resolveSharpenStrength() -> Float {
        guard let s = EnvConfig.string("AISLOPDESK_SHARPEN"), let v = Float(s), v > 0
        else { return 0 }
        return min(4, v)
    }

    /// How far the sharpen may OVERSHOOT the local [min,max] (`AISLOPDESK_SHARPEN_PUNCH`, 0…1, default 1).
    /// `0` = pure RCAS (clamp to the local neighbourhood, ringing-free but gentle). `1` = clamp only to
    /// [0,1] (classic unsharp — crisper/punchier, allows controlled halos). In between blends the two,
    /// so it's a live "how aggressive" dial on top of `AISLOPDESK_SHARPEN`'s strength.
    static let sharpenPunch: Float = {
        guard let s = ProcessInfo.processInfo.environment["AISLOPDESK_SHARPEN_PUNCH"], let v = Float(s)
        else { return 1 }
        return min(1, max(0, v))
    }()

    /// Extra sharpen in DARK regions (`AISLOPDESK_SHARPEN_DARK`, default 0). Dark-mode text (light strokes
    /// on a dark bg) softens more — thin strokes anti-alias to mid-grey at 1× and the eye is fussier about
    /// edges on dark. This scales the luma sharpen by `1 + dark·(1 − localMean)`, so a dark neighbourhood
    /// gets up to `(1+dark)×` the boost while bright areas are untouched. Live-tunable; 0 = uniform.
    static let sharpenDark: Float = {
        guard let s = ProcessInfo.processInfo.environment["AISLOPDESK_SHARPEN_DARK"], let v = Float(s), v > 0
        else { return 0 }
        return min(4, v)
    }()

    public init?(metalLayer: CAMetalLayer) {
        guard let device = metalLayer.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.metalLayer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2 // ~1 vsync latency (doc 04)
        // LAT (2026-06-10 loopback hunt, env AISLOPDESK_NO_VSYNC=1): present the drawable as soon as
        // the GPU finishes instead of holding it for the next display refresh — shaves the
        // 0-16.7ms (avg ~8) composite-alignment wait at the cost of possible tearing mid-scan.
        // Default ON-vsync (today's behavior); opt-in for the latency-first profile.
        // macOS-only: `displaySyncEnabled` does not exist on iOS (this line shipped ungated in
        // the R4-R7b series and broke the iOS app build — caught + gated 2026-06-11).
        #if os(macOS)
        if ProcessInfo.processInfo.environment["AISLOPDESK_NO_VSYNC"] == "1" {
            metalLayer.displaySyncEnabled = false
        }
        #endif

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "aislopdesk_video_vertex"),
              let fragmentFunction = library.makeFunction(name: "aislopdesk_video_fragment")
        else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipelineState = pipelineState

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
    }

    /// Draws one NV12 `CVPixelBuffer`. Called at vsync by ``FramePacer`` with the
    /// most recent decoded frame (show-last-frame on empty queue, skip-late upstream).
    private var renderDiagCount = 0
    private static let renderDiag = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil

    public func render(_ pixelBuffer: CVPixelBuffer) {
        guard let textureCache,
              let drawable = metalLayer.nextDrawable() else { return } // nil → skip this vsync

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // DIAGNOSTIC: the exact render-time geometry — drawable TEXTURE px (what the GPU
        // actually allocated, not the requested drawableSize), layer bounds (pt), contentsScale,
        // gravity, native px. The "half-size top-left" symptom means drawable.texture ≠
        // bounds×scale or gravity isn't resize. Logged on frame 1 + every 120 frames.
        if Self.renderDiag, renderDiagCount == 0 || renderDiagCount.isMultiple(of: 120) {
            FileHandle.standardError
                .write(
                    Data(
                        "Aislopdesk[video.client]: RENDER#\(renderDiagCount) drawable.tex=\(drawable.texture.width)x\(drawable.texture.height)px drawableSize=\(Int(metalLayer.drawableSize.width))x\(Int(metalLayer.drawableSize.height)) layer.bounds=\(Int(metalLayer.bounds.width))x\(Int(metalLayer.bounds.height))pt scale=\(metalLayer.contentsScale) gravity=\(metalLayer.contentsGravity.rawValue) native=\(width)x\(height)px\n"
                            .utf8,
                    ),
                )
        }
        renderDiagCount += 1

        // Keep the CVMetalTexture WRAPPERS (not just the MTLTextures) alive: the
        // MTLTexture does not retain its parent CVMetalTexture, and the texture's backing
        // IOSurface is owned by the wrapper + the cache. The GPU samples these textures
        // ASYNCHRONOUSLY (after `commit()`), so releasing the wrappers at function return
        // is a use-after-free → green/garbage frames or a GPU fault (classic
        // CVMetalTextureCache pitfall). We hold both wrappers until the command buffer
        // completes (see `addCompletedHandler` below).
        guard let lumaCV = makeTexture(
            pixelBuffer,
            cache: textureCache,
            planeIndex: 0,
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
        ),
            let chromaCV = makeTexture(
                pixelBuffer,
                cache: textureCache,
                planeIndex: 1,
                pixelFormat: .rg8Unorm,
                width: width / 2,
                height: height / 2,
            ),
            let lumaTexture = CVMetalTextureGetTexture(lumaCV),
            let chromaTexture = CVMetalTextureGetTexture(chromaCV)
        else {
            return
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        // Clear alpha 0 while a content mask is active so uncovered area (letterbox bars + the masked
        // flank the shader discards) is TRANSPARENT, not an opaque black bar; opaque black otherwise
        // (the prior default — byte-identical when no mask).
        let clearAlpha = contentMask.isEmpty ? 1.0 : 0.0
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: clearAlpha)
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        // Pin the viewport to the drawable's PIXEL size. The default viewport for a
        // CAMetalLayer-backed render target resolves to the layer's POINT bounds (656×433),
        // not the drawable texture's pixel size (1312×866) on a 2× display — so the full-size
        // quad rendered into the top-left half of the drawable, the rest cleared black, then
        // stretched to fill: the video landed in the top-left QUARTER of the pane ("nhỏ 1 góc"
        // + half-scale). libghostty's renderer sets its own viewport, which is why the terminal
        // never showed this. Setting it explicitly to the texture size makes the quad cover the
        // whole drawable. (drawable.texture matches metalLayer.drawableSize.)
        encoder.setViewport(MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(drawable.texture.width),
            height: Double(drawable.texture.height),
            znear: 0,
            zfar: 1,
        ))
        encoder.setRenderPipelineState(pipelineState)
        // ASPECT-FIT: the quad fills the whole drawable unless we shrink it to the video's
        // aspect ratio, which would otherwise STRETCH (distort) a landscape window into a
        // portrait layer (and vice-versa). Compute a per-axis scale that letterboxes /
        // pillarboxes the video inside the drawable; the cleared black background shows in the
        // bars. Drawable size is in PIXELS, matched by the Retina drawableSize set in the
        // pipeline's layoutChanged — so both the fit math and the sampling run at native res.
        var fit = SIMD2<Float>(1, 1)
        let dw = Double(metalLayer.drawableSize.width), dh = Double(metalLayer.drawableSize.height)
        if dw > 0, dh > 0, width > 0, height > 0 {
            // Derive `fit` from the SAME `displayedVideoRect` the input encoder + cursor
            // overlay invert, so render-forward and input-inverse can never drift (doc 17
            // §3.7). Computed in PIXELS here (drawableSize, video pixel size); the input
            // path computes in POINTS — aspect ratio is scale-invariant so the fit is
            // identical either way. `fit` is the quad's per-axis half-extent scale =
            // displayed extent / full extent.
            // `.fill` returns a rect LARGER than the drawable (size > dw/dh) → fit > 1 → the
            // quad extends past NDC [-1,1] and the overflow is clipped by the viewport: a
            // centred cover-crop. `.fit` returns a rect ≤ drawable → fit ≤ 1 → letterbox.
            let r = AspectFit.displayedVideoRect(
                viewSize: VideoSize(width: dw, height: dh),
                videoNativeSize: VideoSize(width: Double(width), height: Double(height)),
                mode: contentMode,
            )
            fit.x = Float(r.size.width / dw)
            fit.y = Float(r.size.height / dh)
            if Self.renderDiag, renderDiagCount == 1 || renderDiagCount % 120 == 1 {
                FileHandle.standardError
                    .write(
                        Data(
                            "Aislopdesk[video.client]:   fit=\(fit.x)x\(fit.y) (rect=\(Int(r.size.width))x\(Int(r.size.height)) in dw×dh=\(Int(dw))x\(Int(dh)))\n"
                                .utf8,
                        ),
                    )
            }
        }
        encoder.setVertexBytes(&fit, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        // Zoom/pan as a UV crop: invZoom shrinks the sampled UV span (zoom in), pan recenters
        // it. Clamp pan so the cropped window never runs past the image edges.
        let z = max(1.0, Float(zoom))
        let invZoom = 1.0 / z
        let panLimit = 0.5 * (1.0 - invZoom)
        let px = min(max(Float(panNormalized.x), -panLimit), panLimit)
        let py = min(max(Float(panNormalized.y), -panLimit), panLimit)
        var zoomPan = SIMD4<Float>(invZoom, px, py, 0)
        encoder.setFragmentBytes(&zoomPan, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        // SCROLL-HINT REPROJECTION: a dedicated UV offset the shader ADDS after the zoom/pan crop (it
        // never overloads them). When the feature is off this is `(0, 0)` ⇒ the sampled UV is
        // unchanged ⇒ byte-identical output. The shader clamps out-of-[0,1] samples (the disocclusion
        // edge revealed by the shift) to black.
        var reproj = reprojectionOffset
        encoder.setFragmentBytes(&reproj, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
        // CHROME-REGION MASK band (normalized UV y bounds): the shader applies `reproj` only inside it.
        // (0,0) (or any y<=x) ⇒ whole-frame warp (byte-identical to before this feature). buffer(9).
        var rband = reprojectBand
        encoder.setFragmentBytes(&rband, length: MemoryLayout<SIMD2<Float>>.size, index: 9)
        // CONTENT MASK: normalize each opaque rect (capture pixels) to sample-UV space [0,1] using the
        // decoded frame size, then hand the shader the rect list + count. The shader keeps a fragment
        // OPAQUE only when its sampled UV is inside one of these rects; everything else → alpha 0. The
        // mask test uses the SAME (zoom/pan/reproj-adjusted) UV the texture is sampled at, so the mask
        // tracks zoom/pan. Empty list ⇒ count 0 ⇒ the shader leaves every fragment opaque.
        var maskRects = [SIMD4<Float>]()
        if !contentMask.isEmpty, width > 0, height > 0 {
            let fw = Float(width), fh = Float(height)
            for r in contentMask.prefix(Self.maxMaskRects) {
                let x0 = Float(r.x) / fw, y0 = Float(r.y) / fh
                let x1 = Float(UInt32(r.x) + UInt32(r.width)) / fw
                let y1 = Float(UInt32(r.y) + UInt32(r.height)) / fh
                maskRects.append(SIMD4<Float>(x0, y0, x1, y1))
            }
        }
        var maskCount = Int32(maskRects.count)
        encoder.setFragmentBytes(&maskCount, length: MemoryLayout<Int32>.size, index: 4)
        // Unsharp-mask strength (luma); 0 ⇒ shader skips the pass = byte-identical output.
        var sharpen = Self.sharpenStrength
        encoder.setFragmentBytes(&sharpen, length: MemoryLayout<Float>.size, index: 5)
        // Overshoot/punch dial (0=RCAS clamp to local [min,max], 1=naive clamp to [0,1]).
        var punch = Self.sharpenPunch
        encoder.setFragmentBytes(&punch, length: MemoryLayout<Float>.size, index: 6)
        // Dark-region sharpen boost (dark-mode text legibility).
        var dark = Self.sharpenDark
        encoder.setFragmentBytes(&dark, length: MemoryLayout<Float>.size, index: 7)
        // Luma texel size (1/decoded-size), hoisted OUT of the per-fragment sharpen loop (was recomputed
        // via get_width()/reciprocal per pixel). Chroma texel = 2× this (4:2:0 half-res).
        var lumaTexel = SIMD2<Float>(width > 0 ? 1.0 / Float(width) : 0, height > 0 ? 1.0 / Float(height) : 0)
        encoder.setFragmentBytes(&lumaTexel, length: MemoryLayout<SIMD2<Float>>.stride, index: 8)
        if maskRects.isEmpty {
            var dummy = SIMD4<Float>(0, 0, 0, 0) // keep buffer(3) bound (validation) though count 0 skips it
            encoder.setFragmentBytes(&dummy, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        } else {
            maskRects.withUnsafeBytes { raw in
                if let base = raw.baseAddress { encoder.setFragmentBytes(base, length: raw.count, index: 3) }
            }
        }
        // WF-6 (#8): the YCbCr→RGB coefficients for the negotiated luma range, from the single pure
        // source of truth (YCbCrConversion). For `.video` these are exactly the prior hardcoded shader
        // literals → byte-identical GPU input on the default-OFF path. Only luma scale/bias differ for
        // `.full`. Packed as two `float4` (the 8th lane is padding) for Metal's 16-byte alignment.
        let coeffs = YCbCrConversion.coefficients(colorRange)
        var ycbcr = YCbCrCoeffsUniform(
            c0: SIMD4<Float>(coeffs.lumaScale, coeffs.lumaBias, coeffs.chromaBias, coeffs.crToR),
            c1: SIMD4<Float>(coeffs.cbToG, coeffs.crToG, coeffs.cbToB, 0),
        )
        encoder.setFragmentBytes(&ycbcr, length: MemoryLayout<YCbCrCoeffsUniform>.stride, index: 1)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        // Pin both CVMetalTexture wrappers (+ the pixel buffer) until the GPU is done
        // reading them. The completed handler runs on a private Metal thread; capturing
        // the wrappers there keeps their IOSurfaces valid for the whole async read. The
        // CV handles are not `Sendable`, so we ferry them in an unchecked-Sendable box —
        // the handler only RETAINS them (never reads), so crossing the boundary is safe.
        let pinned = TexturePin(luma: lumaCV, chroma: chromaCV, pixelBuffer: pixelBuffer)
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(pinned) {}
        }
        commandBuffer.commit()

        // Release this frame's recycled texture mappings so the cache's internal
        // registry does not grow unbounded across frames (the wrappers above keep the
        // in-flight surfaces alive regardless of the flush).
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func makeTexture(
        _ pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        planeIndex: Int,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
    ) -> CVMetalTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            pixelFormat, width, height, planeIndex, &cvTexture,
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return cvTexture
    }

    /// Keeps a frame's CVMetalTexture wrappers + source pixel buffer alive across the
    /// asynchronous GPU read (held by the command buffer's completion handler). The
    /// handler only retains these immutable CoreVideo handles — never reads or mutates
    /// them — so ferrying them into the `@Sendable` handler is the documented escape
    /// hatch for immutable CV handles under strict concurrency.
    private struct TexturePin: @unchecked Sendable {
        let luma: CVMetalTexture
        let chroma: CVMetalTexture
        let pixelBuffer: CVPixelBuffer
    }

    /// WF-6 (#8) fragment uniform mirroring the Metal `YCbCrCoeffs` struct (two `float4`): the seven
    /// YCbCr→RGB coefficients (lumaScale, lumaBias, chromaBias, crToR | cbToG, crToG, cbToB, _pad). Two
    /// `SIMD4<Float>` guarantee the 16-byte alignment Metal uses for `float4`, so the `setFragmentBytes`
    /// byte layout matches the shader's struct exactly.
    private struct YCbCrCoeffsUniform {
        var c0: SIMD4<Float>
        var c1: SIMD4<Float>
    }

    /// Inline Metal shader: full-screen triangle-strip quad + BT.709 NV12 YCbCr→RGB
    /// conversion driven by a coefficient uniform (WF-6 #8 — `.video` values reproduce the
    /// prior hardcoded video-range literals exactly). Kept inline so the target needs no
    /// `.metal` resource.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut { float4 position [[position]]; float2 uv; };
    // WF-6 (#8): the seven YCbCr->RGB coefficients (lumaScale, lumaBias, chromaBias, crToR |
    // cbToG, crToG, cbToB, _pad), fed from AislopdeskVideoProtocol.YCbCrConversion.
    struct YCbCrCoeffs { float4 c0; float4 c1; };

    vertex VertexOut aislopdesk_video_vertex(uint vid [[vertex_id]],
                                        constant float2 &fit [[buffer(0)]]) {
        // Full-screen quad as a triangle strip, scaled by `fit` to preserve the video's
        // aspect ratio (letterbox/pillarbox) instead of stretching it to the drawable.
        float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4]       = { float2(0, 1),  float2(1, 1), float2(0, 0),  float2(1, 0) };
        VertexOut out;
        out.position = float4(positions[vid] * fit, 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 aislopdesk_video_fragment(VertexOut in [[stage_in]],
                                         texture2d<float> lumaTex [[texture(0)]],
                                         texture2d<float> chromaTex [[texture(1)]],
                                         constant float4 &zoomPan [[buffer(0)]],
                                         constant YCbCrCoeffs &coeffs [[buffer(1)]],
                                         constant float2 &reprojOffset [[buffer(2)]],
                                         constant float4 *maskRects [[buffer(3)]],
                                         constant int &maskCount [[buffer(4)]],
                                         constant float &sharpen [[buffer(5)]],
                                         constant float &punch [[buffer(6)]],
                                         constant float &dark [[buffer(7)]],
                                         constant float2 &lumaTexel [[buffer(8)]],
                                         constant float2 &reprojBand [[buffer(9)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // zoomPan = (invZoom, panX, panY, _): crop the sampled UV around the panned centre.
        float2 uv = (in.uv - 0.5) * zoomPan.x + 0.5 + float2(zoomPan.y, zoomPan.z);
        // SCROLL REPROJECTION: shift the sampled coordinate by the integrated scroll offset so the last
        // frame translates between codec frames. reprojOffset is (0,0) when the feature is off ⇒ uv
        // unchanged ⇒ byte-identical output. The newly-revealed disocclusion edge now samples via the
        // sampler's clamp_to_edge (the editor's near-uniform background row ≈ invisible) rather than hard
        // BLACK — the black gutter was the single most objectionable scroll artifact (2026-06-16 reframe).
        //
        // CHROME-REGION MASK: warp ONLY the host-measured moving-content band [reprojBand.x, reprojBand.y]
        // (normalized y). Rows outside it — the static toolbars/tabs/status bar — keep their un-shifted UV
        // so the chrome does not slide with the content (the whole-frame warp was the worst artifact).
        // Inside the band the shifted sample is CLAMPED to it, so chrome above/below is never pulled in and
        // the band's leading edge smears (the disocclusion fill, contained to the editor). A degenerate
        // band (y <= x, incl. the default (0,0)) ⇒ the legacy whole-frame warp (no-band frame / A-B).
        if (reprojBand.y > reprojBand.x) {
            if (uv.y >= reprojBand.x && uv.y <= reprojBand.y) {
                float2 shifted = uv + reprojOffset;
                shifted.y = clamp(shifted.y, reprojBand.x, reprojBand.y);
                uv = shifted;
            }
        } else {
            uv += reprojOffset;
        }
        float y = lumaTex.sample(s, uv).r;
        // UNSHARP MASK on luma (text = luma edges): crisp the upscaled 1× stream back up. Adds
        // amount·(center − avg of 4 source-texel neighbours) to the centre luma. sharpen 0 ⇒ skipped
        // ⇒ byte-identical. Chroma untouched, so images/colours are not over-sharpened.
        if (sharpen > 0.0) {
            float2 tx = lumaTexel; // hoisted draw-uniform (was 1.0/get_width per fragment)
            float up = lumaTex.sample(s, uv + float2(0.0, -tx.y)).r;
            float dn = lumaTex.sample(s, uv + float2(0.0,  tx.y)).r;
            float lf = lumaTex.sample(s, uv + float2(-tx.x, 0.0)).r;
            float rt = lumaTex.sample(s, uv + float2( tx.x, 0.0)).r;
            // DARK-region boost: scale the luma sharpen up where the neighbourhood is dark (dark-mode
            // light-on-dark text softens most). `dark`=0 ⇒ uniform. localMean doubles as the unsharp blur.
            float localMean = 0.25 * (up + dn + lf + rt);
            float effSharpen = sharpen * (1.0 + dark * (1.0 - localMean));
            float sharpened = y + effSharpen * (y - localMean);
            // RCAS-family RINGING LIMITER (2026-06-17, from the client-text-SR research): clamp the
            // sharpened luma to the LOCAL 5-tap [min,max] so it can never overshoot the neighbourhood
            // → no halos/ringing around high-contrast glyph or HEVC-block edges (the failure mode of a
            // plain clamp-to-[0,1] unsharp). Same cost (reuses the 4 taps); steepens edges, invents nothing.
            float mn = min(y, min(min(up, dn), min(lf, rt)));
            float mx = max(y, max(max(up, dn), max(lf, rt)));
            // PUNCH widens the limiter from the local [mn,mx] (ringing-free) toward [0,1] (crisp/punchy).
            y = clamp(sharpened, mix(mn, 0.0, punch), mix(mx, 1.0, punch));
        }
        float2 cbcr = chromaTex.sample(s, uv).rg;
        // UNSHARP on CHROMA too: black text is a luma edge (sharpened above), but SYNTAX HIGHLIGHTING /
        // dark-mode colour is a CHROMA edge — and chroma is 4:2:0 (half-res) so colour bleeds at glyph
        // edges. Sharpening Cb/Cr around the neutral 0.5 tightens the colour transition → coloured text
        // crisper (bounded by the half-res source — 4:4:4 would be the full fix). Same `sharpen` knob.
        if (sharpen > 0.0) {
            float2 ctx = lumaTexel * 2.0; // chroma is 4:2:0 half-res → 2× the luma texel
            float2 cu = chromaTex.sample(s, uv + float2(0.0, -ctx.y)).rg;
            float2 cd = chromaTex.sample(s, uv + float2(0.0,  ctx.y)).rg;
            float2 cl = chromaTex.sample(s, uv + float2(-ctx.x, 0.0)).rg;
            float2 crt = chromaTex.sample(s, uv + float2( ctx.x, 0.0)).rg;
            float2 csharp = cbcr + sharpen * (cbcr - 0.25 * (cu + cd + cl + crt));
            // Same RCAS-family local-[min,max] clamp per chroma channel → tightens the colour edge of
            // syntax/dark-mode text with no colour-ringing/fringe beyond the existing local extremes.
            float2 cmn = min(cbcr, min(min(cu, cd), min(cl, crt)));
            float2 cmx = max(cbcr, max(max(cu, cd), max(cl, crt)));
            cbcr = clamp(csharp, mix(cmn, float2(0.0), punch), mix(cmx, float2(1.0), punch));
        }
        // BT.709 YCbCr -> RGB, coefficient-driven (WF-6 #8). For .video the values are the prior
        // hardcoded literals (lumaScale 255/219, lumaBias 16/255, chromaBias 128/255, crToR 1.5748,
        // cbToG 0.1873, crToG 0.4681, cbToB 1.8556) -> identical output. .full changes ONLY luma.
        float lumaScale = coeffs.c0.x, lumaBias = coeffs.c0.y, chromaBias = coeffs.c0.z, crToR = coeffs.c0.w;
        float cbToG = coeffs.c1.x, crToG = coeffs.c1.y, cbToB = coeffs.c1.z;
        float yy = (y - lumaBias) * lumaScale;
        float cb = cbcr.x - chromaBias;
        float cr = cbcr.y - chromaBias;
        float r = yy + crToR * cr;
        float g = yy - cbToG * cb - crToG * cr;
        float b = yy + cbToB * cb;
        // CONTENT MASK (transparency): when the host sent opaque-content rects, keep this fragment
        // opaque ONLY if its sampled UV lies inside one of them; otherwise alpha 0 so the empty area
        // flanking a popup shows the canvas instead of a black bar. maskCount 0 ⇒ no mask (opaque).
        // Tested against `uv` (post zoom/pan/reproj) so the mask tracks the content under transforms.
        float alpha = 1.0;
        if (maskCount > 0) {
            // A fragment stays opaque only if its sampled point is inside one content rect (window or
            // popup, from the host's real `capture_region` rects); everything else (the empty area
            // flanking a narrow popup) → alpha 0 = transparent. Rectangular test: the rounded corners
            // of a window/menu leave a small black sliver — an accepted cosmetic edge, not masked
            // (rounding them needs either a guessed radius or HEVC-with-alpha, both rejected). uv is
            // post zoom/pan/reproj so the mask tracks the content under transforms.
            bool inside = false;
            for (int i = 0; i < maskCount; i++) {
                float4 m = maskRects[i]; // (x0, y0, x1, y1) normalized
                if (uv.x >= m.x && uv.x < m.z && uv.y >= m.y && uv.y < m.w) { inside = true; break; }
            }
            alpha = inside ? 1.0 : 0.0;
        }
        return float4(r * alpha, g * alpha, b * alpha, alpha);
    }
    """
}
#endif
