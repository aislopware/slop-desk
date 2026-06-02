// `RworkVideoHost` — the macOS host side of the GUI video path (PATH 2 / Phase 4).
//
// USES ScreenCaptureKit / VideoToolbox / CoreGraphics / AppKit. Every type here is
// macOS-only (`#if os(macOS)`), COMPILED + code-reviewed, and **NEVER executed in a
// test**: SCStream capture AND VTCompressionSession HW encode HANG without a
// window-server + Screen-Recording TCC session (docs/research/spikes/vtbench/
// RESULTS.md). The capture/encode configs match the MEASURED spike configs exactly
// (see VideoEncoder.swift / WindowCapturer.swift doc comments for the citations).
//
// On non-macOS platforms this target compiles to an empty module (every file is
// `#if os(macOS)`-gated). This file provides the only always-present symbol so the
// SwiftPM target is never "empty".
//
// Components:
// - WindowCapturer        — SCStream + SCContentFilter(desktopIndependentWindow:),
//                           NV12 zero-copy, showsCursor=false, 30fps cap, queueDepth
//                           3, idle-skip, heartbeat IDR.
// - VideoEncoder          — the 2-session HEVC design (Session A low-latency-RC live;
//                           Session B Quality=1.0 all-intra crisp).
// - CursorSampler         — ~120 Hz NSEvent/NSCursor → cursor side-channel.
// - WindowGeometryWatcher — AX move/resize notifications + CGWindowList drag-poll.
// - InputInjector         — activate-then-control: raise+focus → CGEvent.post,
//                           tagged eventSourceUserData for self-inject filtering.

/// Namespace marker for the macOS GUI-video host module.
public enum RworkVideoHost {
    /// True on the only platform this module has functionality (macOS).
    public static let isSupportedPlatform: Bool = {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }()
}
