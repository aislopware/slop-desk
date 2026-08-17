// SimulatorVideoFormat — the bridge from the simulator server's H.264 bytes to CoreMedia objects.
//
// Nothing here decodes. `CMVideoFormatDescription`, `CMBlockBuffer` and `CMSampleBuffer` are plain
// data objects — no session, no device, no window server — which is what lets this layer be unit
// tested under the hang-safety rule while the thing that ACTUALLY decodes
// (`AVSampleBufferDisplayLayer`, which spins up its own decompression session on first enqueue) stays
// in the view and out of every test.
//
// Why `AVSampleBufferDisplayLayer` and not a `VTDecompressionSession` + Metal path like the desktop
// video client: that path exists there because the desktop stream needs a client-side compositor —
// zoom, pan-lock, cursor overlay, 1:1 snapping, a pacer. The simulator panel needs none of it. It
// shows one rectangle at whatever size the panel is. Handing CoreMedia the sample buffers directly
// is the whole implementation, it is hardware-accelerated the same way, and it deletes the pacing
// and pixel-buffer-lifetime questions rather than answering them again.
//
// The stream is AVCC — each access unit is a run of `[4-byte BE length][NAL]`, already exactly what
// CoreMedia expects. That is why the URL asks for `format=avcc`: the Annex-B alternative would cost a
// start-code rewrite of every access unit on the hot path, for nothing.

#if os(macOS)
import CoreMedia
import Foundation

package enum SimulatorVideoFormat {
    /// Build the format description an avcC record describes.
    ///
    /// The parameter-set pointers must stay valid for the DURATION of the call, which is why the
    /// blobs are copied into one contiguous buffer first and pointed into: handing CoreMedia
    /// `Data`'s bytes through nested `withUnsafeBytes` closures is possible but nests one level per
    /// parameter set, and a stream is free to carry more than the two we have seen.
    package static func formatDescription(for configuration: SimulatorWireProtocol
        .AVCConfiguration) -> CMVideoFormatDescription?
    {
        let sets = configuration.parameterSets
        guard !sets.isEmpty else { return nil }

        var flattened: [UInt8] = []
        var ranges: [(offset: Int, count: Int)] = []
        for set in sets {
            ranges.append((flattened.count, set.count))
            flattened.append(contentsOf: set)
        }

        var description: CMVideoFormatDescription?
        let status = flattened.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            let pointers = ranges.map { UnsafePointer<UInt8>(base + $0.offset) }
            let sizes = ranges.map(\.count)
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    guard let pointerBase = pointerBuffer.baseAddress, let sizeBase = sizeBuffer.baseAddress
                    else { return -1 }
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase,
                        nalUnitHeaderLength: Int32(configuration.nalUnitHeaderLength),
                        formatDescriptionOut: &description,
                    )
                }
            }
        }
        return status == noErr ? description : nil
    }

    /// One AVCC access unit as a sample buffer ready to enqueue —
    /// ``DevicePanelSampleBuffer/sampleBuffer(accessUnit:formatDescription:isKeyframe:)``, which both
    /// device panels share. Only the format description above differs between them.
    package static func sampleBuffer(
        accessUnit: Data, formatDescription: CMVideoFormatDescription, isKeyframe: Bool,
    ) -> CMSampleBuffer? {
        DevicePanelSampleBuffer.sampleBuffer(
            accessUnit: accessUnit, formatDescription: formatDescription, isKeyframe: isKeyframe,
        )
    }

    /// The stream's pixel dimensions, for the panel's aspect ratio. Read off the format description
    /// rather than the device's advertised screen size: a scaled stream (`--scale 2`) is smaller than
    /// the device, and it is the FRAME the view has to fit.
    package static func dimensions(of formatDescription: CMVideoFormatDescription) -> CGSize {
        DevicePanelSampleBuffer.dimensions(of: formatDescription)
    }
}
#endif
