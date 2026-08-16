import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-video`'s `hevc_parameter_sets`, reached through the door of the
/// same name.
///
/// The host (`SlopDeskVideoHost.VideoEncoder`) streams **AVCC** — length-prefixed NAL units, no
/// out-of-band parameter sets. VTCompressionSession keeps the VPS/SPS/PPS in the sample buffer's
/// FORMAT DESCRIPTION (not inline in the CMBlockBuffer), so `VideoEncoder.deliver` explicitly
/// PREPENDS them ahead of the coded slice on a keyframe (`hevcParameterSetsAVCC`). An HEVC IDR
/// access unit therefore carries its **VPS / SPS / PPS** inline, ahead of the coded slice — which
/// is what this type pulls back out, so `VideoDecoder` can build a `CMVideoFormatDescription`
/// before the first slice.
///
/// What crosses is WHERE the three sets sit, not their bytes: a keyframe is most of a frame and
/// this side is already holding it, so the copy happens once, inside the borrow that has the
/// pointer — the same convention ``NALUnit/split(_:)`` answers under.
public enum HEVCParameterSets {
    /// The NAL unit types the extraction looks for (Rec. ITU-T H.265 Table 7-1), from the door, so
    /// neither language writes the numbers down twice.
    private static let types = slopdesk_hevc_types()
    public static var vpsType: UInt8 { types.vps }
    public static var spsType: UInt8 { types.sps }
    public static var ppsType: UInt8 { types.pps }

    /// The VPS/SPS/PPS payloads extracted from a keyframe's AVCC bytes, in the order
    /// `CMVideoFormatDescriptionCreateFromHEVCParameterSets` wants them.
    public struct ParameterSets: Equatable, Sendable {
        public var vps: Data
        public var sps: Data
        public var pps: Data
        public init(vps: Data, sps: Data, pps: Data) {
            self.vps = vps
            self.sps = sps
            self.pps = pps
        }

        /// In the fixed [VPS, SPS, PPS] order the format-description API expects.
        public var ordered: [Data] { [vps, sps, pps] }
    }

    /// The HEVC `nal_unit_type` of a single NAL-unit payload (the bytes WITHOUT the AVCC length
    /// prefix). Returns `nil` for an empty unit.
    public static func nalType(of unit: Data) -> UInt8? {
        let answered = unit.withUnsafeBytes { bytes in
            slopdesk_hevc_nal_type(bytes.baseAddress, bytes.count)
        }
        return answered.present ? answered.nal_type : nil
    }

    /// Pulls the VPS/SPS/PPS payloads out of an AVCC keyframe buffer. Returns `nil` unless all
    /// three parameter sets are present — an incomplete set cannot build a format description, and
    /// the decoder must wait for a full IDR.
    public static func extract(from avcc: Data) -> ParameterSets? {
        avcc.withUnsafeBytes { bytes -> ParameterSets? in
            var found = SlopDeskHevcParameterSets()
            guard slopdesk_hevc_parameter_sets(bytes.baseAddress, bytes.count, &found) else { return nil }
            return ParameterSets(
                vps: payload(of: bytes, at: found.vps),
                sps: payload(of: bytes, at: found.sps),
                pps: payload(of: bytes, at: found.pps),
            )
        }
    }

    /// Copies one answered span out of the buffer the walk read.
    private static func payload(of bytes: UnsafeRawBufferPointer, at span: SlopDeskNalSpan) -> Data {
        let start = Int(span.offset)
        return Data(UnsafeRawBufferPointer(rebasing: bytes[start..<start + Int(span.length)]))
    }
}
