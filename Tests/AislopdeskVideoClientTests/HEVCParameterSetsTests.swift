import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// PURE HEVC parameter-set extraction: walk the length-prefixed NAL units of an AVCC
/// keyframe and pull out VPS(32)/SPS(33)/PPS(34), and detect an IDR slice (19/20). NO
/// VideoToolbox — the format-description build is the GUI-only step.
final class HEVCParameterSetsTests: XCTestCase {
    /// Builds a single NAL-unit payload whose HEVC `nal_unit_type` is `type`, followed
    /// by `extra` filler bytes. HEVC NAL header byte 0 = `forbidden(1) type(6) hi(1)`,
    /// so `type` sits in bits 1..6: `firstByte = type << 1`.
    private func nal(type: UInt8, extra: [UInt8] = [0x00, 0x01]) -> Data {
        Data([type << 1, 0x01] + extra) // 2-byte HEVC NAL header + payload
    }

    func testNalTypeDecodesFromHeaderByte() {
        XCTAssertEqual(HEVCParameterSets.nalType(of: nal(type: 32)), 32) // VPS
        XCTAssertEqual(HEVCParameterSets.nalType(of: nal(type: 33)), 33) // SPS
        XCTAssertEqual(HEVCParameterSets.nalType(of: nal(type: 34)), 34) // PPS
        XCTAssertEqual(HEVCParameterSets.nalType(of: nal(type: 19)), 19) // IDR_W_RADL
        XCTAssertNil(HEVCParameterSets.nalType(of: Data()))
    }

    func testExtractAllThreeParameterSets() {
        let vps = nal(type: 32, extra: [0xAA])
        let sps = nal(type: 33, extra: [0xBB, 0xCC])
        let pps = nal(type: 34, extra: [0xDD])
        let slice = nal(type: 19, extra: [0x10, 0x20, 0x30])
        let avcc = NALUnit.join([vps, sps, pps, slice])

        let sets = HEVCParameterSets.extract(from: avcc)
        XCTAssertNotNil(sets)
        XCTAssertEqual(sets?.vps, vps)
        XCTAssertEqual(sets?.sps, sps)
        XCTAssertEqual(sets?.pps, pps)
        XCTAssertEqual(sets?.ordered, [vps, sps, pps])
    }

    func testExtractReturnsNilWhenAParameterSetIsMissing() {
        // Missing PPS — cannot build a format description.
        let avcc = NALUnit.join([nal(type: 32), nal(type: 33), nal(type: 19)])
        XCTAssertNil(HEVCParameterSets.extract(from: avcc))
    }

    func testExtractTakesTrailingDuplicate() {
        // Two SPS — the active one for the following slices is the last.
        let sps1 = nal(type: 33, extra: [0x01])
        let sps2 = nal(type: 33, extra: [0x02, 0x03])
        let avcc = NALUnit.join([nal(type: 32), sps1, sps2, nal(type: 34), nal(type: 20)])
        XCTAssertEqual(HEVCParameterSets.extract(from: avcc)?.sps, sps2)
    }

    func testContainsIDR() {
        XCTAssertTrue(HEVCParameterSets.containsIDR(NALUnit.join([nal(type: 32), nal(type: 19)])))
        XCTAssertTrue(HEVCParameterSets.containsIDR(NALUnit.join([nal(type: 20)])))
        // A delta frame (slice type 1 = TRAIL_R) carries no IDR.
        XCTAssertFalse(HEVCParameterSets.containsIDR(NALUnit.join([nal(type: 1)])))
    }
}
