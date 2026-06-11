import Foundation

/// `AislopdeskVideoProtocol` — the cross-platform, **pure** wire format for the GUI
/// video path (PATH 2 / Phase 4, doc 17 §3, doc 18).
///
/// This target has ZERO platform dependency (no ScreenCaptureKit, no VideoToolbox,
/// no AppKit) so it compiles for macOS + iOS and is fully unit-testable in
/// isolation — exactly the same discipline as `AislopdeskProtocol` for PATH 1. The
/// capture/encode (`AislopdeskVideoHost`) and decode/render (`AislopdeskVideoClient`) targets
/// build on these types.
///
/// Contents:
/// - ``VideoPacketizer`` / ``FrameReassembler`` — fragment a NALU-bearing frame into
///   <=1200-byte UDP datagrams and reassemble by `frameID`, detecting loss and
///   signalling recovery (doc 17 §3.6).
/// - ``FECScheme`` / ``XORParityFEC`` — ~20% parity per frame with real single-loss
///   recovery (production may swap in Reed-Solomon).
/// - ``RecoveryMessage`` / ``RecoveryPolicy`` — client→host LTR-refresh / IDR
///   request model.
/// - ``CursorUpdate`` — the <64-byte cursor side-channel (doc 17 §3.3).
/// - ``WindowGeometryMessage`` — move/resize/title channel (doc 17 §3.8).
/// - ``CoordinateMapping`` — normalised→host-window-point math with the
///   multi-monitor Cocoa-flip + Retina handling (doc 18 §B, SOLVED).
/// - ``InputEvent`` — mouse/key/scroll/text client→host codec, self-inject tagged
///   (doc 17 §3.9).
public enum AislopdeskVideoProtocol {
    /// Wire protocol version for the video path (bumped on any breaking change).
    public static let version: UInt16 = 1
}
