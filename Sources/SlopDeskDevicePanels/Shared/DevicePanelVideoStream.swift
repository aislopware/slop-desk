// DevicePanelVideoStream — the face over `slopdesk_panel_video_*`, and the ONLY Swift left between a
// device's bytes and an `AVSampleBufferDisplayLayer`.
//
// What used to be here was three files — `AndroidVideoFormat`, `SimulatorVideoFormat` and the
// `DevicePanelSampleBuffer` they shared — building `CMVideoFormatDescription`, `CMBlockBuffer` and
// `CMSampleBuffer` by hand, with the same three framework calls in the same order that
// `rust/slopdesk-apple-vt` was already making for the desktop decoder. Two implementations of one
// framework contract, in two languages, and only one of them under a leak test. The Swift copy even
// carried its own `unsafeBitCast` on the attachment array, which is raw-pointer work in the language
// that has no way to state the obligation.
//
// Now there is one. `slopdesk-apple-vt` builds every CoreMedia object this app has, the parsing that
// feeds it (`slopdesk_video::annexb`, `slopdesk_devicepanel::sim_stream`) was already Rust, and the
// only thing crossing back is a sample buffer the layer can eat.
//
// ⚠️ THE SAMPLE BUFFER ARRIVES AT +1. `slopdesk_panel_video_sample` hands over a RETAINED
// `CMSampleBuffer` — the Create rule, pointed outwards — and `takeRetainedValue()` below IS the
// release the contract requires. This is the same term the decoded pixels already cross under
// (`SlopDeskVideoClient/VideoDecoder.swift`); `takeUnretainedValue()` here would leak one sample
// buffer per frame, at sixty a second, which is the failure that looks like a memory leak nobody can
// find.

import CoreMedia
import CSlopDeskFFI
import Foundation

/// One device panel's video stream: configured once from a config packet, then fed access units.
///
/// A CLASS, and not a struct, for the reason the handle exists at all: the format description
/// outlives the frame, so something has to own it between calls, and `deinit` is what releases it.
///
/// `@unchecked Sendable` for the same reason ``SlopDeskVideoClient/VideoDecoder`` is, and it is the
/// door's property rather than a promise made here: the handle is immutable for the object's life,
/// and the one thing behind it is guarded on the Rust side — a `Mutex` `slopdesk_panel_video_*`
/// takes on every call. Every caller today is a main-actor view; NOT being main-actor is what lets
/// `deinit` free the handle, since an isolated `deinit` cannot touch a non-`Sendable` pointer.
package final class DevicePanelVideoStream: @unchecked Sendable {
    private let handle: OpaquePointer

    /// Creates a stream with no format description yet.
    ///
    /// Returns `nil` only if the allocation itself failed, which is a process that is already over.
    /// Callers treat it as "no video", the same as a config packet that never arrives.
    package init?() {
        guard let handle = slopdesk_panel_video_new() else { return nil }
        self.handle = handle
    }

    deinit { slopdesk_panel_video_free(handle) }

    /// Configures the stream from the simulator server's avcC record.
    ///
    /// The record is handed over UNPARSED. Its parameter sets and its `nalUnitHeaderLength` — the
    /// field that says whether frames carry one, two or four length bytes — are read on the Rust
    /// side by the parser that already owned that layout, so neither ever becomes a Swift value that
    /// could disagree with the description built from it.
    ///
    /// `false` leaves the RUNNING description in place: a malformed record mid-stream is a reason to
    /// keep showing frames against the one that was working, not to stop showing anything.
    @discardableResult
    package func configure(avcc record: Data) -> Bool {
        record.withUnsafeContent { bytes, count in
            slopdesk_panel_video_configure_avcc(handle, bytes, count)
        }
    }

    /// Configures the stream from `scrcpy`'s Annex-B config packet.
    ///
    /// Also unparsed, for the same reason, and `hevc` picks BOTH the parameter-set walk and the
    /// framework entry point — an H.264 walk over an HEVC packet finds nothing, and finding nothing
    /// is what the door refuses.
    @discardableResult
    package func configure(annexB packet: Data, hevc: Bool) -> Bool {
        packet.withUnsafeContent { bytes, count in
            slopdesk_panel_video_configure_annexb(handle, bytes, count, hevc)
        }
    }

    /// The stream's encoded pixel size, or `nil` before a config packet has landed.
    ///
    /// Read off the format DESCRIPTION rather than any session header the device advertised: the
    /// encoded frame is routinely smaller than the device (`--scale` on the simulator, `max_size` on
    /// the bridge), and it is the frame the view has to fit. A header that agrees today is a header
    /// that can disagree tomorrow.
    package var contentSize: CGSize? {
        var width: Int32 = 0
        var height: Int32 = 0
        guard slopdesk_panel_video_dimensions(handle, &width, &height) else { return nil }
        return CGSize(width: Int(width), height: Int(height))
    }

    /// One AVCC access unit as a sample buffer ready to enqueue, or `nil` when there is nothing to
    /// show — no config packet yet, an empty unit, or a framework refusal. All three end the same
    /// way at every call site: drop the frame, wait for the next.
    package func sample(_ accessUnit: Data, isKeyframe: Bool) -> CMSampleBuffer? {
        let raw = accessUnit.withUnsafeContent { bytes, count in
            slopdesk_panel_video_sample(handle, bytes, count, isKeyframe)
        }
        guard let raw else { return nil }
        // +1: the door's terms make this side the owner, and `takeRetainedValue` IS the release.
        return Unmanaged<CMSampleBuffer>.fromOpaque(raw).takeRetainedValue()
    }
}

private extension Data {
    /// Lends these bytes as `(ptr, len)` for the length of one door call.
    ///
    /// Empty `Data` lends the null pair, which every door reads as the same nothing a zero length
    /// is — so an empty payload never needs a branch of its own at the call sites above.
    func withUnsafeContent<T>(_ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        withUnsafeBytes { raw in
            body(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }
}
