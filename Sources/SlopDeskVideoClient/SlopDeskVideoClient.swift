// `SlopDeskVideoClient` — the macOS + iOS client side of the GUI video path (PATH 2 /
// Phase 4). USES VideoToolbox (decode) / Metal / CoreVideo / QuartzCore.
//
// COMPILED + code-reviewed; NEVER executed in a test. Decode was MEASURED safe
// (~0.9-1.1ms synchronous, single-frame — RESULTS.md "F") but to honour the hang-
// safety rule no VTDecompressionSession is instantiated in tests either.
//
// Components:
// - VideoDecoder           — VTDecompressionSession, decodeFlags=[] synchronous
//                            single-frame, RequireHardwareAcceleratedVideoDecoder,
//                            feeds reassembled AVCC.
// - MetalVideoRenderer     — CVMetalTextureCache NV12->Metal zero-copy + YCbCr->RGB
//                            shader, CAMetalLayer maximumDrawableCount=2 (NOT
//                            AVSampleBufferDisplayLayer).
// - FramePacer             — CADisplayLink/VSync-driven, show-last-frame on empty
//                            queue, skip-late frames (pure newest-wins logic).
// - ClientCursorCompositor — side-channel cursor as a CALayer over the decoded frame
//                            at display-refresh -> pointer latency = RTT.
//
// NO VIEW LIVES HERE (docs/56 §3, the video carve). What used to be `VideoWindowView.swift` — one
// file, 2,898 lines, of which the middle 2,514 were an `#if os(macOS)` / `#elseif os(iOS)` two-armed
// conditional — is now two sibling targets, `SlopDeskVideoClientMac` (AppKit) and
// `SlopDeskVideoClientPhone` (UIKit), each linked by exactly one app shell. This target is the engine
// underneath both: decode, pace, transport, and every DECISION the two halves share. A view growing
// back here is a place for a third implementation to hide, which is why check-supervisor's Rule A
// bans one outright.

/// Namespace marker for the GUI-video client module.
public enum SlopDeskVideoClient {
    /// True when the platform can decode + render (macOS / iOS with Metal).
    public static let isSupportedPlatform: Bool = {
        #if canImport(VideoToolbox) && canImport(Metal)
        return true
        #else
        return false
        #endif
    }()
}
