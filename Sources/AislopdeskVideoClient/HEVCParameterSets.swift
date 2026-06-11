import Foundation
import AislopdeskVideoProtocol

/// Pure HEVC parameter-set extraction from an AVCC/HVCC byte buffer.
///
/// The host (`AislopdeskVideoHost.VideoEncoder`) streams **AVCC** — length-prefixed NAL units, no
/// out-of-band parameter sets. VTCompressionSession keeps the VPS/SPS/PPS in the sample buffer's
/// FORMAT DESCRIPTION (not inline in the CMBlockBuffer), so `VideoEncoder.deliver` explicitly
/// PREPENDS them ahead of the coded slice on a keyframe (`hevcParameterSetsAVCC`). An HEVC IDR
/// access unit therefore carries its **VPS (nal type 32) / SPS (33) / PPS (34)** inline, ahead of
/// the coded slice — which is what this type pulls back out.
///
/// The client decoder needs a `CMVideoFormatDescription` built from those three
/// parameter sets (`CMVideoFormatDescriptionCreateFromHEVCParameterSets`) before it
/// can decode the first slice. This type does the **pure** part — walking the
/// length-prefixed NAL units of a keyframe and pulling out the VPS/SPS/PPS payloads —
/// so it is unit-testable with ZERO VideoToolbox dependency (the hang-safety rule).
/// `VideoDecoder` consumes the result to build the format description.
///
/// HEVC NAL header (2 bytes): `forbidden_zero_bit(1) | nal_unit_type(6) | layer(6) |
/// tid(3)`. The type is `(firstByte >> 1) & 0x3F`.
public enum HEVCParameterSets {
    /// HEVC NAL unit types we care about (Rec. ITU-T H.265 Table 7-1).
    public static let vpsType: UInt8 = 32
    public static let spsType: UInt8 = 33
    public static let ppsType: UInt8 = 34
    /// IDR slice types (a coded keyframe slice): IDR_W_RADL (19) / IDR_N_LP (20).
    public static let idrWRADL: UInt8 = 19
    public static let idrNLP: UInt8 = 20

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

    /// The HEVC `nal_unit_type` of a single NAL-unit payload (the bytes WITHOUT the
    /// AVCC length prefix). Returns `nil` for an empty unit.
    public static func nalType(of unit: Data) -> UInt8? {
        guard let first = unit.first else { return nil }
        return (first >> 1) & 0x3F
    }

    /// Whether an AVCC buffer's NAL units include a coded IDR slice — i.e. this frame
    /// is a self-contained decode anchor that carries its own parameter sets.
    public static func containsIDR(_ avcc: Data) -> Bool {
        for unit in NALUnit.split(avcc) {
            if let type = nalType(of: unit), type == idrWRADL || type == idrNLP { return true }
        }
        return false
    }

    /// Pulls the VPS/SPS/PPS payloads out of an AVCC keyframe buffer. Returns `nil`
    /// unless all three parameter sets are present (an incomplete set cannot build a
    /// format description, and the decoder must wait for a full IDR).
    ///
    /// Takes the LAST of each (an access unit normally has one each; if duplicated,
    /// the trailing set is the active one for the slices that follow).
    public static func extract(from avcc: Data) -> ParameterSets? {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        for unit in NALUnit.split(avcc) {
            switch nalType(of: unit) {
            case vpsType: vps = unit
            case spsType: sps = unit
            case ppsType: pps = unit
            default: break
            }
        }
        guard let vps, let sps, let pps else { return nil }
        return ParameterSets(vps: vps, sps: sps, pps: pps)
    }
}
