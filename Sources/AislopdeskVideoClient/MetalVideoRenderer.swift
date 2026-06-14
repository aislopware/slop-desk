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
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
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
                                         constant YCbCrCoeffs &coeffs [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // zoomPan = (invZoom, panX, panY, _): crop the sampled UV around the panned centre.
        float2 uv = (in.uv - 0.5) * zoomPan.x + 0.5 + float2(zoomPan.y, zoomPan.z);
        float y = lumaTex.sample(s, uv).r;
        float2 cbcr = chromaTex.sample(s, uv).rg;
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
        return float4(r, g, b, 1.0);
    }
    """
}
#endif
